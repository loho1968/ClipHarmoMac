// ============================================================
// ClipboardSync 中继服务器 —— 配置文件
// ============================================================

module.exports = {
  // WebSocket 服务端口（内部端口，Nginx 反代后可关闭外部访问）
  port: parseInt(process.env.RELAY_PORT, 10) || 3000,

  // 绑定的地址（0.0.0.0 监听所有网卡，127.0.0.1 仅本地）
  host: process.env.RELAY_HOST || '0.0.0.0',

  // 心跳间隔（毫秒），服务端定期发送 ping，客户端 2 倍时间内无响应则断开
  heartbeatInterval: 30000,

  // 房间空闲超时（毫秒），房间内无设备后自动销毁
  roomIdleTimeout: 5 * 60 * 1000,  // 5 分钟

  // 单房间最大设备数
  maxDevicesPerRoom: 5,

  // 日志前缀
  logPrefix: '[Relay]',
}
