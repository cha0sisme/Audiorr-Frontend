import SwiftUI

// MARK: - Horizontal scroll section

/// Reusable horizontal-scroll row — albums, playlists, artists, etc.
/// Mirrors the React `HorizontalScrollSection.tsx` component.
///
/// Usage:
/// ```
/// HorizontalScrollSection(title: "Álbumes", isLight: isLight) {
///     ForEach(albums) { album in
///         NavigationLink(value: album) { AlbumCard(album: album) }
///     }
/// }
/// ```
///
/// The section:
/// - Renders an optional bold title + optional trailing action.
/// - Bleeds to the screen edges so items align with the app's edge padding.
/// - Does **not** own the color palette — callers pass `isLight` so the title
///   contrasts with the page background.
struct HorizontalScrollSection<Content: View, Action: View>: View {
    let title: String?
    /// Pass `true`/`false` for palette-driven pages. `nil` uses system colors.
    let isLight: Bool?
    let spacing: CGFloat
    /// Si se pasa, el encabezado se vuelve un `NavigationLink` con un chevron `>`
    /// (estilo Apple Music) que abre la sección completa en `SeeAllGridView`.
    let seeAll: SeeAllDestination?
    @ViewBuilder let content: () -> Content
    @ViewBuilder let action: () -> Action

    init(
        title: String? = nil,
        isLight: Bool? = nil,
        spacing: CGFloat = 14,
        seeAll: SeeAllDestination? = nil,
        @ViewBuilder content: @escaping () -> Content,
        @ViewBuilder action: @escaping () -> Action = { EmptyView() }
    ) {
        self.title = title
        self.isLight = isLight
        self.spacing = spacing
        self.seeAll = seeAll
        self.content = content
        self.action = action
    }

    private var titleColor: Color {
        guard let isLight else { return .primary }
        return isLight ? .black : .white
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if title != nil || seeAll != nil || Action.self != EmptyView.self {
                HStack(alignment: .firstTextBaseline) {
                    if let title {
                        if let seeAll {
                            // Encabezado tappable con chevron (Apple Music).
                            NavigationLink(value: seeAll) {
                                HStack(spacing: 5) {
                                    Text(title)
                                        .font(.system(size: 22, weight: .bold))
                                        .foregroundStyle(titleColor)
                                    Image(systemName: "chevron.right")
                                        .font(.system(size: 14, weight: .bold))
                                        .foregroundStyle(titleColor.opacity(0.35))
                                }
                            }
                            .buttonStyle(.plain)
                        } else {
                            Text(title)
                                .font(.system(size: 22, weight: .bold))
                                .foregroundStyle(titleColor)
                        }
                    }
                    Spacer(minLength: 8)
                    action()
                }
                .padding(.horizontal, 16)
            }

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: spacing) {
                    content()
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 4)
            }
        }
    }
}
