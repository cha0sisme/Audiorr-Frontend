import Foundation
import Network

/// Monitors network connectivity using NWPathMonitor.
/// Observed by UI to show offline banners and filter content.
@MainActor @Observable
final class NetworkMonitor {

    static let shared = NetworkMonitor()

    /// Whether any network path is available.
    private(set) var isConnected: Bool = true

    /// Whether the current path is expensive (cellular).
    private(set) var isExpensive: Bool = false

    /// Whether the current path is constrained (Low Data Mode).
    private(set) var isConstrained: Bool = false

    private let monitor = NWPathMonitor()
    private let monitorQueue = DispatchQueue(label: "com.audiorr.networkmonitor", qos: .utility)
    private nonisolated(unsafe) var debounceWork: DispatchWorkItem?

    private init() {
        monitor.pathUpdateHandler = { [weak self] path in
            guard let self else { return }
            self.debounceWork?.cancel()
            let work = DispatchWorkItem { [weak self] in
                Task { @MainActor [weak self] in
                    self?.isConnected = path.status == .satisfied
                    self?.isExpensive = path.isExpensive
                    self?.isConstrained = path.isConstrained
                }
            }
            self.debounceWork = work
            self.monitorQueue.asyncAfter(deadline: .now() + 0.1, execute: work)
        }
        monitor.start(queue: monitorQueue)
    }

    deinit {
        monitor.cancel()
    }
}
