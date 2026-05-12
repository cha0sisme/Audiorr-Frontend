import SwiftUI

/// Sheet nativo iOS que lista los artistas de una canción cuando viene con
/// `song.artists[]` (OpenSubsonic) y tiene más de un artista. Se invoca desde
/// el menú contextual de `SongListView` y de `NowPlayingViewerView`.
///
/// Patrón:
/// - `NavigationStack` + `List` (look-and-feel Apple Music estándar).
/// - `.presentationDetents([.medium, .large])` para que el usuario pueda
///   ampliar si hay muchos artistas.
/// - Cada row carga su avatar de forma independiente con `ArtistImageCache`
///   (mismo cache que el resto de la app — si ya visitaste ese perfil, sale
///   instantáneo).
/// - Tap en row → cierra la sheet y dispara `onSelect(artist)` con el
///   `NavidromeArtist` mínimo. El host decide cómo navegar (NavigationLink
///   en SongListView, `pendingNavigation` en NowPlayingViewerView).
struct ViewArtistsSheet: View {
    @Environment(\.dismiss) private var dismiss
    let artists: [ItemArtist]
    let songTitle: String?
    let onSelect: (NavidromeArtist) -> Void

    var body: some View {
        NavigationStack {
            List {
                if let title = songTitle, !title.isEmpty {
                    Section {
                        ForEach(artists) { artist in
                            row(for: artist)
                        }
                    } header: {
                        Text(title)
                            .font(.system(size: 13))
                            .foregroundStyle(.secondary)
                            .textCase(nil)
                    }
                } else {
                    ForEach(artists) { artist in
                        row(for: artist)
                    }
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle(L.artistsSheetTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(L.close) { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }

    @ViewBuilder
    private func row(for artist: ItemArtist) -> some View {
        Button {
            // Dismissamos antes de propagar el select para que el handler del
            // host pueda hacer push de navegación sin pelearse con la sheet
            // todavía visible (en Now Playing es crítico — el viewer también
            // está colapsándose).
            dismiss()
            onSelect(NavidromeArtist(id: artist.id, name: artist.name, albumCount: nil))
        } label: {
            HStack(spacing: 12) {
                ViewArtistsSheetAvatar(artistId: artist.id, name: artist.name)
                    .frame(width: 44, height: 44)

                Text(artist.name)
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)

                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.tertiary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Avatar circular (carga independiente por row)

/// Avatar circular 44×44 para el sheet — cada instancia resuelve su propia
/// imagen a través de `ArtistImageCache` (RAM + disk + coalescing). Si el
/// artista ya fue visitado o pintado en otra parte, sale del cache de RAM
/// sin red. Si no, se descarga en background y aparece con un fade.
private struct ViewArtistsSheetAvatar: View {
    let artistId: String
    let name: String

    @State private var image: UIImage?
    @State private var didLoad = false

    /// Color HSL determinístico desde el nombre — mismo cálculo que
    /// `ArtistCardView.nameColor` para coherencia visual entre vistas.
    private var fallbackColor: Color {
        let hash = name.unicodeScalars.reduce(0) { ($0 + Int($1.value)) % 360 }
        return Color(hue: Double(hash) / 360.0, saturation: 0.45, brightness: 0.50)
    }

    var body: some View {
        ZStack {
            if let img = image {
                Image(uiImage: img)
                    .resizable()
                    .scaledToFill()
            } else if didLoad {
                // Sin avatar disponible — inicial coloreada (mismo patrón
                // que ArtistCardView para que las cards y el sheet hablen
                // el mismo lenguaje visual).
                fallbackColor.opacity(0.25)
                    .overlay(
                        Text(String(name.prefix(1)).uppercased())
                            .font(.system(size: 18, weight: .bold, design: .rounded))
                            .foregroundStyle(fallbackColor)
                    )
            } else {
                Circle()
                    .fill(Color(.systemGray5))
            }
        }
        .clipShape(Circle())
        .overlay(Circle().stroke(Color(.separator).opacity(0.15), lineWidth: 0.5))
        .task(id: artistId) { await loadAvatar() }
    }

    private func loadAvatar() async {
        // 1. Cache hit instantáneo
        if let cached = ArtistImageCache.shared.image(for: artistId) {
            withAnimation(.easeOut(duration: 0.18)) {
                image = cached
                didLoad = true
            }
            return
        }
        // 2. Resolver URL del avatar (NavidromeService cachea 5 min internamente)
        guard let url = await NavidromeService.shared.artistAvatarURL(artistId: artistId) else {
            withAnimation(.easeOut(duration: 0.18)) { didLoad = true }
            return
        }
        // 3. Descarga con coalescing (mismo path que ArtistCardView)
        if let img = await ArtistImageCache.shared.loadImage(artistId: artistId, url: url) {
            withAnimation(.easeOut(duration: 0.22)) {
                image = img
                didLoad = true
            }
        } else {
            withAnimation(.easeOut(duration: 0.18)) { didLoad = true }
        }
    }
}
