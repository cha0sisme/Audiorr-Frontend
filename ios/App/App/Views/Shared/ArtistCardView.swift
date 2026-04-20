import SwiftUI

// MARK: - Shared artist card (Apple Music style circle + name)

/// Reusable artist cell — circular avatar, name label.
/// Used in ArtistsView, ArtistDetailView (similar artists), SeeAllGridView.
///
/// Shows a skeleton shimmer while the avatar loads, then crossfades to the
/// real image (or a colored initial if no avatar is available).
struct ArtistCardView: View {
    let artist: NavidromeArtist
    var size: CGFloat = 140
    /// Pass `true` when the host page has a light background (palette-driven).
    /// When `nil`, standard system colors are used.
    var isLight: Bool? = nil
    var showStats: Bool = false
    var heroNamespace: Namespace.ID?

    @State private var avatarImage: UIImage?
    @State private var didFinishLoading = false

    private var nameColor: Color {
        let hash = artist.name.unicodeScalars.reduce(0) { ($0 + Int($1.value)) % 360 }
        return Color(hue: Double(hash) / 360.0, saturation: 0.45, brightness: 0.50)
    }

    private var titleColor: Color {
        guard let isLight else { return .primary }
        return isLight ? .black : .white
    }
    private var subtitleColor: Color {
        guard let isLight else { return .secondary }
        return isLight ? Color.black.opacity(0.55) : Color.white.opacity(0.55)
    }

    var body: some View {
        VStack(spacing: 10) {
            ZStack {
                if let img = avatarImage {
                    Image(uiImage: img)
                        .resizable()
                        .scaledToFill()
                        .transition(.opacity)
                } else if didFinishLoading {
                    // No avatar available — show colored initial
                    nameColor.opacity(0.25)
                        .overlay(
                            Text(String(artist.name.prefix(1)).uppercased())
                                .font(.system(size: size * 0.36, weight: .bold, design: .rounded))
                                .foregroundStyle(nameColor)
                        )
                        .transition(.opacity)
                } else {
                    // Skeleton shimmer while loading
                    Circle()
                        .fill(skeletonColor)
                        .overlay(
                            Circle()
                                .fill(skeletonHighlight)
                                .phaseAnimator([false, true]) { content, phase in
                                    content.opacity(phase ? 0.6 : 0.3)
                                } animation: { _ in .easeInOut(duration: 0.9) }
                        )
                }
            }
            .frame(width: size, height: size)
            .clipShape(Circle())
            .overlay(Circle().stroke(Color(.separator).opacity(0.15), lineWidth: 0.5))
            .if(heroNamespace != nil) { $0.matchedTransitionSource(id: artist.id, in: heroNamespace!) }

            Text(artist.name)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(titleColor)
                .lineLimit(2)
                .multilineTextAlignment(.center)
                .frame(width: size)

            if showStats, let count = artist.albumCount, count > 0 {
                Text("\(count) \(count == 1 ? "álbum" : "álbumes")")
                    .font(.system(size: 12))
                    .foregroundStyle(subtitleColor)
                    .lineLimit(1)
                    .frame(width: size)
            }
        }
        .task(id: artist.id) { await loadAvatar() }
        .onAppear {
            if avatarImage == nil && !didFinishLoading {
                if let cached = ArtistImageCache.shared.image(for: artist.id) {
                    avatarImage = cached
                    didFinishLoading = true
                } else {
                    Task { await loadAvatar() }
                }
            }
        }
    }

    private var skeletonColor: Color {
        guard let isLight else { return Color(.systemGray5) }
        return isLight ? Color.black.opacity(0.08) : Color.white.opacity(0.10)
    }

    private var skeletonHighlight: Color {
        guard let isLight else { return Color(.systemGray4) }
        return isLight ? Color.black.opacity(0.12) : Color.white.opacity(0.15)
    }

    private func loadAvatar() async {
        // 1. Check disk + memory cache (instant)
        if let cached = ArtistImageCache.shared.image(for: artist.id) {
            avatarImage = cached
            didFinishLoading = true
            return
        }

        // 2. Resolve avatar URL (cached in NavidromeService for 5 min)
        guard let url = await NavidromeService.shared.artistAvatarURL(artistId: artist.id) else {
            withAnimation(Anim.small) { didFinishLoading = true }
            return
        }

        // 3. Download with coalescing (deduplicates parallel requests for the same artist)
        if let img = await ArtistImageCache.shared.loadImage(artistId: artist.id, url: url) {
            withAnimation(Anim.small) {
                avatarImage = img
                didFinishLoading = true
            }
        } else {
            withAnimation(Anim.small) { didFinishLoading = true }
        }
    }
}

// MARK: - Two-tier image cache for artist avatars (RAM + disk)

final class ArtistImageCache: @unchecked Sendable {
    static let shared = ArtistImageCache()

    private let memory = NSCache<NSString, UIImage>()
    private let diskDir: URL
    private let ioQueue = DispatchQueue(label: "artist.image.cache", qos: .utility)

    /// Actor-isolated in-flight tracker to coalesce duplicate downloads.
    private let coordinator = DownloadCoordinator()

    private init() {
        memory.countLimit = 300

        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        diskDir = caches.appendingPathComponent("artist_avatars", isDirectory: true)
        try? FileManager.default.createDirectory(at: diskDir, withIntermediateDirectories: true)
    }

    private func diskPath(for artistId: String) -> URL {
        diskDir.appendingPathComponent(artistId + ".jpg")
    }

    // MARK: Read

    func image(for artistId: String) -> UIImage? {
        // 1. RAM
        if let img = memory.object(forKey: artistId as NSString) { return img }
        // 2. Disk (sync — small JPEGs, fast SSD)
        let path = diskPath(for: artistId)
        guard let data = try? Data(contentsOf: path),
              let img = UIImage(data: data) else { return nil }
        memory.setObject(img, forKey: artistId as NSString)
        return img
    }

    // MARK: Write

    func setImage(_ image: UIImage, for artistId: String) {
        memory.setObject(image, forKey: artistId as NSString)
        let path = diskPath(for: artistId)
        ioQueue.async {
            if let data = image.jpegData(compressionQuality: 0.82) {
                try? data.write(to: path, options: .atomic)
            }
        }
    }

    // MARK: Coalesced download

    /// Returns a cached image or downloads it, coalescing duplicate in-flight requests.
    func loadImage(artistId: String, url: URL) async -> UIImage? {
        if let cached = image(for: artistId) { return cached }
        let cache = self
        return await coordinator.download(artistId: artistId) {
            guard let (data, _) = try? await URLSession.shared.data(from: url),
                  let img = UIImage(data: data) else { return nil }
            cache.setImage(img, for: artistId)
            return img
        }
    }
}

/// Actor that deduplicates concurrent downloads for the same artist.
private actor DownloadCoordinator {
    private var inFlight: [String: Task<UIImage?, Never>] = [:]

    func download(artistId: String, work: @Sendable @escaping () async -> UIImage?) async -> UIImage? {
        if let existing = inFlight[artistId] {
            return await existing.value
        }
        let task = Task<UIImage?, Never> { await work() }
        inFlight[artistId] = task
        let result = await task.value
        inFlight.removeValue(forKey: artistId)
        return result
    }
}
