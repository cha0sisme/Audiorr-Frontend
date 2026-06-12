import SwiftUI
import UIKit

// MARK: - Favorites virtual playlist (modo sin backend)

/// Playlist virtual "Favoritos" — muestra las canciones starred del usuario
/// como una playlist. No está respaldada por Navidrome como playlist real:
/// se alimenta de `getStarred2` en vivo (patrón DownloadsPlaylistView).
///
/// Solo se usa en modo SIN backend: con backend disponible, la playlist
/// "Favoritos" existe como playlist Navidrome real (la materializa y
/// sincroniza el backend) y llega por `getPlaylists` como una más.
/// El lenguaje visual (degradado azul + estrella blanca) replica la cover
/// que genera el backend para que ambos modos se vean iguales.
struct FavoritesPlaylistView: View {
    @State private var songs: [NavidromeSong] = []
    @State private var isLoading = true
    @State private var scrollY: CGFloat = 0

    private let favorites = FavoritesStore.shared

    /// Paleta azul brand (#0097fe → tonos profundos), coherente con la cover
    /// estrella generada por el backend.
    private let palette = AlbumPalette(
        primary:   UIColor(red: 0.0, green: 0.30, blue: 0.60, alpha: 1),
        secondary: UIColor(red: 0.0, green: 0.18, blue: 0.42, alpha: 1),
        accent:    UIColor(red: 0.0, green: 0.59, blue: 1.0, alpha: 1),
        isSolid:   false
    )

    private let heroHeight: CGFloat = 440

    private var scrollProgress: CGFloat { min(max(scrollY / heroHeight, 0), 1) }
    private var heroOpacity: CGFloat    { 1 - min(scrollProgress * 1.2, 0.92) }
    private var stickyOpacity: CGFloat  { min(max((scrollProgress - 0.55) / 0.25, 0), 1) }
    /// Stretchy header scale: proporcional al pull-down. Anchor `.bottom`
    /// para que el header gane altura hacia arriba en el rebound.
    private var stretchScale: CGFloat {
        let pullDown = max(0, -scrollY)
        return (heroHeight + pullDown) / heroHeight
    }

    private var pageBg: Color { Color(palette.pageBackgroundColor) }

    /// Lista viva: al quitar un favorito desde el menú ··· de la propia
    /// lista, el Set optimista del store lo filtra al instante sin refetch.
    /// Mientras el store no haya cargado, se muestra lo que trajo el fetch.
    private var visibleSongs: [NavidromeSong] {
        favorites.isLoaded
            ? songs.filter { favorites.isStarred($0.id) }
            : songs
    }

    var body: some View {
        ZStack(alignment: .top) {
            pageBg.ignoresSafeArea()

            ScrollView(showsIndicators: false) {
                VStack(spacing: 0) {
                    heroSection
                    songListSection
                    Spacer(minLength: 120)
                }
                .frame(maxWidth: .infinity)
            }
            .ignoresSafeArea(edges: .top)
            .onScrollGeometryChange(for: CGFloat.self) { $0.contentOffset.y } action: { _, y in
                scrollY = y
            }
        }
        .toolbarBackground(.hidden, for: .navigationBar)
        .toolbarColorScheme(.dark, for: .navigationBar)
        .environment(\.colorScheme, .dark)
        .tint(.white)
        .toolbar {
            ToolbarItem(placement: .principal) {
                Text(L.favorites)
                    .font(.headline)
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .opacity(stickyOpacity)
            }
        }
        .task { await loadSongs() }
    }

    private func loadSongs() async {
        isLoading = true
        // nil = fallo de red/auth: conservar lo que hubiera en vez de vaciar.
        if let starred = await NavidromeService.shared.getStarredSongs() {
            songs = starred
        }
        isLoading = false
    }

    // MARK: - Hero

    private var heroSection: some View {
        ZStack(alignment: .bottom) {
            // Background
            ZStack {
                LinearGradient(
                    colors: [Color(red: 0.0, green: 0.59, blue: 1.0).opacity(0.6),
                             Color(red: 0.0, green: 0.30, blue: 0.60).opacity(0.7)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )

                LinearGradient(
                    colors: [
                        Color.black.opacity(0.38),
                        Color.black.opacity(0.22),
                        Color.black.opacity(0.06)
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
            }
            .ignoresSafeArea(edges: .top)
            .frame(height: heroHeight)
            .overlay(alignment: .bottom) {
                LinearGradient(
                    colors: [.clear, pageBg],
                    startPoint: .top, endPoint: .bottom
                )
                .frame(height: heroHeight * 0.35)
            }
            .scaleEffect(stretchScale, anchor: .bottom)

            // Content
            VStack(spacing: 0) {
                Spacer(minLength: 100)

                // Cover icon — degradado + estrella, espejo de la cover backend
                ZStack {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: [Color(red: 0.0, green: 0.59, blue: 1.0),
                                         Color(red: 0.0, green: 0.30, blue: 0.60)],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                    Image(systemName: "star.fill")
                        .font(.system(size: 64, weight: .medium))
                        .foregroundStyle(.white.opacity(0.95))
                        .shadow(color: .black.opacity(0.25), radius: 12)
                }
                .frame(width: 190, height: 190)
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                .shadow(color: .black.opacity(0.55), radius: 22, x: 0, y: 8)

                Spacer(minLength: 20)

                // Title + metadata
                VStack(alignment: .center, spacing: 5) {
                    Text(L.favorites)
                        .font(.system(size: 26, weight: .bold))
                        .foregroundStyle(.white)

                    Text(L.songCount(visibleSongs.count))
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(.white.opacity(0.75))
                }
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.horizontal, 20)

                // Action buttons
                if !visibleSongs.isEmpty {
                    actionButtons
                        .padding(.top, 18)
                }

                Spacer(minLength: 28)
            }
            .frame(maxWidth: .infinity)
            .opacity(heroOpacity)
        }
        .frame(maxWidth: .infinity)
        .frame(height: heroHeight)
        .clipped()
    }

    private var actionButtons: some View {
        let fillColor = Color(palette.buttonFillColor)
        let labelColor: Color = palette.buttonUsesBlackText ? .black : .white

        return HStack(spacing: 12) {
            Button {
                PlayerService.shared.playPlaylist(visibleSongs, startingAt: 0,
                    contextUri: "favorites:all", contextName: L.favorites)
            } label: {
                Image(systemName: "play.fill")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(labelColor)
                    .frame(width: 40, height: 40)
                    .background(fillColor, in: Circle())
            }

            Button {
                PlayerService.shared.playPlaylist(visibleSongs.shuffled(), startingAt: 0,
                    contextUri: "favorites:all", contextName: L.favorites)
            } label: {
                Image(systemName: "shuffle")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(labelColor)
                    .frame(width: 40, height: 40)
                    .background(fillColor, in: Circle())
            }
        }
    }

    // MARK: - Song List

    @ViewBuilder
    private var songListSection: some View {
        if isLoading {
            ProgressView()
                .tint(.white)
                .padding(.top, 40)
        } else if visibleSongs.isEmpty {
            VStack(spacing: 12) {
                Image(systemName: "star")
                    .font(.system(size: 40))
                    .foregroundStyle(.white.opacity(0.3))
                Text(L.noFavoriteSongs)
                    .font(.subheadline)
                    .foregroundStyle(.white.opacity(0.5))
                Text(L.favoritesHint)
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.35))
                    .multilineTextAlignment(.center)
            }
            .padding(.top, 40)
            .padding(.horizontal, 32)
        } else {
            SongListView(
                songs: visibleSongs,
                palette: palette,
                showCover: true,
                contextUri: "favorites:all",
                contextName: L.favorites
            )
        }
    }
}
