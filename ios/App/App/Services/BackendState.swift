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

    private init() {
        // Re-check whenever the network comes back online
        withObservationTracking {
            _ = NetworkMonitor.shared.isConnected
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                if NetworkMonitor.shared.isConnected {
                    self.check()
                } else {
                    self.isAvailable = false
                }
            }
        }
    }

    /// Trigger a fresh availability check. Safe to call from anywhere; coalesces concurrent calls.
    /// Retries once after 3s on failure (transient network issues).
    func check() {
        guard checkTask == nil else { return }
        isChecking = true
        checkTask = Task {
            let result = await NavidromeService.shared.checkBackendAvailable()
            // Bail early if cancelled (invalidateAndRecheck started a new task)
            guard !Task.isCancelled else { return }
            if result {
                self.isAvailable = true
            } else {
                // Show unavailable immediately so UI doesn't wait for retry
                self.isAvailable = false
                // Retry once after 3s — handles transient timeouts on slow networks
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                guard !Task.isCancelled else { return }
                NavidromeService.shared.invalidateBackendAvailableCache()
                let retry = await NavidromeService.shared.checkBackendAvailable()
                guard !Task.isCancelled else { return }
                self.isAvailable = retry
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
        isAvailable = false
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
                    self.invalidateAndRecheck()
                } else {
                    self.isAvailable = false
                    self.observeNetwork()
                }
            }
        }
    }
}
