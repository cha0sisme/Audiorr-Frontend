import Foundation
import SwiftUI
import UIKit

/// Fuente única de verdad del estado de favoritos (Subsonic star/unstar).
///
/// Las filas de canción, el menú contextual y el NowPlayingViewer leen
/// `starredIds` directamente — un solo fetch (`getStarred2`) alimenta toda la
/// UI, sin estados duplicados por vista. El toggle es optimista: el Set se
/// actualiza al instante y se revierte solo si Navidrome rechaza la llamada.
@MainActor @Observable
final class FavoritesStore {
    static let shared = FavoritesStore()

    /// IDs de las canciones favoritas del usuario actual.
    private(set) var starredIds: Set<String> = []

    /// `true` tras la primera carga con éxito. Mientras es `false` la UI no
    /// debe asumir "no es favorita" como verdad firme (el gutter simplemente
    /// no pinta estrella, que es el mismo estado visual).
    private(set) var isLoaded = false

    private init() {
        // Carga inicial perezosa: el primer acceso al singleton (primera fila
        // de canción renderizada) dispara el fetch.
        Task { await refresh() }

        // Recargar al volver a foreground (toggles hechos desde otros
        // clientes: web, Navidrome nativo) y tras login (usuario nuevo).
        NotificationCenter.default.addObserver(
            forName: UIApplication.willEnterForegroundNotification,
            object: nil, queue: .main
        ) { _ in
            Task { @MainActor in await FavoritesStore.shared.refresh() }
        }
        NotificationCenter.default.addObserver(
            forName: .audiorrDidLogin,
            object: nil, queue: .main
        ) { _ in
            Task { @MainActor in
                // Credenciales nuevas: el Set del usuario anterior no vale.
                FavoritesStore.shared.starredIds = []
                FavoritesStore.shared.isLoaded = false
                await FavoritesStore.shared.refresh()
            }
        }
    }

    func isStarred(_ songId: String) -> Bool {
        starredIds.contains(songId)
    }

    /// Resincroniza el Set desde Navidrome. Si la llamada falla (red/auth),
    /// conserva el estado local en vez de vaciarlo.
    func refresh() async {
        guard NavidromeService.shared.isConfigured else { return }
        guard let songs = await NavidromeService.shared.getStarredSongs() else { return }
        starredIds = Set(songs.map(\.id))
        isLoaded = true
    }

    /// Alterna el favorito de una canción. Optimista: la UI cambia ya; si
    /// Navidrome rechaza (sin red, auth caída), se revierte al estado previo.
    func toggle(songId: String) {
        guard !songId.isEmpty else { return }
        let wasStarred = starredIds.contains(songId)
        if wasStarred {
            starredIds.remove(songId)
        } else {
            starredIds.insert(songId)
        }

        Task {
            let ok = wasStarred
                ? await NavidromeService.shared.unstar(id: songId)
                : await NavidromeService.shared.star(id: songId)

            if !ok {
                // Rollback — solo si nadie lo volvió a tocar entre medias.
                if wasStarred {
                    starredIds.insert(songId)
                } else {
                    starredIds.remove(songId)
                }
                return
            }

            // Con backend: avisar para que resincronice la playlist
            // "Favoritos" materializada (fire-and-forget — si falla, el
            // cron de reconciliación del backend lo recoge en ≤15 min).
            if BackendState.shared.isAvailable {
                try? await BackendService.shared.syncStarred()
            }
        }
    }
}
