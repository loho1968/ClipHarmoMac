import { util } from '@kit.ArkTS'
import { socket } from '@kit.NetworkKit'
import { SyncMessage, MessageType, ProtocolConst } from '../common/Protocol'
import { BusinessError } from '@kit.BasicServicesKit'

/**
 * UDP 设备发现服务
 * 通过广播和监听发现局域网中的 Mac 端
 */
export class DiscoveryService {
  private udpSocket: socket.UDPSocket | null = null
  private broadcastTimerId: number = -1
  private isRunning: boolean = false
  private foundDevices: string[] = []  // 已发现的设备ID列表

  // 发现设备回调
  onDeviceFound?: (deviceId: string, ip: string, port: number) => void

  // 重置已发现设备列表（允许重新发现同一设备，用于断线重连）
  resetFoundDevices(): void {
    this.foundDevices = []
    console.info('[Discovery] Found devices reset, can re-discover')
  }

  async start(): Promise<void> {
    if (this.isRunning) {
      return
    }
    this.isRunning = true

    try {
      // 创建 UDP Socket
      this.udpSocket = socket.constructUDPSocketInstance()

      // 监听错误事件（诊断用）
      this.udpSocket.on('error', (err: BusinessError) => {
        console.error('[Discovery] UDP socket error: code=' + err.code + ' msg=' + err.message)
      })

      // 监听消息（必须在 bind 之前注册）
      this.udpSocket.on('message', (info: socket.SocketMessageInfo) => {
        this.handleMessage(info)
      })

      // 绑定广播端口，必须和 Mac 端同一端口才能互相收到广播
      await this.udpSocket.bind({
        address: '0.0.0.0',
        port: ProtocolConst.BROADCAST_PORT,
        family: 1 // IPv4
      })
      console.info('[Discovery] UDP bind success on port ' + ProtocolConst.BROADCAST_PORT)

      // 获取实际绑定的地址（诊断）
      const localAddr = this.udpSocket?.getLocalAddress()
      console.info('[Discovery] UDP local address: ' + JSON.stringify(localAddr))

      // 启用广播
      await this.udpSocket.setExtraOptions({
        broadcast: true,
        reuseAddress: true
      })
      console.info('[Discovery] UDP extra options set (broadcast=true, reuseAddress=true)')

      // 开始定时广播
      this.startBroadcasting()
      console.info('[Discovery] Started, broadcasting to port ' + ProtocolConst.BROADCAST_PORT)
    } catch (e) {
      console.error('[Discovery] start failed: ' + JSON.stringify(e))
    }
  }

  stop(): void {
    this.isRunning = false
    this.foundDevices = []
    if (this.broadcastTimerId !== -1) {
      clearInterval(this.broadcastTimerId)
      this.broadcastTimerId = -1
    }
    if (this.udpSocket) {
      this.udpSocket.off('message')
      this.udpSocket.off('error')
      this.udpSocket.close()
      this.udpSocket = null
    }
  }

  private startBroadcasting(): void {
    // 立即发送一次
    this.sendBroadcast()

    // 定时发送
    this.broadcastTimerId = setInterval(() => {
      this.sendBroadcast()
    }, ProtocolConst.BROADCAST_INTERVAL) as number
  }

  private sendBroadcast(): void {
    if (!this.udpSocket) {
      return
    }

    const msg: SyncMessage = {
      type: MessageType.PING,
      content: 'discover',
      timestamp: Date.now() / 1000,
      deviceId: ProtocolConst.DEVICE_ID
    }

    const jsonStr = JSON.stringify(msg)
    console.info('[Discovery] Sending broadcast, my deviceId=' + ProtocolConst.DEVICE_ID)

    this.udpSocket.send({
      data: jsonStr,
      address: {
        address: '255.255.255.255',
        port: ProtocolConst.BROADCAST_PORT,
        family: 1
      }
    }).then(() => {
      console.info('[Discovery] Broadcast sent')
    }).catch((err: BusinessError) => {
      console.error('[Discovery] Broadcast send failed: ' + err.code + ' ' + err.message)
    })
  }

  private handleMessage(info: socket.SocketMessageInfo): void {
    try {
      console.info('[Discovery] Received UDP message from ' + info.remoteInfo.address + ':' + info.remoteInfo.port)

      // 解析消息
      const bytes = info.message
      let jsonStr = ''
      if (typeof bytes === 'string') {
        jsonStr = bytes
      } else {
        // ArrayBuffer 转 string
        const decoder = new util.TextDecoder('utf-8')
        jsonStr = decoder.decode(new Uint8Array(bytes as ArrayBuffer))
      }

      const msg: SyncMessage = JSON.parse(jsonStr) as SyncMessage
      console.info('[Discovery] Parsed message type=' + msg.type + ' deviceId=' + msg.deviceId)

      if (msg.type === MessageType.PING && msg.deviceId !== ProtocolConst.DEVICE_ID) {
        // 去重：同一设备只回调一次（除非已重置 foundDevices）
        if (this.foundDevices.indexOf(msg.deviceId) !== -1) {
          console.info('[Discovery] Device ' + msg.deviceId + ' already found, skipping')
          return
        }
        this.foundDevices.push(msg.deviceId)

        // 发现了 Mac 端
        const remoteIp = info.remoteInfo.address
        console.info('[Discovery] Found NEW device: ' + msg.deviceId + ' at ' + remoteIp)
        this.onDeviceFound?.(msg.deviceId, remoteIp, ProtocolConst.WS_PORT)
      }
    } catch (e) {
      console.error('[Discovery] handleMessage error: ' + JSON.stringify(e))
    }
  }
}