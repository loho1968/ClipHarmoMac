# 工作交接 — 2026-07-07

## 机器信息
- **主机名**: `loho.local`
- **分支**: `main`
- **最近提交**:
  - `4730423` — chore: 下班交接（本机）
  - `46bdb64` — tool: 集成 deveco-cli
  - `fcdbceb` — fix: Mac重启后中继断连 & 手机→Mac单向不通
  - `26b2e85` — feat: P1体验优化三连 + 鸿蒙后台重连 + SDK适配 + 文档完善
  - `deea982` — 自动连接（端到端加密）
- **工作树**: 干净 ✅

## 本次同步（git pull 合并了两台机器的提交）

### A 线（远程机器 — 7/6 会话）

#### 1. 功能确认 & 文档
- 功能确认分析（29 项全部已实现）→ `开发计划/功能确认.md`
- 改进计划（3 P1 + 2 P2 + 3 P3）→ `开发计划/改进计划.md`
- 测试计划（8 类 50+ 条用例）→ `开发计划/剪贴板同步测试.md`
- README.md 大幅完善（功能表 + FAQ + 完整文件清单）
- `.mcp.json` 配置 codegraph + codegraph-arkts

#### 2. P1 三连修复
- **P1-1: 显示设备名而非 IP** — `DiscoveryService.onDeviceFound` + `senderIP`，`SyncManager` 构建 IP→设备名映射
- **P1-2: 纯局域网不连中继** — `hasRelayConfig` 判断，无配置时跳过 WebSocket，避免误报
- **P1-3: 多网卡广播** — 枚举所有活跃接口，每接口独立 socket bind 后发送，解决「Mac 有线+手机 WiFi」跨子网问题

#### 3. 鸿蒙端后台/重连改进
- EntryAbility 移除后台启动的前置连接条件
- SyncManager: `ensureConnectionOnWakeup()` 主动重连（TCP→WS fallback），`addImmediatePoll()`
- WSClient: 新增 `forceReconnect(url, roomKey)`

#### 4. 鸿蒙端 SDK 适配
- CryptoModule.ets: KDF API → `HKDFSpec` + `EXTRACT_AND_EXPAND`（API 12+），GCM 参数增加 `algName`

#### 5. Bug 修复（后续提交）
- **Mac 重启后中继断连** & **手机→Mac 单向不通**（六合一修复，`fcdbceb`）
- **手机端剪贴板同步三个缺陷**（`fc8c9eb`）

#### 6. DevEco CLI 集成
- CLAUDE.md 增加 devecocli 命令参考
- 安装 Skill: `.claude-code/skills/deveco-cli/SKILL.md`
- 鸿蒙端 `.mcp.json` 配置

### B 线（本机 — 7/5 会话）

#### 端到端加密（ECDH + AES-256-GCM）
- Mac 端 `CryptoModule.swift`（249 行）：ECDH P-256 + AES-256-GCM，私钥存 Keychain
- 鸿蒙端 `CryptoModule.ets`（309 行）：线格式与 Mac 完全一致
- 自动密钥交换：连接建立后自动发送 `keyExchange`
- 透明加解密：SyncManager 收发 pipeline 自动处理
- AAD 绑定 `deviceId|messageType` 防重放
- 协议扩展：`keyExchange` 类型 + `publicKey` 字段

## 全部文件变更（自 7/4 以来累计）

| 文件 | 变更说明 |
|------|---------|
| `ClipboardSync/mac/ClipboardSync/DiscoveryService.swift` | 多网卡广播重构 |
| `ClipboardSync/mac/ClipboardSync/SyncManager.swift` | P1 三连 + 加密 pipeline + 中继断连修复 |
| `ClipboardSync/mac/ClipboardSync/CryptoModule.swift` | **新增**：ECDH + AES-256-GCM |
| `ClipboardSync/mac/ClipboardSync/Protocol.swift` | 新增 `keyExchange` / `publicKey` |
| `ClipboardSync/harmony/.../CryptoModule.ets` | **新增** + SDK 适配（API 12+） |
| `ClipboardSync/harmony/.../SyncManager.ets` | 后台重连 + 加密 pipeline + bug 修复 |
| `ClipboardSync/harmony/.../TCPClient.ets` | 诊断日志 |
| `ClipboardSync/harmony/.../WSClient.ets` | `forceReconnect()` |
| `ClipboardSync/harmony/.../EntryAbility.ets` | 后台启动去条件化 |
| `ClipboardSync/harmony/.../Protocol.ets` | `KEY_EXCHANGE` + `publicKey` |
| `README.md` | 功能表 + FAQ + 文件清单 |
| `CLAUDE.md` | deveco-cli 集成 |
| `.mcp.json` | codegraph / codegraph-arkts / deveco-mcp |
| `.claude-code/skills/deveco-cli/SKILL.md` | **新增**：deveco-cli skill |
| `开发计划/*.md` | **新增**：功能确认 + 改进计划 + 测试计划 |

## 编译状态
✅ **Mac 端编译通过**（仅预存 NSUserNotification 弃用警告）
⚠️ 鸿蒙端需 DevEco Studio 验证（CryptoModule API 兼容性 + 多文件改动）

## 整体进度

### 已完成 ✅
- 文本/图片/文件剪贴板同步
- UDP 多网卡广播 + TCP 直连 + WebSocket 中继
- LAN/中继自动切换、二维码配对
- 短信验证码提取、开机自启、同步历史、菜单栏状态图标
- 图片/文件暂存待发
- TCP 连接看门狗
- 鸿蒙端文件分享 + 后台轮询 + 熄屏重连
- Mac 端显示设备名（非 IP）
- 纯局域网自动跳过中继
- **端到端 AES-256-GCM 加密**
- Bug 修复：中继断连 / 手机→Mac 单向不通 / 手机端同步缺陷
- DevEco CLI 集成

### 待完成（优先级排序）
1. **P0**: 鸿蒙端编译验证 + 真机测试全流程
2. **P1**: 中继通道图片/文件分片发送（目前仅 TCP 支持）
3. **P2**: TCP 应用层心跳 + 消息序列号
4. **P2**: 多设备同时连接
5. **P3**: 单元测试

## 工作断点
- **正在做**: 大集成后的稳定阶段，编译验证 + 真机测试
- **卡在哪里**: 无阻塞
- **下一步**: 鸿蒙端编译 → 真机测试加密 + 多网卡广播 + 后台重连

## 待清理
- [x] 无 stash
- [x] 代码已全部提交
- [ ] 鸿蒙端编译 + 真机测试
