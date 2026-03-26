import Foundation
import Network
import Combine

// MARK: - NetworkMonitor
/// NWPathMonitor 기반 실시간 네트워크 상태 감지.
/// @Published isConnected를 구독해 오프라인 배너를 표시합니다.
final class NetworkMonitor: ObservableObject {

    static let shared = NetworkMonitor()

    @Published private(set) var isConnected: Bool = true

    private let monitor = NWPathMonitor()
    private let queue   = DispatchQueue(label: "com.waitwhat.networkmonitor", qos: .utility)

    private init() {
        monitor.pathUpdateHandler = { [weak self] path in
            DispatchQueue.main.async {
                self?.isConnected = path.status == .satisfied
            }
        }
        monitor.start(queue: queue)
    }

    deinit {
        monitor.cancel()
    }
}
