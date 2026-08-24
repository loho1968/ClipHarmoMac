# 剪贴板同步“假连接”修复方案

## 一、立即恢复（无需改码，先做）

手机 App 中继卡片 → 点「扫码」扫 Mac 当前的配对二维码（或点「清除」后手动输入 Mac 显示的配对码）。两端配对码一致后即恢复同步。

## 二、代码修复（三端联动，把“静默失败”变成“可见失败”）

### 1. relay-server/src/room.js — 房间无人时回执发送方
`Room.relay()` 中 `count === 0` 时，向发送方回 `{ action: 'relay_no_peer', type: payload?.type }`。
- `ping → pong` 走独立分支，不受影响；旧客户端收到未知 action 自动忽略，可平滑部署。

### 2. Mac 端（3 个文件）
- `WSClient.swift`：解析 `relay_no_peer` → 新增 `onNoPeer` 回调。
- `SyncManager.swift`：`onNoPeer` → `relayStatusText = "房间内无其他设备，内容未被送达（检查两端配对码）"`。
- `MainView.swift`：状态显示按“是否已配对”区分，而不是只看传输层：
  - 已配对（`relayPairedDeviceId` 非空）→ 绿点“中继在线”＋顶部“云中继 · 剪贴板将自动同步”（维持现状）；
  - 未配对 → 黄点“等待设备加入”，顶部不再声称“将自动同步”，改为“云中继 · 等待设备加入”。

### 3. 鸿蒙端（2 个文件）
- `WSClient.ets`：新增 `RELAY_NO_PEER` action 解析 → `onNoPeer` 回调。
- `SyncManager.ets`：
  - `onNoPeer` → `_relayStatusText = "房间内无设备，内容未送达（当前配对码 XXXXXX）"`；
  - WS 连上但未配对时状态文本明确为“已连中继，等待 Mac 加入（配对码 XXXXXX）”，替换含义模糊的“等待设备加入...”；
  - **修复 2301115 刷屏**：`onNetworkLost` 中调用 `this.tcpClient.disconnect()`，WiFi 丢失后停掉对局域网 IP 的无限重连（回到 WiFi 时 `onNetworkMatched` 会自动重建 TCP）。

## 三、验证
1. relay-server：`node --check src/room.js` ＋ 本地起服务、两个 ws 客户端脚本验证：同 roomKey 互通、不同 roomKey 发送方收到 `relay_no_peer`。
2. Mac：`swift build --package-path ClipboardSync/mac` 零错误。
3. 鸿蒙：`devecocli build --project-path ClipboardSync/harmony` 零错误（将加载 deveco-cli 技能执行）。

## 四、部署提醒
`relay_no_peer` 需将 relay-server 更新部署到 110.42.225.37（PM2）后才生效；客户端改动可先上线，对旧服务器无副作用（只是收不到回执）。

## 五、不做的事（说明）
- 不改 roomKey 生成/持久化机制（配对码分叉的根因在双 Mac 场景，本次先保证分叉时“一眼可见、立刻可修”；多房间同时加入属架构级改动，另行规划）。
- 不动 `TCPClient` 的重连上限（`onNetworkLost` 断开已覆盖本场景，保留 LAN 优先的自动恢复能力）。