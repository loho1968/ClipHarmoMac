import { webSocket } from '@kit.NetworkKit'
import { SyncMessage, RelayConfig, RelayAction, RelayMessage, ProtocolConst } from './Protocol'
import { BusinessError } from '@kit.BasicServicesKit'
import { util } from '@kit.ArkTS'

/**
 * WebSocket 中继客户端
 * 使用 @kit.NetworkKit webSocket 模块
 * 负责连接/认证/心跳/重连/消息收发
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
      console.info('[WSClient] connect() skipped: already connected/connecting')
      return
    }
    this.targetUrl = url
    this.roomKey = roomKey
    this.shouldReconnect = true
    console.info('[WSClient] Connecting to ' + url + ' with roomKey=' + roomKey)
    this.doConnect(url)
  }

  disconnect(): void {
    console.info('[WSClient] disconnect()')
    this.shouldReconnect = false
    this.cleanup()
    this.closeSocket()
    this.mode = WSClient.CONNECTION_MODE_DISCONNECTED
    this.onStatusChange?.(this.mode)
  }

  /**
   * 通过中继发送剪贴板消息
   * @param msg 剪贴板同步消息
   * @returns 是否发送成功
   */
  sendRelay(msg: SyncMessage): boolean {
    if (!this.ws || !this.isConnected) {
      console.error('[WSClient] sendRelay() failed: not connected')
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
      console.info('[WSClient] Relay sent')
    }).catch((err: BusinessError) => {
      console.error('[WSClient] Relay send failed: ' + err.code)
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
    this.ws.send(JSON.stringify(pingMsg)).catch((_err: BusinessError) => {
      // ignore
    })
  }

  // ========== 私有方法 ==========

  private doConnect(url: string): void {
    this.isConnecting = true
    this.mode = WSClient.CONNECTION_MODE_CONNECTING
    this.onStatusChange?.(this.mode)
    this.ws = webSocket.createWebSocket()

    this.ws.on('open', (_err: BusinessError, _value: Object) => {
      console.info('[WSClient] WebSocket opened')
      // 发送 auth 消息
      const authMsg: RelayMessage = {
        action: RelayAction.AUTH,
        roomKey: this.roomKey,
        deviceId: ProtocolConst.DEVICE_ID
      }
      this.ws!.send(JSON.stringify(authMsg)).catch((err: BusinessError) => {
        console.error('[WSClient] Auth send failed: ' + err.code)
      })
    })

    this.ws.on('message', (_err: BusinessError, value: string | ArrayBuffer) => {
      this.handleMessage(value)
    })

    this.ws.on('close', (_err: BusinessError, closeValue: webSocket.CloseResult) => {
      console.info('[WSClient] WebSocket closed, code=' + closeValue.code)
      this.isConnected = false
      this.isConnecting = false
      this.clearHeartbeat()
      if (this.shouldReconnect) {
        this.scheduleReconnect()
      }
      const newMode = this.shouldReconnect ?
        WSClient.CONNECTION_MODE_CONNECTING : WSClient.CONNECTION_MODE_DISCONNECTED
      this.mode = newMode
      this.onDisconnected?.()
      this.onStatusChange?.(this.mode)
    })

    this.ws.on('error', (err: BusinessError) => {
      console.error('[WSClient] WebSocket error: code=' + err.code)
      this.isConnected = false
      this.isConnecting = false
      this.onError?.('WebSocket error: ' + err.code)
    })

    this.ws.connect(url)
  }

  private handleMessage(value: string | ArrayBuffer): void {
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
          this.pairedDeviceId = msg.pairedDeviceId
          this.mode = WSClient.CONNECTION_MODE_PAIRED
          this.onPaired?.(msg.pairedDeviceId)
          this.onStatusChange?.(this.mode)
        }
        break

      case RelayAction.PEER_GONE:
        this.pairedDeviceId = ''
        this.mode = WSClient.CONNECTION_MODE_WAITING_FOR_PAIR
        if (msg.fromDeviceId) {
          this.onPeerGone?.(msg.fromDeviceId)
        }
        this.onStatusChange?.(this.mode)
        break

      case RelayAction.PONG:
        break  // 心跳响应，无需处理

      case RelayAction.ERROR:
        this.onError?.(msg.message || '未知中继错误')
        break

      default:
        console.info('[WSClient] Unknown action: ' + msg.action)
    }
  }

  // ========== 心跳 ==========

  private startHeartbeat(): void {
    this.clearHeartbeat()
    this.heartbeatTimerId = setInterval(() => {
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
    console.info('[WSClient] Reconnect in ' + delay + 'ms (attempt ' + this.reconnectAttempt + ')')
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
