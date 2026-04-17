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
            .modifier(OptionalHeroSource(id: "artist_\(artist.id)", namespace: heroNamespace))

            Text(artist.name)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(titleColor)
                .lineLimit(2)
                .multilineTextAlignment(.center)
                .frame(width: size)
        }
        .task(id: artist.id) {
            await loadAvatar()
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
        // Check in-memory cache first
        if let cached = ArtistImageCache.shared.image(for: artist.id) {
            avatarImage = cached
            didFinishLoading = true
            return
        }

        guard let url = await NavidromeService.shared.artistAvatarURL(artistId: artist.id) else {
            withAnimation(.easeOut(duration: 0.25)) { didFinishLoading = true }
            return
        }

        guard let (data, _) = try? await URLSession.shared.data(from: url),
              let img = UIImage(data: data) else {
            withAnimation(.easeOut(duration: 0.25)) { didFinishLoading = true }
            return
        }

        ArtistImageCache.shared.setImage(img, for: artist.id)
        withAnimation(.easeOut(duration: 0.25)) {
            avatarImage = img
            didFinishLoading = true
        }
    }
}

// MARK: - Conditional hero source modifier

private struct OptionalHeroSource: ViewModifier {
    let id: String
    let namespace: Namespace.ID?

    func body(content: Content) -> some View {
        if let ns = namespace {
            content.matchedGeometryEffect(id: id, in: ns)
        } else {
            content
        }
    }
}

// MARK: - In-memory image cache for artist avatars

final class ArtistImageCache: @unchecked Sendable {
    static let shared = ArtistImageCache()

    private let cache = NSCache<NSString, UIImage>()

    private init() {
        cache.countLimit = 200
    }

    func image(for artistId: String) -> UIImage? {
        cache.object(forKey: artistId as NSString)
    }

    func setImage(_ image: UIImage, for artistId: String) {
        cache.setObject(image, forKey: artistId as NSString)
    }
}
