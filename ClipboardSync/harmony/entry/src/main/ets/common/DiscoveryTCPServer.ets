import { socket } from '@kit.NetworkKit'
import { BusinessError } from '@kit.BasicServicesKit'
import { ProtocolConst } from './Protocol'

/**
 * TCP 发现服务
 * 监听端口 19878，等待 Mac 端 TCP 连接
 * 从连接的 remoteAddress 获取 Mac 的 IP 地址
 * 解决 UDP 广播无法从 Mac 到达鸿蒙的问题
 */
export class DiscoveryTCPServer {
  private serverSocket: socket.TCPSocketServer | null = null
  private isRunning: boolean = false

  // 发现 Mac IP 回调
  onMacIPFound?: (macIP: string) => void

  async start(): Promise<void> {
    if (this.isRunning) {
      return
    }
    this.isRunning = true

    try {
      this.serverSocket = socket.constructTCPSocketServerInstance()

      // 必须在 listen 之前注册事件，否则可能丢失连接
      this.serverSocket.on('connect', (client: socket.TCPSocketConnection) => {
        this.handleClientConnected(client)
      })

      this.serverSocket.on('error', (err: BusinessError) => {
        console.error('[DiscoveryTCP] Server error: code=' + err.code + ' msg=' + err.message)
      })

      const listenAddr: socket.NetAddress = {
        address: '0.0.0.0',
        port: ProtocolConst.DISCOVERY_TCP_PORT,
        family: 1
      }

      await this.serverSocket.listen(listenAddr)
      console.info('[DiscoveryTCP] Listening on port ' + ProtocolConst.DISCOVERY_TCP_PORT)
    } catch (e) {
      const errMsg = e instanceof Error ? e.message : JSON.stringify(e)
      console.error('[DiscoveryTCP] start failed: ' + errMsg)
    }
  }

  stop(): void {
    this.isRunning = false
    if (this.serverSocket) {
      this.serverSocket.off('connect')
      this.serverSocket.off('error')
      this.serverSocket.close()
      this.serverSocket = null
    }
  }

  private handleClientConnected(client: socket.TCPSocketConnection): void {
    // getRemoteAddress 返回 Promise，使用 callback 方式获取
    client.getRemoteAddress((err: BusinessError, remoteAddr: socket.NetAddress) => {
      if (err) {
        console.error('[DiscoveryTCP] getRemoteAddress failed: ' + err.message)
        client.close()
        return
      }
      const macIP: string = remoteAddr.address
      console.info('[DiscoveryTCP] Mac connected from: ' + macIP)

      // 回调通知 SyncManager
      this.onMacIPFound?.(macIP)

      // 关闭连接（仅用于发现，不用于数据传输）
      client.close()
    })
  }
}
