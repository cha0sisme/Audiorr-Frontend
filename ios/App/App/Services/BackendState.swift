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

    // MARK: - Entitlement por fases (2026-06-12)

    /// `true` si este dispositivo consiguió ALGUNA VEZ una respuesta 2xx
    /// AUTENTICADA (con Bearer) del backend — prueba simultánea de whitelist
    /// y de backend vivo. Decide si merece la pena sondear `/api/health`
    /// fuera del arranque: quien nunca conectó no genera tráfico recurrente.
    ///
    /// El ancla es el 2xx con Bearer y NO el health (público, responde a
    /// cualquiera) ni un 2xx cualquiera: las rutas soft del backend
    /// (canvas, artwork, covers) devuelven 2xx sin validar el Bearer, y
    /// `performRequest` puede salir sin Bearer cuando no hay sesión.
    /// Persistido en UserDefaults; se resetea al cambiar credenciales/logout.
    private(set) var everConnected: Bool = UserDefaults.standard.bool(forKey: BackendState.everConnectedKey)
    private static let everConnectedKey = "audiorr_backend_ever_connected"

    private func markEverConnected() {
        guard !everConnected else { return }
        everConnected = true
        UserDefaults.standard.set(true, forKey: Self.everConnectedKey)
    }

    /// Cuenta o server nuevos = entitlement nuevo. Lo invocan
    /// `saveCredentials` y `reset()` (logout); el siguiente 2xx con Bearer
    /// lo vuelve a marcar si el nuevo contexto tiene acceso.
    func resetEntitlement() {
        everConnected = false
        UserDefaults.standard.removeObject(forKey: Self.everConnectedKey)
    }

    private var checkTask: Task<Void, Never>?
    /// Sonda de auto-recuperación tras una caída detectada in-band. Único dueño
    /// (no se solapan sondas) — ver `scheduleRecoveryProbe()`.
    private var recoveryTask: Task<Void, Never>?

    /// v12 (audit 2026-05-05) — punto unico de mutacion de `isAvailable`.
    /// Mantiene en sync el espejo `TransitionDiagnostics.backendAvailable`
    /// (consultado por publishers nonisolated). Cuando el backend pasa a
    /// no-disponible, tambien fuerza apagar la captura de diagnosticos para
    /// que no haya "datos zombies" colandose hasta que el usuario abra Settings.
    private func setAvailable(_ value: Bool) {
        self.isAvailable = value
        TransitionDiagnostics.backendAvailable = value
        if value {
            // Recuperado por cualquier vía → la sonda de recuperación ya no aporta.
            recoveryTask?.cancel()
            recoveryTask = nil
        } else {
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
        recoveryTask?.cancel()
        recoveryTask = nil
        consecutiveInBandFailures = 0
        setAvailable(false)
        isChecking = false
        resetEntitlement()
    }

    // MARK: - In-band reachability (VPN → Cloudflare, audit 2026-06)

    /// Con Cloudflare el transporte es estable y ya no pingeamos /api/health
    /// de forma proactiva en cada flap. En su lugar, el propio tráfico REST
    /// informa del estado: `BackendService.performRequest` llama a estos
    /// hooks. El health-check proactivo queda reducido al arranque
    /// (`ContentView .task`), al login, y a las sondas de RECUPERACIÓN
    /// (foreground / vuelta de red, solo en estado caído + `everConnected`).
    private var consecutiveInBandFailures = 0
    /// Fallos de transporte seguidos antes de marcar no-disponible. >1 para
    /// no parpadear ante un 502/timeout puntual de Cloudflare.
    private let inBandFailureThreshold = 2

    /// Una request REST real ha respondido 2xx: el backend está vivo y nos
    /// atiende. Confirma disponibilidad sin gastar un ping y resetea el
    /// contador de fallos.
    ///
    /// `authenticated` indica si la request viajó con Bearer: solo entonces
    /// el 2xx prueba entitlement y marca `everConnected`. Las rutas soft
    /// (canvas, artwork, covers) responden 2xx sin validar el token, así que
    /// un 2xx sin Bearer NO puede activar la fase.
    func noteRequestSucceeded(authenticated: Bool = false) {
        consecutiveInBandFailures = 0
        if authenticated {
            markEverConnected()
        }
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
            scheduleRecoveryProbe()
        }
    }

    /// Tras una caída detectada in-band, sondea la recuperación con backoff en
    /// vez de quedar caído hasta el próximo foreground / cambio de red / reinicio
    /// — esa asimetría (caída rápida, recuperación inexistente) era la causa de
    /// "se pierde el backend y hay que cerrar y reabrir la app".
    ///
    /// Diseño:
    /// - **Único dueño**: una sola sonda viva a la vez; `setAvailable(true)` y
    ///   `reset()` la cancelan.
    /// - **Techo de intentos** + backoff: no martillea al backend/CF si está
    ///   caído de verdad.
    /// - **Pausa en segundo plano**: no gasta red/batería ni revela actividad
    ///   cuando la app no está en uso (el foreground ya tiene su propia sonda).
    /// - **Gates de auth/cuota mandan**: un 403/429 no es caída de transporte;
    ///   si están activos, deja de sondear (no reintroduce el martilleo que esos
    ///   gates evitan).
    /// - El health-check confirma el TRANSPORTE (CF + Node responden) y
    ///   desbloquea el gating; el primer tráfico REST autenticado que entonces
    ///   fluya CONFIRMA (`noteRequestSucceeded`) o REVIERTE (`noteRequestFailed`,
    ///   que vuelve a armar esta sonda). Así no marcamos "vivo" a ciegas por un
    ///   health público que no prueba auth.
    private func scheduleRecoveryProbe() {
        guard recoveryTask == nil else { return }
        // Backoff acotado (≈105 s en 6 intentos). Si tras esto sigue caído, el
        // foreground / cambio de red / reinicio retoman la recuperación.
        let backoffSeconds: [UInt64] = [3, 6, 12, 24, 30, 30]
        recoveryTask = Task { [weak self] in
            for delay in backoffSeconds {
                try? await Task.sleep(nanoseconds: delay * 1_000_000_000)
                guard let self, !Task.isCancelled else { return }
                if self.isAvailable { break }                  // ya recuperado por otra vía
                // En segundo plano no sondeamos; el foreground tiene su sonda.
                if UIApplication.shared.applicationState == .background { continue }
                // Sin credenciales o con gates de auth/cuota activos no hay nada
                // que recuperar pingueando: esos casos no son caída de transporte.
                guard NavidromeService.shared.credentials != nil,
                      AuthTokenStore.shared.backendUnauthorizedUntil() == nil,
                      AuthTokenStore.shared.lockedUntil() == nil,
                      AuthTokenStore.shared.consecutiveLoginFailuresUntil() == nil
                else { break }
                NavidromeService.shared.invalidateBackendAvailableCache()
                if await NavidromeService.shared.checkBackendAvailable() {
                    guard !Task.isCancelled else { return }
                    self.setAvailable(true)
                    break
                }
            }
            self?.recoveryTask = nil
        }
    }

    // MARK: - Private

    /// Observa la conectividad de red. La **caída total** marca no-disponible
    /// de inmediato (UX offline correcta). La **recuperación** solo dispara
    /// una sonda cuando estamos caídos Y este dispositivo conectó alguna vez
    /// (`everConnected`): es la única transición donde el ping aporta — sin
    /// ella, una red que vuelve en mitad de la sesión no se recuperaría hasta
    /// el próximo foreground. En estado sano no se pingea jamás por flaps
    /// (eso era de la era VPN; con Cloudflare el transporte es estable).
    /// Se re-arma a sí misma porque `withObservationTracking` es one-shot.
    private func observeNetwork() {
        withObservationTracking {
            _ = NetworkMonitor.shared.isConnected
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                if !NetworkMonitor.shared.isConnected {
                    self.setAvailable(false)
                } else if !self.isAvailable && self.everConnected {
                    self.invalidateAndRecheck()
                }
                self.observeNetwork()
            }
        }
    }

    /// Re-evalúa la disponibilidad al volver a primer plano — pero SOLO como
    /// sonda de recuperación (estado caído + `everConnected`). En estado sano
    /// el propio tráfico REST confirma la disponibilidad (inferencia in-band
    /// en BackendService) y el ping no aporta; y quien nunca conectó al
    /// backend no debe generar tráfico recurrente hacia él (su vía de
    /// descubrimiento es el check de arranque y el de login).
    private func observeForeground() {
        NotificationCenter.default.addObserver(
            forName: UIApplication.willEnterForegroundNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                if !self.isAvailable && self.everConnected {
                    self.invalidateAndRecheck()
                }
            }
        }
    }
}
