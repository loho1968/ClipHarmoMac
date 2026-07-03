// ============================================================
// ClipboardSync 中继服务器 —— 入口
// ============================================================

const http = require('http')
const config = require('./config')
const { createServer } = require('./server')
const { roomManager } = require('./room')

// ---- 健康检查 HTTP 服务 ----
const httpServer = http.createServer((req, res) => {
  const url = new URL(req.url, `http://${req.headers.host}`)

  if (url.pathname === '/health') {
    const stats = roomManager.stats
    res.writeHead(200, { 'Content-Type': 'application/json' })
    res.end(JSON.stringify({
      status: 'ok',
      uptime: Math.floor(process.uptime()),
      rooms: stats.rooms,
      devices: stats.devices,
      memoryMB: Math.round(process.memoryUsage().rss / 1024 / 1024),
      version: '1.0.0',
    }))
    return
  }

  // 根路径
  if (url.pathname === '/') {
    const stats = roomManager.stats
    res.writeHead(200, { 'Content-Type': 'text/html; charset=utf-8' })
    res.end(`<!DOCTYPE html>
<html lang="zh-CN">
<head>
  <meta charset="UTF-8">
  <meta name="viewport" content="width=device-width, initial-scale=1.0">
  <title>ClipboardSync 中继服务</title>
  <style>
    body { font-family: -apple-system, sans-serif; max-width: 600px; margin: 50px auto; padding: 20px; background: #f5f5f5; }
    .card { background: white; border-radius: 12px; padding: 24px; box-shadow: 0 2px 8px rgba(0,0,0,.1); margin-bottom: 16px; }
    h1 { margin: 0 0 8px; color: #333; font-size: 20px; }
    .status { display: inline-block; width: 8px; height: 8px; border-radius: 50%; background: #4caf50; margin-right: 6px; }
    .stat { display: flex; justify-content: space-between; padding: 6px 0; border-bottom: 1px solid #eee; }
    .stat:last-child { border: none; }
    .label { color: #666; }
    .value { font-weight: 600; }
    .footer { text-align: center; color: #999; font-size: 12px; margin-top: 16px; }
  </style>
</head>
<body>
  <div class="card">
    <h1><span class="status"></span>ClipboardSync 中继服务</h1>
    <p style="color:#666;font-size:14px;margin:4px 0 16px;">运行正常 · 仅个人/家人使用</p>
    <div class="stat"><span class="label">活跃房间</span><span class="value">${stats.rooms}</span></div>
    <div class="stat"><span class="label">在线设备</span><span class="value">${stats.devices}</span></div>
    <div class="stat"><span class="label">运行时间</span><span class="value">${Math.floor(process.uptime())}秒</span></div>
    <div class="stat"><span class="label">内存占用</span><span class="value">${Math.round(process.memoryUsage().rss / 1024 / 1024)}MB</span></div>
  </div>
  <div class="footer">ClipboardSync Relay v1.0.0 · 自托管</div>
</body>
</html>`)
    return
  }

  // 404
  res.writeHead(404, { 'Content-Type': 'text/plain' })
  res.end('Not Found')
})

// ---- 启动 ----
const PORT = config.port

// 将 WebSocket 挂到同一个 HTTP Server 上
createServer(httpServer)

httpServer.listen(PORT, config.host, () => {
  console.log('')
  console.log('╔══════════════════════════════════════════╗')
  console.log('║  ClipboardSync 中继服务器 v1.0.0          ║')
  console.log('╠══════════════════════════════════════════╣')
  console.log(`║  WS:    ws://${config.host}:${PORT}              ║`)
  console.log(`║  HTTP:  http://${config.host}:${PORT}             ║`)
  console.log(`║  健康:  http://${config.host}:${PORT}/health       ║`)
  console.log('╚══════════════════════════════════════════╝')
  console.log('')
})

// ---- 优雅退出 ----
process.on('SIGINT', () => {
  console.log(`\n${config.logPrefix} 收到 SIGINT，关闭中...`)
  const stats = roomManager.stats
  if (stats.rooms > 0) {
    console.log(`${config.logPrefix} 清理 ${stats.rooms} 个房间、${stats.devices} 个连接`)
  }
  httpServer.close(() => {
    console.log(`${config.logPrefix} 服务已关闭`)
    process.exit(0)
  })
})

process.on('SIGTERM', () => {
  console.log(`\n${config.logPrefix} 收到 SIGTERM`)
  httpServer.close(() => process.exit(0))
})
