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
    console.info('[TCPClient] Socket created')

    this.tcpSocket.on('connect', () => {
      this.isConnected = true
      this.isConnecting = false
      console.info('[TCPClient] on(connect) fired')
      this.onConnected?.()
    })

    this.tcpSocket.on('message', (value: socket.SocketMessageInfo) => {
      this.handleIncomingData(value)
    })

    this.tcpSocket.on('close', () => {
      console.info('[TCPClient] on(close) fired, isActive=' + this.isActive)
      this.isConnected = false
      this.isConnecting = false
      if (this.isActive) {
        this.onDisconnected?.()
        this.scheduleReconnect()
      }
    })

    this.tcpSocket.on('error', (err: BusinessError) => {
      console.error('[TCPClient] on(error): code=' + err.code + ' msg=' + err.message)
      this.isConnected = false
      this.isConnecting = false
      if (this.isActive) {
        this.onError?.('TCP error: ' + err.code)
        this.scheduleReconnect()
      }
    })

    console.info('[TCPClient] Calling tcpSocket.connect() to ' + this.targetIp + ':' + this.targetPort)
    this.tcpSocket.connect({
      address: {
        address: this.targetIp,
        port: this.targetPort,
        family: 1
      },
      timeout: 10000
    }).then(() => {
      console.info('[TCPClient] connect() promise resolved')
      if (!this.isConnected) {
        this.isConnected = true
        this.isConnecting = false
        this.onConnected?.()
      }
    }).catch((err: BusinessError) => {
      console.error('[TCPClient] connect() rejected: code=' + err.code + ' msg=' + err.message)
      this.isConnecting = false
      if (this.isActive) {
        this.onError?.('Connect failed: ' + err.code)
        this.scheduleReconnect()
      }
    })
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
    if (this.reconnectTimerId !== -1) {
      clearTimeout(this.reconnectTimerId)
      this.reconnectTimerId = -1
    }
  }
}