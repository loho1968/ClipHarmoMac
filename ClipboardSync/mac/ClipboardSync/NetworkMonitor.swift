import Foundation
import Network
import CoreWLAN

/// 网络变化监听器
/// 使用 NWPathMonitor 监听网络状态变化，WiFi SSID 变化时通知 SyncManager 重建 LAN 服务
class NetworkMonitor: ObservableObject {
    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "com.clipboardsync.networkmonitor")

    /// 当前 WiFi SSID
    @Published var currentSSID: String?

    /// 网络变化回调（WiFi 切换时触发）
    var onNetworkChange: (() -> Void)?

    private var previousSSID: String?

    func start() {
        previousSSID = CWWiFiClient.shared().interface()?.ssid()
        currentSSID = previousSSID

        monitor.pathUpdateHandler = { [weak self] path in
            guard let self else { return }

            let currentSSID = CWWiFiClient.shared().interface()?.ssid()

            DispatchQueue.main.async {
                self.currentSSID = currentSSID

                // 仅在 SSID 确实变化时触发回调
                if currentSSID != self.previousSSID {
                    let old = self.previousSSID ?? "无"
                    let new = currentSSID ?? "无"
                    print("[NetworkMonitor] WiFi changed: \(old) → \(new)")
                    self.previousSSID = currentSSID
                    self.onNetworkChange?()
                }
            }
        }

        monitor.start(queue: queue)
        print("[NetworkMonitor] Started, current SSID: \(currentSSID ?? "无")")
    }

    func stop() {
        monitor.cancel()
        print("[NetworkMonitor] Stopped")
    }
}
