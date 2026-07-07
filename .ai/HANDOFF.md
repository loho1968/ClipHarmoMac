# 工作交接 — 2025-07-07

## 机器信息
- **主机名**: `loho.local`
- **分支**: `main`
- **最后提交**: `deea982` — 自动连接
- **工作树**: 干净 ✅

## 本次新增（自 7/4 交接以来）

### 端到端加密（ECDH + AES-256-GCM）
- [x] **Mac 端 CryptoModule** (`CryptoModule.swift`, 249 行)：ECDH P-256 密钥协商 + AES-256-GCM 加密，私钥存 Keychain，对端公钥存 UserDefaults，重启自动恢复会话
- [x] **鸿蒙端 CryptoModule** (`CryptoModule.ets`, 309 行)：与 Mac 端线格式完全一致，使用 `@kit.CryptoArchitectureKit` 原生加密 API，对端公钥存 preferences
- [x] **自动密钥交换**：连接建立后（LAN/中继）自动发送 `keyExchange` 消息，交换 ECDH 公钥
- [x] **透明加解密**：`SyncManager` 在 `sendOrBroadcast` / `handleRemoteMessage` 中自动对数据消息加解密，上层无感
- [x] **AAD 绑定**：加密时绑定 `deviceId|messageType` 作为附加认证数据，防跨设备/跨类型重放
- [x] **协议扩展**：新增 `keyExchange` 消息类型和 `publicKey` 字段，`SyncMessage.content` 改为 `var` 支持就地解密

### 加密范围
加密的消息类型：`clipboardText`, `clipboardImage`, `clipboardFile`, `clipboardDataChunk`, `verificationCode`
不加密：`ping`, `pong`, `keyExchange`, `roomKeyInfo`, `clipboardPoll`

## 文件变更清单（本次）
| 文件 | 变更说明 |
|------|---------|
| `ClipboardSync/mac/ClipboardSync/CryptoModule.swift` | **新增**：ECDH + AES-256-GCM 加密模块 |
| `ClipboardSync/mac/ClipboardSync/SyncManager.swift` | 集成加密 pipeline；`sendKeyExchange` / `handleKeyExchange`；`content` 改为 `var` |
| `ClipboardSync/mac/ClipboardSync/Protocol.swift` | 新增 `keyExchange` 类型；新增 `publicKey` 字段；`content` 改为 `var` |
| `ClipboardSync/harmony/.../CryptoModule.ets` | **新增**：鸿蒙端加密模块（与 Mac 端线格式一致） |
| `ClipboardSync/harmony/.../SyncManager.ets` | 集成加密 pipeline；`handleRemoteMessage` 改为 async；密钥交换逻辑 |
| `ClipboardSync/harmony/.../Protocol.ets` | 新增 `KEY_EXCHANGE` 类型；新增 `publicKey` 字段 |
| `CLAUDE.md` | 微调 |

## 编译状态
✅ **Mac 端编译通过**（`DEVELOPER_DIR` + `swift build` 成功）
⚠️ 鸿蒙端需在 DevEco Studio 中验证编译

## 整体进度

### 已完成
- 文本/图片/文件剪贴板同步
- UDP 广播设备发现、TCP 直连、WebSocket 中继
- LAN/中继自动切换、二维码配对
- 短信验证码自动提取、开机自启、同步历史、菜单栏状态图标
- 图片/文件暂存待发（防误触发）
- TCP 连接看门狗
- 鸿蒙端文件分享到 Mac
- 鸿蒙端后台轮询
- **✅ 端到端 AES-256-GCM 加密**

### 待完成（优先级排序）
1. **P1**: 鸿蒙端编译验证 + 真机测试加密流程
2. **P1**: 真机测试暂存待发流程（Mac 复制图片→菜单栏点击发送→手机接收）
3. **P1**: 考虑中继通道的图片/文件支持（目前仅 TCP 有分片发送）
4. **P2**: 多设备同时连接支持
5. **P3**: 单元测试

## 工作断点
- **正在做**: 端到端加密刚刚完成，进入测试验证阶段
- **卡在哪里**: 无阻塞
- **下一步**: 真机测试 ECDH 密钥交换 + AES 加解密端到端流程

## 关键决策
- ECDH 密钥协商后通过 HKDF-SHA256 派生 AES-256 密钥（无盐，共享密钥本身高熵）
- info 字符串 `"ClipSync-v1"` 硬编码两端，未来升级协议时改版本号
- 加密失败时 fallback 明文发送（鸿蒙端），Mac 端直接丢弃
- 密钥交换消息不加密，首次连接两端各发一次公钥即可建立会话

## 待清理
- [x] 无 stash
- [x] 代码已全部提交
- [ ] 鸿蒙端需真机测试验证
