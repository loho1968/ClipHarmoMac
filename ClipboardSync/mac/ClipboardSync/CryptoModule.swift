import CryptoKit
import Foundation

// MARK: - 错误类型

enum CryptoError: Error {
    case keyNotEstablished
    case invalidCiphertext
    case decryptFailed
    case encryptFailed
}

// MARK: - 加密模块

/// 端到端加密模块：配对码 (roomKey) → HKDF-SHA256 → AES-256-GCM
/// 两端用同一配对码派生相同密钥，无需 ECDH 握手
final class CryptoModule {
    /// 派生出的 AES-256 对称密钥（加密/解密用）
    private var derivedKey: SymmetricKey?

    /// 加密是否就绪
    var isEncryptionReady: Bool { derivedKey != nil }

    // MARK: 初始化

    init() {}

    // MARK: 密钥派生

    /// 从配对码 (roomKey) 派生 AES-256 密钥
    /// 两端传入相同 roomKey 得到相同密钥，无需密钥交换
    func deriveKeyFromRoomKey(_ roomKey: String) {
        guard !roomKey.isEmpty else {
            print("[CryptoModule] deriveKeyFromRoomKey: empty roomKey, skipped")
            return
        }
        let keyMaterial = SymmetricKey(data: Data(roomKey.utf8))
        let salt = "ClipSync-RoomKey-v1".data(using: .utf8)!
        let info = "ClipSync-v1".data(using: .utf8)!
        derivedKey = HKDF<SHA256>.deriveKey(
            inputKeyMaterial: keyMaterial,
            salt: salt,
            info: info,
            outputByteCount: 32
        )
        print("[CryptoModule] AES-256 key derived from roomKey")
    }

    // MARK: 加密 / 解密

    /// 加密明文内容
    /// - Returns: Base64 编码的密文（nonce[12] + ciphertext + tag[16]）
    func encrypt(_ plaintext: String, deviceId: String, messageType: String) throws -> String {
        guard let key = derivedKey else {
            throw CryptoError.keyNotEstablished
        }

        let plainData = Data(plaintext.utf8)
        let nonce = AES.GCM.Nonce() // 12 random bytes

        // AAD 绑定到设备+消息类型，防跨设备/跨类型重放
        let aad = "\(deviceId)|\(messageType)".data(using: .utf8) ?? Data()

        let sealed: AES.GCM.SealedBox
        do {
            sealed = try AES.GCM.seal(plainData, using: key, nonce: nonce, authenticating: aad)
        } catch {
            throw CryptoError.encryptFailed
        }

        // 组装: nonce[12] + ciphertext + tag[16]
        var combined = Data()
        combined.append(Data(nonce))
        combined.append(sealed.ciphertext)
        combined.append(sealed.tag)

        return combined.base64EncodedString()
    }

    /// 解密密文
    /// - Parameter ciphertextBase64: Base64 编码的（nonce[12] + ciphertext + tag[16]）
    /// - Returns: 解密后的明文
    func decrypt(_ ciphertextBase64: String, deviceId: String, messageType: String) throws -> String {
        guard let key = derivedKey else {
            throw CryptoError.keyNotEstablished
        }

        guard let combined = Data(base64Encoded: ciphertextBase64),
              combined.count >= 28 else { // 12 (nonce) + 0 (min) + 16 (tag)
            throw CryptoError.invalidCiphertext
        }

        let nonceData = combined.prefix(12)
        let tagData = combined.suffix(16)
        let cipherData = combined.dropFirst(12).dropLast(16)

        let nonce: AES.GCM.Nonce
        do {
            nonce = try AES.GCM.Nonce(data: nonceData)
        } catch {
            throw CryptoError.invalidCiphertext
        }

        let aad = "\(deviceId)|\(messageType)".data(using: .utf8) ?? Data()
        let sealedBox: AES.GCM.SealedBox
        do {
            sealedBox = try AES.GCM.SealedBox(nonce: nonce, ciphertext: cipherData, tag: tagData)
        } catch {
            throw CryptoError.invalidCiphertext
        }

        let decrypted: Data
        do {
            decrypted = try AES.GCM.open(sealedBox, using: key, authenticating: aad)
        } catch {
            throw CryptoError.decryptFailed
        }

        guard let result = String(data: decrypted, encoding: .utf8) else {
            throw CryptoError.decryptFailed
        }

        return result
    }

    // MARK: 加密范围判断

    /// 判断某类消息的 content 是否需要加密
    static func shouldEncrypt(messageType: MessageType) -> Bool {
        switch messageType {
        case .clipboardText, .clipboardImage, .clipboardFile,
             .clipboardDataChunk, .verificationCode:
            return true
        case .ping, .pong, .keyExchange, .roomKeyInfo, .clipboardPoll:
            return false
        }
    }

    /// 清除加密会话（新配对扫码时调用）
    func clearSession() {
        derivedKey = nil
        print("[CryptoModule] Session cleared")
    }
}
