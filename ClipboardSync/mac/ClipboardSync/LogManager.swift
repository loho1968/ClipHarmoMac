import Foundation

/// 应用内诊断日志管理器
/// - 内存环形缓冲（最多 1000 条）
/// - 异步持久化到 ~/.clipboardsync/logs/app.log（App 重启后仍可查看）
/// - 供 UI 查看 / 复制 / 清除，方便把日志导出给开发者分析连接问题
final class LogManager {
    static let shared = LogManager()

    /// 内存中最多保留的行数
    private static let maxLines = 1000
    /// 日志文件大小上限（超过后重新开始写，防止无限增长）
    private static let maxFileBytes = 512 * 1024

    private var lines: [String] = []
    private let lock = NSLock()
    private let writeQueue = DispatchQueue(label: "com.clipboardsync.logwriter")
    private let logFileURL: URL

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "MM-dd HH:mm:ss.SSS"
        return f
    }()

    private init() {
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".clipboardsync", isDirectory: true)
            .appendingPathComponent("logs", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        logFileURL = dir.appendingPathComponent("app.log")
    }

    /// 记录一条日志（带时间戳），同时输出到控制台
    func log(_ message: String) {
        let line = "[\(Self.timeFormatter.string(from: Date()))] \(message)"
        print(line)

        lock.lock()
        lines.append(line)
        if lines.count > Self.maxLines {
            lines.removeFirst(lines.count - Self.maxLines)
        }
        lock.unlock()

        writeQueue.async { [weak self] in
            guard let self else { return }
            self.appendToFile(line)
        }
    }

    /// 获取全部日志文本（供 UI 显示 / 复制）
    var allText: String {
        lock.lock()
        defer { lock.unlock() }
        return lines.joined(separator: "\n")
    }

    /// 清除内存与文件日志
    func clear() {
        lock.lock()
        lines.removeAll()
        lock.unlock()
        writeQueue.async { [weak self] in
            try? FileManager.default.removeItem(at: self?.logFileURL ?? URL(fileURLWithPath: "/dev/null"))
        }
    }

    // MARK: - 文件写入

    private func appendToFile(_ line: String) {
        let fm = FileManager.default
        // 文件过大时滚动：重命名旧的，重新开始
        if let size = (try? fm.attributesOfItem(atPath: logFileURL.path)[.size] as? Int), size > Self.maxFileBytes {
            try? fm.removeItem(at: logFileURL)
        }
        let data = (line + "\n").data(using: .utf8) ?? Data()
        if fm.fileExists(atPath: logFileURL.path),
           let handle = try? FileHandle(forWritingTo: logFileURL) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        } else {
            try? data.write(to: logFileURL)
        }
    }
}

/// 全局日志函数：替代 print，同时写入 LogManager（UI 可查看/复制）
func clipLog(_ message: String) {
    LogManager.shared.log(message)
}
