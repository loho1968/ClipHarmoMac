import CryptoKit
import Foundation
import Security

// MARK: - 错误类型

enum CryptoError: Error {
    case keyNotEstablished
    case invalidPublicKey
    case invalidCiphertext
    case decryptFailed
    case encryptFailed
    case keychainError(OSStatus)
}

// MARK: - 加密模块

/// 端到端加密模块：ECDH P-256 密钥协商 + AES-256-GCM 内容加密
/// 所有操作在调用方线程执行（SyncManager 保证主线程串行访问）
final class CryptoModule {
    // MARK: 密钥存储

    /// ECDH P-256 私钥（生命周期：跨应用重启，存 Keychain）
    private let privateKey: P256.KeyAgreement.PrivateKey

    /// 对端公钥（收到 keyExchange 后设置）
    private var peerPublicKey: P256.KeyAgreement.PublicKey?

    /// 派生出的 AES-256 对称密钥（加密/解密用）
    private var derivedKey: SymmetricKey?

    /// 加密是否就绪
    var isEncryptionReady: Bool { derivedKey != nil }

    /// 本机公钥（Base64 编码，65 bytes ANSI X9.63 未压缩格式）
    var publicKeyBase64: String {
        privateKey.publicKey.x963Representation.base64EncodedString()
    }

    // MARK: Keychain 常量

    private static let keychainTag = "com.clipboardsync.ecdh.privatekey".data(using: .utf8)!
    private static let keychainLabel = "com.clipboardsync.ecdh"

    // MARK: 初始化

    init() {
        if let existing = Self.loadPrivateKey() {
            self.privateKey = existing
            print("[CryptoModule] Loaded existing ECDH key pair from Keychain")
        } else {
            self.privateKey = P256.KeyAgreement.PrivateKey()
            Self.savePrivateKey(self.privateKey)
            print("[CryptoModule] Generated new ECDH key pair")
        }

        // 尝试恢复已有会话（从 UserDefaults 加载对端公钥）
        if let savedPeerKey = RelayConfig.sharedDefaults.string(forKey: "com.clipboardsync.peerPublicKey"),
           !savedPeerKey.isEmpty {
            try? establishSession(peerPublicKeyBase64: savedPeerKey)
            if derivedKey != nil {
                print("[CryptoModule] Restored encryption session from persisted peer key")
            }
        }
    }

    // MARK: 密钥协商

    /// 使用对端公钥建立会话（ECDH → HKDF → AES key）
    func establishSession(peerPublicKeyBase64: String) throws {
        guard let peerData = Data(base64Encoded: peerPublicKeyBase64),
              peerData.count == 65 else {
            throw CryptoError.invalidPublicKey
        }

        let peerKey: P256.KeyAgreement.PublicKey
        do {
            peerKey = try P256.KeyAgreement.PublicKey(x963Representation: peerData)
        } catch {
            throw CryptoError.invalidPublicKey
        }

        self.peerPublicKey = peerKey

        // ECDH 密钥协商
        let sharedSecret = try privateKey.sharedSecretFromKeyAgreement(with: peerKey)

        // HKDF-SHA256 派生 AES-256 密钥（无盐，共享密钥本身就是高熵的）
        let sharedData = sharedSecret.withUnsafeBytes { Data($0) }
        let info = "ClipSync-v1".data(using: .utf8) ?? Data()
        let derived = HKDF<SHA256>.deriveKey(
            inputKeyMaterial: SymmetricKey(data: sharedData),
            salt: Data(),
            info: info,
            outputByteCount: 32
        )

        self.derivedKey = derived

        // 持久化对端公钥（下次启动自动恢复会话）
        RelayConfig.sharedDefaults.set(peerPublicKeyBase64, forKey: "com.clipboardsync.peerPublicKey")

        print("[CryptoModule] Session established, AES-256 key derived")
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
        case .clipboardImage, .clipboardFile,
             .clipboardDataChunk, .verificationCode:
            return true
        case .clipboardText, .ping, .pong, .keyExchange, .roomKeyInfo, .clipboardPoll:
            return false
        }
    }

    // MARK: Keychain 持久化

    private static func savePrivateKey(_ key: P256.KeyAgreement.PrivateKey) {
        let rawKey = key.rawRepresentation // 32 bytes

        // 先删除旧条目（如果存在）
        let deleteQuery: [String: Any] = [
            kSecClass as String: kSecClassKey,
            kSecAttrApplicationTag as String: keychainTag,
        ]
        SecItemDelete(deleteQuery as CFDictionary)

        // 添加新条目
        let addQuery: [String: Any] = [
            kSecClass as String: kSecClassKey,
            kSecAttrApplicationTag as String: keychainTag,
            kSecAttrLabel as String: keychainLabel,
            kSecValueData as String: rawKey,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
        ]

        let status = SecItemAdd(addQuery as CFDictionary, nil)
        if status != errSecSuccess {
            print("[CryptoModule] Keychain save failed: \(status)")
        }
    }

    private static func loadPrivateKey() -> P256.KeyAgreement.PrivateKey? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassKey,
            kSecAttrApplicationTag as String: keychainTag,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess,
              let data = item as? Data,
              data.count == 32 else {
            return nil
        }

        return try? P256.KeyAgreement.PrivateKey(rawRepresentation: data)
    }

    /// 清除加密会话（用于新配对场景）
    func clearSession() {
        peerPublicKey = nil
        derivedKey = nil
        RelayConfig.sharedDefaults.removeObject(forKey: "com.clipboardsync.peerPublicKey")
        print("[CryptoModule] Session cleared")
    }
}
