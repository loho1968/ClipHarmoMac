# 架构决策记录 (Architecture Decision Records)

> 本文档记录 ClipHarmoMac 项目中的关键架构决策、技术选型理由和设计权衡。
> 格式参考 [ADR](https://adr.github.io/) 理念，按时间倒序排列。

---

## ADR-001: 双模通信架构（局域网直连 + 云中继）

**日期**: 2025-07  
**状态**: ✅ 已实现

### 背景

剪贴板同步需要在不同网络场景下都能工作：
- 同一 WiFi 下希望低延迟（局域网直连）
- 手机在户外用 5G/4G 时也希望同步（需跨网络）

### 决策

采用**局域网优先、中继后备**的双模架构：

```
同一 WiFi → TCP 直连 (LAN)
不同网络 → WebSocket 中继 (Relay)
```

- Mac 作为 TCP Server（端口 19877），鸿蒙作为 TCP Client
- 中继服务器独立部署，两端各作为 WebSocket Client 连接
- SyncManager 统一管理两种模式的无缝切换

### 理由

1. **局域网优先**：TCP 直连延迟 < 1ms，不依赖外部服务器，不消耗带宽
2. **中继必备**：不同网络场景无法 NAT 穿透，中继是最可靠方案
3. **自动切换**：用户无需手动选择，WiFi 变化时自动重建 LAN 服务
4. **向后兼容**：纯局域网场景即使中继不可用，LAN 同步仍正常工作

### 影响

- 需要维护三套代码（Mac 客户端、鸿蒙客户端、中继服务器）
- 去重机制需要在两种通道上都生效
- 连接状态 UI 需要同时反映 LAN 和中继的状态

---

## ADR-002: 中继服务器技术选型（Node.js + ws）

**日期**: 2025-07  
**状态**: ✅ 已实现

### 背景

需要一个轻量级的消息中继服务，支持：
- 按配对码（Room Key）隔离设备
- WebSocket 长连接
- 心跳保活
- 设备上下线感知

### 决策

- **运行时**: Node.js 20+
- **WebSocket 库**: `ws`（npm）
- **进程守护**: PM2
- **反向代理**: Nginx（生产环境 wss://）

### 备选方案

| 方案 | 优点 | 缺点 |
|------|------|------|
| Node.js + ws | 生态成熟、轻量、与服务器镜像匹配 | JavaScript 非强类型 |
| Go + gorilla/ws | 高性能、并发好 | 需要 Go 运行环境，增加维护成本 |
| Python + aiohttp | 语法熟悉 | 异步模型复杂，连接管理不如 Node.js 方便 |

### 理由

1. 腾讯云轻量服务器 Node.js 镜像开箱即用
2. `ws` 是 npm 生态最成熟的 WebSocket 库，API 简洁
3. PM2 提供进程守护和日志管理，零配置
4. 代码量少（< 300 行），个人项目不宜过度设计

### 影响

- 中继服务器不存储任何消息（即发即忘）
- 房间空闲 5 分钟后自动销毁
- 需要 Nginx 配置 WebSocket 升级和 SSL 终结

---

## ADR-003: Mac 端网络栈选型（NWListener + BSD Socket 混用）

**日期**: 2025-06  
**状态**: ✅ 已实现

### 决策

| 用途 | 技术 | 理由 |
|------|------|------|
| TCP 服务端 | Network.framework `NWListener` | 原生 API，支持 `allowLocalEndpointReuse`，简洁 |
| UDP 广播发送/监听 | BSD Socket (`socket()/sendto()/recvfrom()`) | 更底层控制广播选项，`NWListener` 对 UDP 广播支持不完善 |
| WebSocket 客户端 | `URLSessionWebSocketTask` | 系统原生，无需第三方依赖 |

### 理由

1. `NWListener` 的 TCP 抽象比 BSD Socket 更简洁，自动处理连接生命周期
2. `NWListener` 默认监听 IPv6 但自动支持双栈（不影响 IPv4 连接）
3. UDP 广播发送在 `NWConnection` 中设置较繁琐，BSD Socket 更直接
4. `URLSessionWebSocketTask` 是 Apple 官方推荐方式（macOS 13+）

### 影响

- Swift 和 C 混合使用，需要手动管理 BSD Socket 生命周期
- `recvfrom` 阻塞式读取需要独立 DispatchQueue
- 广播发送队列需与接收队列分离（否则 send 被 recvfrom 阻塞）

---

## ADR-004: 协议设计（JSON + 换行分隔 vs Protobuf）

**日期**: 2025-06  
**状态**: ✅ 已实现

### 决策

采用 **JSON + `\n` 换行分隔** 作为传输协议。

### 理由

1. **可读性**：调试时直接看日志，无需反序列化工具
2. **跨语言**：Swift `Codable` 和 ArkTS `JSON.parse` 都原生支持
3. **简单可靠**：换行分隔天然解决 TCP 粘包问题
4. **性能足够**：剪贴板消息通常几十到几百字节，JSON 开销可忽略

### 不选 Protobuf/MessagePack 的理由

- Protobuf 需要 `.proto` 文件 + 代码生成，增加构建复杂度
- 剪贴板同步不是高频大吞吐场景，二进制编码的边际收益极低
- 个人项目优先可维护性而非极致性能

### 影响

- 大图片/文件需要 Base64 编码，体积膨胀约 33%
- 但通过分片传输（>500KB 自动切分）和 JPEG 压缩（长边 1920、质量 0.80）控制单条消息大小

---

## ADR-005: 分片传输策略（256KB 分片 + 500KB 阈值）

**日期**: 2025-07  
**状态**: ✅ 已实现

### 背景

图片和文件通过 Base64 编码传输，大文件会导致单条 WS/JSON 消息过大。

### 决策

- **分片大小**: 256KB（原始数据）
- **分片阈值**: >500KB 自动启动分片
- **分片超时**: 30 秒未收齐则丢弃
- **传输标识**: UUID `transferId`，按 `chunkIndex` 排序组装

### 理由

1. 256KB 分片在 Base64 后约 342KB，JSON 包装后 < 400KB，单条消息安全
2. 500KB 阈值：小图（如截图）通常 < 500KB，单条直接发送，零开销
3. 30 秒超时：剪贴板同步是实时场景，超时后丢弃不必持久化等待
4. 首片使用原始 `type`（如 `clipboardImage`），后续片统一使用 `clipboardDataChunk`

### 影响

- `SyncMessage` 结构新增 `transferId`、`chunkIndex`、`totalChunks` 字段
- 接收端维护 `transferBuffers` 哈希表，定时清理超时缓冲
- 各片乱序到达也能正确组装（通过 chunkIndex 排序）

---

## ADR-006: Room Key 配对机制

**日期**: 2025-07  
**状态**: ✅ 已实现

### 决策

- 使用 **6 位大写字母+数字** 作为房间配对码（36^6 ≈ 21 亿种组合）
- Mac 端自动生成，持久化到 `UserDefaults`（永久不变，除非主动重新生成）
- 鸿蒙端输入配对码后也持久化到本地存储
- 中继服务器按 `roomKey` 隔离房间，同一房间内双向转发

### 安全考量

| 阶段 | 措施 |
|------|------|
| V1（当前） | Room Key 鉴权 |
| V2（规划） | 端到端 AES-256-GCM 加密 |
| V3（规划） | TLS + Token 认证 |

### 理由

1. 个人/家人自用，V1 安全级别已足够
2. 6 位码易记易输入，同时暴力破解不现实
3. 服务端不存储任何消息内容（即发即忘）
4. 后续升级加密不影响现有协议层

### 配套机制

- **二维码**：Mac 生成含 roomKey、relayHost、局域网 IP 的二维码，手机扫码完成配对
- **roomKeyInfo**：TCP 连接建立后，Mac 自动向手机发送 roomKey，同一 WiFi 零手动操作
- **WiFi 匹配**：手机根据 WiFi SSID 自动匹配对应的 Mac（双 Mac 场景）

---

## ADR-007: macOS 菜单栏应用设计

**日期**: 2025-06  
**状态**: ✅ 已实现

### 决策

- 应用类型：**菜单栏应用**（`LSUIElement = true`，无 Dock 图标、无主窗口）
- 交互方式：点击菜单栏图标弹出 NSPopover
- UI 框架：SwiftUI 内嵌到 `NSHostingController`
- 生命周期：`applicationDidFinishLaunching` 中自动启动同步服务

### 理由

1. 剪贴板同步是后台服务，不需要主窗口
2. 菜单栏常驻，用户随时可查看状态和历史
3. SwiftUI 写 UI 简洁，通过 `NSHostingController` 桥接到 AppKit Popover
4. 开机自启通过 LaunchAgent 注册（`~/Library/LaunchAgents/`）

### 影响

- 需要在 AppDelegate 中手动管理 NSStatusItem 和 NSPopover
- SwiftUI 的 `@main App` 只用于声明入口，实际逻辑在 AppDelegate
- 通知发送需兼容 UNUserNotificationCenter + NSUserNotificationCenter 双通道

---

## ADR-008: 去重与回环防护

**日期**: 2025-06  
**状态**: ✅ 已实现

### 决策

采用**双层去重**机制：

1. **Timestamp 过滤**：每条消息附带发送时间戳，接收端忽略 `timestamp <= lastSentTimestamp` 的自回声消息
2. **isProcessingRemote 标记**：远端写入剪贴板时设置标志位，阻止 ClipboardMonitor 将远端写入误判为本地变化

### 理由

1. Timestamp 过滤防止"发送 → 中继转发回自身"的回环
2. isProcessingRemote 防止"远端写入剪贴板 → ClipboardMonitor 检测到变化 → 再次发送"的级联
3. 两个机制互补，覆盖不同回环路径

### 影响

- 同一设备在 LAN 和中继双通道时不会收到重复消息
- 时钟偏差可能影响去重精度（但 LAN 场景下同一设备时间一致）

---

## ADR-009: 保存目录管理

**日期**: 2025-07  
**状态**: ✅ 已实现

### 决策

- **默认目录**: `~/Downloads/ClipboardSync/`
- **自定义目录**: 用户可在 UI 中选择任意目录
- **重名处理**: 文件名冲突时追加序号 `(1)`, `(2)`...
- **持久化**: 自定义路径通过 `UserDefaults` 保存

### 理由

1. 接收到的图片/文件需要落盘（方便后续打开、存档）
2. `~/Downloads` 是用户最自然寻找的位置
3. 允许自定义满足不同用户习惯

---

## ADR-010: 验证码自动提取

**日期**: 2025-07  
**状态**: ✅ 已实现

### 决策

- 短信验证码在**鸿蒙端**自动提取（手机有短信权限）
- 提取后通过 `verificationCode` 消息类型发送到 Mac
- Mac 端收到后写入剪贴板 + 发送系统通知

### 理由

1. 手机能直接读取短信，Mac 不能
2. 验证码是高价值同步场景（Mac 上填验证码比手机方便）
3. 专用消息类型 `verificationCode` 区分于普通文本同步

### 影响

- Protocol 新增 `verificationCode` 消息类型和 `smsSender` 字段
- 降级检测：普通 `clipboardText` 也会尝试识别验证码模式

---

## ADR-011: 鸿蒙端网络权限与后台保活

**日期**: 2025-06  
**状态**: ✅ 已实现（权限）/ ⏳ 规划中（保活）

### 决策

- `module.json5` 声明 `ohos.permission.INTERNET`（API 23 自动授予，无需动态申请）
- 后台数据同步需申请 `backgroundModes: dataTransfer` 常驻任务

### 理由

1. 局域网通信在鸿蒙中归入 INTERNET 权限
2. API 23 对 INTERNET 权限自动授予，用户无感知
3. 后台保活是鸿蒙端最大的挑战，应用被系统冻结后无法同步

---

## 技术债务 & 未来决策方向

| 编号 | 事项 | 优先级 | 备注 |
|------|------|--------|------|
| TD-001 | 端到端加密 | P2 | V1 明文传输，中继服务端可读取消息内容 |
| TD-002 | 中继服务器认证升级 | P2 | Room Key 验证过于简单，长期应引入 Token |
| TD-003 | 鸿蒙端图片接收与写入剪贴板 | P1 | 当前仅有框架，需实现完整功能 |
| TD-004 | 鸿蒙端 UDP 自动发现后自动连接 | P0 | 收到广播后应自动发起 TCP 连接 |
| TD-005 | 无测试覆盖 | P2 | 所有模块无单元测试，仅靠人工验证 |
| TD-006 | 消息确认与重传机制 | P3 | 当前 fire-and-forget，弱网可能丢消息 |
| TD-007 | 中继服务器图片/文件分片转发 | P2 | 中继层 `maxPayload=4MB`，大文件需中继层也分片 |
| TD-008 | 鸿蒙端后台同步降级方案 | P1 | 应用被冻结时使用通知触发同步 |
