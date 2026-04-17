import AVFoundation

/// Fetches and parses synced/plain lyrics for a song.
///
/// Priority:
///   1. Embedded lyrics from audio file metadata (ID3 USLT, Vorbis Comments)
///   2. LRCLib API (synced lyrics preferred, plain as fallback)
///   3. Navidrome getLyrics.view API
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
            case embedded, lrclib, navidrome
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
        cache[songId] = result
        return result
    }

    func invalidate(songId: String) {
        cache[songId] = nil
    }

    // MARK: - Fetch chain

    private func doFetch(songId: String, title: String, artist: String) async -> LyricsResult {
        print("[LyricsService] doFetch: songId=\(songId) title='\(title)' artist='\(artist)'")

        // 1. Try embedded lyrics from audio file metadata
        let embedded = await fetchEmbedded(songId: songId)
        if let embedded {
            print("[LyricsService] Found embedded: \(embedded.lines.count) lines, synced=\(embedded.isSynced)")
        }

        // If embedded lyrics are good quality (synced + more than 1 line), use them directly
        if let embedded, embedded.isSynced, embedded.lines.count > 1 {
            print("[LyricsService] ✓ Using embedded lyrics (good quality)")
            return embedded
        }

        // 2. Try LRCLib (better source for synced lyrics)
        if let lrclib = await fetchLRCLib(title: title, artist: artist) {
            print("[LyricsService] ✓ Found LRCLib lyrics: \(lrclib.lines.count) lines, synced=\(lrclib.isSynced)")
            return lrclib
        }
        print("[LyricsService] ✗ No LRCLib lyrics")

        // 3. Try Navidrome getLyrics
        if let nd = await fetchNavidrome(title: title, artist: artist) {
            print("[LyricsService] ✓ Found Navidrome lyrics: \(nd.lines.count) lines")
            return nd
        }
        print("[LyricsService] ✗ No Navidrome lyrics")

        // 4. Fallback: use embedded even if low quality (unsynced or single line)
        if let embedded {
            print("[LyricsService] ✓ Falling back to embedded lyrics (low quality)")
            return embedded
        }

        print("[LyricsService] ✗ No lyrics found — returning empty")
        return .empty
    }

    // MARK: - 1. Embedded lyrics (AVAsset metadata)

    private func fetchEmbedded(songId: String) async -> LyricsResult? {
        guard let url = NavidromeService.shared.streamURL(songId: songId) else { return nil }

        let asset = AVURLAsset(url: url)
        do {
            // Load only metadata — does not download the full audio file
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
            let (data, response) = try await URLSession.shared.data(for: request)
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

    // MARK: - 3. Navidrome getLyrics

    private func fetchNavidrome(title: String, artist: String) async -> LyricsResult? {
        guard !title.isEmpty,
              let creds = NavidromeService.shared.credentials,
              let token = creds.token,
              let base = URL(string: creds.serverUrl) else { return nil }

        let u = creds.username.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? creds.username
        let p = token.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? token
        let encodedArtist = artist.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? artist
        let encodedTitle = title.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? title

        let urlStr = "\(base)/rest/getLyrics.view?u=\(u)&p=\(p)&v=1.16.0&c=audiorr&f=json&artist=\(encodedArtist)&title=\(encodedTitle)"
        guard let url = URL(string: urlStr) else { return nil }

        do {
            let (data, response) = try await URLSession.shared.data(from: url)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { return nil }
            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let subsonicResponse = json["subsonic-response"] as? [String: Any],
                  let lyrics = subsonicResponse["lyrics"] as? [String: Any],
                  let text = lyrics["value"] as? String, !text.isEmpty
            else { return nil }

            let parsed = parseLRC(text)
            if !parsed.isEmpty {
                return LyricsResult(lines: parsed, isSynced: true, source: .navidrome)
            }

            let lines = text.components(separatedBy: .newlines)
                .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
                .enumerated()
                .map { LyricLine(id: $0.offset, time: -1, text: $0.element) }
            if !lines.isEmpty {
                return LyricsResult(lines: lines, isSynced: false, source: .navidrome)
            }
        } catch {}
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
