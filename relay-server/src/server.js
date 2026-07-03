// ============================================================
// WebSocket 中继服务器核心
// 处理连接/认证/心跳/转发
// ============================================================

const { WebSocketServer } = require('ws')
const config = require('./config')
const { roomManager } = require('./room')

/**
 * 启动 WebSocket 服务器
 * @param {import('http').Server} [httpServer] - 可选，共享 HTTP Server
 * @returns {WebSocketServer}
 */
function createServer(httpServer) {
  const wss = new WebSocketServer({
    server: httpServer,
    ...(httpServer ? {} : { port: config.port, host: config.host }),
    maxPayload: 4 * 1024 * 1024,  // 4MB 最大消息（支持分片图片/文件传输）
  })

  console.log(`${config.logPrefix} WebSocket 服务启动 (${httpServer ? '共享HTTP' : `ws://${config.host}:${config.port}`})`)

  wss.on('connection', (ws, req) => {
    const clientIP = req.socket.remoteAddress || 'unknown'

    console.log(`${config.logPrefix} 新连接来自 ${clientIP} (当前 ${wss.clients.size} 个连接)`)

    // 连接级状态
    let deviceId = null
    let roomKey = null
    let heartbeatTimer = null
    let heartbeatTimeout = null
    let isAuthenticated = false  // 是否已完成 auth

    // ---- 发送消息给当前连接 ----
    function sendToClient(data) {
      try {
        if (ws.readyState === 1) {
          ws.send(JSON.stringify(data))
        }
      } catch (err) {
        console.error(`${config.logPrefix} 发送失败:`, err.message)
      }
    }

    // ---- 心跳 ----
    function startHeartbeat() {
      clearHeartbeat()

      heartbeatTimer = setInterval(() => {
        if (ws.readyState === 1) {
          ws.ping()
        }
      }, config.heartbeatInterval)

      // pong 超时检测
      const resetPongTimeout = () => {
        if (heartbeatTimeout) clearTimeout(heartbeatTimeout)
        heartbeatTimeout = setTimeout(() => {
          console.log(`${config.logPrefix} [${roomKey}] 设备 ${deviceId} 心跳超时，断开`)
          ws.terminate()
        }, config.heartbeatInterval * 2)
      }

      ws.on('pong', resetPongTimeout)
      resetPongTimeout()  // 首次启动
    }

    function clearHeartbeat() {
      if (heartbeatTimer) { clearInterval(heartbeatTimer); heartbeatTimer = null }
      if (heartbeatTimeout) { clearTimeout(heartbeatTimeout); heartbeatTimeout = null }
    }

    function cleanup() {
      clearHeartbeat()
      if (roomKey && deviceId) {
        roomManager.leaveBySocket(ws)
      }
    }

    // ---- 消息处理 ----
    ws.on('message', (raw) => {
      let msg
      try {
        msg = JSON.parse(raw.toString())
      } catch (_) {
        sendToClient({ action: 'error', message: '消息格式错误，需要 JSON' })
        return
      }

      const { action, roomKey: msgRoomKey, deviceId: msgDeviceId, payload } = msg

      // 非 auth 消息需要先认证
      if (action !== 'auth' && action !== 'ping' && !isAuthenticated) {
        sendToClient({ action: 'error', message: '请先发送 auth 认证' })
        return
      }

      switch (action) {
        // ---- 认证 ----
        case 'auth': {
          if (!msgDeviceId || typeof msgDeviceId !== 'string') {
            sendToClient({ action: 'error', message: '缺少 deviceId' })
            return
          }
          if (!msgRoomKey || typeof msgRoomKey !== 'string' || msgRoomKey.length < 4) {
            sendToClient({ action: 'error', message: 'roomKey 无效（至少 4 位字符）' })
            return
          }

          // 如果已认证且要换房间，先退出原房间
          if (isAuthenticated && roomKey) {
            roomManager.leaveBySocket(ws)
          }

          deviceId = msgDeviceId
          roomKey = msgRoomKey

          const room = roomManager.getOrCreate(roomKey)
          const result = room.join(deviceId, ws)

          if (!result.success) {
            sendToClient({ action: 'error', message: result.message || '加入房间失败' })
            return
          }

          isAuthenticated = true
          startHeartbeat()

          sendToClient({
            action: 'auth_ok',
            pairedDeviceId: result.pairedDeviceId || null,
            roomDeviceCount: room.deviceCount,
          })

          console.log(`${config.logPrefix} [${roomKey}] ${deviceId} 认证成功` +
            (result.pairedDeviceId ? `, 配对设备: ${result.pairedDeviceId}` : ', 等待配对'))
          break
        }

        // ---- 心跳 ----
        case 'ping':
          sendToClient({ action: 'pong' })
          break

        // ---- 转发 ----
        case 'relay': {
          if (!payload) {
            sendToClient({ action: 'error', message: '缺少 payload' })
            return
          }
          if (!deviceId || !roomKey) {
            sendToClient({ action: 'error', message: '内部错误：缺少认证信息' })
            return
          }
          const room = roomManager.getOrCreate(roomKey)
          room.relay(deviceId, payload)
          break
        }

        default:
          sendToClient({ action: 'error', message: `未知 action: ${action}` })
      }
    })

    // ---- 断开 ----
    ws.on('close', (code) => {
      console.log(`${config.logPrefix} [${roomKey || '?'}] ${deviceId || '?'} 断开 (code=${code})`)
      cleanup()
    })

    ws.on('error', (err) => {
      console.error(`${config.logPrefix} [${roomKey || '?'}] ${deviceId || '?'} 异常:`, err.message)
      cleanup()
    })
  })

  return wss
}

module.exports = { createServer }
