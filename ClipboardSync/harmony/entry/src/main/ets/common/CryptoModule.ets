import { cryptoFramework } from '@kit.CryptoArchitectureKit'
import { util } from '@kit.ArkTS'
import { preferences } from '@kit.ArkData'

// P-256 DER SubjectPublicKeyInfo 前缀（27 字节），用于构造/解析公钥
const P256_DER_PREFIX_HEX = '3059301306072a8648ce3d020106082a8648ce3d030107034200'
const PEER_PUBLIC_KEY_KEY = 'com.clipboardsync.peerPublicKey'

function hexToUint8Array(hex: string): Uint8Array {
  const bytes = new Uint8Array(hex.length / 2)
  for (let i = 0; i < hex.length; i += 2) {
    bytes[i / 2] = parseInt(hex.substring(i, i + 2), 16)
  }
  return bytes
}

function bigIntToUint8Array(value: bigint, byteLength: number): Uint8Array {
  const bytes = new Uint8Array(byteLength)
  let v = value
  for (let i = byteLength - 1; i >= 0; i--) {
    bytes[i] = Number(v & BigInt(0xff))
    v = v >> BigInt(8)
  }
  return bytes
}

/**
 * ECDH + AES-256-GCM 端到端加密模块
 * 与 Mac 端 CryptoModule.swift 线格式完全一致
 */
export class CryptoModule {
  private eccGenerator = cryptoFramework.createAsyKeyGenerator('ECC256')
  private eccKeyAgreement = cryptoFramework.createKeyAgreement('ECC256')
  private kdf = cryptoFramework.createKdf('HKDF|SHA256|EXTRACT_AND_EXPAND')
  private symKeyGenerator = cryptoFramework.createSymKeyGenerator('AES256')

  private privateKey: cryptoFramework.PriKey | null = null
  private peerPublicKey: cryptoFramework.PubKey | null = null
  private derivedKey: cryptoFramework.SymKey | null = null
  private publicKeyRaw: Uint8Array = new Uint8Array(0) // 65 bytes raw format

  private _isEncryptionReady: boolean = false
  private _publicKeyBase64: string = ''

  get isEncryptionReady(): boolean {
    return this._isEncryptionReady
  }

  get publicKeyBase64(): string {
    return this._publicKeyBase64
  }

  /**
   * 初始化：生成或加载 ECDH 密钥对，尝试恢复已有会话
   */
  async initialize(prefs: preferences.Preferences): Promise<void> {
    console.info('[CryptoModule] Initializing...')
    await this.loadOrGenerateKeyPair()
    await this.tryRestoreSession(prefs)
  }

  /**
   * 加载或生成本机 ECDH P-256 密钥对
   */
  private async loadOrGenerateKeyPair(): Promise<void> {
    try {
      // 生成新密钥对
      const keyPair = await this.eccGenerator.generateKeyPair()
      this.privateKey = keyPair.priKey
      const pubKey = keyPair.pubKey

      // 导出公钥为 65 字节未压缩格式（与 Mac 端 x963Representation 一致）
      this.publicKeyRaw = this.exportRawPublicKey(pubKey)

      const base64 = new util.Base64Helper()
      this._publicKeyBase64 = base64.encodeToStringSync(this.publicKeyRaw)

      console.info('[CryptoModule] Generated new ECDH key pair, pk=' +
        this._publicKeyBase64.substring(0, 16) + '...')
    } catch (e) {
      console.error('[CryptoModule] Failed to generate key pair: ' + JSON.stringify(e))
    }
  }

  /**
   * 导出公钥为 65 字节未压缩格式: 0x04 || X(32) || Y(32)
   */
  private exportRawPublicKey(pubKey: cryptoFramework.PubKey): Uint8Array {
    try {
      const x = pubKey.getAsyKeySpec(cryptoFramework.AsyKeySpecItem.ECC_PK_X_BN) as bigint
      const y = pubKey.getAsyKeySpec(cryptoFramework.AsyKeySpecItem.ECC_PK_Y_BN) as bigint

      const xBytes = bigIntToUint8Array(x, 32)
      const yBytes = bigIntToUint8Array(y, 32)

      const raw = new Uint8Array(65)
      raw[0] = 0x04
      raw.set(xBytes, 1)
      raw.set(yBytes, 33)
      return raw
    } catch (e) {
      console.error('[CryptoModule] exportRawPublicKey failed: ' + JSON.stringify(e))
      return new Uint8Array(0)
    }
  }

  /**
   * 尝试从持久化存储恢复加密会话
   */
  private async tryRestoreSession(prefs: preferences.Preferences): Promise<void> {
    try {
      const savedPeerKey = prefs.getSync(PEER_PUBLIC_KEY_KEY, '') as string
      if (savedPeerKey.length > 0) {
        await this.establishSession(savedPeerKey)
        console.info('[CryptoModule] Restored encryption session from persisted peer key')
      }
    } catch (e) {
      console.info('[CryptoModule] No saved session to restore')
    }
  }

  /**
   * 使用对端 Base64 公钥建立加密会话
   */
  async establishSession(peerPublicKeyBase64: string): Promise<void> {
    try {
      const base64 = new util.Base64Helper()
      const peerRaw = base64.decodeSync(peerPublicKeyBase64)

      if (peerRaw.length !== 65 || peerRaw[0] !== 0x04) {
        console.error('[CryptoModule] Invalid peer public key: len=' + peerRaw.length)
        return
      }

      // 构造 DER SubjectPublicKeyInfo 以导入公钥
      const derPrefix = hexToUint8Array(P256_DER_PREFIX_HEX)
      const der = new Uint8Array(derPrefix.length + peerRaw.length)
      der.set(derPrefix)
      der.set(peerRaw, derPrefix.length)

      const keyPair = await this.eccGenerator.convertKey({ data: der }, null)
      this.peerPublicKey = keyPair.pubKey

      // ECDH 密钥协商
      if (!this.privateKey) {
        console.error('[CryptoModule] No private key for ECDH')
        return
      }
      const sharedSecret = await this.eccKeyAgreement.generateSecret(
        this.privateKey, this.peerPublicKey
      )

      // HKDF-SHA256 派生 AES-256 key
      // info = "ClipSync-v1", 与 Mac 端一致
      const infoStr = 'ClipSync-v1'
      const encoder = new util.TextEncoder()
      const info = encoder.encode(infoStr)

      const hkdfSpec: cryptoFramework.HKDFSpec = {
        algName: 'HKDF',
        key: new Uint8Array(sharedSecret.data),
        salt: new Uint8Array(0),
        info: info,
        keySize: 32
      }

      const derivedKeyData = await this.kdf.generateSecret(hkdfSpec)
      this.derivedKey = await this.symKeyGenerator.convertKey(derivedKeyData)
      this._isEncryptionReady = true

      console.info('[CryptoModule] Session established, AES-256 key derived')
    } catch (e) {
      console.error('[CryptoModule] establishSession failed: ' + JSON.stringify(e))
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
  clearSession(prefs: preferences.Preferences): void {
    this.peerPublicKey = null
    this.derivedKey = null
    this._isEncryptionReady = false
    try {
      prefs.putSync(PEER_PUBLIC_KEY_KEY, '')
      prefs.flush()
    } catch (_e) {
      // ignore
    }
    console.info('[CryptoModule] Session cleared')
  }

  /**
   * 持久化对端公钥
   */
  savePeerPublicKey(prefs: preferences.Preferences, key: string): void {
    try {
      prefs.putSync(PEER_PUBLIC_KEY_KEY, key)
      prefs.flush()
    } catch (_e) {
      // ignore
    }
  }
}
