import AppKit

/// 图片元数据（发送图片时携带的附加信息）
struct ClipboardImageMetadata {
    let width: Int
    let height: Int
    let fileSize: Int
    let format: String       // "jpeg"
    let fileName: String     // 自动生成的文件名
}

/// 剪贴板监听模块
class ClipboardMonitor {
    private var timer: Timer?
    private var lastChangeCount: Int
    private let pasteboard = NSPasteboard.general

    /// 剪贴板变化回调：(文本, 图片数据, 图片元数据, 文件路径)
    /// 文本复制 → 仅 text 有值，自动发送
    /// 图片复制 → imageData + metadata 有值，暂存待用户手动发送
    /// 文件复制 → fileURL 有值，暂存待用户手动发送
    var onClipboardChanged: ((String?, Data?, ClipboardImageMetadata?, URL?) -> Void)?
    var isRemoteUpdate: Bool = false

    /// 图片压缩参数
    static let maxImageLongSide: CGFloat = 1920
    static let jpegQuality: CGFloat = 0.80
    static let maxImageSize: Int = 20 * 1024 * 1024  // 20MB（压缩后）

    init() {
        lastChangeCount = pasteboard.changeCount
    }

    func start() {
        timer = Timer.scheduledTimer(
            withTimeInterval: ProtocolConst.clipboardPollInterval,
            repeats: true
        ) { [weak self] _ in
            self?.checkClipboard()
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    /// 写入剪贴板（来自远端的消息）
    func writeText(_ text: String) {
        isRemoteUpdate = true
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        lastChangeCount = pasteboard.changeCount
        isRemoteUpdate = false
    }

    /// 写入图片到剪贴板
    func writeImage(_ imageData: Data) {
        isRemoteUpdate = true
        if let image = NSImage(data: imageData) {
            pasteboard.clearContents()
            pasteboard.writeObjects([image])
        }
        lastChangeCount = pasteboard.changeCount
        isRemoteUpdate = false
    }

    /// 生成图片文件名
    private static func generateImageFileName(format: String) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd_HHmmss"
        return "clipboard_\(formatter.string(from: Date())).\(format)"
    }

    /// 压缩图片：TIFF → 缩放 → JPEG
    /// 返回 (压缩后的 Data, 元数据)，失败返回 nil
    static func compressImage(tiffData: Data) -> (Data, ClipboardImageMetadata)? {
        guard let image = NSImage(data: tiffData),
              let tiffRep = NSBitmapImageRep(data: tiffData) else {
            print("[ClipboardMonitor] Failed to read TIFF image")
            return nil
        }

        let originalWidth = CGFloat(tiffRep.pixelsWide)
        let originalHeight = CGFloat(tiffRep.pixelsHigh)
        let longSide = max(originalWidth, originalHeight)

        // 计算缩放比例
        var targetWidth = originalWidth
        var targetHeight = originalHeight
        if longSide > maxImageLongSide {
            let scale = maxImageLongSide / longSide
            targetWidth = (originalWidth * scale).rounded()
            targetHeight = (originalHeight * scale).rounded()
        }

        // 创建缩放后的 NSImage
        let scaledImage = NSImage(size: NSSize(width: targetWidth, height: targetHeight))
        scaledImage.lockFocus()
        NSGraphicsContext.current?.imageInterpolation = .high
        image.draw(in: NSRect(x: 0, y: 0, width: targetWidth, height: targetHeight),
                   from: NSRect(origin: .zero, size: image.size),
                   operation: .copy,
                   fraction: 1.0)
        scaledImage.unlockFocus()

        // JPEG 编码
        guard let cgImage = scaledImage.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            print("[ClipboardMonitor] Failed to get CGImage from scaled image")
            return nil
        }

        let bitmapRep = NSBitmapImageRep(cgImage: cgImage)
        guard let jpegData = bitmapRep.representation(using: .jpeg, properties: [.compressionFactor: jpegQuality]) else {
            print("[ClipboardMonitor] Failed to JPEG encode")
            return nil
        }

        // 大小检查
        if jpegData.count > maxImageSize {
            print("[ClipboardMonitor] Image too large after compression: \(jpegData.count / 1024 / 1024)MB, skipping")
            return nil
        }

        let metadata = ClipboardImageMetadata(
            width: Int(targetWidth),
            height: Int(targetHeight),
            fileSize: jpegData.count,
            format: "jpeg",
            fileName: generateImageFileName(format: "jpeg")
        )

        print("[ClipboardMonitor] Image compressed: \(Int(originalWidth))×\(Int(originalHeight)) → \(Int(targetWidth))×\(Int(targetHeight)), \(tiffData.count / 1024)KB → \(jpegData.count / 1024)KB")
        return (jpegData, metadata)
    }

    private func checkClipboard() {
        guard !isRemoteUpdate else { return }
        guard pasteboard.changeCount != lastChangeCount else { return }

        print("[ClipboardMonitor] change: \(lastChangeCount) → \(pasteboard.changeCount)")

        lastChangeCount = pasteboard.changeCount

        // 优先读取文本（自动发送，无需用户手动触发）
        if let text = pasteboard.string(forType: .string) {
            onClipboardChanged?(text, nil, nil, nil)
            return
        }

        // 尝试读取图片（压缩后回调，暂存待用户手动发送）
        if let tiffData = pasteboard.data(forType: .tiff),
           NSImage(data: tiffData) != nil {
            if let (compressedData, metadata) = Self.compressImage(tiffData: tiffData) {
                onClipboardChanged?(nil, compressedData, metadata, nil)
                return
            }
        }

        // 尝试读取文件 URL（Finder 中复制文件时，暂存待用户手动发送）
        if let fileURLs = pasteboard.readObjects(forClasses: [NSURL.self], options: nil) as? [URL],
           let fileURL = fileURLs.first {
            print("[ClipboardMonitor] File detected: \(fileURL.path)")
            onClipboardChanged?(nil, nil, nil, fileURL)
        }
    }
}
