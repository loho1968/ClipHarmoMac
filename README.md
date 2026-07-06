# ClipHarmoMac — 剪贴板同步

Mac 与鸿蒙手机之间的剪贴板实时同步工具，支持局域网直连和云中继两种模式，可在家庭/公司多台 Mac 之间自动切换。

## 功能

| 功能 | 说明 |
|------|------|
| 文字剪贴板同步 | Mac ↔ 手机，双向实时同步 |
| 图片发送 | Mac 截图/复制 → 发送到手机；手机相册 → 发送到 Mac |
| 文件发送 | 文件通过剪贴板或分享 → 发送到对端 |
| 短信验证码 | 手机复制验证码 → Mac 自动写入剪贴板 + 通知 |
| 局域网自动发现 | 同一 WiFi 下 UDP 广播发现，零手动操作 |
| 云中继 | 不同网络（5G ↔ WiFi）通过 WebSocket 中继同步 |
| 二维码配对 | 扫码完成配对，同步设置中继地址和局域网 IP |
| 端到端加密 | ECDH P-256 + AES-256-GCM，中继服务器无法读取内容 |
| 熄屏恢复同步 | 手机亮屏后自动拉取 Mac 最新剪贴板 |
| 双 Mac 自动切换 | 家/公司各一台 Mac，手机根据 WiFi 自动匹配 |
| 后台保活 | 鸿蒙端后台持续运行，常驻通知显示连接模式 |
| 开机自启 | Mac 端通过 LaunchAgent 实现登录自动启动 |
| 保存目录管理 | 接收的图片/文件可自定义保存位置 |

## 工作原理

```
┌──────────────────────────────────────────────────┐
│              同一 WiFi → 局域网直连（LAN）          │
│  Mac ←──UDP 广播发现──→ 手机                       │
│  Mac ←──TCP :19877 ──── 手机（数据传输）            │
│                                                 │
│              不同网络 → 云中继（Relay）             │
│  Mac ←──WebSocket──→ 中继服务器 ←──WebSocket──→ 手机 │
└──────────────────────────────────────────────────┘
```

- **局域网优先**：同一 WiFi 下自动走 TCP 直连，延迟最低
- **中继后备**：不同网络时自动切换云中继，确保随时可同步
- **双 Mac 切换**：家/公司各一台 Mac 时，手机根据 WiFi 自动匹配对应的 Mac

## 快速开始

### Mac 端

```bash
# 一键构建并安装
./generate.sh

# 或手动启动（调试）
cd ClipboardSync/mac && swift run
```

首次运行会自动生成 6 位配对码，显示在菜单栏的"云中继"卡片中。

### 手机端

在 DevEco Studio 中打开 `ClipboardSync/harmony` 项目，编译部署到手机。

### 首次配对

**方式一（推荐）：同一 WiFi 自动获取**

1. Mac 和手机连接**同一 WiFi**
2. 两端 App 都启动
3. 手机会自动发现 Mac，通过 TCP 接收配对码，无需手动输入
4. 手机弹出"记住此网络"→ 点击记住
5. 看到"已连接"即配对成功

**方式二：二维码扫码**

1. Mac 菜单栏点击配对码旁的二维码图标
2. 手机 App 点击"扫码"，扫描二维码
3. 自动完成配对码设置 + 中继连接 + 局域网直连

**方式三：手动输入**

1. 在 Mac 菜单栏查看 6 位配对码
2. 在手机 App 中输入该配对码
3. 点击连接

## 配对码说明

| 场景 | 配对码变化？ |
|------|-------------|
| 首次启动 | 自动生成，之后永久不变 |
| 重启 Mac / 重启 App | 不变 |
| 点击 Mac 端的"重新生成"按钮 | 换新的 |
| 不同 Mac | 各自独立生成，互不相同 |

> 配对码保存在 `~/Library/Preferences/com.clipboardsync.app.plist` 中。

## 多台 Mac 切换（家 / 公司）

如果你家里和公司各有一台 Mac：

### 首次配置

1. **在家**：手机连家里 WiFi → 自动发现 Mac-Home → 自动获取家 Mac 的配对码
2. **在公司**：手机连公司 WiFi → 自动发现 Mac-Company → 自动获取公司 Mac 的配对码

> 两边各只需一次。如果在同一 WiFi 下，完全不需要手动输入配对码。

### 日常使用

之后永久自动切换：
- 手机连家里 WiFi → 自动连接家 Mac
- 手机连公司 WiFi → 自动连接公司 Mac
- 手机用 5G / 其他网络 → 自动通过云中继连接上一次配对的 Mac

## 中继服务器

中继服务器用于跨网络（如手机在外面用 4G/5G 时）同步剪贴板。

> **纯局域网用户**：如果不配置中继服务器，App 仅使用局域网模式运行，不会尝试连接中继。局域网同步功能完全正常。

### 配置方式

**方式一：应用内配置（推荐）**

1. 启动 Mac App 和鸿蒙 App
2. 在"云中继"卡片中，点击服务器地址旁的"修改"
3. 输入你的中继服务器 IP 或域名
4. 两端输入相同的配对码即可连接

**方式二：配置文件预设（适合自用）**

如果你有自己的中继服务器，可以通过配置文件预设默认地址，避免每次手动输入。

**Mac 端**：

```bash
mkdir -p ~/.clipboardsync
cp relay_config.example.json ~/.clipboardsync/relay_config.json
# 编辑配置文件，填入你的服务器地址
vim ~/.clipboardsync/relay_config.json
```

**鸿蒙端**：

```bash
cp ClipboardSync/harmony/config_example/relay_config.example.json \
   ClipboardSync/harmony/entry/src/main/resources/rawfile/relay_config.json
# 编辑配置文件，填入你的服务器地址
```

配置文件格式：

```json
{
  "relay": {
    "defaultHost": "your-server-ip-or-domain",
    "defaultPort": 8443,
    "wsPath": "/ws"
  }
}
```

> 注意：配置文件仅设置默认服务器地址。在 App 中修改后会自动持久化，下次启动优先使用已保存的地址。

### 自建中继服务器

```bash
cd relay-server
# 安装依赖
npm install
# 启动（默认端口 3000）
node src/index.js
# 或使用 PM2
pm2 start ecosystem.config.js
```

需要配置 Nginx 反向代理来处理 WebSocket 升级，参考 `relay-server/deploy/nginx.conf`。

环境变量：
- `RELAY_PORT` — 服务端口，默认 3000
- `RELAY_HOST` — 绑定地址，默认 0.0.0.0

## 局域网端口

| 端口 | 协议 | 用途 |
|------|------|------|
| 19876 | UDP | 广播发现设备 |
| 19877 | TCP | 剪贴板数据传输 |
| 19878 | TCP | Mac → 手机的 IP 反向发现 |

## 项目结构

```
ClipboardSync/
├── mac/            # macOS 客户端（SwiftUI）
│   └── ClipboardSync/
│       ├── SyncManager.swift           # 核心协调器（双模切换+加密+分片）
│       ├── WSClient.swift              # WebSocket 中继客户端
│       ├── TCPServer.swift             # TCP 数据服务端
│       ├── DiscoveryService.swift      # UDP 广播发现（多网卡）
│       ├── NetworkMonitor.swift        # WiFi 变化感知
│       ├── ClipboardMonitor.swift      # NSPasteboard 轮询监听
│       ├── CryptoModule.swift          # ECDH + AES-256-GCM 端到端加密
│       ├── Protocol.swift              # 消息协议 + 中继配置
│       ├── MainView.swift              # 菜单栏 Popover UI
│       ├── AppDelegate.swift           # 菜单栏 + 通知管理
│       ├── QRCodeGenerator.swift       # 二维码生成
│       ├── VerificationCodeHandler.swift # 验证码提取与通知
│       ├── SaveDirectoryManager.swift  # 接收文件保存目录管理
│       ├── LaunchAgentManager.swift    # 开机自启
│       └── ClipboardSyncApp.swift      # @main 入口
├── harmony/        # 鸿蒙手机客户端（ArkTS）
│   └── entry/src/main/ets/
│       ├── model/SyncManager.ets          # 核心协调器（双模+加密+分片）
│       ├── model/NetworkContextManager.ets # WiFi 网络感知 + Profile 管理
│       ├── model/SaveDirectoryManager.ets  # 接收文件保存目录管理
│       ├── common/WSClient.ets             # WebSocket 中继客户端
│       ├── common/TCPClient.ets            # TCP 数据客户端（自动重连）
│       ├── common/DiscoveryService.ets     # UDP 广播发现
│       ├── common/DiscoveryTCPServer.ets   # TCP 反向发现
│       ├── common/CryptoModule.ets         # ECDH + AES-256-GCM 端到端加密
│       ├── common/Protocol.ets             # 消息协议 + 中继配置
│       ├── pages/Index.ets                 # 主界面
│       ├── pages/ScanPage.ets              # 二维码扫码页
│       └── entryability/EntryAbility.ets   # 生命周期 + 后台保活
└── relay-server/    # 云中继服务器（Node.js）
    └── src/
        ├── index.js   # HTTP 入口 + WebSocket 启动
        ├── server.js  # WebSocket 核心 + 消息路由
        └── room.js    # 房间管理
```

## 常见问题

**Q: 手机连 WiFi 后不自动发现 Mac？**

A: 
1. 检查两端是否在同一子网（没有 AP 隔离）
2. 端口 19876-19878 未被防火墙阻止
3. **Mac 有线 + 手机 WiFi 可能处于不同子网**，此时需手动扫码：Mac 菜单栏点击"本机IP"按钮 → 手机扫码即可直连

**Q: Mac 显示"中继已断开"？**

A: 
1. 确认已在 App 中正确配置了中继服务器地址
2. 检查服务器是否可达：`curl http://<你的服务器IP>:8443/health`
3. 确认两端使用了相同的配对码
4. 纯局域网用户可不配置中继，局域网同步不受影响

**Q: Mac 有线 + 手机 WiFi 无法自动连接？**

A: 这种情况常出现在公司网络（Mac 插网线、手机连 WiFi）。Mac 的 UDP 广播可能走有线网卡而手机收不到。解决方法：Mac 菜单栏点击"本机IP"按钮，手机扫码即可建立直连。连接成功后，之后同网络可自动重连。

**Q: 如何更换配对码？**

A: 点击 Mac 菜单栏中配对码旁边的旋转箭头按钮，然后在手机上重新输入或扫码。

**Q: 手机熄屏后重新亮屏，剪贴板是最新的吗？**

A: 是的。手机亮屏时自动向 Mac 拉取最新剪贴板内容（仅文字），无需手动操作。

**Q: 传输内容是否加密？**

A: 是的。两端建立连接后自动进行 ECDH P-256 密钥协商，后续所有数据消息（文字、图片、文件）均通过 AES-256-GCM 加密传输。中继服务器无法读取消息内容。

**Q: Mac 上截图或复制图片后为什么没自动发送？**

A: 图片和文件采用"暂存待发"模式：复制后不自动发送，需要打开 Mac 菜单栏，在"待发送"卡片中点击"发送到手机"。这是为了避免误发送大文件消耗流量。

**Q: 手机后台运行会被系统杀死吗？**

A: 鸿蒙端已申请后台常驻任务（多设备连接模式），会显示常驻通知"剪贴板同步正在运行"。极端情况下被杀后，重新打开 App 即可恢复。
