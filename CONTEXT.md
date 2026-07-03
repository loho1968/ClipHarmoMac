# 项目背景 (Project Context)

> 本文档为新加入的开发者（或未来的自己换设备后）提供项目全貌，
> 包括项目是什么、为什么存在、技术栈、当前状态、如何开始工作。

---

## 一、项目概述

**ClipHarmoMac** 是一款 Mac 与鸿蒙手机之间的**剪贴板实时同步工具**。

在 Mac 上复制一段文字，手机会自动收到；在手机上复制，Mac 也会同步。支持文本、图片、文件和短信验证码同步。

这是**个人自用项目**，不计划上架发布，以实用为第一优先级。

### 核心价值

- 消除 Mac 和手机之间手动传输剪贴板内容的摩擦
- 特别适合验证码场景：手机收到短信 → 自动提取 → Mac 剪贴板就绪
- 家里和公司各一台 Mac 时自动切换，无需手动配置

---

## 二、为什么有这个项目

### 动机

1. **日常工作痛点**：Mac 上填验证码需要拿起手机看一眼再敲，烦
2. **没有现成方案**：鸿蒙手机和 Mac 之间没有类似 Apple 连续互通的生态
3. **学习实践**：通过实际项目学习 Swift/SwiftUI 和 ArkTS/ArkUI 开发

### 使用场景

| 场景 | 描述 |
|------|------|
| 验证码同步 | 手机收到短信验证码 → 自动提取 → Mac 剪贴板直接粘贴 |
| 文本同步 | Mac 复制一段文字 → 手机随手粘贴 |
| 图片同步 | Mac 截图 → 手机相册/聊天中粘贴 |
| 跨网络同步 | 手机在户外 5G，Mac 在家 WiFi，通过云中继同步 |
| 双 Mac 切换 | 家里 Mac-Home，公司 Mac-Office，手机自动匹配 |

### 项目边界

- **做什么**：Mac ↔ 鸿蒙手机剪贴板同步
- **不做什么**：不搞剪贴板历史管理、不搞云存储、不搞多平台（iOS/Android）、不搞商业化
- **目标用户**：自己 + 家人（纯个人用途）

---

## 三、总体架构

```
┌──────────────────────────────────────────────────────────┐
│                     ClipHarmoMac                          │
│                                                          │
│  ┌──────────────────┐       ┌──────────────────┐        │
│  │    Mac 端        │       │   鸿蒙手机端      │        │
│  │  (Swift/SwiftUI) │       │  (ArkTS/ArkUI)   │        │
│  │                  │       │                  │        │
│  │  SyncManager ────┼──TCP──┼── SyncManager    │        │
│  │  (总协调器)       │ 19877 │  (总协调器)       │        │
│  │                  │       │                  │        │
│  │  WSClient ───────┼──WS───┼── WSClient       │        │
│  └──────────────────┘       └──────────────────┘        │
│           │                          │                   │
│           │    WebSocket             │                   │
│           └────────┬─────────────────┘                   │
│                    │                                     │
│           ┌────────▼────────┐                            │
│           │  中继服务器       │                            │
│           │  (Node.js/ws)   │                            │
│           │  腾讯云轻量服务器  │                            │
│           └─────────────────┘                            │
└──────────────────────────────────────────────────────────┘
```

### 连接模式

| 模式 | 协议 | 何时使用 | 延迟 |
|------|------|---------|------|
| **局域网直连** | TCP (19877) + UDP 广播 (19876) | 同一 WiFi | < 1ms |
| **云中继** | WebSocket | 不同网络 | 取决于服务器延迟 |
| **混合** | 两者同时运行 | 局域网优先，中继后备 | 自动切换 |

### 端口分配

| 端口 | 协议 | 用途 |
|------|------|------|
| 19876 | UDP | 广播发现设备 |
| 19877 | TCP | 剪贴板数据传输 |
| 19878 | TCP | Mac → 手机 IP 反向发现 |
| 8443 | WebSocket | 云中继服务器（Nginx 反代） |

---

## 四、项目结构

```
ClipHarmoMac/                        # 仓库根目录
├── ClipboardSync/                   # 客户端代码
│   ├── mac/                         # Mac 端 (Swift + SwiftUI)
│   │   ├── Package.swift            # SPM 构建配置
│   │   └── ClipboardSync/
│   │       ├── ClipboardSyncApp.swift   # @main 入口
│   │       ├── AppDelegate.swift        # 菜单栏 + Popover 管理
│   │       ├── MainView.swift           # 菜单栏 UI（状态/中继/历史）
│   │       ├── SyncManager.swift        # 核心协调器（双模切换）
│   │       ├── Protocol.swift           # 消息协议 + 中继配置
│   │       ├── ClipboardMonitor.swift   # NSPasteboard 轮询监听
│   │       ├── TCPServer.swift          # TCP 服务端（NWListener）
│   │       ├── DiscoveryService.swift   # UDP 广播（BSD Socket）
│   │       ├── WSClient.swift           # WebSocket 中继客户端
│   │       ├── NetworkMonitor.swift     # WiFi 变化感知
│   │       ├── QRCodeGenerator.swift    # 二维码生成
│   │       ├── VerificationCodeHandler.swift # 验证码提取与通知
│   │       ├── SaveDirectoryManager.swift    # 接收文件保存目录
│   │       ├── LaunchAgentManager.swift      # 开机自启
│   │       └── Info.plist              # LSUIElement=true
│   │
│   └── harmony/                     # 鸿蒙端 (ArkTS + ArkUI)
│       └── entry/src/main/ets/
│           ├── model/
│           │   ├── SyncManager.ets           # 核心协调器
│           │   └── NetworkContextManager.ets  # WiFi 网络感知
│           ├── common/
│           │   ├── Protocol.ets              # 通信协议
│           │   ├── WSClient.ets              # WebSocket 中继客户端
│           │   ├── TCPClient.ets             # TCP 客户端
│           │   ├── DiscoveryService.ets      # UDP 广播发现
│           │   └── DiscoveryTCPServer.ets    # TCP 反向发现
│           ├── entryability/
│           │   └── EntryAbility.ets
│           └── pages/
│               └── Index.ets                 # 主 UI
│
├── relay-server/                    # 云中继服务器 (Node.js)
│   ├── package.json
│   ├── ecosystem.config.js          # PM2 配置
│   └── src/
│       ├── index.js                 # HTTP + WS 入口
│       ├── server.js                # WebSocket 核心 + 消息路由
│       ├── room.js                  # 房间管理（按 roomKey 隔离）
│       └── config.js                # 配置常量
│
├── 开发计划/                         # 需求规划文档
│   ├── 云同步计划.md                 # 中继服务器方案设计
│   ├── 二维码配对计划.md
│   ├── 图片剪贴板-mac.md
│   ├── 图片剪贴板-手机.md
│   ├── 自动复制验证码.md
│   └── 中继服务器配置解耦计划.md
│
├── .ai/                            # AI 辅助开发上下文
│   ├── DECISIONS.md                 # 架构决策（本文档的详细版）
│   ├── HANDOFF.md
│   └── TODO.md
│
├── generate.sh                     # 一键构建+启动 Mac App
├── kill_clipboard_sync.sh          # 杀掉运行中的进程
├── relay_config.example.json       # 中继服务器配置文件模板
├── README.md                       # 使用说明
├── CLAUDE.md                       # Claude Code 开发约定
└── AGENTS.md                       # Agent 配置
```

---

## 五、当前功能状态（2025-07）

### 已完成 ✅

| 功能 | Mac 端 | 鸿蒙端 | 备注 |
|------|--------|--------|------|
| 文本剪贴板同步 | ✅ | ✅ | LAN + 中继双模 |
| 图片剪贴板同步 | ✅ | ⚠️ 框架 | Mac 发送图片已通，鸿蒙接收待实现 |
| 文件剪贴板同步 | ✅ | ⏳ | 含分片传输 |
| 短信验证码自动提取 | ✅ 接收 | ✅ 提取 | 手机提取后发 Mac |
| UDP 广播设备发现 | ✅ | ✅ | |
| TCP 直连 | ✅ | ✅ | |
| WebSocket 中继 | ✅ | ✅ | |
| LAN/中继自动切换 | ✅ | ⏳ | WiFi 变化感知已通 |
| 二维码配对 | ✅ | ⏳ | Mac 端生成，手机端扫码待实现 |
| 开机自启 | ✅ | - | LaunchAgent |
| 同步历史记录 | ✅ | ⏳ | 最近 50 条 |
| 系统通知 | ✅ | ⏳ | 双通道 UN + NS |
| 保存目录自定义 | ✅ | - | 默认 ~/Downloads/ClipboardSync/ |
| 菜单栏状态图标 | ✅ | - | 绿/橙/灰三色 |
| 单实例保护 | ✅ | - | |

### 待完成 ⏳

| 优先级 | 事项 |
|--------|------|
| P0 | 鸿蒙端 UDP 自动发现后自动发起 TCP 连接 |
| P1 | 鸿蒙端图片接收并写入系统剪贴板 |
| P1 | 鸿蒙端后台保活（ContinuousTask） |
| P2 | 端到端 AES-256-GCM 加密 |
| P2 | 多设备同时连接支持 |
| P2 | 中继管理后台（Web 页面） |
| P3 | 单元测试 |

---

## 六、技术栈

| 端 | 语言 | UI 框架 | 网络 | 剪贴板 API | 构建工具 |
|----|------|---------|------|-----------|---------|
| Mac | Swift 5.9 | SwiftUI | NWListener, BSD Socket, URLSessionWebSocketTask | NSPasteboard | SPM / Xcode |
| 鸿蒙 | ArkTS | ArkUI | @kit.NetworkKit (socket) | @kit.BasicServicesKit (pasteboard) | DevEco Studio 6.1+ |
| 中继 | Node.js 20 | 无（后端服务） | ws (WebSocket) | - | npm / PM2 |

### 环境要求

| 工具 | 版本 |
|------|------|
| macOS | Darwin 25.x (macOS 26) |
| Xcode Command Line Tools | Swift 5.9+ |
| DevEco Studio | 6.1+ |
| HarmonyOS SDK | API 23 (6.1.0) |
| 鸿蒙手机 | HarmonyOS 6.1, API 23 |
| Node.js | 20+ |
| macOS 部署目标 | macOS 13+ |

---

## 七、如何开始工作

### 7.1 拉取代码后

```bash
git clone <repo-url> ClipHarmoMac
cd ClipHarmoMac
```

### 7.2 Mac 端开发

```bash
# 构建
cd ClipboardSync/mac
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
swift build

# 调试运行
swift run ClipboardSync

# 一键构建 + 后台运行
./generate.sh
```

**注意**：
- `swift run` 模式下没有 Bundle ID，系统通知功能不可用
- 构建产物路径：`.build/debug/ClipboardSync`
- 配置文件：`~/.clipboardsync/relay_config.json`（不存在则用 localhost 兜底）

### 7.3 鸿蒙端开发

1. 用 DevEco Studio 6.1+ 打开 `ClipboardSync/harmony`
2. 连接鸿蒙真机
3. 编译运行
4. 查看日志：DevEco Studio Log 窗口筛选 `SyncManager` / `TCPClient` / `WSClient`

**手动连接测试**：
1. Mac 端启动后，获取局域网 IP：`ipconfig getifaddr en0`
2. 鸿蒙端输入该 IP，点击连接

### 7.4 中继服务器开发

```bash
cd relay-server
npm install
node src/index.js
# 访问 http://localhost:3000/health 验证
```

### 7.5 常见调试场景

| 场景 | 调试方法 |
|------|---------|
| Mac 端日志 | Xcode Console 或终端 `swift run` |
| 鸿蒙端日志 | DevEco Studio Log 窗口 |
| 中继日志 | 终端输出或 `pm2 logs` |
| 局域网通不通 | `curl http://<Mac IP>:19877` 无响应是正常的（TCP 需要 JSON） |
| 验证 UDP 广播 | Wireshark 监听端口 19876 |
| 验证 WebSocket | `wscat -c ws://localhost:3000` |

---

## 八、通信协议速览

### 消息结构

```swift
struct SyncMessage: Codable {
    let type: MessageType       // clipboardText | clipboardImage | clipboardFile | ...
    let content: String         // 文本内容或 Base64 数据
    let timestamp: Double       // 去重用
    let deviceId: String        // 发送方标识
    let mimeType: String?       // text/plain | image/jpeg | ...
    let networkSSID: String?    // WiFi SSID（双 Mac 切换用）
    // 分片字段
    var transferId: String?     // UUID
    var chunkIndex: Int?
    var totalChunks: Int?
    // 文件元数据
    var fileName: String?
    var fileSize: Int?
    // ... 更多可选字段
}
```

### 中继层协议

```
客户端 → 服务端:  { action: "auth", roomKey, deviceId }
服务端 → 客户端:  { action: "auth_ok", pairedDeviceId }
客户端 → 服务端:  { action: "relay", roomKey, deviceId, payload: SyncMessage }
服务端 → 客户端:  { action: "relay", fromDeviceId, payload: SyncMessage }
```

### 去重机制

1. **Timestamp 过滤**：`msg.timestamp <= lastSentTimestamp && msg.deviceId == selfDeviceId` → 丢弃
2. **isProcessingRemote 标记**：远端写入时跳过 ClipboardMonitor 检测

---

## 九、关键设计约束

### 安全约束

- V1 阶段：中继服务器可读取消息内容（明文传输）
- 仅个人/家人使用，不对外暴露服务
- Room Key 不通过 URL 传递（始终在 JSON body 中）

### 性能约束

- NSPasteboard 轮询间隔：0.5 秒
- UDP 广播间隔：3 秒
- 中继心跳：30 秒
- 剪贴板历史：最多 50 条
- 图片压缩：长边 1920px、JPEG 质量 0.80、最大 20MB
- 分片大小：256KB（>500KB 自动分片）
- 中继消息最大 4MB

### 平台约束

- macOS 最低版本：13.0
- HarmonyOS API 最低版本：23 (6.1.0)
- Mac 端不依赖任何第三方 Swift 包（纯系统框架）
- 鸿蒙端不依赖任何第三方 npm 包（纯系统 API）

### 构建约束

- Mac 端必须用 Xcode 自带的 Swift 工具链（`/Applications/Xcode.app/Contents/Developer`）
- 不支持 `swift build` 用系统默认工具链（会缺少 AppKit 等框架）
- `LSUIElement = true` 意味着调试需手动查看 Xcode Console 或终端日志

---

## 十、网络拓扑与配对流程

### 局域网配对（零操作）

```
1. Mac 和手机连同一 WiFi
2. 两端 App 启动
3. Mac 通过 UDP 广播发出 ping (含 deviceId)
4. 手机收到广播 → 知道 Mac 的 IP
5. 手机 TCP 连接 Mac:19877
6. Mac 通过 TCP 下发 roomKeyInfo（roomKey + relayHost）
7. 手机保存配对信息，连接成功
```

### 云中继配对（手动/扫码）

```
1. Mac 启动 → 自动生成 6 位 Room Key
2. Mac 连接中继服务器，auth(roomKey)
3. 用户将 Room Key 传达给手机端（手动输入 / 扫码）
4. 手机连接中继服务器，auth(roomKey)
5. 服务器匹配同一 roomKey 的两端 → 配对成功消息
6. 双向消息转发开始
```

### 双 Mac 场景（家/公司）

```
1. 手机连家里 WiFi → 自动发现家 Mac → 保存（SSID, roomKey, relayHost）配对档案
2. 手机连公司 WiFi → 自动发现公司 Mac → 保存另一份配对档案
3. 后续：
   - 连家里 WiFi → NetworkContextManager 匹配档案 → 连家 Mac
   - 连公司 WiFi → 匹配另一份档案 → 连公司 Mac
   - 用 5G → 无 WiFi 匹配 → 通过云中继连接最近配对的 Mac
```

---

## 十一、中继服务器运维

### 服务器信息

| 项目 | 配置 |
|------|------|
| 云平台 | 腾讯云轻量应用服务器 |
| 镜像 | Node.js |
| 代码路径 | `/opt/relay-server/` |
| 进程管理 | PM2 |
| 健康检查 | `GET /health` → `{ status: "ok", rooms, devices }` |

### 部署命令

```bash
# SSH 到服务器
ssh user@<服务器IP>

# 拉取更新
cd /opt/relay-server && git pull && npm install

# 重启服务
pm2 reload ecosystem.config.js

# 查看状态
pm2 status
pm2 logs relay-server
```

---

## 十二、已知踩坑记录

### Mac 端

1. **NWListener 默认监听 IPv6**：`lsof` 显示 IPv6 是正常的，实际支持双栈
2. **UDP 广播发送和接收必须不同队列**：共用队列会导致 send 被 recvfrom 阻塞
3. **swift run 无 Bundle ID**：通知、LaunchAgent 等功能不可用，需 `generate.sh` 构建为 .app
4. **TIFF → JPEG 转换**：NSPasteboard 读图片是 TIFF 格式，发送前需转为 JPEG

### 鸿蒙端

1. **socket.close() 是异步的**：重连前需等旧 socket 完全关闭，建议延迟 500ms
2. **SocketErrorInfo 在 API 23 中不存在**：改用 BusinessError
3. **build-profile.json5 SDK 版本必须是字符串**：`"6.1.0(23)"` 而非 `23`

---

## 十三、文档索引

| 文档 | 内容 |
|------|------|
| `README.md` | 用户使用说明 |
| `DECISIONS.md` | 架构决策记录 |
| `CONTEXT.md` | 本文档 — 项目背景 |
| `CLAUDE.md` | Claude Code 开发约定 |
| `ClipboardSync/PROJECT.md` | 技术架构详细说明 |
| `开发计划/*.md` | 各功能规划文档 |
| `.ai/TODO.md` | 开发待办 |
| `.qoder/repowiki/zh/` | Qoder 知识库（API 参考、构建部署等） |

---

> **提示**：如果你是新加入的开发者（或未来的自己），建议阅读顺序：
> 1. 先读本文档了解全貌
> 2. 读 `DECISIONS.md` 理解架构决策
> 3. 读 `README.md` 了解如何使用
> 4. 读 `ClipboardSync/PROJECT.md` 了解技术细节
> 5. 开始写代码
