import SwiftUI

// MARK: - Shared album card (Apple Music style)

/// Reusable album cell — cover art, title, explicit badge, configurable subtitle.
/// Used in HomeView, ArtistDetailView, SeeAllGridView.
///
/// Two axes via `axis`:
/// - `.horizontal`: fixed-width card for horizontal scroll rows.
/// - `.grid`: flexible width that fills its container (LazyVGrid).
///
/// Two subtitle modes via `subtitle`:
/// - `.artist`: shows the album artist name (default — HomeView, SeeAllGridView).
/// - `.year`: shows the release year (ArtistDetailView discography).
struct AlbumCardView: View {
    let album: NavidromeAlbum
    var subtitle: Subtitle = .artist
    /// Pass `true` when the host page has a light background (palette-driven).
    /// When `nil`, standard system colors are used.
    var isLight: Bool? = nil
    var axis: Axis = .horizontal
    var size: CGFloat = 150
    var heroNamespace: Namespace.ID?

    @State private var coverImage: UIImage?
    @State private var retryCount = 0

    private let nowPlaying = NowPlayingState.shared

    private var isGrid: Bool { axis == .grid }
    private var titleColor: Color {
        guard let isLight else { return .primary }
        return isLight ? .black : .white
    }
    private var subtitleColor: Color {
        guard let isLight else { return .secondary }
        return isLight ? Color.black.opacity(0.55) : Color.white.opacity(0.55)
    }

    private var isCurrentContext: Bool {
        nowPlaying.isVisible && nowPlaying.contextUri == "album:\(album.id)"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ZStack(alignment: .bottomLeading) {
                ZStack {
                    if let img = coverImage {
                        Image(uiImage: img)
                            .resizable()
                            .scaledToFill()
                    } else {
                        coverPlaceholder
                    }
                }
                .if(isGrid) { $0.aspectRatio(1, contentMode: .fit) }
                .if(!isGrid) { $0.frame(width: size, height: size) }
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .shadow(color: .black.opacity(0.18), radius: 6, y: 3)
                .if(heroNamespace != nil) { $0.matchedTransitionSource(id: album.id, in: heroNamespace!) }

                if isCurrentContext {
                    NowPlayingIndicator(
                        isPlaying: nowPlaying.isPlaying,
                        bpm: nowPlaying.currentBpm,
                        color: Color.white,
                        barWidth: 3, height: 14
                    )
                    .padding(8)
                    .background(Material.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .padding(6)
                }
            }

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 5) {
                    Text(album.name)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(titleColor)
                        .lineLimit(1)

                    if album.isExplicit {
                        ExplicitBadge(color: subtitleColor)
                    }
                }
                .frame(maxWidth: isGrid ? .infinity : size, alignment: .leading)

                subtitleView
                    .frame(maxWidth: isGrid ? .infinity : size, alignment: .leading)
            }
        }
        .task(id: album.id) { await loadCover() }
        .onAppear {
            // Retry if image was purged from NSCache or previous load failed
            if coverImage == nil {
                if let cached = AlbumCoverCache.shared.image(for: album.coverArt) {
                    coverImage = cached
                } else {
                    Task { await loadCover() }
                }
            }
        }
    }

    private func loadCover() async {
        if let cached = AlbumCoverCache.shared.image(for: album.coverArt) {
            coverImage = cached
            return
        }
        guard let url = NavidromeService.shared.coverURL(id: album.coverArt, size: 300) else { return }

        // Retry up to 2 times with backoff
        for attempt in 0..<3 {
            if attempt > 0 {
                try? await Task.sleep(nanoseconds: UInt64(attempt) * 1_000_000_000)
            }
            guard let (data, _) = try? await URLSession.shared.data(from: url),
                  let img = UIImage(data: data) else { continue }
            AlbumCoverCache.shared.setImage(img, for: album.coverArt)
            coverImage = img
            return
        }
    }

    @ViewBuilder
    private var subtitleView: some View {
        switch subtitle {
        case .artist:
            Text(album.artist)
                .font(.caption)
                .foregroundStyle(subtitleColor)
                .lineLimit(1)
        case .year:
            if let year = album.year {
                Text(String(year))
                    .font(.caption)
                    .foregroundStyle(subtitleColor)
            }
        }
    }

    private var coverPlaceholder: some View {
        SkeletonView()
    }

    enum Subtitle {
        case artist
        case year
    }

    enum Axis {
        case horizontal, grid
    }
}

// MARK: - In-memory image cache for album covers

final class AlbumCoverCache: @unchecked Sendable {
    static let shared = AlbumCoverCache()

    private let cache = NSCache<NSString, UIImage>()

    private init() {
        cache.countLimit = 300
    }

    func image(for coverArtId: String?) -> UIImage? {
        guard let id = coverArtId else { return nil }
        return cache.object(forKey: id as NSString)
    }

    func setImage(_ image: UIImage, for coverArtId: String?) {
        guard let id = coverArtId else { return }
        cache.setObject(image, forKey: id as NSString)
    }
}

// MARK: - Conditional modifier helper

extension View {
    @ViewBuilder
    func `if`<T: View>(_ condition: Bool, transform: (Self) -> T) -> some View {
        if condition {
            transform(self)
        } else {
            self
        }
    }
}

// MARK: - Animated equalizer bars (now-playing indicator)

/// Realistic equalizer indicator. Each bar layers 5 sine waves at
/// incommensurate frequencies — the result is quasi-random, aperiodic
/// motion that never visibly repeats, similar to real audio levels.
/// BPM scales the overall tempo; without BPM a natural ~120 BPM feel is used.
/// TimelineView drives at display refresh rate — no Timer/state needed.
struct NowPlayingIndicator: View {
    var isPlaying: Bool
    var bpm: Double? = nil
    var color: Color = .accentColor
    var barWidth: CGFloat = 3
    var height: CGFloat = 14
    var spacing: CGFloat = 1.5

    /// Per-bar frequency seeds (irrational ratios → never repeats).
    /// Each bar simulates a different frequency band (bass / mid / treble).
    private static let seeds: [[Double]] = [
        [3.07, 5.13, 8.91, 1.53, 13.27],  // bass — heavier, slower swings
        [4.31, 7.29, 2.17, 11.03, 6.43],   // mid — medium movement
        [5.67, 3.41, 9.73, 7.19, 2.89],    // treble — more erratic
    ]

    private var speedScale: Double {
        guard let bpm else { return 1.0 }
        return max(0.5, min(2.5, bpm / 120.0))
    }

    var body: some View {
        TimelineView(.animation(minimumInterval: nil, paused: !isPlaying)) { timeline in
            let t = isPlaying ? timeline.date.timeIntervalSinceReferenceDate : 0
            HStack(alignment: .bottom, spacing: spacing) {
                ForEach(0..<3, id: \.self) { i in
                    let f = Self.seeds[i]
                    let s = speedScale
                    // 5 layered sines at incommensurate frequencies → aperiodic motion
                    let v = 0.35 * sin(t * f[0] * s)
                          + 0.25 * sin(t * f[1] * s + 1.7)
                          + 0.20 * sin(t * f[2] * s + 3.1)
                          + 0.12 * sin(t * f[3] * s + 5.3)
                          + 0.08 * sin(t * f[4] * s + 7.9)
                    // v ∈ ~[-1,1], map to 0.10…1.0 with bias toward mid-range
                    let norm = (v + 1) / 2            // 0…1
                    let shaped = norm * norm * 0.6 + norm * 0.4  // slight peak bias
                    let fraction = isPlaying
                        ? 0.10 + 0.90 * shaped
                        : 0.12
                    RoundedRectangle(cornerRadius: barWidth / 2)
                        .fill(color)
                        .frame(width: barWidth, height: height * fraction)
                        // No animation during playback — TimelineView drives at 60/120fps.
                        // Slow ease-out only for the pause→rest transition.
                        .animation(isPlaying ? nil : .easeOut(duration: 0.4), value: isPlaying)
                }
            }
            .frame(height: height, alignment: .bottom)
        }
    }
}

// MARK: - Cached cover thumbnail (shared — used in queue, search, add-to-playlist)

/// Small cover thumbnail backed by AlbumCoverCache.
/// Survives view recreation without flashing.
struct CachedCoverThumbnail: View {
    let coverArt: String?
    var size: CGFloat = 48
    var cornerRadius: CGFloat = 6

    /// Convenience: accept either `coverArt` (String?) or legacy `id` label.
    init(coverArt: String?, size: CGFloat = 48, cornerRadius: CGFloat = 6) {
        self.coverArt = coverArt
        self.size = size
        self.cornerRadius = cornerRadius
    }

    /// Legacy init for SearchView (parameter named `id`).
    init(id: String?, cornerRadius: CGFloat = 6) {
        self.coverArt = id
        self.size = 48
        self.cornerRadius = cornerRadius
    }

    @State private var image: UIImage?

    var body: some View {
        ZStack {
            if let img = image {
                Image(uiImage: img)
                    .resizable()
                    .scaledToFill()
            } else {
                Color(.tertiarySystemFill)
                    .overlay(
                        Image(systemName: "music.note")
                            .foregroundStyle(.quaternary)
                            .font(.system(size: size * 0.33))
                    )
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        .onAppear {
            if image == nil, let coverArt, !coverArt.isEmpty {
                image = AlbumCoverCache.shared.image(for: coverArt)
            }
        }
        .task(id: coverArt) {
            guard let coverArt, !coverArt.isEmpty else { return }
            if let cached = AlbumCoverCache.shared.image(for: coverArt) {
                image = cached
                return
            }
            guard let url = NavidromeService.shared.coverURL(id: coverArt, size: Int(size * 2)),
                  let (data, _) = try? await URLSession.shared.data(from: url),
                  let img = UIImage(data: data) else { return }
            AlbumCoverCache.shared.setImage(img, for: coverArt)
            image = img
        }
    }
}

