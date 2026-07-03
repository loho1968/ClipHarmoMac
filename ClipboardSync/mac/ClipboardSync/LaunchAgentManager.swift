import Foundation

/// 管理 LaunchAgent，实现开机自启
enum LaunchAgentManager {
    private static let label = "com.clipboardsync.agent"
    private static let plistName = "\(label).plist"

    /// ~/Library/LaunchAgents 目录
    private static var launchAgentsDir: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents")
    }

    /// plist 文件路径
    private static var plistURL: URL {
        launchAgentsDir.appendingPathComponent(plistName)
    }

    /// 是否已注册（plist 文件存在）
    static var isEnabled: Bool {
        FileManager.default.fileExists(atPath: plistURL.path)
    }

    /// 获取当前可执行文件的绝对路径
    private static var executablePath: String {
        // CommandLine.arguments[0] 在 swift run 下可能是相对路径，需要解析
        let rawPath = CommandLine.arguments[0]
        // 如果是绝对路径直接解析 symlinks，否则拼接当前目录
        let resolved: String
        if rawPath.hasPrefix("/") {
            resolved = rawPath
        } else {
            resolved = FileManager.default.currentDirectoryPath + "/" + rawPath
        }
        // 解析符号链接，标准化路径
        return (resolved as NSString).resolvingSymlinksInPath
            .replacingOccurrences(of: "//", with: "/")
    }

    /// 注册 LaunchAgent（开机自启）
    static func enable() {
        // 确保目录存在
        try? FileManager.default.createDirectory(at: launchAgentsDir, withIntermediateDirectories: true)

        let plist: [String: Any] = [
            "Label": label,
            "ProgramArguments": [executablePath],
            "RunAtLoad": true,
            "KeepAlive": true,
            "ProcessType": "Background"
        ]

        do {
            let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
            try data.write(to: plistURL)
            print("[LaunchAgent] plist 已写入: \(plistURL.path)")

            // 加载到 launchd
            runLaunchCtl(command: "load")
        } catch {
            print("[LaunchAgent] 写入 plist 失败: \(error)")
        }
    }

    /// 注销 LaunchAgent（取消开机自启）
    static func disable() {
        // 先从 launchd 卸载
        runLaunchCtl(command: "unload")

        // 删除 plist 文件
        if FileManager.default.fileExists(atPath: plistURL.path) {
            try? FileManager.default.removeItem(at: plistURL)
            print("[LaunchAgent] plist 已删除: \(plistURL.path)")
        }
    }

    /// 执行 launchctl load/unload
    private static func runLaunchCtl(command: String) {
        let task = Process()
        task.launchPath = "/bin/launchctl"
        task.arguments = [command, plistURL.path]
        task.standardOutput = FileHandle.nullDevice
        task.standardError = FileHandle.nullDevice
        do {
            try task.run()
            task.waitUntilExit()
            print("[LaunchAgent] launchctl \(command) 结果: \(task.terminationStatus == 0 ? "成功" : "失败(\(task.terminationStatus))")")
        } catch {
            print("[LaunchAgent] launchctl \(command) 异常: \(error)")
        }
    }
}
