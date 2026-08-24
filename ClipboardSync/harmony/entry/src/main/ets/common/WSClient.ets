import { webSocket } from '@kit.NetworkKit'
import { SyncMessage, RelayConfig, RelayAction, RelayMessage, ProtocolConst } from './Protocol'
import { BusinessError } from '@kit.BasicServicesKit'
import { util } from '@kit.ArkTS'
import { hilog } from '@kit.PerformanceAnalysisKit'

const TAG: string = 'ClipHarmoMac'
const DOMAIN: number = 0x0000

/**
 * WebSocket 中继客户端
 * 使用 @kit.NetworkKit webSocket 模块
 * 负责连接/认证/心跳/重连/消息收发
 *
 * 假连接检测（重要）：
 * 息屏后系统可能休眠网络，服务器 60s 心跳超时会踢掉本端，
 * 但本地 socket 变成"半开"状态收不到 close 事件，isConnected 永远为 true，
 * 所有消息静默丢失（表现为"显示已连接但发什么都没效果"）。
 * 因此心跳必须双向校验：
 * 1. 发送失败连续 2 次 → 判死
 * 2. 超过 3 个心跳周期（90s）未收到服务器任何消息 → 判死
 */
export class WSClient {

  // 连接模式
  static readonly CONNECTION_MODE_DISCONNECTED: string = 'disconnected'
  static readonly CONNECTION_MODE_CONNECTING: string = 'connecting'
  static readonly CONNECTION_MODE_WAITING_FOR_PAIR: string = 'waitingForPair'
  static readonly CONNECTION_MODE_PAIRED: string = 'paired'

  // 回调
  onConnected?: () => void
  onDisconnected?: () => void
  onMessage?: (msg: SyncMessage) => void
  onPaired?: (deviceId: string) => void
  onPeerGone?: (deviceId: string) => void
  // 发送被丢弃回执（房间内无其他设备），参数为被丢弃的消息类型
  onNoPeer?: (droppedType: string) => void
  onAuthResult?: (success: boolean, pairedDeviceId: string | null) => void
  onError?: (msg: string) => void
  onStatusChange?: (mode: string) => void

  private ws: webSocket.WebSocket | null = null
  private isConnected: boolean = false
  private isConnecting: boolean = false
  private reconnectAttempt: number = 0
  private reconnectTimerId: number = -1
  private heartbeatTimerId: number = -1
  private shouldReconnect: boolean = true
  private targetUrl: string = ''
  private roomKey: string = ''
  private pairedDeviceId: string = ''
  private mode: string = WSClient.CONNECTION_MODE_DISCONNECTED

  // ==== 假连接检测状态 ====
  /// 最近一次收到服务器消息的时间戳（ms）——任何消息都代表服务器可达
  private lastServerActivityMs: number = 0
  /// 连续发送失败次数（收到服务器消息即清零）
  private sendFailCount: number = 0

  get connected(): boolean {
    return this.isConnected
  }

  get currentMode(): string {
    return this.mode
  }

  get currentPairedDeviceId(): string {
    return this.pairedDeviceId
  }

  /**
   * 连接到中继服务器并认证
   * @param url WebSocket URL
   * @param roomKey 加入的房间 Key
   */
  connect(url: string, roomKey: string): void {
    if (this.isConnected || this.isConnecting) {
      hilog.error(DOMAIN, TAG, `[WS] connect() skipped: already connected/connecting (isConnected=${this.isConnected})`)
      return
    }
    this.targetUrl = url
    this.roomKey = roomKey
    this.shouldReconnect = true
    hilog.error(DOMAIN, TAG, `[WS] Connecting to ${url} roomKey=${roomKey}`)
    this.doConnect(url)
  }

  disconnect(): void {
    hilog.error(DOMAIN, TAG, `[WS] disconnect()`)
    this.shouldReconnect = false
    this.cleanup()
    this.closeSocket()
    this.mode = WSClient.CONNECTION_MODE_DISCONNECTED
    this.onStatusChange?.(this.mode)
  }

  forceReconnect(url: string, roomKey: string): void {
    hilog.error(DOMAIN, TAG, `[WS] forceReconnect() to ${url} (wasConnected=${this.isConnected})`)
    this.shouldReconnect = true
    this.targetUrl = url
    this.roomKey = roomKey
    this.closeSocket()
    this.cleanup()
    this.isConnected = false
    this.isConnecting = false
    this.reconnectAttempt = 0
    this.mode = WSClient.CONNECTION_MODE_CONNECTING
    this.onStatusChange?.(this.mode)
    this.doConnect(url)
  }

  /**
   * 通过中继发送剪贴板消息
   * @param msg 剪贴板同步消息
   * @returns 是否发送成功
   */
  sendRelay(msg: SyncMessage): boolean {
    if (!this.ws || !this.isConnected) {
      hilog.error(DOMAIN, TAG, `[WS] sendRelay FAILED: not connected (type=${msg.type})`)
      return false
    }
    const relayMsg: RelayMessage = {
      action: RelayAction.RELAY,
      roomKey: this.roomKey,
      deviceId: ProtocolConst.DEVICE_ID,
      payload: msg
    }
    const jsonStr = JSON.stringify(relayMsg)
    this.ws.send(jsonStr).then(() => {
      hilog.error(DOMAIN, TAG, `[WS] Relay sent OK (type=${msg.type} len=${msg.content.length})`)
    }).catch((err: BusinessError) => {
      this.sendFailCount++
      hilog.error(DOMAIN, TAG, `[WS] Relay send FAILED: code=${err.code} failCount=${this.sendFailCount} (type=${msg.type})`)
      if (this.sendFailCount >= 2) {
        this.handleDeadConnection(`send failed ${this.sendFailCount} times in a row`)
      }
    })
    return true
  }

  /**
   * 发送应用层心跳
   */
  sendPing(): void {
    if (!this.ws || !this.isConnected) {
      return
    }
    const pingMsg: RelayMessage = {
      action: RelayAction.PING,
      deviceId: ProtocolConst.DEVICE_ID
    }
    this.ws.send(JSON.stringify(pingMsg)).then(() => {
      // 发送成功不代表对端收到，真正的判活依据是 lastServerActivityMs
    }).catch((err: BusinessError) => {
      this.sendFailCount++
      hilog.error(DOMAIN, TAG, `[WS] ping send FAILED: code=${err.code} failCount=${this.sendFailCount}`)
      if (this.sendFailCount >= 2) {
        this.handleDeadConnection(`ping failed ${this.sendFailCount} times in a row`)
      }
    })
  }

  // ========== 私有方法 ==========

  private doConnect(url: string): void {
    this.isConnecting = true
    this.mode = WSClient.CONNECTION_MODE_CONNECTING
    this.onStatusChange?.(this.mode)
    this.ws = webSocket.createWebSocket()

    this.ws.on('open', (_err: BusinessError, _value: Object) => {
      hilog.error(DOMAIN, TAG, `[WS] WebSocket opened, sending auth...`)
      // 发送 auth 消息
      const authMsg: RelayMessage = {
        action: RelayAction.AUTH,
        roomKey: this.roomKey,
        deviceId: ProtocolConst.DEVICE_ID
      }
      this.ws!.send(JSON.stringify(authMsg)).catch((err: BusinessError) => {
        hilog.error(DOMAIN, TAG, `[WS] Auth send failed: code=${err.code}`)
      })
    })

    this.ws.on('message', (_err: BusinessError, value: string | ArrayBuffer) => {
      this.handleMessage(value)
    })

    this.ws.on('close', (_err: BusinessError, closeValue: webSocket.CloseResult) => {
      hilog.error(DOMAIN, TAG, `[WS] WebSocket closed: code=${closeValue.code} reason=${closeValue.reason}`)
      this.handleConnectionLost(`close code=${closeValue.code}`)
    })

    this.ws.on('error', (err: BusinessError) => {
      hilog.error(DOMAIN, TAG, `[WS] WebSocket ERROR: code=${err.code} msg=${err.message}`)
      this.onError?.('WebSocket error: ' + err.code)
      // error 事件同样意味着连接不可用（连接失败/连接中断都会触发），
      // 必须走统一的断线重连流程，否则会卡在 connecting 状态不再重试
      this.handleConnectionLost(`error code=${err.code}`)
    })

    this.ws.connect(url)
  }

  private handleMessage(value: string | ArrayBuffer): void {
    // 收到任何服务器消息 = 通道活着，刷新假连接检测状态
    this.lastServerActivityMs = Date.now()
    this.sendFailCount = 0
    try {
      let text = ''
      if (typeof value === 'string') {
        text = value
      } else {
        const decoder = new util.TextDecoder('utf-8')
        text = decoder.decode(new Uint8Array(value as ArrayBuffer))
      }
      const msg: RelayMessage = JSON.parse(text) as RelayMessage
      this.routeMessage(msg)
    } catch (_e) {
      // JSON 解析失败，忽略
    }
  }

  /**
   * 按 action 路由消息到对应回调
   */
  private routeMessage(msg: RelayMessage): void {
    switch (msg.action) {
      case RelayAction.AUTH_OK:
        this.isConnected = true
        this.isConnecting = false
        this.reconnectAttempt = 0
        this.pairedDeviceId = msg.pairedDeviceId || ''
        this.mode = (msg.pairedDeviceId) ?
          WSClient.CONNECTION_MODE_PAIRED : WSClient.CONNECTION_MODE_WAITING_FOR_PAIR
        hilog.error(DOMAIN, TAG, `[WS] AUTH_OK: paired=${this.pairedDeviceId || '(waiting)'} roomCount=${msg.roomDeviceCount}`)
        this.startHeartbeat()
        this.onAuthResult?.(true, msg.pairedDeviceId || null)
        if (msg.pairedDeviceId) {
          this.onPaired?.(msg.pairedDeviceId)
        }
        this.onConnected?.()
        this.onStatusChange?.(this.mode)
        break

      case RelayAction.RELAY:
        if (msg.payload) {
          this.onMessage?.(msg.payload)
        }
        break

      case RelayAction.PAIRED:
        if (msg.pairedDeviceId) {
          hilog.error(DOMAIN, TAG, `[WS] PAIRED: peer ${msg.pairedDeviceId} joined room`)
          this.pairedDeviceId = msg.pairedDeviceId
          this.mode = WSClient.CONNECTION_MODE_PAIRED
          this.onPaired?.(msg.pairedDeviceId)
          this.onStatusChange?.(this.mode)
        }
        break

      case RelayAction.PEER_GONE:
        hilog.error(DOMAIN, TAG, `[WS] PEER_GONE: peer ${msg.fromDeviceId || '?'} left room (mac offline/kicked)`)
        this.pairedDeviceId = ''
        this.mode = WSClient.CONNECTION_MODE_WAITING_FOR_PAIR
        if (msg.fromDeviceId) {
          this.onPeerGone?.(msg.fromDeviceId)
        }
        this.onStatusChange?.(this.mode)
        break

      case RelayAction.PONG:
        break  // 心跳响应（lastServerActivityMs 已在 handleMessage 刷新）

      case RelayAction.RELAY_NO_PEER:
        // 房间内无其他设备：消息已被服务端丢弃（典型原因：两端配对码不一致）
        hilog.error(DOMAIN, TAG, `[WS] RELAY_NO_PEER: 房间内无其他设备，${msg.type || '消息'} 未被送达`)
        this.pairedDeviceId = ''
        this.mode = WSClient.CONNECTION_MODE_WAITING_FOR_PAIR
        this.onNoPeer?.(msg.type || '消息')
        this.onStatusChange?.(this.mode)
        break

      case RelayAction.ERROR:
        hilog.error(DOMAIN, TAG, `[WS] server ERROR: ${msg.message}`)
        this.onError?.(msg.message || '未知中继错误')
        break

      default:
        console.info('[WSClient] Unknown action: ' + msg.action)
    }
  }

  // ========== 断线统一处理 ==========

  /**
   * 连接丢失（close/error 事件触发）——统一入口，防止重复触发
   */
  private handleConnectionLost(reason: string): void {
    // 守卫：已经处于断开状态则跳过（close + error 双事件、重复回调场景）
    if (!this.isConnected && !this.isConnecting) {
      hilog.error(DOMAIN, TAG, `[WS] handleConnectionLost ignored (already disconnected): ${reason}`)
      return
    }
    hilog.error(DOMAIN, TAG, `[WS] ═══ connection LOST: ${reason} ═══`)
    this.isConnected = false
    this.isConnecting = false
    this.clearHeartbeat()
    if (this.shouldReconnect) {
      this.scheduleReconnect()
    }
    this.mode = this.shouldReconnect ?
      WSClient.CONNECTION_MODE_CONNECTING : WSClient.CONNECTION_MODE_DISCONNECTED
    this.onDisconnected?.()
    this.onStatusChange?.(this.mode)
  }

  /**
   * 检测到假连接（本地认为已连接，但服务器早已断开/踢人）：
   * 发送连续失败 或 长时间收不到服务器任何消息。
   * 主动关闭死 socket 并立即走重连流程。
   */
  private handleDeadConnection(reason: string): void {
    hilog.error(DOMAIN, TAG, `[WS] ☠️ DEAD connection detected: ${reason} — forcing reconnect`)
    // closeSocket 会 off 所有监听，主动 close 不会触发 close 事件，
    // 所以这里直接走断线流程（绕过 handleConnectionLost 的守卫）
    this.closeSocket()
    this.isConnected = false
    this.isConnecting = false
    this.clearHeartbeat()
    if (this.shouldReconnect) {
      this.scheduleReconnect()
    }
    this.mode = this.shouldReconnect ?
      WSClient.CONNECTION_MODE_CONNECTING : WSClient.CONNECTION_MODE_DISCONNECTED
    this.onDisconnected?.()
    this.onStatusChange?.(this.mode)
  }

  // ========== 心跳 ==========

  private startHeartbeat(): void {
    this.clearHeartbeat()
    // 初始化服务器活跃时间（auth_ok 刚收到）
    this.lastServerActivityMs = Date.now()
    this.sendFailCount = 0
    this.heartbeatTimerId = setInterval(() => {
      // 假连接判活：超过 3 个心跳周期（90s）未收到服务器任何消息（含 pong），
      // 说明连接早已死亡（典型场景：息屏后被服务器踢掉、半开连接）
      const silentMs: number = Date.now() - this.lastServerActivityMs
      if (silentMs > RelayConfig.HEARTBEAT_INTERVAL * 3) {
        this.handleDeadConnection(`no server activity for ${Math.floor(silentMs / 1000)}s`)
        return
      }
      this.sendPing()
    }, RelayConfig.HEARTBEAT_INTERVAL) as number
  }

  private clearHeartbeat(): void {
    if (this.heartbeatTimerId !== -1) {
      clearInterval(this.heartbeatTimerId)
      this.heartbeatTimerId = -1
    }
  }

  // ========== 重连 ==========

  /**
   * 指数退避重连：1s → 2s → 4s → 8s → 16s（最大 30s）
   */
  private scheduleReconnect(): void {
    this.cleanup()
    const delay = Math.min(
      RelayConfig.RECONNECT_BASE_DELAY * Math.pow(2, this.reconnectAttempt),
      RelayConfig.RECONNECT_MAX_DELAY
    )
    this.reconnectAttempt += 1
    hilog.error(DOMAIN, TAG, `[WS] Reconnect in ${delay}ms (attempt ${this.reconnectAttempt})`)
    this.reconnectTimerId = setTimeout(() => {
      if (this.shouldReconnect) {
        this.closeSocket()
        this.doConnect(this.targetUrl)
      }
    }, delay) as number
  }

  // ========== 清理 ==========

  private closeSocket(): void {
    if (this.ws) {
      try {
        this.ws.off('open')
        this.ws.off('message')
        this.ws.off('close')
        this.ws.off('error')
        this.ws.close()
      } catch (_e) {
        // ignore
      }
      this.ws = null
    }
    this.isConnected = false
    this.isConnecting = false
  }

  private cleanup(): void {
    if (this.reconnectTimerId !== -1) {
      clearTimeout(this.reconnectTimerId)
      this.reconnectTimerId = -1
    }
    this.clearHeartbeat()
  }
}
