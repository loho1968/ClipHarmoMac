import { pasteboard } from '@kit.BasicServicesKit'
import { power } from '@kit.BasicServicesKit'
import { SyncMessage, MessageType, ProtocolConst, RelayConfig } from '../common/Protocol'
import { DiscoveryService } from '../common/DiscoveryService'
import { DiscoveryTCPServer } from '../common/DiscoveryTCPServer'
import { TCPClient } from '../common/TCPClient'
import { WSClient } from '../common/WSClient'
import { NetworkContextManager, NetworkProfile } from '../model/NetworkContextManager'
import { wifiManager } from '@kit.ConnectivityKit'
import { preferences } from '@kit.ArkData'
import { util } from '@kit.ArkTS'
import { image } from '@kit.ImageKit'
import { fileIo, picker } from '@kit.CoreFileKit'
import { SaveDirectoryManager } from '../model/SaveDirectoryManager'
import { photoAccessHelper } from '@kit.MediaLibraryKit'
import { Want } from '@kit.AbilityKit'
import { CryptoModule } from '../common/CryptoModule'

// 同步记录
export interface SyncRecord {
  id: string
  content: string
  time: string
  direction: 'sent' | 'received'
}

// 图片提取结果
interface ImagePayload {
  base64: string
  width: number
  height: number
  size: number
  format: string
}

// 分片缓冲
interface ChunkBuffer {
  transferId: string
  totalChunks: number
  chunks: Map<number, string>
  metadata: SyncMessage
  timestamp: number
}

// 待保存文件
export interface PendingFile {
  id: string
  base64: string
  fileName: string
  fileSize: number
  mimeType: string
  format: string
  isImage: boolean
  receivedAt: number
}

// 同步状态
export enum SyncStatus {
  DISCONNECTED = '未连接',
  DISCOVERING = '搜索设备中',
  CONNECTED = '已连接'
}

// 连接模式
export enum ConnectionMode {
  NONE = '无',
  LAN = '局域网',
  RELAY = '云中继'
}

/**
 * 剪贴板同步管理器
 * 协调设备发现、TCP 连接、剪贴板监听
 */
export class SyncManager {
  private discovery: DiscoveryService = new DiscoveryService()
  private discoveryTCP: DiscoveryTCPServer = new DiscoveryTCPServer()
  private tcpClient: TCPClient = new TCPClient()
  private oldTcpClient: TCPClient | null = null
  private wsClient: WSClient = new WSClient()
  private networkCtx: NetworkContextManager = new NetworkContextManager()
  private crypto: CryptoModule = new CryptoModule()
  private hasSentKeyExchange: boolean = false
  private systemPasteboard: pasteboard.SystemPasteboard = pasteboard.getSystemPasteboard()
  private pollTimerId: number = -1
  private isRemoteUpdate: boolean = false
  private lastChangeCount: number = -1
  private lastSentTimestamp: number = 0
  private _clipboardDirty: boolean = false
  private _cachedClipboardText: string = ''
  private _connectingIp: string = ''  // 正在连接中的 IP，防重入
  private _lastDiscoveredMacId: string = ''  // 最近发现的 Mac deviceId
  private _lastDiscoveredSSID: string = ''  // 最近发现的 Mac 所在 SSID
  private relayPrefs: preferences.Preferences | null = null

  // 分片传输
  private chunkBuffers: Map<string, ChunkBuffer> = new Map()
  private chunkCleanupTimer: number = -1

  // 弹出"记住此网络"提示
  onAskRememberNetwork?: (ssid: string, macIP: string, macDeviceId: string) => void

  // 待保存文件队列
  private pendingFiles: PendingFile[] = []
  onPendingFileReceived?: (file: PendingFile) => void

  // 后台亮屏检测 + 定时拉取
  private backgroundPollTimerId: number = -1
  private screenWasOff: boolean = false
  private pollTickCount: number = 0

  // 状态
  private _status: SyncStatus = SyncStatus.DISCONNECTED
  get status(): SyncStatus {
    return this._status
  }

  private _connectedDevice: string = ''
  get connectedDevice(): string {
    return this._connectedDevice
  }

  private _history: SyncRecord[] = []
  get history(): SyncRecord[] {
    return this._history
  }

  private _lastSyncTime: string = ''
  get lastSyncTime(): string {
    return this._lastSyncTime
  }

  // 中继状态
  private _connectionMode: ConnectionMode = ConnectionMode.NONE
  get connectionMode(): ConnectionMode {
    return this._connectionMode
  }

  private _roomKey: string = ''
  get roomKey(): string {
    return this._roomKey
  }

  private _relayStatusText: string = ''
  get relayStatusText(): string {
    return this._relayStatusText
  }

  private _relayPairedDeviceId: string = ''
  get relayPairedDeviceId(): string {
    return this._relayPairedDeviceId
  }

  private _relayServerHost: string = RelayConfig.DEFAULT_HOST
  get relayServerHost(): string {
    return this._relayServerHost
  }

  // 状态变化回调（供 UI 层使用）
  onStateChange?: () => void

  // 诊断信息（供 UI 显示）
  private _discoveryLog: string = ''  // 最近一次发现日志
  get discoveryLog(): string {
    return this._discoveryLog
  }

  private _tcpLog: string = ''  // 最近一次TCP日志
  get tcpLog(): string {
    return this._tcpLog
  }

  // 最近收到的 roomKey 信息（来自 TCP 连接的 Mac），用于存入 NetworkProfile
  private _pendingRoomKey: string = ''
  private _pendingRelayHost: string = ''
  // 防止 switchRelayRoomKey 重入
  private _isSwitchingRelay: boolean = false

  // 网络环境管理器（供 UI 访问 Profile 列表）
  get networkManager(): NetworkContextManager {
    return this.networkCtx
  }

  start(): void {
    console.info('[SyncManager] start() called, deviceId=' + ProtocolConst.DEVICE_ID)
    this._status = SyncStatus.DISCOVERING
    this._connectionMode = ConnectionMode.NONE
    this.onStateChange?.()

    // 设置中继回调（整个生命周期只调用一次）
    this.setupWSCallbacks()
    console.info('[SyncManager] setupWSCallbacks done')

    // 初始化网络环境管理器
    this.initNetworkContext()

    // 启动 UDP 设备发现
    this.discovery.onDeviceFound = (deviceId: string, ip: string, port: number) => {
      this.handleDeviceFound(deviceId, ip, port)
    }
    this.discovery.start()

    // 启动 TCP 发现服务（Mac 通过 TCP 告知自己的 IP）
    this.discoveryTCP.onMacIPFound = (macIP: string) => {
      console.info('[SyncManager] TCP反向发现: Mac IP=' + macIP)
      this._discoveryLog = 'TCP 反向发现 Mac: ' + macIP
      this.onStateChange?.()
      // TCP 已连接则跳过，否则总是尝试（即使中继已连接，LAN 优先）
      if (this.tcpClient.connected) {
        console.info('[SyncManager] TCP反向发现: TCP已连接，跳过')
        return
      }
      this.setupTcpClient(macIP)
    }
    this.discoveryTCP.start()

    // 启动剪贴板监听
    this.startClipboardListener()

    // 初始化加密模块
    this.initCrypto()

    // 初始化中继连接
    this.initRelay()

    // 启动分片超时清理
    this.startChunkCleanup()

    // 后台亮屏检测 + 定时拉取
    this.startBackgroundPoll()
  }

  stop(): void {
    this.stopBackgroundPoll()
    this.discovery.stop()
    this.discoveryTCP.stop()
    this.tcpClient.disconnect()
    this.wsClient.disconnect()
    this.stopClipboardPoll()
    this.stopChunkCleanup()
    this.networkCtx.stopMonitoring()
    this._connectingIp = ''
    this._status = SyncStatus.DISCONNECTED
    this._connectionMode = ConnectionMode.NONE
    this._connectedDevice = ''
    this._relayPairedDeviceId = ''
    this.hasSentKeyExchange = false
    this.onStateChange?.()
  }

  // 手动连接（通过 IP）
  connectManual(ip: string): void {
    console.info('[SyncManager] Manual connect to: ' + ip)
    this._status = SyncStatus.DISCOVERING
    this._connectedDevice = ''
    this.onStateChange?.()
    this.setupTcpClient(ip)
  }

  // ============ 设备发现处理 ============

  private handleDeviceFound(deviceId: string, ip: string, port: number): void {
    console.info('[SyncManager] UDP发现: device=' + deviceId + ' ip=' + ip + ' tcpConnected=' + this.tcpClient.connected)
    // 即使中继已连接也尝试 TCP：LAN 优先，且需要 TCP 接收 roomKeyInfo
    if (this.tcpClient.connected) {
      console.info('[SyncManager] UDP发现: TCP已连接，跳过')
      return
    }
    this._discoveryLog = 'UDP 发现 Mac: ' + ip
    this._lastDiscoveredMacId = deviceId
    this.onStateChange?.()
    this.setupTcpClient(ip)
  }

  private setupTcpClient(ip: string): void {
    console.info('[SyncManager] setupTcpClient: ip=' + ip + ' connectingIp=' + this._connectingIp)
    // 防重入：同一 IP 正在连接中，跳过
    if (this._connectingIp === ip) {
      console.info('[SyncManager] Already connecting to ' + ip + ', skip duplicate')
      return
    }

    // 先断开旧连接
    if (this.tcpClient) {
      this.tcpClient.disconnect()
    }

    // 保留旧实例引用，延迟清理（等 socket.close() 完成）
    this.oldTcpClient = this.tcpClient

    // 创建新实例并延迟连接，等旧 socket 释放
    this.tcpClient = new TCPClient()

    // 记录正在连接的 IP
    this._connectingIp = ip

    this.tcpClient.onConnected = () => {
      console.info('[SyncManager] TCP connected to ' + ip)
      this._connectingIp = ''
      this._status = SyncStatus.CONNECTED
      this._connectedDevice = ip
      this._connectionMode = ConnectionMode.LAN
      this.initiateKeyExchangeIfNeeded()
      this.onStateChange?.()

      // 检查是否需要提示用户记住此网络
      this.checkAndPromptSaveNetwork(ip)

      // 连接建立后刷新剪贴板缓存
      this.flushPendingClipboard()

      setTimeout(() => {
        this.requestRemoteClipboard()
      }, 1500)
    }

    this.tcpClient.onDisconnected = () => {
      console.info('[SyncManager] TCP disconnected')
      this._connectingIp = ''
      // LAN 断开，检测中继是否可用
      if (this.wsClient.connected) {
        this._connectionMode = ConnectionMode.RELAY
        this._status = SyncStatus.CONNECTED
      } else if (this._roomKey.length > 0 && !this._isSwitchingRelay) {
        // 中继未连接但有 roomKey，主动连接中继
        console.info('[SyncManager] TCP lost, connecting relay with saved roomKey')
        const url = RelayConfig.buildURL(this._relayServerHost)
        this.wsClient.connect(url, this._roomKey)
        this._status = SyncStatus.DISCOVERING
        this._connectionMode = ConnectionMode.NONE
      } else {
        this._status = SyncStatus.DISCOVERING
        this._connectionMode = ConnectionMode.NONE
      }
      this._connectedDevice = ''
      // 重置发现去重，允许重新发现同一设备并自动重连
      this.discovery.resetFoundDevices()
      this.onStateChange?.()
    }

    this.tcpClient.onMessage = (msg: SyncMessage) => {
      this.handleRemoteMessage(msg)
    }

    this.tcpClient.onError = (err: string) => {
      console.error('[SyncManager] TCP error: ' + err)
      this._connectingIp = ''
      // 连接失败后重置发现去重，允许下次广播触发重新连接
      this.discovery.resetFoundDevices()
    }

    // 延迟 500ms 再连接，等待旧 socket 完全关闭
    setTimeout(() => {
      this.oldTcpClient = null
      this.tcpClient.connect(ip)
    }, 500)
  }

  // ============ 网络环境感知 ============

  private async initNetworkContext(): Promise<void> {
    const ctx = this._context
    if (!ctx) {
      return
    }
    await this.networkCtx.init(ctx)

    // WiFi 匹配到已知网络 → 自动连接
    this.networkCtx.onNetworkMatched = (profile: NetworkProfile) => {
      console.info('[SyncManager] Network matched: ' + profile.name + ' -> ' + profile.macIP)
      this._discoveryLog = 'WiFi匹配:' + profile.name + ' ip=' + profile.macIP
      this.onStateChange?.()
      // 总是尝试 TCP（LAN 优先于中继），仅当已 TCP 连接时跳过
      if (!this.tcpClient.connected) {
        this.setupTcpClient(profile.macIP)
      }
      // 双 Mac 场景：切换到该网络对应 Mac 的 roomKey
      const profileRoomKey = profile.roomKey || ''
      const profileRelayHost = profile.relayHost || RelayConfig.DEFAULT_HOST
      if (profileRoomKey.length > 0 && profileRoomKey !== this._roomKey) {
        console.info('[SyncManager] Switching relay for matched network: ' + profile.name)
        this.switchRelayRoomKey(profileRoomKey, profileRelayHost)
      }
    }

    this.networkCtx.onNetworkLost = () => {
      console.info('[SyncManager] WiFi disconnected')
      // 确保中继连接活跃（5G/蜂窝网络下唯一的数据通道）
      if (!this.wsClient.connected && this._roomKey.length > 0) {
        console.info('[SyncManager] WiFi lost, reconnecting relay with saved roomKey')
        const url = RelayConfig.buildURL(this._relayServerHost)
        this.wsClient.connect(url, this._roomKey)
      }
    }

    this.networkCtx.startMonitoring()
  }

  private async checkAndPromptSaveNetwork(macIP: string): Promise<void> {
    const currentSSID = this.networkCtx.getCurrentSSID()
    if (currentSSID.length === 0) {
      return
    }

    const existingProfile = await this.networkCtx.getProfileBySSID(currentSSID)
    if (existingProfile) {
      // 已有 Profile，检查 IP 是否变化
      if (existingProfile.macIP !== macIP) {
        console.info('[SyncManager] IP changed for ' + currentSSID + ': ' + existingProfile.macIP + ' -> ' + macIP)
        await this.networkCtx.updateProfileIP(currentSSID, macIP)
      }
      return
    }

    // 新网络，提示用户
    console.info('[SyncManager] New network detected: ' + currentSSID)
    this.onAskRememberNetwork?.(currentSSID, macIP, this._lastDiscoveredMacId)
  }

  // 用户确认记住此网络（供 UI 调用）
  async saveCurrentNetwork(name: string): Promise<void> {
    const ssid = this.networkCtx.getCurrentSSID()
    const ip = this._connectedDevice
    if (ssid.length === 0 || ip.length === 0) {
      return
    }

    try {
      const linkedInfo: wifiManager.WifiLinkedInfo = await wifiManager.getLinkedInfo()
      const bssid: string = linkedInfo.bssid || ''
      const profile = await this.networkCtx.upsertProfile(ssid, bssid, ip, name)
      // 同时写入已收到的 roomKey（来自 Mac TCP 连接）
      if (this._pendingRoomKey.length > 0) {
        await this.networkCtx.updateProfileRoomKey(ssid, this._pendingRoomKey, this._pendingRelayHost)
      }
      console.info('[SyncManager] Network saved: ' + name + ' ssid=' + ssid + ' roomKey=' + this._pendingRoomKey)
    } catch (e) {
      console.error('[SyncManager] saveCurrentNetwork error: ' + JSON.stringify(e))
    }
  }

  // 删除当前网络 Profile（供 UI 调用）
  async forgetNetwork(ssid: string): Promise<void> {
    const profile = await this.networkCtx.getProfileBySSID(ssid)
    if (profile) {
      await this.networkCtx.deleteProfile(profile.id)
    }
  }

  // ============ 中继连接 ============

  private setupWSCallbacks(): void {
    this.wsClient.onConnected = () => {
      console.info('[SyncManager] WS connected')
      if (!this.tcpClient.connected) {
        this._connectionMode = ConnectionMode.RELAY
        this._status = SyncStatus.CONNECTED
      }
      this._relayPairedDeviceId = this.wsClient.currentPairedDeviceId
      this._relayStatusText = this.wsClient.currentPairedDeviceId.length > 0
        ? '已配对: ' + this.wsClient.currentPairedDeviceId
        : '等待设备加入...'
      this.onStateChange?.()

      if (!this.tcpClient.connected) {
        this.flushPendingClipboard()
      }
    }

    this.wsClient.onDisconnected = () => {
      console.info('[SyncManager] WS disconnected')
      if (this._connectionMode === ConnectionMode.RELAY) {
        this._connectionMode = ConnectionMode.NONE
        this._status = SyncStatus.DISCOVERING
        this.discovery.resetFoundDevices()
      }
      this._relayPairedDeviceId = ''
      this._relayStatusText = '中继已断开'
      this.onStateChange?.()
    }

    this.wsClient.onMessage = (msg: SyncMessage) => {
      this.handleRemoteMessage(msg)
    }

    this.wsClient.onPaired = (deviceId: string) => {
      this._relayPairedDeviceId = deviceId
      this._relayStatusText = '已配对: ' + deviceId
      if (!this.tcpClient.connected) {
        this._connectionMode = ConnectionMode.RELAY
        this._status = SyncStatus.CONNECTED
      }
      this.initiateKeyExchangeIfNeeded()
      this.onStateChange?.()

      setTimeout(() => {
        this.requestRemoteClipboard()
      }, 1500)
    }

    this.wsClient.onPeerGone = (_deviceId: string) => {
      this._relayPairedDeviceId = ''
      this._relayStatusText = '配对设备已离线'
      this.onStateChange?.()
    }

    this.wsClient.onError = (msg: string) => {
      console.error('[SyncManager] WS error: ' + msg)
      this._relayStatusText = '中继错误: ' + msg
      this.onStateChange?.()
    }
  }

  // ============ 加密模块初始化 ============

  private async initCrypto(): Promise<void> {
    try {
      if (!this.relayPrefs) {
        const ctx = this._context
        if (!ctx) {
          return
        }
        this.relayPrefs = preferences.getPreferencesSync(ctx, { name: 'clipboardsync_relay' })
      }
      await this.crypto.initialize(this.relayPrefs)
      console.info('[SyncManager] Crypto module initialized, ready=' + this.crypto.isEncryptionReady)
    } catch (e) {
      console.error('[SyncManager] Crypto init failed: ' + JSON.stringify(e))
    }
  }

  private initiateKeyExchangeIfNeeded(): void {
    if (this.hasSentKeyExchange) {
      return
    }
    this.sendKeyExchange()
  }

  private sendKeyExchange(): void {
    const msg: SyncMessage = {
      type: MessageType.KEY_EXCHANGE,
      content: '',
      timestamp: Date.now() / 1000,
      deviceId: ProtocolConst.DEVICE_ID,
      publicKey: this.crypto.publicKeyBase64
    }
    // 密钥交换消息不加密，直接发送
    if (this.tcpClient.connected) {
      this.tcpClient.send(msg)
    } else if (this.wsClient.connected) {
      this.wsClient.sendRelay(msg)
    }
    this.hasSentKeyExchange = true
    console.info('[SyncManager] Sent keyExchange, pk=' +
      this.crypto.publicKeyBase64.substring(0, 16) + '...')
  }

  private async handleKeyExchange(msg: SyncMessage): Promise<void> {
    const publicKeyBase64 = msg.publicKey || ''
    if (publicKeyBase64.length === 0) {
      console.info('[SyncManager] keyExchange received without publicKey')
      return
    }

    console.info('[SyncManager] Received keyExchange from ' + msg.deviceId)

    await this.crypto.establishSession(publicKeyBase64)

    if (this.crypto.isEncryptionReady && this.relayPrefs) {
      this.crypto.savePeerPublicKey(this.relayPrefs, publicKeyBase64)

      // 如果本端还未发送公钥，回复之
      if (!this.hasSentKeyExchange) {
        this.sendKeyExchange()
      }

      console.info('[SyncManager] Key exchange complete, encryption active')
    }
  }

  // ============ 中继连接 ============

  private async initRelay(): Promise<void> {
    console.info('[SyncManager] initRelay() called')
    const ctx = this._context
    if (!ctx) {
      console.error('[SyncManager] initRelay: NO CONTEXT, abort')
      return
    }
    // 加载持久化的 Room Key
    if (!this.relayPrefs) {
      try {
        this.relayPrefs = preferences.getPreferencesSync(ctx, { name: 'clipboardsync_relay' })
        console.info('[SyncManager] initRelay: prefs created')
      } catch (_e) {
        console.error('[SyncManager] initRelay: prefs creation failed')
        return
      }
    }
    // 加载已保存的服务器主机
    const savedHost: string = this.relayPrefs.getSync(RelayConfig.HOST_STORAGE_KEY, RelayConfig.DEFAULT_HOST) as string
    if (savedHost.length > 0) {
      this._relayServerHost = savedHost
    }

    const savedKey: string = this.relayPrefs.getSync(RelayConfig.ROOM_KEY_STORAGE_KEY, '') as string
    console.info('[SyncManager] initRelay: savedKey=' + (savedKey.length > 0 ? savedKey : '(empty)'))
    if (savedKey.length > 0) {
      this._roomKey = savedKey
      const url = RelayConfig.buildURL(this._relayServerHost)
      console.info('[SyncManager] initRelay: connecting to ' + url)
      this.wsClient.connect(url, savedKey)
    } else {
      console.info('[SyncManager] initRelay: no saved key, waiting for TCP roomKeyInfo')
    }
  }

  /**
   * 用户设置/更新 Room Key 并连接中继
   * @param roomKey 6 位配对码
   */
  setRoomKey(roomKey: string): void {
    if (roomKey.length !== RelayConfig.ROOM_KEY_LENGTH) {
      console.error('[SyncManager] Invalid room key length: ' + roomKey.length)
      return
    }
    this._roomKey = roomKey
    // 持久化
    if (this.relayPrefs) {
      this.relayPrefs.putSync(RelayConfig.ROOM_KEY_STORAGE_KEY, roomKey)
      this.relayPrefs.flush()
    }
    // 先断开旧连接（如果有），再用新 key 连接
    this.wsClient.disconnect()
    const url = RelayConfig.buildURL(this._relayServerHost)
    this.wsClient.connect(url, roomKey)
    this._relayStatusText = '正在连接中继...'
    this.onStateChange?.()
  }

  /**
   * 更新中继服务器地址并重连
   * @param host IP 地址或域名
   */
  updateRelayHost(host: string): void {
    const trimmed = host.trim()
    if (trimmed.length === 0) {
      return
    }
    this._relayServerHost = trimmed
    // 持久化
    if (this.relayPrefs) {
      this.relayPrefs.putSync(RelayConfig.HOST_STORAGE_KEY, trimmed)
      this.relayPrefs.flush()
    }
    // 断开旧连接，用新地址重连
    this.wsClient.disconnect()
    if (this._roomKey.length > 0) {
      const url = RelayConfig.buildURL(trimmed)
      this.wsClient.connect(url, this._roomKey)
      this._relayStatusText = '服务器地址已更新，重连中...'
    } else {
      this._relayStatusText = '服务器地址已更新'
    }
    this.onStateChange?.()
  }

  /**
   * 清除已保存的 Room Key 并断开中继
   */
  clearRoomKey(): void {
    this._roomKey = ''
    if (this.relayPrefs) {
      this.relayPrefs.putSync(RelayConfig.ROOM_KEY_STORAGE_KEY, '')
      this.relayPrefs.flush()
      this.crypto.clearSession(this.relayPrefs)
    }
    this.wsClient.disconnect()
    this._relayPairedDeviceId = ''
    this._relayStatusText = ''
    this.hasSentKeyExchange = false
    this.onStateChange?.()
  }

  // ============ 接收远端消息 ============

  private async handleRemoteMessage(msg: SyncMessage): Promise<void> {
    console.info('[SyncManager] ←←← handleRemoteMessage: type=' + msg.type + ' contentLen=' + msg.content.length)
    let decryptedMsg = msg

    // 密钥交换（必须在解密之前处理）
    if (msg.type === MessageType.KEY_EXCHANGE) {
      await this.handleKeyExchange(msg)
      return
    }

    // 解密数据消息
    if (this.shouldEncryptType(msg.type) && this.crypto.isEncryptionReady) {
      try {
        decryptedMsg.content = await this.crypto.decrypt(
          msg.content,
          msg.deviceId,
          msg.type
        )
        // 用一个带解密后 content 的新对象继续
        decryptedMsg = {
          type: msg.type,
          content: decryptedMsg.content,
          timestamp: msg.timestamp,
          deviceId: msg.deviceId,
          mimeType: msg.mimeType,
          networkSSID: msg.networkSSID,
          roomKey: msg.roomKey,
          relayHost: msg.relayHost,
          publicKey: msg.publicKey,
          transferId: msg.transferId,
          chunkIndex: msg.chunkIndex,
          totalChunks: msg.totalChunks,
          fileName: msg.fileName,
          fileSize: msg.fileSize,
          imageWidth: msg.imageWidth,
          imageHeight: msg.imageHeight,
          format: msg.format,
          fileCount: msg.fileCount
        }
      } catch (e) {
        console.error('[SyncManager] Decryption failed: ' + JSON.stringify(e) + ', treating as plaintext')
        // 不 return，继续用原始 decryptedMsg（兼容未加密的对端）
      }
    }

    // roomKeyInfo 消息不参与去重判断
    if (decryptedMsg.type === MessageType.ROOM_KEY_INFO) {
      this.handleRoomKeyInfo(decryptedMsg)
      return
    }

    // 去重检查：仅忽略自己刚发出去的消息回环
    if (decryptedMsg.timestamp <= this.lastSentTimestamp &&
        decryptedMsg.deviceId === ProtocolConst.DEVICE_ID) {
      return
    }

    switch (decryptedMsg.type) {
      case MessageType.CLIPBOARD_TEXT:
        console.info('[SyncManager] →→→ writeClipboardText: len=' + decryptedMsg.content.length)
        this.writeClipboardText(decryptedMsg.content)
        this.addRecord(decryptedMsg.content, 'received')
        break
      case MessageType.CLIPBOARD_IMAGE:
        if (!this.handleChunk(decryptedMsg)) {
          this.writeClipboardImage(decryptedMsg)
        }
        break
      case MessageType.CLIPBOARD_FILE:
        if (!this.handleChunk(decryptedMsg)) {
          this.writeClipboardFile(decryptedMsg)
        }
        break
      case MessageType.CLIPBOARD_DATA_CHUNK:
        this.handleChunk(decryptedMsg)
        break
      case MessageType.PING:
      case MessageType.PONG:
      case MessageType.KEY_EXCHANGE:
        break
    }

    this._lastSyncTime = new Date().toLocaleTimeString()
    this.onStateChange?.()
  }

  /**
   * 处理 Mac 通过 TCP 发来的 roomKey 信息
   * 自动更新当前 WiFi 对应的 NetworkProfile 中的 roomKey（仅记录，不主动切换中继）
   * 中继切换由 onNetworkMatched（WiFi 匹配）统一触发
   */
  private async handleRoomKeyInfo(msg: SyncMessage): Promise<void> {
    const roomKey = msg.roomKey || ''
    const relayHost = msg.relayHost || RelayConfig.DEFAULT_HOST

    console.info('[SyncManager] Received roomKeyInfo: roomKey=' + roomKey + ' relayHost=' + relayHost)

    if (roomKey.length === 0) {
      return
    }

    // 保存到待写入 Profile 的缓存
    this._pendingRoomKey = roomKey
    this._pendingRelayHost = relayHost

    // 如果当前已连接 WiFi，静默更新 Profile（不触发中继切换）
    const currentSSID = this.networkCtx.getCurrentSSID()
    if (currentSSID.length > 0) {
      await this.networkCtx.updateProfileRoomKey(currentSSID, roomKey, relayHost)
    }

    // 仅在手机完全没有 roomKey 时自动设置（首次配队场景）
    if (this._roomKey.length === 0) {
      console.info('[SyncManager] First-time auto-set relay roomKey from Mac: ' + roomKey)
      this._roomKey = roomKey
      this._relayServerHost = relayHost
      if (this.relayPrefs) {
        this.relayPrefs.putSync(RelayConfig.ROOM_KEY_STORAGE_KEY, roomKey)
        this.relayPrefs.putSync(RelayConfig.HOST_STORAGE_KEY, relayHost)
        this.relayPrefs.flush()
      }
      const url = RelayConfig.buildURL(relayHost)
      this.wsClient.connect(url, roomKey)
      this._relayStatusText = '已通过局域网获取配对码'
      this.onStateChange?.()
    }
    // 注意：如果已有 roomKey 且与收到的不一致，不在此处切换
    // 中继切换由 onNetworkMatched（WiFi 网络匹配）统一触发，避免重复切换
  }

  /**
   * 切换到指定 roomKey 的中继房间（双 Mac 场景切换）
   */
  private switchRelayRoomKey(roomKey: string, relayHost: string): void {
    // 防重入：正在切换中则跳过
    if (this._isSwitchingRelay) {
      console.info('[SyncManager] switchRelayRoomKey skipped: already switching')
      return
    }
    // 已是目标 roomKey 则跳过
    if (this._roomKey === roomKey && this._relayServerHost === relayHost && this.wsClient.connected) {
      console.info('[SyncManager] switchRelayRoomKey skipped: already on target roomKey')
      return
    }

    console.info('[SyncManager] Switching relay to roomKey=' + roomKey + ' host=' + relayHost)
    this._isSwitchingRelay = true
    this._roomKey = roomKey
    this._relayServerHost = relayHost
    // 持久化
    if (this.relayPrefs) {
      this.relayPrefs.putSync(RelayConfig.ROOM_KEY_STORAGE_KEY, roomKey)
      this.relayPrefs.putSync(RelayConfig.HOST_STORAGE_KEY, relayHost)
      this.relayPrefs.flush()
    }
    // 断开旧中继，用新 roomKey 重连
    this.wsClient.disconnect()
    const url = RelayConfig.buildURL(relayHost)
    this.wsClient.connect(url, roomKey)
    this._relayStatusText = '已切换到当前 Mac 的中继房间'
    this.onStateChange?.()

    // 延迟重置重入标记（等连接完成）
    setTimeout(() => {
      this._isSwitchingRelay = false
    }, 3000)
  }

  // ============ 剪贴板监听 ============

  private startClipboardListener(): void {
    // 事件监听：前台时即时响应剪贴板变化
    try {
      this.systemPasteboard.on('update', () => {
        if (this.isRemoteUpdate) {
          return
        }
        console.info('[SyncManager] Clipboard update event fired')
        this._clipboardDirty = true
        this.onClipboardChanged()
      })
    } catch (e) {
      console.error('[SyncManager] Failed to register clipboard listener: ' + JSON.stringify(e))
    }

    // 轮询兜底：某些设备上 on('update') 触发后 getData 返回空，或后台时事件不触发
    this.pollTimerId = setInterval(() => {
      if (this.isRemoteUpdate) {
        return
      }
      try {
        const changeCount = this.systemPasteboard.getChangeCount()
        if (changeCount !== this.lastChangeCount) {
          console.info('[SyncManager] Clipboard change detected via poll: ' + this.lastChangeCount + ' -> ' + changeCount)
          this.lastChangeCount = changeCount
          this._clipboardDirty = true
          this.onClipboardChanged()
        }
      } catch (e) {
        // silent
      }
    }, ProtocolConst.CLIPBOARD_POLL_INTERVAL) as number
  }

  private stopClipboardPoll(): void {
    if (this.pollTimerId !== -1) {
      clearInterval(this.pollTimerId)
      this.pollTimerId = -1
    }
    try {
      this.systemPasteboard.off('update')
    } catch (_e) {
      // ignore
    }
  }

  private onClipboardChanged(): void {
    if (!this.tcpClient.connected && !this.wsClient.connected) {
      // 尚未连接，读剪贴板并缓存
      this.readAndCacheClipboard()
      return
    }
    this.readClipboardAndSend()
  }

  private readAndCacheClipboard(): void {
    this.systemPasteboard.getData().then((data: pasteboard.PasteData) => {
      if (!data) {
        return
      }
      const text = this.extractText(data)
      if (text.length > 0) {
        this._cachedClipboardText = text
        console.info('[SyncManager] Clipboard cached (not connected): len=' + text.length)
      }
    }).catch((_err: Error) => { /* silent */ })
  }

  private readClipboardAndSend(): void {
    this.systemPasteboard.getData().then(async (data: pasteboard.PasteData) => {
      if (!data) {
        console.info('[SyncManager] readClipboard: data is null')
        return
      }
      const text = this.extractText(data)
      console.info('[SyncManager] readClipboard: text length=' + text.length)
      if (text.length > 0 && text !== this._cachedClipboardText) {
        this._cachedClipboardText = text
        this.sendClipboardText(text)
        this.addRecord(text, 'sent')
      } else {
        // 剪贴板无变化，清除脏标记
        this._clipboardDirty = false
      }
    }).catch((err: Error) => {
      console.error('[SyncManager] readClipboard error: ' + err.message)
    })
  }

  private extractText(data: pasteboard.PasteData): string {
    let text: string | null = data.getPrimaryText()
    if (!text || text.length === 0) {
      try {
        const html = data.getPrimaryHtml()
        if (html && html.length > 0) {
          text = html.replace(/<[^>]*>/g, '').replace(/&nbsp;/g, ' ')
                     .replace(/&lt;/g, '<').replace(/&gt;/g, '>')
                     .replace(/&amp;/g, '&').trim()
        }
      } catch (_h) { /* no html */ }
    }
    return text || ''
  }

  /**
   * 连接建立后 + 从后台切回前台时调用，发送缓存或重新读取剪贴板
   */
  onAppForeground(): void {
    console.info('[SyncManager] onAppForeground: dirty=' + this._clipboardDirty + ' cachedLen=' + this._cachedClipboardText.length)
    try {
      const changeCount = this.systemPasteboard.getChangeCount()
      if (changeCount !== this.lastChangeCount) {
        this.lastChangeCount = changeCount
        this._clipboardDirty = true
      }
    } catch (_e) { /* silent */ }

    // 记录本次前台恢复时是否检测到本地变化
    const hadLocalChange = this._clipboardDirty
    this.onClipboardChanged()

    if (this.pendingFiles.length > 0) {
      console.info('[SyncManager] onAppForeground: flushing ' + this.pendingFiles.length + ' pending files')
      for (let i = 0; i < this.pendingFiles.length; i++) {
        this.onPendingFileReceived?.(this.pendingFiles[i])
      }
    }

    // 只有本地无变化时才拉取 Mac 剪贴板，防止 Mac 旧内容覆盖刚推送的本地内容
    // 等 Mac 确认收到并自身剪贴板更新后，下次 poll 自然是最新的
    if (!hadLocalChange) {
      setTimeout(() => {
        this.addImmediatePoll()
      }, 1500)
    } else {
      console.info('[SyncManager] onAppForeground: skipping poll (just pushed local clipboard)')
    }
  }

  private addImmediatePoll(): void {
    if (this.tcpClient.connected || this.wsClient.connected) {
      this.requestRemoteClipboard()
    } else {
      console.info('[SyncManager] addImmediatePoll: not connected, reconnecting')
      void this.ensureConnectionOnWakeup()
    }
  }

  private async ensureConnectionOnWakeup(): Promise<void> {
    if (this.tcpClient.connected) {
      console.info('[SyncManager] ensureConnectionOnWakeup: already connected, skipping')
      return
    }
    if (this._connectingIp.length > 0) {
      console.info('[SyncManager] ensureConnectionOnWakeup: already connecting to ' + this._connectingIp + ', skipping')
      return
    }
    const ssid = this.networkCtx.getCurrentSSID()
    if (ssid.length > 0) {
      const profile = await this.networkCtx.getProfileBySSID(ssid)
      if (profile && profile.macIP.length > 0) {
        console.info('[SyncManager] Wakeup: reconnecting TCP to ' + profile.macIP)
        this.setupTcpClient(profile.macIP)
        return
      }
    }
    if (this._roomKey.length > 0) {
      const url = RelayConfig.buildURL(this._relayServerHost)
      console.info('[SyncManager] Wakeup: reconnecting WS to ' + url)
      this.wsClient.forceReconnect(url, this._roomKey)
    }
  }

  private requestRemoteClipboard(): void {
    if (!this.tcpClient.connected && !this.wsClient.connected) {
      console.info('[SyncManager] requestRemoteClipboard: not connected, skipping')
      return
    }
    const msg: SyncMessage = {
      type: MessageType.CLIPBOARD_POLL,
      content: '',
      timestamp: Date.now() / 1000,
      deviceId: ProtocolConst.DEVICE_ID
    }
    void this.sendMsg(msg)
    console.info('[SyncManager] requestRemoteClipboard: sent CLIPBOARD_POLL')
  }

  private startBackgroundPoll(): void {
    this.stopBackgroundPoll()
    this.screenWasOff = false
    this.pollTickCount = 0
    this.backgroundPollTimerId = setInterval(() => {
      let active: boolean = false
      try {
        active = power.isActive()
      } catch (_e) { /* ignore */ }

      if (!active) {
        this.screenWasOff = true
        return
      }

      // 亮屏时：强制重连，重连成功后回调中会自动 POLL
      if (this.screenWasOff) {
        this.screenWasOff = false
        this.pollTickCount = 0
        console.info('[SyncManager] backgroundPoll: screen just woke up, reconnecting')
        void this.ensureConnectionOnWakeup()
        return
      }

      // 后台检测本地剪贴板变化（推送到 Mac）
      if (!this.isRemoteUpdate) {
        try {
          const cc = this.systemPasteboard.getChangeCount()
          if (cc !== this.lastChangeCount) {
            this.lastChangeCount = cc
            console.info('[SyncManager] backgroundPoll: local clipboard changed')
            this.onClipboardChanged()
          }
        } catch (_e) { /* silent */ }
      }

      this.pollTickCount++
      // 30s / 5s = 6 ticks
      if (this.pollTickCount >= 6) {
        this.pollTickCount = 0
        if (this.tcpClient.connected || this.wsClient.connected) {
          console.info('[SyncManager] backgroundPoll: periodic poll (30s)')
          this.requestRemoteClipboard()
        } else {
          console.info('[SyncManager] backgroundPoll: not connected, reconnecting')
          void this.ensureConnectionOnWakeup()
        }
      }
    }, 5000) as number
    console.info('[SyncManager] backgroundPoll started (5s check, 30s poll, screen-gated, local-clipboard-detect)')
  }

  private stopBackgroundPoll(): void {
    if (this.backgroundPollTimerId !== -1) {
      clearInterval(this.backgroundPollTimerId)
      this.backgroundPollTimerId = -1
      console.info('[SyncManager] backgroundPoll stopped')
    }
  }

  /**
   * 连接可用时尝试发送剪贴板缓存
   */
  private flushPendingClipboard(): void {
    if (this._cachedClipboardText.length === 0) {
      return
    }
    if (!this.tcpClient.connected && !this.wsClient.connected) {
      return
    }
    console.info('[SyncManager] Flushing cached clipboard: len=' + this._cachedClipboardText.length)
    this.sendClipboardText(this._cachedClipboardText)
    this.addRecord(this._cachedClipboardText, 'sent')
    this._cachedClipboardText = ''
    this._clipboardDirty = false
  }

  /**
   * 手动发送文本到对端（降级方案：无需读剪贴板权限）
   */
  manualSendText(text: string): void {
    if (text.length === 0) {
      return
    }
    if (!this.tcpClient.connected && !this.wsClient.connected) {
      // 未连接时缓存文本，连接建立后由 flushPendingClipboard() 自动发送
      console.info('[SyncManager] manualSendText: not connected, caching for later: len=' + text.length)
      this._cachedClipboardText = text
      this._clipboardDirty = true
      return
    }
    this.sendClipboardText(text)
    this.addRecord(text, 'sent')
  }

  // ============ 发送消息 ============

  private sendClipboardText(text: string): void {
    const timestamp = Date.now() / 1000
    this.lastSentTimestamp = timestamp
    console.info('[SyncManager] sendClipboardText: len=' + text.length + ' tcp=' + this.tcpClient.connected + ' ws=' + this.wsClient.connected)

    const msg: SyncMessage = {
      type: MessageType.CLIPBOARD_TEXT,
      content: text,
      timestamp: timestamp,
      deviceId: ProtocolConst.DEVICE_ID,
      mimeType: 'text/plain'
    }
    // WS 中继优先（跨网络可靠），TCP 仅作局域网加速
    if (this.wsClient.connected) {
      this.wsClient.sendRelay(msg)
    }
    if (this.tcpClient.connected) {
      this.tcpClient.send(msg)
    }
    if (!this.tcpClient.connected && !this.wsClient.connected) {
      console.warn('[SyncManager] sendClipboardText: NO connection available, message dropped!')
    }
  }

  // ============ 二维码配对 ============

  /**
   * 解析二维码扫描结果，自动完成配对连接
   * 二维码格式: {"v":1,"rk":"A1B2C3","rh":"host","ip":"192.168.1.5"}
   */
  processQRCode(qrData: string): void {
    console.info('[SyncManager] processQRCode: ' + qrData)
    try {
      const data = JSON.parse(qrData) as Record<string, Object>
      if (!data || (data.v as number) !== 1) {
        console.error('[SyncManager] Invalid QR code: wrong version')
        return
      }

      const roomKey: string = (data.rk as string) || ''
      const relayHost: string = (data.rh as string) || ''
      const localIP: string = (data.ip as string) || ''

      if (roomKey.length === RelayConfig.ROOM_KEY_LENGTH) {
        // 更新中继服务器地址
        if (relayHost.length > 0) {
          this.updateRelayHost(relayHost)
        }
        // 设置配对码并连接中继
        this.setRoomKey(roomKey)
        console.info('[SyncManager] QR code: relay paired')
      }

      // 同一 WiFi 下可尝试直连
      if (localIP.length > 0 && !this.tcpClient.connected) {
        setTimeout(() => {
          this.connectManual(localIP)
        }, 1000)
        console.info('[SyncManager] QR code: connecting TCP to ' + localIP)
      }
    } catch (e) {
      console.error('[SyncManager] QR code parse error: ' + JSON.stringify(e))
    }
  }

  // ============ 写入剪贴板 ============

  writeClipboardText(text: string): void {
    this.isRemoteUpdate = true
    console.info('[SyncManager] writeClipboardText (remote): len=' + text.length)
    try {
      const data = pasteboard.createData(pasteboard.MIMETYPE_TEXT_PLAIN, text)
      this.systemPasteboard.setDataSync(data)
      this.lastChangeCount = this.systemPasteboard.getChangeCount()
      this._cachedClipboardText = text
      this._clipboardDirty = false
    } catch (_e) {
      // ignore
    }
    this.isRemoteUpdate = false
  }

  // ============ 公共发送 ============

  private async sendMsg(msg: SyncMessage): Promise<void> {
    let msgToSend = msg

    // 对数据消息进行端到端加密
    if (this.shouldEncryptType(msg.type) && this.crypto.isEncryptionReady) {
      try {
        msgToSend.content = await this.crypto.encrypt(
          msg.content,
          msg.deviceId,
          msg.type
        )
      } catch (e) {
        console.error('[SyncManager] Encryption failed: ' + JSON.stringify(e))
        return // 丢弃消息
      }
    }

    // WS 中继优先（跨网络可靠），TCP 仅作局域网加速
    if (this.wsClient.connected) {
      this.wsClient.sendRelay(msgToSend)
    }
    if (this.tcpClient.connected) {
      this.tcpClient.send(msgToSend)
    }
  }

  /**
   * 判断某类消息是否需要加密
   */
  private shouldEncryptType(type: MessageType): boolean {
    if (type === MessageType.CLIPBOARD_TEXT ||
        type === MessageType.CLIPBOARD_IMAGE ||
        type === MessageType.CLIPBOARD_FILE ||
        type === MessageType.CLIPBOARD_DATA_CHUNK) {
      return true
    }
    return false
  }

  // ============ 图片发送 ============

  private sendClipboardImage(payload: ImagePayload): void {
    const timestamp = Date.now() / 1000
    this.lastSentTimestamp = timestamp
    const dateStr = new Date().toISOString().replace(/[:.]/g, '')
    const msg: SyncMessage = {
      type: MessageType.CLIPBOARD_IMAGE,
      content: payload.base64,
      timestamp: timestamp,
      deviceId: ProtocolConst.DEVICE_ID,
      mimeType: 'image/jpeg',
      imageWidth: payload.width,
      imageHeight: payload.height,
      fileSize: payload.size,
      format: 'jpeg',
      fileName: 'clipboard_' + dateStr + '.jpeg'
    }

    if (payload.size <= 500 * 1024) {
      console.info('[SyncManager] sendImage: single msg, size=' + payload.size)
      void this.sendMsg(msg)
    } else {
      console.info('[SyncManager] sendImage: chunked, size=' + payload.size)
      const base64 = new util.Base64Helper()
      const buffer = base64.decodeSync(payload.base64)
      this.sendInChunks(msg, buffer)
    }
  }

  // ============ 手动选择图片发送 ============

  async selectAndSendImage(): Promise<void> {
    console.info('[SyncManager] selectAndSendImage: opening picker...')
    try {
      const photoSelectOptions = new photoAccessHelper.PhotoSelectOptions()
      photoSelectOptions.MIMEType = photoAccessHelper.PhotoViewMIMETypes.IMAGE_TYPE
      photoSelectOptions.maxSelectNumber = 10
      const photoPicker = new photoAccessHelper.PhotoViewPicker()
      const result: photoAccessHelper.PhotoSelectResult = await photoPicker.select(photoSelectOptions)
      const uris: string[] = result.photoUris
      console.info('[SyncManager] selectAndSendImage: selected ' + uris.length + ' images')

      if (uris.length === 0) {
        return
      }

      for (let i = 0; i < uris.length; i++) {
        const uri: string = uris[i]
        console.info('[SyncManager] selectAndSendImage: processing ' + uri)

        // 从 URI 读取文件数据
        let file = fileIo.openSync(uri, fileIo.OpenMode.READ_ONLY)
        const stat = fileIo.statSync(uri)
        const buffer = new ArrayBuffer(stat.size)
        fileIo.readSync(file.fd, buffer)
        fileIo.closeSync(file)

        // 解码为 PixelMap
        const imageSource: image.ImageSource = image.createImageSource(buffer)
        const pixelMap: image.PixelMap = await imageSource.createPixelMap()
        const imageInfo: image.ImageInfo = await pixelMap.getImageInfo()
        let width: number = imageInfo.size.width
        let height: number = imageInfo.size.height
        console.info('[SyncManager] selectAndSendImage: decoded ' + width + 'x' + height)
        imageSource.release()

        // 缩放
        const maxLongSide: number = 1920
        if (Math.max(width, height) > maxLongSide) {
          const scaleRatio: number = maxLongSide / Math.max(width, height)
          const newWidth: number = Math.round(width * scaleRatio)
          const newHeight: number = Math.round(height * scaleRatio)
          try {
            await pixelMap.scale(newWidth / width, newHeight / height)
            width = newWidth
            height = newHeight
          } catch (_e) {
            // ignore
          }
        }

        // JPEG 编码
        const imagePacker: image.ImagePacker = image.createImagePacker()
        const packOpts: image.PackingOption = { format: 'image/jpeg', quality: 80 }
        let buf: ArrayBuffer = await imagePacker.packToData(pixelMap, packOpts)
        imagePacker.release()
        console.info('[SyncManager] selectAndSendImage: JPEG encoded, size=' + buf.byteLength)

        const base64Helper = new util.Base64Helper()
        const base64: string = base64Helper.encodeToStringSync(new Uint8Array(buf))
        const payload: ImagePayload = { base64: base64, width: width, height: height, size: buf.byteLength, format: 'jpeg' }
        this.sendClipboardImage(payload)
        this.addRecord('[图片] ' + width + 'x' + height, 'sent')
      }
    } catch (err) {
      console.error('[SyncManager] selectAndSendImage error: ' + JSON.stringify(err))
    }
  }

  // ============ 手动选择文件发送 ============

  async selectAndSendFile(): Promise<void> {
    console.info('[SyncManager] selectAndSendFile: opening picker...')
    try {
      const options = new picker.DocumentSelectOptions()
      options.maxSelectNumber = 1
      const documentPicker = new picker.DocumentViewPicker()
      const result: string[] = await documentPicker.select(options)
      if (!result || result.length === 0) {
        return
      }
      const uri: string = result[0]
      console.info('[SyncManager] selectAndSendFile: selected ' + uri)

      const file = fileIo.openSync(uri, fileIo.OpenMode.READ_ONLY)
      const stat = fileIo.statSync(uri)
      const buffer = new ArrayBuffer(stat.size)
      fileIo.readSync(file.fd, buffer)
      fileIo.closeSync(file)

      const fileName: string = uri.substring(uri.lastIndexOf('/') + 1) || 'unknown_file'
      const fileSize: number = stat.size
      console.info('[SyncManager] selectAndSendFile: ' + fileName + ' size=' + fileSize)

      this.sendFile(buffer, fileName, fileSize)
      this.addRecord('[文件] ' + fileName, 'sent')
    } catch (err) {
      console.error('[SyncManager] selectAndSendFile error: ' + JSON.stringify(err))
    }
  }

  private sendFile(data: ArrayBuffer, fileName: string, fileSize: number): void {
    const timestamp = Date.now() / 1000
    this.lastSentTimestamp = timestamp
    const base64Helper = new util.Base64Helper()
    const base64: string = base64Helper.encodeToStringSync(new Uint8Array(data))

    const msg: SyncMessage = {
      type: MessageType.CLIPBOARD_FILE,
      content: base64,
      timestamp: timestamp,
      deviceId: ProtocolConst.DEVICE_ID,
      mimeType: 'application/octet-stream',
      fileName: fileName,
      fileSize: fileSize
    }

    if (fileSize <= 500 * 1024) {
      console.info('[SyncManager] sendFile: single msg, size=' + fileSize)
      void this.sendMsg(msg)
    } else {
      console.info('[SyncManager] sendFile: chunked, size=' + fileSize)
      this.sendInChunks(msg, new Uint8Array(data))
    }
  }

  // ============ 接收其他 App 分享内容 ============

  async handleSharedContent(want: Want): Promise<void> {
    console.info('[SyncManager] handleSharedContent: action=' + want.action)

    const uris: string[] = []
    if (want.uri && want.uri.length > 0) {
      uris.push(want.uri)
      console.info('[SyncManager] handleSharedContent: want.uri=' + want.uri)
    }

    const params = want.parameters as Record<string, Object> | undefined
    if (params) {
      const stream = params['ability.params.stream'] as string[] | undefined
      if (stream) {
        for (let i = 0; i < stream.length; i++) {
          uris.push(stream[i])
        }
        console.info('[SyncManager] handleSharedContent: stream count=' + stream.length)
      }
    }

    if (uris.length === 0) {
      console.info('[SyncManager] handleSharedContent: no URIs found')
      return
    }

    if (this._status === SyncStatus.DISCONNECTED) {
      console.info('[SyncManager] handleSharedContent: starting sync manager...')
      this.start()
      let waited: number = 0
      let connected: boolean = false
      while (waited < 10000) {
        await new Promise<void>((r: Function) => setTimeout(r, 500))
        waited += 500
        if (this.status === SyncStatus.CONNECTED) {
          connected = true
          break
        }
      }
      if (!connected) {
        console.warn('[SyncManager] handleSharedContent: connection timeout, aborting')
        return
      }
    }

    for (let i = 0; i < uris.length; i++) {
      await this.processSharedUri(uris[i])
    }
  }

  private async processSharedUri(uri: string): Promise<void> {
    console.info('[SyncManager] processSharedUri: ' + uri)
    try {
      const file = fileIo.openSync(uri, fileIo.OpenMode.READ_ONLY)
      const stat = fileIo.statSync(uri)
      const buffer = new ArrayBuffer(stat.size)
      fileIo.readSync(file.fd, buffer)
      fileIo.closeSync(file)

      const fileName: string = uri.substring(uri.lastIndexOf('/') + 1) || 'shared_file'
      const fileSize: number = stat.size

      const isImage: boolean = fileName.endsWith('.jpg') || fileName.endsWith('.jpeg') ||
        fileName.endsWith('.png') || fileName.endsWith('.gif') ||
        fileName.endsWith('.webp') || fileName.endsWith('.bmp') ||
        fileName.endsWith('.heic') || fileName.endsWith('.heif')

      if (isImage) {
        const imageSource: image.ImageSource = image.createImageSource(buffer)
        const pixelMap: image.PixelMap = await imageSource.createPixelMap()
        const imageInfo: image.ImageInfo = await pixelMap.getImageInfo()
        let width: number = imageInfo.size.width
        let height: number = imageInfo.size.height
        imageSource.release()

        const maxLongSide: number = 1920
        if (Math.max(width, height) > maxLongSide) {
          const scaleRatio: number = maxLongSide / Math.max(width, height)
          const newWidth: number = Math.round(width * scaleRatio)
          const newHeight: number = Math.round(height * scaleRatio)
          try {
            await pixelMap.scale(newWidth / width, newHeight / height)
            width = newWidth
            height = newHeight
          } catch (_e) { /* ignore */ }
        }

        const imagePacker: image.ImagePacker = image.createImagePacker()
        const packOpts: image.PackingOption = { format: 'image/jpeg', quality: 80 }
        let jpegBuf: ArrayBuffer = await imagePacker.packToData(pixelMap, packOpts)
        imagePacker.release()

        const base64Helper = new util.Base64Helper()
        const base64: string = base64Helper.encodeToStringSync(new Uint8Array(jpegBuf))
        const payload: ImagePayload = {
          base64: base64, width: width, height: height, size: jpegBuf.byteLength, format: 'jpeg'
        }
        this.sendClipboardImage(payload)
        this.addRecord('[图片] ' + width + 'x' + height + ' (分享)', 'sent')
        console.info('[SyncManager] processSharedUri: image sent, size=' + jpegBuf.byteLength)
      } else {
        this.sendFile(buffer, fileName, fileSize)
        this.addRecord('[文件] ' + fileName + ' (分享)', 'sent')
        console.info('[SyncManager] processSharedUri: file sent, size=' + fileSize)
      }
    } catch (e) {
      console.error('[SyncManager] processSharedUri error: ' + JSON.stringify(e))
    }
  }

  // ============ 图片提取 ============

  private async extractImage(data: pasteboard.PasteData): Promise<ImagePayload | null> {
    const recordCount: number = data.getRecordCount()
    console.info('[SyncManager] extractImage: recordCount=' + recordCount)
    for (let i = 0; i < recordCount; i++) {
      const record: pasteboard.PasteDataRecord = data.getRecord(i)
      const pixelMapValue: image.PixelMap | undefined = record.pixelMap
      const uriValue: string | undefined = record.uri
      console.info('[SyncManager] extractImage: record[' + i + '] hasPixelMap=' + (pixelMapValue !== undefined) + ' hasUri=' + (uriValue !== undefined))
      if (pixelMapValue) {
        let pixelMap: image.PixelMap = pixelMapValue

        const imageInfo: image.ImageInfo = await pixelMap.getImageInfo()
        let width: number = imageInfo.size.width
        let height: number = imageInfo.size.height
        console.info('[SyncManager] extractImage: original=' + width + 'x' + height)

        // 缩放（长边 > 1920px）
        const maxLongSide: number = 1920
        if (Math.max(width, height) > maxLongSide) {
          const scaleRatio: number = maxLongSide / Math.max(width, height)
          const newWidth: number = Math.round(width * scaleRatio)
          const newHeight: number = Math.round(height * scaleRatio)
          try {
            await pixelMap.scale(newWidth / width, newHeight / height)
            width = newWidth
            height = newHeight
            console.info('[SyncManager] extractImage: scaled to ' + width + 'x' + height)
          } catch (_e) {
            console.error('[SyncManager] scale failed, using original')
          }
        }

        // JPEG 编码
        const imagePacker: image.ImagePacker = image.createImagePacker()
        const packOpts: image.PackingOption = { format: 'image/jpeg', quality: 80 }
        let buf: ArrayBuffer | null = null
        try {
          buf = await imagePacker.packToData(pixelMap, packOpts)
          console.info('[SyncManager] extractImage: JPEG encoded, size=' + buf.byteLength)
        } catch (_e) {
          console.error('[SyncManager] packToData failed')
          continue
        }
        imagePacker.release()

        if (buf.byteLength > 20 * 1024 * 1024) {
          console.warn('[SyncManager] Image too large (' + buf.byteLength + ' bytes), skipping')
          continue
        }

        const base64Helper = new util.Base64Helper()
        const base64: string = base64Helper.encodeToStringSync(new Uint8Array(buf))
        console.info('[SyncManager] extractImage: success, base64 len=' + base64.length)
        return { base64: base64, width: width, height: height, size: buf.byteLength, format: 'jpeg' }
      }
      // 尝试从 URI 记录加载图片（分享→复制场景）
      if (uriValue) {
        console.info('[SyncManager] extractImage: trying to load from URI: ' + uriValue)
        try {
          const imageSource: image.ImageSource = image.createImageSource(uriValue)
          const pixelMap: image.PixelMap = await imageSource.createPixelMap()
          imageSource.release()

          const imageInfo: image.ImageInfo = await pixelMap.getImageInfo()
          let width: number = imageInfo.size.width
          let height: number = imageInfo.size.height
          console.info('[SyncManager] extractImage: URI loaded, size=' + width + 'x' + height)

          // 缩放
          const maxLongSide: number = 1920
          if (Math.max(width, height) > maxLongSide) {
            const scaleRatio: number = maxLongSide / Math.max(width, height)
            const newWidth: number = Math.round(width * scaleRatio)
            const newHeight: number = Math.round(height * scaleRatio)
            try {
              await pixelMap.scale(newWidth / width, newHeight / height)
              width = newWidth
              height = newHeight
            } catch (_e) {
              // ignore
            }
          }

          // JPEG 编码
          const imagePacker: image.ImagePacker = image.createImagePacker()
          const packOpts: image.PackingOption = { format: 'image/jpeg', quality: 80 }
          let buf: ArrayBuffer | null = null
          try {
            buf = await imagePacker.packToData(pixelMap, packOpts)
            console.info('[SyncManager] extractImage: URI JPEG encoded, size=' + buf.byteLength)
          } catch (_e) {
            console.error('[SyncManager] URI packToData failed')
            continue
          }
          imagePacker.release()

          if (buf.byteLength > 20 * 1024 * 1024) {
            console.warn('[SyncManager] URI image too large, skipping')
            continue
          }

          const base64Helper = new util.Base64Helper()
          const base64: string = base64Helper.encodeToStringSync(new Uint8Array(buf))
          console.info('[SyncManager] extractImage: URI success, base64 len=' + base64.length)
          return { base64: base64, width: width, height: height, size: buf.byteLength, format: 'jpeg' }
        } catch (_e) {
          console.error('[SyncManager] extractImage: URI load failed: ' + JSON.stringify(_e))
        }
      }
    }
    console.info('[SyncManager] extractImage: no image found in any record')
    return null
  }

  // ============ 图片写入剪贴板 ============

  private async writeClipboardImage(msg: SyncMessage): Promise<void> {
    this.isRemoteUpdate = true
    console.info('[SyncManager] writeClipboardImage: size=' + (msg.fileSize ?? 0))

    const base64Helper = new util.Base64Helper()
    const buffer: Uint8Array = base64Helper.decodeSync(msg.content)
    const imageSource: image.ImageSource = image.createImageSource(buffer.buffer as ArrayBuffer)
    const pixelMap: image.PixelMap = await imageSource.createPixelMap()
    imageSource.release()

    const pasteData: pasteboard.PasteData = pasteboard.createData(pasteboard.MIMETYPE_PIXELMAP, pixelMap)
    this.systemPasteboard.setDataSync(pasteData)

    this.lastChangeCount = this.systemPasteboard.getChangeCount()
    this._clipboardDirty = false
    this.isRemoteUpdate = false

    this.addRecord('[图片]', 'received')

    const fileName: string = msg.fileName ?? 'clipboard_' +
      new Date().toISOString().replace(/[:.]/g, '') + '.jpeg'
    const pending: PendingFile = {
      id: util.generateRandomUUID(),
      base64: msg.content,
      fileName: fileName,
      fileSize: msg.fileSize ?? buffer.byteLength,
      mimeType: msg.mimeType ?? 'image/jpeg',
      format: msg.format ?? 'jpeg',
      isImage: true,
      receivedAt: Date.now()
    }
    this.pendingFiles.push(pending)
    this.onPendingFileReceived?.(pending)
  }

  // ============ 文件写入 ============

  private async writeClipboardFile(msg: SyncMessage): Promise<void> {
    this.isRemoteUpdate = true
    const fileName: string = msg.fileName ?? 'received_file'

    this.isRemoteUpdate = false

    this.addRecord('[文件] ' + fileName, 'received')

    const pending: PendingFile = {
      id: util.generateRandomUUID(),
      base64: msg.content,
      fileName: fileName,
      fileSize: msg.fileSize ?? 0,
      mimeType: msg.mimeType ?? 'application/octet-stream',
      format: msg.format ?? '',
      isImage: false,
      receivedAt: Date.now()
    }
    this.pendingFiles.push(pending)
    this.onPendingFileReceived?.(pending)
  }

  /**
   * 将待保存文件写入指定目录
   * @param id 待保存文件 ID
   * @param directoryPath 目标目录路径
   * @returns 保存后的完整文件路径，失败返回空字符串
   */
  async savePendingFile(id: string, directoryPath: string): Promise<string> {
    const index = this.pendingFiles.findIndex((f: PendingFile) => f.id === id)
    if (index === -1) {
      console.error('[SyncManager] savePendingFile: not found ' + id)
      return ''
    }
    const pending: PendingFile = this.pendingFiles[index]
    this.pendingFiles.splice(index, 1)

    const base64Helper = new util.Base64Helper()
    const buffer: Uint8Array = base64Helper.decodeSync(pending.base64)

    let filePath: string = directoryPath + '/' + pending.fileName
    let counter: number = 1
    const ext: string = pending.fileName.includes('.') ?
      pending.fileName.substring(pending.fileName.lastIndexOf('.')) : ''
    const baseName: string = pending.fileName.includes('.') ?
      pending.fileName.substring(0, pending.fileName.lastIndexOf('.')) : pending.fileName

    try {
      while (fileIo.accessSync(filePath)) {
        filePath = directoryPath + '/' + baseName + ' (' + counter + ')' + ext
        counter++
      }
      const file = fileIo.openSync(filePath,
        fileIo.OpenMode.CREATE | fileIo.OpenMode.WRITE_ONLY)
      fileIo.writeSync(file.fd, buffer.buffer as ArrayBuffer)
      fileIo.closeSync(file)
      console.info('[SyncManager] savePendingFile: saved to ' + filePath)
    } catch (_e) {
      console.error('[SyncManager] savePendingFile: write failed for ' + filePath)
      return ''
    }

    if (!pending.isImage) {
      try {
        this.isRemoteUpdate = true
        const pasteData: pasteboard.PasteData =
          pasteboard.createData(pasteboard.MIMETYPE_TEXT_URI, filePath)
        this.systemPasteboard.setDataSync(pasteData)
        this.isRemoteUpdate = false
      } catch (_e) {
        console.error('[SyncManager] savePendingFile: clipboard write failed')
      }
    }

    return filePath
  }

  // ============ 分片发送 ============

  private sendInChunks(basePayload: SyncMessage, data: Uint8Array): void {
    const chunkSize: number = 256 * 1024
    const totalChunks: number = Math.ceil(data.byteLength / chunkSize)
    const transferId: string = util.generateRandomUUID()
    const base64Helper = new util.Base64Helper()

    for (let i = 0; i < totalChunks; i++) {
      const start: number = i * chunkSize
      const end: number = Math.min((i + 1) * chunkSize, data.byteLength)
      const chunk: Uint8Array = data.slice(start, end)
      const base64: string = base64Helper.encodeToStringSync(chunk)

      if (i === 0) {
        const msg: SyncMessage = {
          type: basePayload.type,
          content: base64,
          timestamp: basePayload.timestamp,
          deviceId: basePayload.deviceId,
          mimeType: basePayload.mimeType,
          transferId: transferId,
          chunkIndex: 0,
          totalChunks: totalChunks,
          fileName: basePayload.fileName,
          fileSize: basePayload.fileSize,
          imageWidth: basePayload.imageWidth,
          imageHeight: basePayload.imageHeight,
          format: basePayload.format
        }
        void this.sendMsg(msg)
      } else {
        const msg: SyncMessage = {
          type: MessageType.CLIPBOARD_DATA_CHUNK,
          content: base64,
          timestamp: Date.now() / 1000,
          deviceId: ProtocolConst.DEVICE_ID,
          transferId: transferId,
          chunkIndex: i,
          totalChunks: totalChunks
        }
        void this.sendMsg(msg)
      }
    }
  }

  // ============ 分片接收 ============

  private handleChunk(msg: SyncMessage): boolean {
    if (!msg.transferId || (msg.totalChunks ?? 1) <= 1) {
      return false
    }

    let buffer: ChunkBuffer = this.chunkBuffers.get(msg.transferId) ?? {
      transferId: msg.transferId,
      totalChunks: msg.totalChunks!,
      chunks: new Map<number, string>(),
      metadata: msg,
      timestamp: Date.now()
    }

    buffer.chunks.set(msg.chunkIndex!, msg.content)

    if (buffer.chunks.size === buffer.totalChunks) {
      let fullBase64: string = ''
      for (let i = 0; i < buffer.totalChunks; i++) {
        fullBase64 += buffer.chunks.get(i)
      }
      this.chunkBuffers.delete(msg.transferId)

      const fullMsg: SyncMessage = {
        type: buffer.metadata.type,
        content: fullBase64,
        timestamp: buffer.metadata.timestamp,
        deviceId: buffer.metadata.deviceId,
        mimeType: buffer.metadata.mimeType,
        fileName: buffer.metadata.fileName,
        fileSize: buffer.metadata.fileSize,
        imageWidth: buffer.metadata.imageWidth,
        imageHeight: buffer.metadata.imageHeight,
        format: buffer.metadata.format
      }

      if (buffer.metadata.type === MessageType.CLIPBOARD_IMAGE) {
        this.writeClipboardImage(fullMsg)
      } else if (buffer.metadata.type === MessageType.CLIPBOARD_FILE) {
        this.writeClipboardFile(fullMsg)
      }
      return true
    }

    this.chunkBuffers.set(msg.transferId, buffer)
    return true
  }

  // ============ 分片超时清理 ============

  private startChunkCleanup(): void {
    this.chunkCleanupTimer = setInterval(() => {
      const now: number = Date.now()
      const toDelete: string[] = []
      this.chunkBuffers.forEach((buf: ChunkBuffer, id: string) => {
        if (now - buf.timestamp > 30000) {
          console.warn('[SyncManager] Chunk transfer ' + id + ' timed out')
          toDelete.push(id)
        }
      })
      for (let i = 0; i < toDelete.length; i++) {
        this.chunkBuffers.delete(toDelete[i])
      }
    }, 30000) as number
  }

  private stopChunkCleanup(): void {
    if (this.chunkCleanupTimer !== -1) {
      clearInterval(this.chunkCleanupTimer)
      this.chunkCleanupTimer = -1
    }
  }

  // ============ 后台任务 ============

  private _context: Context | null = null

  setContext(ctx: Context): void {
    this._context = ctx
  }

  getContext(): Context | null {
    return this._context
  }

  // ============ 记录管理 ============

  private addRecord(content: string, direction: 'sent' | 'received'): void {
    const record: SyncRecord = {
      id: Date.now().toString(),
      content: content.length > 50 ? content.substring(0, 50) + '...' : content,
      time: new Date().toLocaleTimeString(),
      direction: direction
    }
    this._history.unshift(record)
    if (this._history.length > 50) {
      this._history = this._history.slice(0, 50)
    }
    this.onStateChange?.()
  }
}

// 模块级共享实例，供 EntryAbility 和 Index 共用
let _sharedSyncManager: SyncManager | null = null

export function getSharedSyncManager(): SyncManager {
  if (_sharedSyncManager === null) {
    _sharedSyncManager = new SyncManager()
  }
  return _sharedSyncManager
}
