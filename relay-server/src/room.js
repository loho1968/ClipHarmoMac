// ============================================================
// 房间管理模块
// 按 roomKey 隔离设备，同一房间内的设备互相转发消息
// ============================================================

const config = require('./config')

class Room {
  constructor(roomKey) {
    this.roomKey = roomKey
    /** @type {Map<string, import('ws').WebSocket>} deviceId → ws */
    this.devices = new Map()
    this.createdAt = Date.now()
    this.idleTimer = null
  }

  /**
   * 设备加入房间
   * @param {string} deviceId
   * @param {import('ws').WebSocket} ws
   * @returns {{ success: boolean, pairedDeviceId?: string, message?: string }}
   */
  join(deviceId, ws) {
    // 同名 deviceId 已在房间内：踢掉旧连接
    if (this.devices.has(deviceId)) {
      const oldWs = this.devices.get(deviceId)
      this._send(oldWs, { action: 'error', message: '设备已在别处登录，当前连接已断开' })
      this._closeSocket(oldWs)
      this.devices.delete(deviceId)
      console.log(`${config.logPrefix} [${this.roomKey}] 设备 ${deviceId} 重连，踢掉旧连接`)
    }

    // 检查房间容量
    if (this.devices.size >= config.maxDevicesPerRoom) {
      return { success: false, message: '房间已满' }
    }

    this.devices.set(deviceId, ws)
    this._clearIdleTimer()
    console.log(`${config.logPrefix} [${this.roomKey}] 设备 ${deviceId} 加入 (共 ${this.devices.size} 台)`)

    // 找到第一个配对设备
    const others = Array.from(this.devices.keys()).filter(id => id !== deviceId)
    const pairedDeviceId = others.length > 0 ? others[0] : null

    // 通知房间内其他设备有新设备加入
    if (pairedDeviceId) {
      this._send(this.devices.get(pairedDeviceId), {
        action: 'paired',
        pairedDeviceId: deviceId,
      })
    }

    return { success: true, pairedDeviceId }
  }

  /**
   * 设备离开房间
   * @param {string} deviceId
   */
  leave(deviceId) {
    this.devices.delete(deviceId)
    console.log(`${config.logPrefix} [${this.roomKey}] 设备 ${deviceId} 离开 (剩余 ${this.devices.size} 台)`)

    // 通知剩余设备
    if (this.devices.size > 0) {
      const others = Array.from(this.devices.keys())
      for (const id of others) {
        this._send(this.devices.get(id), {
          action: 'peer_gone',
          fromDeviceId: deviceId,
        })
      }
    }

    // 房间空了，启动空闲计时
    if (this.devices.size === 0) {
      this._startIdleTimer()
    }
  }

  /**
   * 转发消息给房间内所有其他设备
   * @param {string} fromDeviceId - 发送方 deviceId（不会转发给自己）
   * @param {object} payload - 要转发的消息体
   */
  relay(fromDeviceId, payload) {
    let count = 0
    const msgType = payload?.type || '?'
    console.log(`${config.logPrefix} [${this.roomKey}] ← \x1b[33mrelay\x1b[0m ${fromDeviceId} → ${msgType} (payload ${JSON.stringify(payload).length} bytes)`)
    for (const [deviceId, ws] of this.devices) {
      if (deviceId !== fromDeviceId) {
        this._send(ws, {
          action: 'relay',
          fromDeviceId,
          payload,
        })
        count++
        console.log(`${config.logPrefix} [${this.roomKey}]   → forwarded to ${deviceId}`)
      }
    }
    if (count === 0) {
      console.log(`${config.logPrefix} [${this.roomKey}]   → no other devices to forward to`)
    }
    return count
  }

  /**
   * 向单个设备发送消息
   * @param {string} action
   * @param {string} deviceId
   * @param {object} extra
   */
  sendTo(deviceId, action, extra = {}) {
    const ws = this.devices.get(deviceId)
    if (ws) {
      this._send(ws, { action, ...extra })
      return true
    }
    return false
  }

  get deviceCount() {
    return this.devices.size
  }

  get deviceIds() {
    return Array.from(this.devices.keys())
  }

  // ---- 内部方法 ----

  _send(ws, data) {
    try {
      if (ws.readyState === 1) {  // WebSocket.OPEN
        ws.send(JSON.stringify(data))
      }
    } catch (err) {
      console.error(`${config.logPrefix} [${this.roomKey}] 发送失败:`, err.message)
    }
  }

  _closeSocket(ws) {
    try {
      if (ws.readyState === 1 || ws.readyState === 0) {
        ws.close(4001, '服务端主动关闭')
      }
    } catch (_) { /* ignore */ }
  }

  _startIdleTimer() {
    if (this.idleTimer) return
    this.idleTimer = setTimeout(() => {
      console.log(`${config.logPrefix} [${this.roomKey}] 房间空闲超时，销毁`)
      roomManager.destroy(this.roomKey)
    }, config.roomIdleTimeout)
  }

  _clearIdleTimer() {
    if (this.idleTimer) {
      clearTimeout(this.idleTimer)
      this.idleTimer = null
    }
  }
}

// ============================================================
// 房间管理器（单例）
// ============================================================
class RoomManager {
  constructor() {
    /** @type {Map<string, Room>} roomKey → Room */
    this.rooms = new Map()
  }

  /**
   * 获取或创建房间
   * @param {string} roomKey
   * @returns {Room}
   */
  getOrCreate(roomKey) {
    if (!this.rooms.has(roomKey)) {
      const room = new Room(roomKey)
      this.rooms.set(roomKey, room)
      console.log(`${config.logPrefix} 创建房间: ${roomKey}`)
    }
    return this.rooms.get(roomKey)
  }

  /**
   * 销毁房间
   * @param {string} roomKey
   */
  destroy(roomKey) {
    const room = this.rooms.get(roomKey)
    if (room) {
      // 通知所有设备房间关闭
      for (const [deviceId, ws] of room.devices) {
        room._send(ws, { action: 'error', message: '房间已关闭' })
        room._closeSocket(ws)
      }
      room.devices.clear()
      if (room.idleTimer) {
        clearTimeout(room.idleTimer)
        room.idleTimer = null
      }
      this.rooms.delete(roomKey)
      console.log(`${config.logPrefix} 销毁房间: ${roomKey}`)
    }
  }

  /**
   * 设备离开其所在房间（通过 ws 反向查找）
   * @param {import('ws').WebSocket} ws
   */
  leaveBySocket(ws) {
    for (const [roomKey, room] of this.rooms) {
      for (const [deviceId, devWs] of room.devices) {
        if (devWs === ws) {
          room.leave(deviceId)
          return
        }
      }
    }
  }

  get stats() {
    let totalDevices = 0
    for (const room of this.rooms.values()) {
      totalDevices += room.deviceCount
    }
    return {
      rooms: this.rooms.size,
      devices: totalDevices,
    }
  }
}

const roomManager = new RoomManager()
module.exports = { Room, roomManager }
