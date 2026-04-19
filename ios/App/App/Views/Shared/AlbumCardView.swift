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
                        color: Color.white,
                        barWidth: 3, height: 14
                    )
                    .padding(8)
                    .background(Material.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
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

/// Shows 3 bars that animate when `isPlaying` is true, freezes when paused.
struct NowPlayingIndicator: View {
    var isPlaying: Bool
    var color: Color = .accentColor
    var barWidth: CGFloat = 3
    var height: CGFloat = 14
    var spacing: CGFloat = 1.5

    @State private var animating = false

    var body: some View {
        HStack(spacing: spacing) {
            bar(delay: 0.0, minScale: 0.3, maxScale: 1.0)
            bar(delay: 0.15, minScale: 0.2, maxScale: 0.85)
            bar(delay: 0.3, minScale: 0.35, maxScale: 0.95)
        }
        .frame(height: height)
        .onChange(of: isPlaying, initial: true) { _, playing in
            animating = playing
        }
    }

    private func bar(delay: Double, minScale: CGFloat, maxScale: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: barWidth / 2)
            .fill(color)
            .frame(width: barWidth, height: height)
            .scaleEffect(y: animating ? maxScale : minScale, anchor: .bottom)
            .animation(
                animating
                    ? .easeInOut(duration: 0.45)
                        .repeatForever(autoreverses: true)
                        .delay(delay)
                    : .easeOut(duration: 0.2),
                value: animating
            )
    }
}

