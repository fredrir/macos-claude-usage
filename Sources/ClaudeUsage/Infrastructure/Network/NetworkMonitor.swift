import Foundation
import Network

@MainActor
final class NetworkMonitor {
    private let monitor = NWPathMonitor()
    private(set) var isOnline = true
    var onReconnect: (() -> Void)?

    func start() {
        monitor.pathUpdateHandler = { [weak self] path in
            let online = path.status == .satisfied
            Task { @MainActor in self?.update(online: online) }
        }
        monitor.start(queue: DispatchQueue(label: "com.fredrir.ClaudeUsage.network"))
    }

    private func update(online: Bool) {
        let reconnected = online && !isOnline
        isOnline = online
        if reconnected { onReconnect?() }
    }
}

extension URLError {
    var isConnectivityFailure: Bool {
        switch code {
        case .notConnectedToInternet, .networkConnectionLost, .cannotFindHost,
            .cannotConnectToHost, .dnsLookupFailed, .timedOut, .dataNotAllowed,
            .internationalRoamingOff, .callIsActive:
            true
        default:
            false
        }
    }
}
