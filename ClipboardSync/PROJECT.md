# ClipboardSync - Mac 与鸿蒙手机剪贴板同步

局域网内 Mac 电脑与鸿蒙手机之间的剪贴板实时同步工具。自用项目，不上架发布。

## 项目结构

```
ClipboardSync/
├── mac/                                    # Mac 端 (Swift + SwiftUI)
│   ├── Package.swift                       # SPM 构建配置
│   └── ClipboardSync/
│       ├── ClipboardSyncApp.swift          # 入口，菜单栏应用
│       ├── AppDelegate.swift              # 菜单栏 popover 管理
│       ├── MainView.swift                 # 主 UI（状态+历史列表）
│       ├── Protocol.swift                 # 通信协议常量与消息结构
│       ├── DiscoveryService.swift         # UDP 广播设备发现
│       ├── TCPServer.swift                # TCP 服务端（换行分隔JSON）
│       ├── ClipboardMonitor.swift         # NSPasteboard 轮询监听
│       ├── SyncManager.swift              # 总协调器
│       └── Info.plist                     # LSUIElement=true, 无Dock图标
│
├── harmony/                                # 鸿蒙端 (ArkTS + ArkUI)
│   ├── AppScope/app.json5
│   ├── build-profile.json5
│   ├── oh-package.json5
│   └── entry/
│       ├── oh-package.json5
│       ├── build-profile.json5
│       ├── hvigorfile.ts
│       ├── src/main/
│       │   ├── module.json5               # 模块配置+权限声明
│       │   ├── ets/
│       │   │   ├── common/
│       │   │   │   ├── Protocol.ets       # 通信协议（与Mac端共享定义）
│       │   │   │   ├── DiscoveryService.ets # UDP 广播发现
│       │   │   │   └── TCPClient.ets      # TCP 客户端
│       │   │   ├── model/
│       │   │   │   └── SyncManager.ets    # 总协调器
│       │   │   ├── entryability/
│       │   │   │   └── EntryAbility.ets
│       │   │   └── pages/
│       │   │       └── Index.ets          # 主 UI
│       │   └── resources/base/
│       │       ├── element/{string,color}.json
│       │       └── profile/main_pages.json
│       └── hvigor/
│           └── hvigor-config.json5
│
└── PROJECT.md                              # 本文档
```

## 通信架构

| 层 | 协议 | 端口 | 说明 |
|---|---|---|---|
| **设备发现** | UDP 广播 | 19876 | 双端定时发送 `{type:"ping", deviceId:"xxx"}` 广播包，收到后得知对方存在 |
| **数据传输** | TCP 长连接 | 19877 | 鸿蒙端主动连接 Mac 端，JSON + `\n` 分隔，自动处理粘包 |
| **消息格式** | JSON | - | `{type, content, timestamp, deviceId, mimeType}` |

**连接角色**：Mac 为 TCP Server，鸿蒙为 TCP Client。

**去重机制**：每条消息附带 `timestamp`，接收端只处理 `timestamp > lastSentTimestamp` 的消息，避免写入剪贴板后触发监听回环。

## 运行方式

### Mac 端

```bash
cd ClipboardSync/mac
swift build
swift run ClipboardSync
```

应用以菜单栏图标运行（无 Dock 图标），点击图标弹出状态面板。

> 注意：服务在 `applicationDidFinishLaunching` 中自动启动，无需手动操作。

### 鸿蒙端

1. 用 **DevEco Studio 6.1+** 打开 `ClipboardSync/harmony` 目录
2. 连接鸿蒙真机，编译安装运行
3. 在主界面手动输入 Mac 的局域网 IP 地址（如 `192.168.x.x`）点击连接

获取 Mac 局域网 IP：

```bash
ipconfig getifaddr en0
```

## 当前功能状态

| 功能 | 状态 | 备注 |
|------|------|------|
| Mac → 鸿蒙 文本同步 | ✅ 已通 | LAN + 中继双模 |
| 鸿蒙 → Mac 文本同步 | ✅ 已通 | LAN + 中继双模 |
| UDP 自动发现 + 自动连接 | ✅ 已通 | 鸿蒙收到广播后自动提取 IP → TCP 连接；TCP 反向发现兜底 |
| 手动输入 IP 连接 | ✅ 已通 | 鸿蒙端输入 Mac IP 后连接成功 |
| 图片剪贴板同步 | ✅ 已通 | 两端均支持发送/接收，含 JPEG 压缩、分片传输 |
| 文件剪贴板同步 | ✅ 已通 | Base64 + 分片，接收后保存到本地目录 |
| 去重防回环 | ✅ 已通 | Timestamp + isProcessingRemote 双层防护 |
| 同步历史记录 | ✅ 已通 | 两端 UI 显示最近 50 条 |
| WebSocket 云中继 | ✅ 已通 | Node.js 中继服务器 + 两端 WS 客户端 |
| LAN/中继自动切换 | ✅ 已通 | 局域网优先，WiFi 变化自动切换 |
| 二维码配对 | ✅ 已通 | Mac 生成含 roomKey+IP 的二维码，手机扫码配对 |
| 开机自启（Mac） | ✅ 已通 | LaunchAgent 注册 |
| 菜单栏状态图标 | ✅ 已通 | 绿/橙/灰 三色指示 |
| 双 Mac 切换（家/公司） | ✅ 已通 | NetworkProfile 按 WiFi SSID 匹配 |
| 系统通知 | ✅ 已通 | UN + NS 双通道 |
| 保存目录自定义 | ✅ 已通 | 默认 ~/Downloads/ClipboardSync/ |
| 验证码自动提取 | ✅ 已通 | 鸿蒙端提取短信 → 发 Mac |

## 已知问题与踩坑记录

### 1. 鸿蒙端 TCP 连接 `2301115 Operation in progress`

**原因**：`socket.close()` 是异步操作，旧 socket 还没完全关闭就创建新连接，系统拒绝。

**解决**：`SyncManager.setupTcpClient()` 中先 `disconnect()` 旧 TCPClient，再创建新实例，延迟 500ms 后才调用 `connect()`。

### 2. 鸿蒙端 `socket.SocketErrorInfo` 不存在

**原因**：API 23 中 `@kit.NetworkKit` 的 socket 模块没有导出 `SocketErrorInfo` 类型。

**解决**：使用 `BusinessError`（从 `@kit.BasicServicesKit` 导入）作为 `on('error')` 回调的参数类型。

### 3. Mac 端 `build-profile.json5` SDK 版本类型错误

**原因**：`compileSdkVersion` 和 `compatibleSdkVersion` 必须是字符串类型，不能是数字。

**解决**：使用 `"6.1.0(23)"` 而不是 `23`。

### 4. Mac 端 SyncManager.start() 未在启动时调用

**原因**：最初只在 `MainView.onAppear` 中调用，而 `onAppear` 需要用户点击菜单栏图标才触发。

**解决**：在 `AppDelegate.applicationDidFinishLaunching` 中直接调用 `syncManager.start()`。

### 5. Mac 端 NWListener 默认监听 IPv6

**原因**：macOS 的 NWListener 监听 IPv6 时自动支持双栈（IPv4+IPv6），实际不影响连接，但 `lsof` 显示为 IPv6 可能造成误判。

## 后续完善方向

### P0 - 必须修复

- [x] **UDP 自动发现连接**：✅ 鸿蒙端 DiscoveryService 提取 `remoteInfo.address` → 自动 TCP 连接
- [x] **LAN/中继双模**：✅ 局域网优先，中继后备，WiFi 变化自动切换

### P1 - 体验优化

- [x] **图片剪贴板同步**：✅ 两端均支持发送/接收，JPEG 压缩 + 分片
- [x] **Mac 端菜单栏状态图标**：✅ 已连接/搜索中/断开 三色
- [x] **Mac 端开机自启**：✅ LaunchAgent
- [ ] **鸿蒙端后台保活**：申请 ContinuousTask（`backgroundModes: dataTransfer`），保持后台同步
- [x] **连接状态持久化**：✅ NetworkProfile 按 WiFi SSID 记住 Mac IP

### P2 - 安全与扩展

- [ ] **端到端加密**：两端配对时交换密钥，AES-256-GCM 加密传输内容
- [x] **跨 WiFi/广域网支持**：✅ WebSocket 中继服务器已部署
- [x] **多设备支持**：✅ TCPServer 支持多个 TCP 连接
- [x] **大文件传输优化**：✅ 256KB 分片 + 500KB 阈值
- [ ] **鸿蒙端后台同步降级方案**：应用被系统冻结时，使用通知或手动打开应用触发同步

## 技术栈

| 端 | 语言 | UI 框架 | 网络 | 剪贴板 API |
|---|---|---|---|---|
| Mac | Swift 5.9 | SwiftUI | NWListener (TCP) + BSD Socket (UDP) | NSPasteboard |
| 鸿蒙 | ArkTS | ArkUI | @kit.NetworkKit (socket.TCPSocket / socket.UDPSocket) | @kit.BasicServicesKit (pasteboard) |

## 开发环境

| 工具 | 版本 |
|---|---|
| macOS | Darwin 25.5.0 |
| Xcode Command Line Tools | Swift 5.9+ |
| DevEco Studio | 6.1+ |
| HarmonyOS SDK | API 23 (6.1.0) |
| 鸿蒙手机 | HarmonyOS 6.1, API 23 |
