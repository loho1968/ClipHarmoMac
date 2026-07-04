import { socket } from '@kit.NetworkKit'
import { SyncMessage, ProtocolConst } from '../common/Protocol'
import { util } from '@kit.ArkTS'
import { BusinessError } from '@kit.BasicServicesKit'

/**
 * TCP 客户端
 * 连接到 Mac 端的 TCP 服务器，使用换行符分隔 JSON 消息
 * 每次 SyncManager.setupTcpClient 会创建新实例，无需处理旧连接复用
 */
export class TCPClient {
  private tcpSocket: socket.TCPSocket | null = null
  private isConnected: boolean = false
  private isConnecting: boolean = false
  private reconnectTimerId: number = -1
  private targetIp: string = ''
  private targetPort: number = ProtocolConst.WS_PORT
  private buffer: string = ''
  private isActive: boolean = true
  private connectWatchdog: number = -1  // 连接看门狗定时器

  // 回调
  onConnected?: () => void
  onDisconnected?: () => void
  onMessage?: (msg: SyncMessage) => void
  onError?: (err: string) => void

  get connected(): boolean {
    return this.isConnected
  }

  connect(ip: string, port: number = ProtocolConst.WS_PORT): void {
    if (this.isConnected || this.isConnecting) {
      console.info('[TCPClient] connect() skipped: connected=' + this.isConnected + ' connecting=' + this.isConnecting)
      return
    }
    this.targetIp = ip
    this.targetPort = port
    console.info('[TCPClient] connect() to ' + ip + ':' + port)
    this.doConnect()
  }

  disconnect(): void {
    console.info('[TCPClient] disconnect()')
    this.isActive = false
    this.isConnecting = false
    this.cleanup()
    this.closeSocket()
  }

  send(msg: SyncMessage): boolean {
    if (!this.tcpSocket || !this.isConnected) {
      console.error('[TCPClient] ✗ send failed: connected=' + this.isConnected)
      return false
    }
    const jsonStr = JSON.stringify(msg) + '\n'
    console.info('[TCPClient] → sending ' + jsonStr.length + ' bytes: ' + jsonStr.substring(0, 80))
    this.tcpSocket.send({
      data: jsonStr
    }).then(() => {
      console.info('[TCPClient] ✓ sent ok')
    }).catch((err: BusinessError) => {
      console.error('[TCPClient] ✗ send error: code=' + err.code)
    })
    return true
  }

  private doConnect(): void {
    this.isConnecting = true
    this.tcpSocket = socket.constructTCPSocketInstance()
    console.info('[TCPClient] Socket created, connecting to ' + this.targetIp + ':' + this.targetPort)

    this.tcpSocket.on('connect', () => {
      console.info('[TCPClient] on(connect) event fired')
      this.markConnected()
    })

    this.tcpSocket.on('message', (value: socket.SocketMessageInfo) => {
      this.handleIncomingData(value)
    })

    this.tcpSocket.on('close', () => {
      console.info('[TCPClient] on(close) fired, isActive=' + this.isActive)
      this.clearWatchdog()
      this.isConnected = false
      this.isConnecting = false
      if (this.isActive) {
        this.onDisconnected?.()
        this.scheduleReconnect()
      }
    })

    this.tcpSocket.on('error', (err: BusinessError) => {
      console.error('[TCPClient] on(error): code=' + err.code + ' msg=' + err.message)
      this.clearWatchdog()
      this.isConnected = false
      this.isConnecting = false
      if (this.isActive) {
        this.onError?.('TCP error: ' + err.code)
        this.scheduleReconnect()
      }
    })

    this.tcpSocket.connect({
      address: {
        address: this.targetIp,
        port: this.targetPort,
        family: 1
      },
      timeout: 10000
    }).then(() => {
      console.info('[TCPClient] connect() promise resolved')
      this.markConnected()
    }).catch((err: BusinessError) => {
      console.error('[TCPClient] connect() rejected: code=' + err.code + ' msg=' + err.message)
      this.clearWatchdog()
      this.isConnecting = false
      if (this.isActive) {
        this.onError?.('Connect failed: ' + err.code)
        this.scheduleReconnect()
      }
    })

    // 连接看门狗：3 秒后若仍未标记已连接，主动检查 socket 状态
    // 解决 on('connect') 和 connect().then() 在某些 HarmonyOS 版本上不触发的问题
    this.startWatchdog()
  }

  /**
   * 标记连接成功（统一入口，防止重复回调）
   */
  private markConnected(): void {
    if (this.isConnected) {
      return  // 已标记，跳过重复调用
    }
    this.clearWatchdog()
    this.isConnected = true
    this.isConnecting = false
    console.info('[TCPClient] ✓ Connected to ' + this.targetIp)
    this.onConnected?.()
  }

  /**
   * 启动连接看门狗：3 秒后检查 socket 是否实际已连通
   */
  private startWatchdog(): void {
    this.clearWatchdog()
    this.connectWatchdog = setTimeout(() => {
      if (this.isConnected || !this.isConnecting) {
        // 已连接或已停止连接，无需检查
        return
      }
      console.warn('[TCPClient] Watchdog: neither on(connect) nor connect().then() fired after 3s, checking socket state...')
      this.checkSocketState()
    }, 3000) as number
  }

  /**
   * 主动检查 socket 连通状态（看门狗备用方案）
   * 通过 getRemoteAddress 验证：若成功获取对端地址，说明 socket 已连通
   */
  private checkSocketState(): void {
    if (!this.tcpSocket || !this.isConnecting || this.isConnected) {
      return
    }
    try {
      this.tcpSocket.getRemoteAddress().then((addr: socket.NetAddress) => {
        console.info('[TCPClient] Watchdog: getRemoteAddress succeeded, addr=' + addr.address + ' — socket IS connected!')
        this.markConnected()
      }).catch((_err: BusinessError) => {
        console.warn('[TCPClient] Watchdog: getRemoteAddress failed, socket not connected yet')
        // 再等 3 秒后重试一次（connect timeout 是 10s）
        this.connectWatchdog = setTimeout(() => {
          if (!this.isConnected && this.isConnecting) {
            this.checkSocketState()
          }
        }, 3000) as number
      })
    } catch (_e) {
      console.error('[TCPClient] Watchdog: getRemoteAddress threw exception')
    }
  }

  private clearWatchdog(): void {
    if (this.connectWatchdog !== -1) {
      clearTimeout(this.connectWatchdog)
      this.connectWatchdog = -1
    }
  }

  private handleIncomingData(value: socket.SocketMessageInfo): void {
    try {
      const bytes = value.message
      let text = ''
      if (typeof bytes === 'string') {
        text = bytes
      } else {
        const uint8 = new Uint8Array(bytes as ArrayBuffer)
        const decoder = new util.TextDecoder('utf-8')
        text = decoder.decode(uint8)
      }

      this.buffer += text

      while (this.buffer.includes('\n')) {
        const newlineIndex = this.buffer.indexOf('\n')
        const line = this.buffer.substring(0, newlineIndex)
        this.buffer = this.buffer.substring(newlineIndex + 1)

        if (line.length > 0) {
          try {
            const msg: SyncMessage = JSON.parse(line) as SyncMessage
            this.onMessage?.(msg)
          } catch (_e) {
            // JSON 解析失败
          }
        }
      }
    } catch (_e) {
      // 数据处理失败
    }
  }

  private scheduleReconnect(): void {
    this.cleanup()
    console.info('[TCPClient] Reconnect in 5s to ' + this.targetIp)
    this.reconnectTimerId = setTimeout(() => {
      if (this.isActive) {
        this.closeSocket()
        this.doConnect()
      }
    }, 5000) as number
  }

  private closeSocket(): void {
    if (this.tcpSocket) {
      try {
        this.tcpSocket.off('connect')
        this.tcpSocket.off('message')
        this.tcpSocket.off('close')
        this.tcpSocket.off('error')
        this.tcpSocket.close()
      } catch (_e) {
        // ignore
      }
      this.tcpSocket = null
    }
    this.isConnected = false
    this.isConnecting = false
  }

  private cleanup(): void {
    this.clearWatchdog()
    if (this.reconnectTimerId !== -1) {
      clearTimeout(this.reconnectTimerId)
      this.reconnectTimerId = -1
    }
  }
}