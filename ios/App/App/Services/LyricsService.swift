import AVFoundation

/// Fetches and parses synced/plain lyrics for a song.
///
/// Política (gated por `BackendState.isAvailable`):
///   - Embedded sincronizado (USLT/SYLT/iTunes lyrics LRC) → siempre se prefiere.
///   - Si embedded no es sync y backend disponible → LRCLib (solo si devuelve sync).
///   - Si backend no disponible → fallback a embedded plano (mejor que nada offline).
///   - Online sin sync (ni embedded ni LRCLib) → vacío. No se muestran letras planas
///     cuando hay backend porque hemos decidido que "no nos interesan letras sin sync".
///
/// No se consulta Navidrome porque su API `getLyrics.view` solo expone texto plano
/// sin timestamps.
@MainActor
final class LyricsService {
    static let shared = LyricsService()

    struct LyricLine: Identifiable, Equatable {
        let id: Int          // index
        let time: Double     // seconds (-1 for unsynced)
        let text: String
    }

    struct LyricsResult: Equatable {
        let lines: [LyricLine]
        let isSynced: Bool
        let source: Source

        enum Source: String {
            case embedded, lrclib
        }

        static let empty = LyricsResult(lines: [], isSynced: false, source: .embedded)
    }

    // Cache: songId → result
    private var cache: [String: LyricsResult] = [:]
    private var pending: [String: Task<LyricsResult, Never>] = [:]

    private init() {}

    /// Fetch lyrics for a song. Returns cached result if available.
    func fetch(songId: String, title: String, artist: String) async -> LyricsResult {
        if let cached = cache[songId] { return cached }

        if let existing = pending[songId] {
            return await existing.value
        }

        let task = Task<LyricsResult, Never> {
            await doFetch(songId: songId, title: title, artist: artist)
        }
        pending[songId] = task
        let result = await task.value
        pending[songId] = nil
        // Don't cache empty results — they typically come from a race where
        // state.title arrived after state.songId (so LRCLib + Navidrome had
        // nothing to query). The retry path in NowPlayingViewerView resets
        // its dedup guard on title change and calls fetch() again; without
        // this guard the second call would just re-serve the cached empty.
        // Songs that genuinely have no lyrics anywhere will re-fetch on
        // subsequent viewer opens (cheap: LRCLib + Navidrome both 404 fast).
        if !result.lines.isEmpty {
            cache[songId] = result
        }
        return result
    }

    func invalidate(songId: String) {
        cache[songId] = nil
    }

    // MARK: - Fetch chain

    private func doFetch(songId: String, title: String, artist: String) async -> LyricsResult {
        let backendUp = BackendState.shared.isAvailable
        print("[LyricsService] doFetch: songId=\(songId) title='\(title)' artist='\(artist)' backendUp=\(backendUp)")

        // Embedded siempre. AVAsset.load(.metadata) puede colgarse en streams
        // remotos lentos, así que el helper aplica un timeout de 3s.
        let embedded = await fetchEmbeddedWithTimeout(songId: songId)
        if let embedded {
            print("[LyricsService] Embedded: \(embedded.lines.count) lines, synced=\(embedded.isSynced)")
        } else {
            print("[LyricsService] Embedded: ausente")
        }

        // 1. Embedded sync de calidad (≥2 líneas) → gana siempre, evita red.
        if let embedded, embedded.isSynced, embedded.lines.count > 1 {
            print("[LyricsService] ✓ Embedded sync")
            return embedded
        }

        // 2. Backend disponible → LRCLib. Solo aceptamos sync. Si LRCLib
        //    devuelve plano o 404, online se queda en vacío (decisión de
        //    producto: sin sync no interesa cuando hay alternativa).
        if backendUp {
            if let lrclib = await fetchLRCLib(title: title, artist: artist), lrclib.isSynced {
                print("[LyricsService] ✓ LRCLib sync")
                return lrclib
            }
            print("[LyricsService] ✗ LRCLib sin sync o 404 — vacío (online)")
            return .empty
        }

        // 3. Offline: aceptamos embedded plano como fallback degradado.
        //    Mejor mostrar texto sin auto-scroll que no mostrar nada cuando
        //    no hay otra fuente disponible.
        if let embedded {
            print("[LyricsService] ✓ Embedded \(embedded.isSynced ? "sync corto" : "plain") (offline fallback)")
            return embedded
        }

        print("[LyricsService] ✗ Sin letras")
        return .empty
    }

    /// Embedded metadata read with a 3 s upper bound — same withTaskGroup race
    /// pattern as before, just hoisted to a helper so doFetch can fire it as
    /// `async let` alongside LRCLib + Navidrome.
    private func fetchEmbeddedWithTimeout(songId: String) async -> LyricsResult? {
        await withTaskGroup(of: LyricsResult?.self) { group in
            group.addTask { await self.fetchEmbedded(songId: songId) }
            group.addTask {
                try? await Task.sleep(for: .seconds(3))
                return nil // timeout sentinel
            }
            for await result in group {
                if result != nil {
                    group.cancelAll()
                    return result
                }
            }
            return nil
        }
    }

    // MARK: - 1. Embedded lyrics (AVAsset metadata)

    private func fetchEmbedded(songId: String) async -> LyricsResult? {
        // Prefer local cached file (instant disk read) over remote stream URL
        let url: URL
        if let cachedURL = AudioFileLoader.shared.cachedFileURL(for: songId) {
            url = cachedURL
        } else if let streamURL = NavidromeService.shared.streamURL(songId: songId) {
            url = streamURL
        } else {
            return nil
        }

        let asset = AVURLAsset(url: url)
        do {
            let metadata = try await asset.load(.metadata)

            // Search for lyrics in common metadata spaces
            let lyricsText = await findLyricsInMetadata(metadata)
            guard let text = lyricsText, !text.isEmpty else { return nil }

            let parsed = parseLRC(text)
            if !parsed.isEmpty {
                return LyricsResult(lines: parsed, isSynced: true, source: .embedded)
            }

            // Plain text lyrics (no timestamps)
            let plain = text.components(separatedBy: .newlines)
                .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
                .enumerated()
                .map { LyricLine(id: $0.offset, time: -1, text: $0.element) }
            if !plain.isEmpty {
                return LyricsResult(lines: plain, isSynced: false, source: .embedded)
            }
        } catch {
            // Metadata load failed — skip to next source
        }
        return nil
    }

    private func findLyricsInMetadata(_ items: [AVMetadataItem]) async -> String? {
        // ID3v2 USLT (unsynchronized lyrics)
        if let item = AVMetadataItem.metadataItems(from: items,
                filteredByIdentifier: .id3MetadataUnsynchronizedLyric).first,
           let text = try? await item.load(.stringValue), !text.isEmpty {
            return text
        }

        // iTunes lyrics
        if let item = AVMetadataItem.metadataItems(from: items,
                filteredByIdentifier: .iTunesMetadataLyrics).first,
           let text = try? await item.load(.stringValue), !text.isEmpty {
            return text
        }

        // Fallback: scan all items for anything that looks like lyrics
        for item in items {
            if let key = item.commonKey, key == .commonKeyDescription {
                continue
            }
            if let identifier = item.identifier?.rawValue.lowercased(),
               identifier.contains("lyric"),
               let text = try? await item.load(.stringValue), !text.isEmpty {
                return text
            }
        }

        return nil
    }

    // MARK: - 2. LRCLib API

    private func fetchLRCLib(title: String, artist: String) async -> LyricsResult? {
        guard !title.isEmpty, !artist.isEmpty else { return nil }

        let encodedArtist = artist.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? artist
        let encodedTitle = title.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? title
        let urlStr = "https://lrclib.net/api/get?artist_name=\(encodedArtist)&track_name=\(encodedTitle)"
        guard let url = URL(string: urlStr) else { return nil }

        do {
            var request = URLRequest(url: url)
            request.setValue("Audiorr/1.0", forHTTPHeaderField: "User-Agent")
            // Sesión `interactive`: el usuario abrió el viewer y espera letras.
            let (data, response) = try await AudiorrNetwork.interactive.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { return nil }
            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }

            // Prefer synced lyrics
            if let synced = json["syncedLyrics"] as? String, !synced.isEmpty {
                let parsed = parseLRC(synced)
                if !parsed.isEmpty {
                    return LyricsResult(lines: parsed, isSynced: true, source: .lrclib)
                }
            }

            // Plain lyrics fallback
            if let plain = json["plainLyrics"] as? String, !plain.isEmpty {
                let lines = plain.components(separatedBy: .newlines)
                    .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
                    .enumerated()
                    .map { LyricLine(id: $0.offset, time: -1, text: $0.element) }
                if !lines.isEmpty {
                    return LyricsResult(lines: lines, isSynced: false, source: .lrclib)
                }
            }
        } catch {
            // Network error — skip
        }
        return nil
    }

    // MARK: - LRC Parser

    /// Parses LRC format: [MM:SS.ms] text
    /// Same regex as React: /\[(\d+):(\d+(?:\.\d+)?)\]\s*(.*)/
    func parseLRC(_ text: String) -> [LyricLine] {
        let pattern = #"\[(\d+):(\d+(?:\.\d+)?)\]\s*(.*)"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }

        var lines: [LyricLine] = []

        for line in text.components(separatedBy: .newlines) {
            let nsLine = line as NSString
            let range = NSRange(location: 0, length: nsLine.length)
            guard let match = regex.firstMatch(in: line, range: range) else { continue }

            let minutes = Double(nsLine.substring(with: match.range(at: 1))) ?? 0
            let seconds = Double(nsLine.substring(with: match.range(at: 2))) ?? 0
            let text = nsLine.substring(with: match.range(at: 3))
                .trimmingCharacters(in: .whitespaces)

            // Skip empty lines
            if text.isEmpty { continue }

            let time = minutes * 60 + seconds
            lines.append(LyricLine(id: lines.count, time: time, text: text))
        }

        return lines.sorted { $0.time < $1.time }
    }
}
