import Foundation
import UIKit

/// Centralized, reactive backend-availability state.
/// All views observe `BackendState.shared.isAvailable` instead of
/// calling `checkBackendAvailable()` independently.
@MainActor @Observable
final class BackendState {

    static let shared = BackendState()

    /// Whether the Audiorr backend at <navidrome-host>:2999 is reachable.
    private(set) var isAvailable: Bool = false

    /// True while the initial check is in flight (lets UI show shimmer vs hiding sections).
    private(set) var isChecking: Bool = false

    private var checkTask: Task<Void, Never>?

    /// v12 (audit 2026-05-05) — punto unico de mutacion de `isAvailable`.
    /// Mantiene en sync el espejo `TransitionDiagnostics.backendAvailable`
    /// (consultado por publishers nonisolated). Cuando el backend pasa a
    /// no-disponible, tambien fuerza apagar la captura de diagnosticos para
    /// que no haya "datos zombies" colandose hasta que el usuario abra Settings.
    private func setAvailable(_ value: Bool) {
        self.isAvailable = value
        TransitionDiagnostics.backendAvailable = value
        if !value {
            // Backend caido → cortar captura inmediatamente. La history existente
            // se conserva (el usuario debe poder exportar lo que ya tenia).
            Task { @MainActor in
                TransitionDiagnostics.shared.handleBackendUnavailable()
            }
        }
    }

    private init() {
        observeNetwork()
        observeForeground()
    }

    /// Trigger a fresh availability check. Safe to call from anywhere; coalesces concurrent calls.
    /// Retries once after 3s on failure (transient network issues).
    func check() {
        guard checkTask == nil else { return }
        // Gate: sin credenciales Navidrome configuradas no hay nada que
        // autenticar contra el backend Audiorr — pingear /api/health desde
        // un dispositivo recien instalado solo gasta CF y revela actividad
        // sin proposito. Cuando el usuario complete el flujo de LoginView,
        // `saveCredentials` invocara `invalidateAndRecheck()` y entonces si
        // pingearemos.
        guard NavidromeService.shared.credentials != nil else {
            setAvailable(false)
            return
        }
        // Gate anti-trafico: si AuthTokenStore ya sabe que el backend nos
        // rechaza (403 whitelist 24h) o nos limita (429 Retry-After), no
        // pierdas un round-trip pingueando /api/health — el resultado va a
        // ser "available" pero las features REST recibiran 401/403/429 de
        // todos modos. Marcamos isAvailable=false directamente para que los
        // callers no intenten requests innecesarias al backend del operador.
        if AuthTokenStore.shared.backendUnauthorizedUntil() != nil ||
           AuthTokenStore.shared.lockedUntil() != nil ||
           AuthTokenStore.shared.consecutiveLoginFailuresUntil() != nil {
            setAvailable(false)
            return
        }
        isChecking = true
        let wasAvailable = isAvailable
        checkTask = Task {
            let result = await NavidromeService.shared.checkBackendAvailable()
            // Bail early if cancelled (invalidateAndRecheck started a new task)
            guard !Task.isCancelled else { return }
            if result {
                self.setAvailable(true)
            } else {
                // Show unavailable immediately so UI doesn't wait for retry
                self.setAvailable(false)
                // Retry once after 3s — handles transient timeouts on slow networks
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                guard !Task.isCancelled else { return }
                NavidromeService.shared.invalidateBackendAvailableCache()
                let retry = await NavidromeService.shared.checkBackendAvailable()
                guard !Task.isCancelled else { return }
                self.setAvailable(retry)
            }
            // On transition unavailable→available, re-pull cover hashes. Without
            // this, any PlaylistCoverView that rendered during the offline window
            // pinned a Navidrome-fallback JPG to disk under the playlistId key
            // *without* registering a content hash (setImage skips cachedHashes
            // when contentHashes[id] is nil). Those entries survive cold launch
            // and dominate the cache forever unless something forces a fresh
            // hash refresh — which `oldHash == nil` in registerContentHashes will
            // then invalidate, evicting the orphan and re-fetching from backend.
            if !wasAvailable && self.isAvailable {
                await NavidromeService.shared.refreshPlaylistCoverHashes()
                // Diagnostics history vive en backend (round 2026-05-10
                // diagnostics-backend-port). Si la app arrancó offline,
                // TransitionDiagnostics.init() encontró history vacía. Al
                // recuperar conexión, repoblar para que la UI no arranque
                // ciega permanentemente.
                await TransitionDiagnostics.shared.loadHistoryFromBackend()
            }
            self.isChecking = false
            self.checkTask = nil
        }
    }

    /// Call after login / credentials change to force a fresh check.
    func invalidateAndRecheck() {
        NavidromeService.shared.invalidateBackendAvailableCache()
        checkTask?.cancel()
        checkTask = nil
        check()
    }

    /// Mark as unavailable immediately (e.g. on logout).
    func reset() {
        checkTask?.cancel()
        checkTask = nil
        consecutiveInBandFailures = 0
        setAvailable(false)
        isChecking = false
    }

    // MARK: - In-band reachability (VPN → Cloudflare, audit 2026-06)

    /// Con Cloudflare el transporte es estable y ya no pingeamos /api/health
    /// de forma proactiva en cada flap. En su lugar, el propio tráfico REST
    /// informa del estado: `BackendService.performRequest` llama a estos
    /// hooks. El health-check proactivo queda reducido al arranque
    /// (`ContentView .task`) y al re-check de foreground.
    private var consecutiveInBandFailures = 0
    /// Fallos de transporte seguidos antes de marcar no-disponible. >1 para
    /// no parpadear ante un 502/timeout puntual de Cloudflare.
    private let inBandFailureThreshold = 2

    /// Una request REST real ha respondido 2xx: el backend está vivo y nos
    /// atiende. Confirma disponibilidad sin gastar un ping y resetea el
    /// contador de fallos. Un usuario sin backend (Navidrome puro) nunca llega
    /// aquí — sus requests reciben 401/403, que NO pasan por este hook —, así
    /// que el gate de UI no se enciende por error.
    func noteRequestSucceeded() {
        consecutiveInBandFailures = 0
        if !isAvailable {
            setAvailable(true)
        }
    }

    /// Una request REST ha fallado por transporte (sin red, timeout, 5xx).
    /// Tras `inBandFailureThreshold` fallos seguidos marcamos no-disponible.
    /// Los errores de auth/cuota (401/403/429) NO llaman aquí: ya los
    /// gestionan AuthTokenStore y sus gates, y no implican que el backend
    /// esté caído.
    func noteRequestFailed() {
        consecutiveInBandFailures += 1
        if consecutiveInBandFailures >= inBandFailureThreshold && isAvailable {
            setAvailable(false)
        }
    }

    // MARK: - Private

    /// Observa la conectividad de red. Solo reacciona a la **caída total** de
    /// red marcando no-disponible de inmediato (UX offline correcta). La
    /// recuperación ya NO dispara un re-check por cada flap: ese comportamiento
    /// nervioso existía para detectar la VPN cayéndose/volviendo, y con acceso
    /// por Cloudflare (transporte estable) sobra. La disponibilidad se
    /// reevalúa al volver a foreground (`observeForeground`) y cuando el propio
    /// tráfico REST vuelve a funcionar (inferencia in-band en BackendService).
    /// Se re-arma a sí misma porque `withObservationTracking` es one-shot.
    private func observeNetwork() {
        withObservationTracking {
            _ = NetworkMonitor.shared.isConnected
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                if !NetworkMonitor.shared.isConnected {
                    self.setAvailable(false)
                }
                self.observeNetwork()
            }
        }
    }

    /// Re-evalúa la disponibilidad al volver a primer plano. Sustituye al
    /// re-check por cada cambio de red: con un transporte estable basta con
    /// comprobar una vez por foreground, y cubre el caso "el backend del
    /// operador se cayó mientras la app estaba en background".
    private func observeForeground() {
        NotificationCenter.default.addObserver(
            forName: UIApplication.willEnterForegroundNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.invalidateAndRecheck()
            }
        }
    }
}
