import AppKit
import SwiftUI
import Combine
import UserNotifications

/// 通知类别标识符
enum NotificationCategory {
    static let fileReceived = "FILE_RECEIVED"
}

/// 通知操作标识符
enum NotificationActionID {
    static let openFile = "OPEN_FILE"
    static let openFolder = "OPEN_FOLDER"
}

class AppDelegate: NSObject, NSApplicationDelegate {
    var statusItem: NSStatusItem!
    var popover: NSPopover!
    let syncManager = SyncManager()
    private var statusObserver: AnyCancellable?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // 单实例保护
        let bundleId = Bundle.main.bundleIdentifier ?? "com.clipboardsync.app"
        let runningApps = NSRunningApplication.runningApplications(withBundleIdentifier: bundleId)
        if runningApps.count > 1 {
            print("[AppDelegate] Another instance is already running, terminating this one")
            NSApp.terminate(nil)
            return
        }

        syncManager.start()

        // 创建 popover
        let popover = NSPopover()
        popover.contentSize = NSSize(width: 340, height: 520)
        popover.behavior = .transient
        popover.animates = true
        popover.contentViewController = NSHostingController(
            rootView: MainView(syncManager: syncManager)
        )
        self.popover = popover

        // 创建菜单栏图标
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.target = self
            button.action = #selector(togglePopover)
            updateStatusIcon(for: syncManager.status)
        } else {
            print("[AppDelegate] WARNING: status item button is nil!")
        }

        // 监听连接状态变化
        statusObserver = syncManager.$status.sink { [weak self] newStatus in
            self?.updateStatusIcon(for: newStatus)
        }

        // 收到内容时自动弹出菜单
        syncManager.onContentReceived = { [weak self] in
            self?.showPopover()
        }

        NSApp.setActivationPolicy(.accessory)
        setupNotifications()
    }

    // MARK: - 通知设置

    private func setupNotifications() {
        guard Bundle.main.bundleIdentifier != nil else {
            print("[AppDelegate] ⚠️ swift run 模式，跳过通知")
            return
        }

        // 只请求权限，不设 delegate。LSUIElement app 默认即后台模式，系统会自动弹横幅
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { granted, _ in
            print("[AppDelegate] UN 权限: \(granted ? "✅" : "❌")")
        }
        // NSUserNotificationCenter 不设 delegate，默认行为更可靠

        print("[AppDelegate] Bundle ID: \(Bundle.main.bundleIdentifier!)")
        print("[AppDelegate] ✅ 通知就绪")
    }

    // MARK: - 状态图标

    /// 打开菜单栏弹窗
    private func showPopover() {
        guard let button = statusItem?.button, !popover.isShown else { return }
        NSApp.activate(ignoringOtherApps: true)
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
    }

    private func updateStatusIcon(for status: SyncManager.SyncStatus) {
        guard let button = statusItem?.button else { return }

        let color: NSColor
        switch status {
        case .connected:    color = .systemGreen
        case .discovering:  color = .systemOrange
        case .disconnected: color = .systemGray
        }

        let symbolConfig = NSImage.SymbolConfiguration(pointSize: 16, weight: .medium)
            .applying(NSImage.SymbolConfiguration(paletteColors: [color]))
        let image = NSImage(systemSymbolName: "clipboard", accessibilityDescription: "ClipboardSync")?
            .withSymbolConfiguration(symbolConfig)
        image?.isTemplate = false
        button.image = image
    }

    @objc func togglePopover() {
        if let button = statusItem.button {
            if popover.isShown {
                popover.performClose(nil)
            } else {
                NSApp.activate(ignoringOtherApps: true)
                popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            }
        }
    }
}
