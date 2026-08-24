# AGENTS.md

ClipHarmoMac — Mac 与鸿蒙手机之间的剪贴板同步工具（文字 + 图片 + 文件），自用项目，不上架发布。

**全部用中文回答。**

## 项目组成（三部分）

| 部分 | 技术栈 | 位置 |
|------|--------|------|
| Mac 端 | Swift + SwiftUI（菜单栏应用，SPM） | `ClipboardSync/mac/` |
| 鸿蒙端 | ArkTS + ArkUI（API 23 / HarmonyOS 6.1） | `ClipboardSync/harmony/` |
| 云中继 | Node.js + ws（PM2 + Nginx） | `relay-server/` |

## 构建与运行

### Mac 端（Swift Package，无 .xcodeproj）

```bash
# 编译验证（修改 Swift 代码后必须执行，并修复所有编译错误）
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift build --package-path ClipboardSync/mac

# 调试运行
cd ClipboardSync/mac && swift run

# 一键构建并后台启动（杀旧进程 → 构建 → 启动）
./generate.sh
```

### 鸿蒙端（deveco-cli 工具链）

```bash
devecocli build --project-path ClipboardSync/harmony        # 编译
devecocli run --project-path ClipboardSync/harmony          # 运行到真机
devecocli log --project-path ClipboardSync/harmony --level E --tail 50   # 看错误日志
devecocli device list                                       # 设备列表
devecocli docs search <关键词>                               # 查鸿蒙开发文档
```

- 语法检查已通过 `deveco-mcp` 在 `.mcp.json` 中配置（`mcp__deveco-mcp__check`）
- 语法检查失败时（DevEco 路径映射不匹配等），跳过检查，直接手动验证代码逻辑

### 云中继服务器

```bash
cd relay-server
npm install
node src/index.js          # 默认端口 3000，环境变量 RELAY_PORT / RELAY_HOST
# 或 PM2：pm2 start ecosystem.config.js
```

## 项目结构

```
ClipboardSync/
├── mac/ClipboardSync/          # Mac 端源码
│   ├── SyncManager.swift       # 总协调器（双模切换 + 加密 + 分片）
│   ├── Protocol.swift          # 消息协议 + 中继配置（与鸿蒙端 Protocol.ets 镜像）
│   ├── WSClient.swift          # WebSocket 中继客户端
│   ├── TCPServer.swift         # TCP 数据服务端
│   ├── DiscoveryService.swift  # UDP 广播发现（多网卡）
│   ├── NetworkMonitor.swift    # WiFi 变化感知
│   ├── ClipboardMonitor.swift  # NSPasteboard 轮询监听
│   ├── CryptoModule.swift      # 配对码 HKDF → AES-256-GCM 端到端加密
│   ├── MainView.swift          # 菜单栏 Popover UI
│   ├── AppDelegate.swift       # 菜单栏 + 通知管理
│   ├── VerificationCodeHandler.swift  # 验证码提取与通知
│   ├── SaveDirectoryManager.swift / LaunchAgentManager.swift / QRCodeGenerator.swift
│   └── ClipboardSyncApp.swift  # @main 入口
├── harmony/entry/src/main/ets/ # 鸿蒙端源码
│   ├── model/SyncManager.ets       # 总协调器（双模 + 加密 + 分片）
│   ├── model/NetworkContextManager.ets  # WiFi 感知 + 双 Mac 配对档案
│   ├── model/SaveDirectoryManager.ets
│   ├── common/{WSClient,TCPClient,DiscoveryService,DiscoveryTCPServer,CryptoModule,Protocol}.ets
│   ├── pages/Index.ets             # 主界面
│   ├── pages/ScanPage.ets          # 二维码扫码配对
│   └── entryability/EntryAbility.ets  # 生命周期 + 后台保活
└── relay-server/src/           # 中继服务源码
    ├── index.js                # HTTP 入口 + WebSocket 启动
    ├── server.js               # WebSocket 核心（auth/心跳/转发）
    ├── room.js                 # 按 roomKey 分房间管理
    └── config.js
```

## 通信架构

**双模：局域网直连优先，云中继后备，自动切换。**

| 通道 | 协议/端口 | 说明 |
|------|-----------|------|
| 设备发现 | UDP 19876 广播 | 同一 WiFi 自动发现；TCP 19878 反向发现兜底 |
| LAN 数据 | TCP 19877 | Mac 为 Server，鸿蒙为 Client；JSON + `\n` 分隔 |
| 中继数据 | WebSocket（ws://host:port/ws） | 6 位配对码（roomKey）建房间，双向转发 |

### 关键机制

- **消息协议**：`SyncMessage` JSON 结构（`type/content/timestamp/deviceId` + 分片字段 `transferId/chunkIndex/totalChunks`），两端协议定义必须保持镜像同步
- **端到端加密**：roomKey → HKDF-SHA256 → AES-256-GCM；AAD 绑定 deviceId + 消息类型；解密失败回退明文（兼容旧端）
- **分片传输**：>500KB 按 256KB 分片，30s 超时丢弃
- **防回环**：timestamp 过滤（自回声）+ `isProcessingRemote` 标记（远端写入不回传）双层防护
- **双 Mac 切换**：手机按 WiFi SSID 匹配 NetworkProfile；TCP 建连后 Mac 自动下发 `roomKeyInfo`（配对码 + 中继地址）
- **图片/文件**：Mac 端"暂存待发"，用户手动点发送；手机复制验证码自动推送 Mac 写剪贴板 + 通知

## 开发规则

1. **代码探索优先使用 codegraph**：阅读或修改代码前，优先用 `mcp__codegraph__codegraph_explore` 搜索代码结构、符号定义和调用关系，避免直接 Read 整个文件
2. **修改代码后同步索引**：每次完成代码修改后执行 `codegraph sync`；若报告 "not initialized"，先 `codegraph init` 再 sync
3. **Swift 修改后必须编译验证**：用上面的 `swift build --package-path` 命令，修复所有编译错误
4. **SwiftUI 优先**：除非功能只有 AppKit 支持；UI 遵循 macOS HIG，用 SF Symbols；无兼容性包袱，target 最新 macOS + 最新 Swift 语言特性（async/await、actors）
5. **鸿蒙端注意**：`socket.close()` 是异步操作，重连前先断开旧连接并延迟；API 23 socket 模块无 `SocketErrorInfo`，用 `BusinessError`
6. **改协议要两端同步**：`Protocol.swift` 与 `Protocol.ets` 的消息类型/字段需同步修改

## 相关文档

- `README.md` — 功能说明、配对流程、常见问题
- `ClipboardSync/PROJECT.md` — 项目结构、已知踩坑记录
- `.ai/DECISIONS.md` — 架构决策记录（ADR）
- `.ai/HANDOFF.md` — 最近一次工作交接
- `开发计划/` — 历次开发/交接/改进计划
