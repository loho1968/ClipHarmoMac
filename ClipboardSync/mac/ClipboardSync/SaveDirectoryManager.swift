import Foundation
import AppKit

/// 保存目录管理器
/// 管理接收到的图片/文件的保存目录，支持记住上次目录、设置默认目录、恢复默认
final class SaveDirectoryManager {
    static let shared = SaveDirectoryManager()

    private let defaultsKey = "com.clipboardsync.saveDirectory_bookmark"

    /// 默认保存目录：~/Downloads/ClipboardSync
    var defaultDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Downloads")
            .appendingPathComponent("ClipboardSync")
    }

    /// 当前保存目录（优先读取记住的目录，否则使用默认目录）
    var currentDirectory: URL {
        if let url = resolveBookmark() {
            return url
        }
        return defaultDirectory
    }

    /// 是否已自定义保存目录
    var hasCustomDirectory: Bool {
        UserDefaults.standard.data(forKey: defaultsKey) != nil
    }

    // MARK: - 目录操作

    /// 设置并记忆保存目录
    func setDirectory(_ url: URL) {
        guard let bookmark = try? url.bookmarkData(
            options: .withSecurityScope,
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        ) else {
            print("[SaveDirectoryManager] Failed to create bookmark for: \(url.path)")
            return
        }
        UserDefaults.standard.set(bookmark, forKey: defaultsKey)
        print("[SaveDirectoryManager] Directory set: \(url.path)")
    }

    /// 恢复默认目录
    func resetToDefault() {
        UserDefaults.standard.removeObject(forKey: defaultsKey)
        print("[SaveDirectoryManager] Reset to default: \(defaultDirectory.path)")
    }

    /// 打开 NSOpenPanel 让用户选择保存目录
    /// 使用回调模式避免 SwiftUI Menu dismiss 动画阻塞 panel 弹出
    func promptChooseDirectory(completion: @escaping (URL?) -> Void) {
        // 延迟到下一个 runloop，等 Menu dismiss 完成后再弹出 panel
        DispatchQueue.main.async {
            let panel = NSOpenPanel()
            panel.canChooseDirectories = true
            panel.canChooseFiles = false
            panel.canCreateDirectories = true
            panel.message = "选择图片/文件接收后的保存目录"
            panel.prompt = "选择"
            panel.directoryURL = self.currentDirectory

            if panel.runModal() == .OK, let url = panel.url {
                self.setDirectory(url)
                completion(url)
            } else {
                completion(nil)
            }
        }
    }

    // MARK: - Private

    /// 从 UserDefaults 解析安全书签
    private func resolveBookmark() -> URL? {
        guard let data = UserDefaults.standard.data(forKey: defaultsKey) else { return nil }

        var isStale = false
        guard let url = try? URL(
            resolvingBookmarkData: data,
            options: .withSecurityScope,
            relativeTo: nil,
            bookmarkDataIsStale: &isStale
        ) else {
            // 书签损坏，清除
            UserDefaults.standard.removeObject(forKey: defaultsKey)
            print("[SaveDirectoryManager] Bookmark data corrupted, cleared")
            return nil
        }

        if isStale {
            // 书签过期，尝试重建
            if let newBookmark = try? url.bookmarkData(
                options: .withSecurityScope,
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            ) {
                UserDefaults.standard.set(newBookmark, forKey: defaultsKey)
                print("[SaveDirectoryManager] Bookmark renewed for: \(url.path)")
            }
        }

        // 验证目录存在
        var isDir: ObjCBool = false
        if !FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) || !isDir.boolValue {
            print("[SaveDirectoryManager] Saved directory no longer exists: \(url.path), falling back to default")
            return nil
        }

        return url
    }
}
