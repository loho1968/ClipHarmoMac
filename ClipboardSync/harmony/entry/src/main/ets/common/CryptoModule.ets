import { cryptoFramework } from '@kit.CryptoArchitectureKit'
import { util } from '@kit.ArkTS'

/**
 * AES-256-GCM 端到端加密模块
 * 配对码 (roomKey) → HKDF-SHA256 → AES-256 key
 * 两端用同一配对码派生相同密钥，无需 ECDH 握手
 */
export class CryptoModule {
  private kdf = cryptoFramework.createKdf('HKDF|SHA256|EXTRACT_AND_EXPAND')
  private symKeyGenerator = cryptoFramework.createSymKeyGenerator('AES256')
  private derivedKey: cryptoFramework.SymKey | null = null
  private _isEncryptionReady: boolean = false

  get isEncryptionReady(): boolean {
    return this._isEncryptionReady
  }

  /**
   * 从配对码 (roomKey) 派生 AES-256 密钥
   * 两端传入相同 roomKey 得到相同密钥
   */
  async deriveKeyFromRoomKey(roomKey: string): Promise<void> {
    if (roomKey.length === 0) {
      console.info('[CryptoModule] deriveKeyFromRoomKey: empty roomKey, skipped')
      return
    }
    try {
      const encoder = new util.TextEncoder()
      const keyMaterial = encoder.encode(roomKey)
      const salt = encoder.encode('ClipSync-RoomKey-v1')
      const info = encoder.encode('ClipSync-v1')

      const hkdfSpec: cryptoFramework.HKDFSpec = {
        algName: 'HKDF',
        key: new Uint8Array(keyMaterial),
        salt: new Uint8Array(salt),
        info: new Uint8Array(info),
        keySize: 32
      }

      const derivedKeyData = await this.kdf.generateSecret(hkdfSpec)
      this.derivedKey = await this.symKeyGenerator.convertKey(derivedKeyData)
      this._isEncryptionReady = true
      console.info('[CryptoModule] AES-256 key derived from roomKey')
    } catch (e) {
      console.error('[CryptoModule] deriveKeyFromRoomKey failed: ' + JSON.stringify(e))
    }
  }

  /**
   * 加密明文 content
   * @returns Base64(nonce[12] + ciphertext + tag[16])
   */
  async encrypt(plaintext: string, deviceId: string, messageType: string): Promise<string> {
    if (!this.derivedKey || !this._isEncryptionReady) {
      console.error('[CryptoModule] encrypt: key not established')
      return plaintext // fallback: 明文发送
    }

    try {
      const cipher = cryptoFramework.createCipher('AES256|GCM|PKCS5')

      // 12-byte random nonce
      const nonce = this.generateNonce()

      // AAD: "deviceId|messageType"，与 Mac 端一致
      const encoder = new util.TextEncoder()
      const aad = encoder.encode(deviceId + '|' + messageType)

      // 加密
      const params: cryptoFramework.GcmParamsSpec = {
        algName: 'GcmParamsSpec',
        iv: { data: nonce },
        aad: { data: aad },
        authTag: { data: new Uint8Array(16) }
      }
      await cipher.init(cryptoFramework.CryptoMode.ENCRYPT_MODE, this.derivedKey, params)

      const plainData: cryptoFramework.DataBlob = { data: encoder.encode(plaintext) }
      const result = await cipher.doFinal(plainData)

      // 组装: nonce[12] + ciphertext + tag[16]
      const ciphertext = result.data
      const tag = params.authTag.data
      const combined = new Uint8Array(12 + ciphertext.length + 16)
      combined.set(nonce, 0)
      combined.set(ciphertext, 12)
      combined.set(tag, 12 + ciphertext.length)

      const base64 = new util.Base64Helper()
      return base64.encodeToStringSync(combined)
    } catch (e) {
      console.error('[CryptoModule] encrypt failed: ' + JSON.stringify(e))
      return plaintext // fallback
    }
  }

  /**
   * 解密 Base64 密文
   * @returns 解密后的明文
   */
  async decrypt(ciphertextBase64: string, deviceId: string, messageType: string): Promise<string> {
    if (!this.derivedKey || !this._isEncryptionReady) {
      console.error('[CryptoModule] decrypt: key not established')
      return ciphertextBase64 // fallback: 原样返回（无法解密）
    }

    try {
      const base64 = new util.Base64Helper()
      const combined = base64.decodeSync(ciphertextBase64)

      if (combined.length < 28) { // 12 (nonce) + 0 + 16 (tag)
        console.error('[CryptoModule] decrypt: ciphertext too short')
        return ciphertextBase64
      }

      const nonce = combined.slice(0, 12)
      const tag = combined.slice(combined.length - 16)
      const cipherData = combined.slice(12, combined.length - 16)

      // AAD
      const encoder = new util.TextEncoder()
      const aad = encoder.encode(deviceId + '|' + messageType)

      // 解密
      const cipher = cryptoFramework.createCipher('AES256|GCM|PKCS5')
      const params: cryptoFramework.GcmParamsSpec = {
        algName: 'GcmParamsSpec',
        iv: { data: new Uint8Array(nonce) },
        aad: { data: aad },
        authTag: { data: new Uint8Array(tag) }
      }
      await cipher.init(cryptoFramework.CryptoMode.DECRYPT_MODE, this.derivedKey, params)

      const result = await cipher.doFinal({ data: new Uint8Array(cipherData) })

      const decoder = new util.TextDecoder('utf-8')
      return decoder.decode(result.data)
    } catch (e) {
      console.error('[CryptoModule] decrypt failed: ' + JSON.stringify(e))
      return ciphertextBase64 // fallback: 原样返回
    }
  }

  /**
   * 生成 12 字节随机 nonce（GCM 要求）
   */
  private generateNonce(): Uint8Array {
    const nonce = new Uint8Array(12)
    for (let i = 0; i < 12; i++) {
      nonce[i] = Math.floor(Math.random() * 256)
    }
    return nonce
  }

  /**
   * 清除加密会话
   */
  clearSession(): void {
    this.derivedKey = null
    this._isEncryptionReady = false
    console.info('[CryptoModule] Session cleared')
  }
}
