# HarmonyAndMac — 剪贴板同步

Mac 与鸿蒙手机之间的剪贴板实时同步工具，支持局域网直连和云中继两种模式，可在家庭/公司多台 Mac 之间自动切换。

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
4. 看到"已连接"即配对成功

**方式二：手动输入**

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

中继服务器用于跨网络（如手机在外面用 4G/5G 时）同步剪贴板。默认没有预置服务器地址，首次使用需要在 App 中配置。

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
│       ├── SyncManager.swift      # 核心协调器
│       ├── WSClient.swift         # WebSocket 中继客户端
│       ├── TCPServer.swift        # TCP 数据服务端
│       ├── DiscoveryService.swift # UDP 广播发现
│       ├── NetworkMonitor.swift   # 网络变化感知
│       ├── ClipboardMonitor.swift # 剪贴板监听
│       └── MainView.swift         # 菜单栏 UI
├── harmony/        # 鸿蒙手机客户端（ArkTS）
│   └── entry/src/main/ets/
│       ├── model/SyncManager.ets          # 核心协调器
│       ├── model/NetworkContextManager.ets # WiFi 网络感知
│       ├── common/WSClient.ets            # WebSocket 中继客户端
│       ├── common/TCPClient.ets           # TCP 数据客户端
│       ├── common/DiscoveryService.ets    # UDP 广播发现
│       └── common/DiscoveryTCPServer.ets  # TCP 反向发现
└── relay-server/    # 云中继服务器（Node.js）
    └── src/
        ├── index.js   # HTTP 入口 + WebSocket 启动
        ├── server.js  # WebSocket 核心 + 消息路由
        └── room.js    # 房间管理
```

## 常见问题

**Q: Mac 显示"中继已断开"？**

A: 
1. 确认已在 App 中正确配置了中继服务器地址（参见上方配置方式）
2. 检查服务器是否可达：`curl http://<你的服务器IP>:8443/health`
3. 确认两端使用了相同的配对码

**Q: 手机连 WiFi 后不自动发现 Mac？**

A: 确保两端在同一子网（没有 AP 隔离），端口 19876-19878 未被防火墙阻止。

**Q: 如何更换配对码？**

A: 点击 Mac 菜单栏中配对码旁边的旋转箭头按钮，然后在手机上重新输入新码。
