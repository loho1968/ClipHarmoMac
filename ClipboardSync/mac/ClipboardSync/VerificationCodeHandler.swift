import Foundation
import AppKit
import UserNotifications

class VerificationCodeHandler {
    private static let codePatterns: [(String, NSRegularExpression)] = {
        let patterns = [
            "验证码[：:]\\s*(\\d{4,8})",
            "验证码是\\s*(\\d{4,8})",
            "code[：:]\\s*(\\d{4,8})",
            "(\\d{4,8})\\s*（验证码）",
            "(\\d{4,8})"
        ]
        return patterns.compactMap { p in
            guard let regex = try? NSRegularExpression(pattern: p, options: []) else { return nil }
            return (p, regex)
        }
    }()

    /// 判断文本是否包含验证码，返回提取到的验证码
    static func extractCode(from text: String) -> String? {
        for (_, regex) in codePatterns {
            let range = NSRange(text.startIndex..., in: text)
            if let match = regex.firstMatch(in: text, options: [], range: range) {
                if match.numberOfRanges > 1,
                   let codeRange = Range(match.range(at: 1), in: text) {
                    return String(text[codeRange])
                }
            }
        }
        return nil
    }

    /// 处理验证码：复制到剪贴板 + 弹出系统通知
    static func handle(code: String, sender: String?) {
        // 1. 写入剪贴板
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(code, forType: .string)

        // 2. 弹出系统通知（仅在有 app bundle 时，开发模式跳过）
        guard Bundle.main.bundleIdentifier != nil else {
            print("[VerificationCode] Notification skipped (no app bundle)")
            return
        }

        let content = UNMutableNotificationContent()
        content.title = "验证码: " + code
        if let sender = sender, !sender.isEmpty {
            content.body = "来自: " + sender + "，已复制到剪贴板"
        } else {
            content.body = "已从手机同步，可直接粘贴"
        }
        content.sound = .default

        let request = UNNotificationRequest(
            identifier: UUID().uuidString,
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request)
    }
}
