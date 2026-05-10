import Foundation

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
    private var networkDebounceTask: Task<Void, Never>?

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
        // Re-check whenever the network comes back online
        withObservationTracking {
            _ = NetworkMonitor.shared.isConnected
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                if NetworkMonitor.shared.isConnected {
                    self.debouncedCheck()
                } else {
                    self.setAvailable(false)
                }
            }
        }
    }

    /// Debounce network-triggered checks to avoid hammering on flaky connections
    private func debouncedCheck() {
        networkDebounceTask?.cancel()
        networkDebounceTask = Task {
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            guard !Task.isCancelled else { return }
            self.check()
        }
    }

    /// Trigger a fresh availability check. Safe to call from anywhere; coalesces concurrent calls.
    /// Retries once after 3s on failure (transient network issues).
    func check() {
        guard checkTask == nil else { return }
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
            // Re-observe network changes (withObservationTracking is one-shot)
            self.observeNetwork()
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
        setAvailable(false)
        isChecking = false
    }

    // MARK: - Private

    private func observeNetwork() {
        withObservationTracking {
            _ = NetworkMonitor.shared.isConnected
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                if NetworkMonitor.shared.isConnected {
                    self.networkDebounceTask?.cancel()
                    self.networkDebounceTask = Task {
                        try? await Task.sleep(nanoseconds: 2_000_000_000)
                        guard !Task.isCancelled else { return }
                        self.invalidateAndRecheck()
                    }
                } else {
                    self.setAvailable(false)
                    self.observeNetwork()
                }
            }
        }
    }
}
