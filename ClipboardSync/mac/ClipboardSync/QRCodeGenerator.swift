import CoreImage
import AppKit

struct QRCodeGenerator {
    /// 从字符串生成二维码 NSImage
    /// - Parameters:
    ///   - string: 要编码的字符串
    ///   - size: 输出图片尺寸（默认 200pt）
    /// - Returns: 二维码图片，生成失败返回 nil
    static func generate(from string: String, size: CGFloat = 200) -> NSImage? {
        guard let data = string.data(using: .utf8) else { return nil }

        let filter = CIFilter(name: "CIQRCodeGenerator")!
        filter.setValue(data, forKey: "inputMessage")
        filter.setValue("M", forKey: "inputCorrectionLevel")

        guard let ciImage = filter.outputImage else { return nil }

        // CIQRCodeGenerator 输出的像素极小，需要放大
        let scaleX = size / ciImage.extent.width
        let scaleY = size / ciImage.extent.height
        let transformed = ciImage.transformed(by: CGAffineTransform(scaleX: scaleX, y: scaleY))

        let rep = NSCIImageRep(ciImage: transformed)
        let nsImage = NSImage(size: NSSize(width: size, height: size))
        nsImage.addRepresentation(rep)
        return nsImage
    }
}
