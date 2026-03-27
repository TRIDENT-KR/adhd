import Foundation
import Network
import Combine

// MARK: - NetworkMonitor
/// NWPathMonitor 기반 실시간 네트워크 상태 감지.
/// - isConnected       : 현재 네트워크 연결 여부
/// - isOfflineBannerVisible : 오프라인 배너 표시 여부 (3초 후 자동 해제)
final class NetworkMonitor: ObservableObject {

    // MARK: - Singleton
    static let shared = NetworkMonitor()

    // MARK: - Published State
    @Published private(set) var isConnected: Bool = true
    @Published private(set) var isOfflineBannerVisible: Bool = false
    @Published private(set) var isBackOnlineBannerVisible: Bool = false

    // MARK: - Private
    private let monitor = NWPathMonitor()
    private let queue   = DispatchQueue(label: "com.waitwhat.networkmonitor", qos: .utility)
    /// 배너를 숨기는 타이머 작업 — 새 이벤트 발생 시 이전 타이머를 무효화합니다.
    private var bannerWorkItem: DispatchWorkItem?

    private init() {
        monitor.pathUpdateHandler = { [weak self] path in
            guard let self else { return }
            let connected = path.status == .satisfied
            DispatchQueue.main.async {
                let wasConnected = self.isConnected
                self.isConnected = connected

                // ── Trigger 1: 네트워크 단절 최초 감지 시 배너 표시 ──
                if wasConnected && !connected {
                    self.showOfflineBannerTemporarily()
                }
                // ── Trigger 2: 네트워크 복구 시 "Back online" 배너 표시 ──
                if !wasConnected && connected {
                    self.showBackOnlineBannerTemporarily()
                }
            }
        }
        monitor.start(queue: queue)
    }

    /// "Back online" 배너를 숨기는 타이머 작업
    private var backOnlineWorkItem: DispatchWorkItem?

    deinit {
        monitor.cancel()
        bannerWorkItem?.cancel()
        backOnlineWorkItem?.cancel()
    }

    // MARK: - Public API
    /// 오프라인 배너를 3초간 표시 후 자동으로 숨깁니다.
    /// 짧은 간격으로 반복 호출되더라도 타이머가 리셋되어 중복 표시를 방지합니다.
    func showOfflineBannerTemporarily() {
        // 이전 타이머 취소
        bannerWorkItem?.cancel()

        isOfflineBannerVisible = true

        let work = DispatchWorkItem { [weak self] in
            self?.isOfflineBannerVisible = false
        }
        bannerWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.0, execute: work)
    }

    /// "Back online" 배너를 2초간 표시 후 자동으로 숨깁니다.
    func showBackOnlineBannerTemporarily() {
        backOnlineWorkItem?.cancel()

        isBackOnlineBannerVisible = true

        let work = DispatchWorkItem { [weak self] in
            self?.isBackOnlineBannerVisible = false
        }
        backOnlineWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0, execute: work)
    }
}
