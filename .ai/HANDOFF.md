# 工作交接 — 2026-07-06

## 机器信息
- **主机名**: `loho.local`
- **分支**: `main`
- **最后提交**: `deea982` — 自动连接
- **工作树**: 有未提交改动 ⚠️（见下方文件变更清单）

## 今日完成

### 1. 功能确认与改进计划
- [x] **功能确认分析**：对照代码逐项验证 29 项功能，结论全部已实现 ✅→ `开发计划/功能确认.md`
- [x] **改进计划**：输出 3 个 P1（体验优化）、2 个 P2（健壮性）、3 个 P3（锦上添花），总体评估项目可投入使用 → `开发计划/改进计划.md`
- [x] **测试计划**：8 大类 50+ 条测试用例覆盖全部场景 → `开发计划/剪贴板同步测试.md`

### 2. P1 三连修复（全部实现）
- [x] **P1-1: Mac 端显示设备名而非 IP** — `DiscoveryService.onDeviceFound` 回调增加 `senderIP`，`SyncManager` 构建 `deviceIPMap` 建立 IP→deviceId 映射，TCP 连接时优先用设备名
- [x] **P1-2: 纯局域网用户不尝试连接中继** — `SyncManager` 增加 `hasRelayConfig` 判断（检查配置文件+自定义host），无配置时仅生成 roomKey（TCP key exchange 需要）但不连 WebSocket，避免后台误报"中继已断开"
- [x] **P1-3: 多网卡广播从所有活跃接口发送** — `DiscoveryService` 重构：`activeInterfaceAddresses()` 枚举所有活跃非回环 IPv4 接口，为每个接口创建独立 socket 绑定到该接口 IP 再发广播，解决"Mac 有线+手机 WiFi 不同子网"时广播走错接口的问题。含 fallback 到 INADDR_ANY

### 3. 鸿蒙端后台/重连改进
- [x] **EntryAbility**：移除 `startBackgroundRunning()` 中"必须已连接才启动后台任务"的前置条件，允许未连接时也启动后台保活
- [x] **SyncManager**：
  - 熄屏恢复时改为 `ensureConnectionOnWakeup()` 主动重连（优先 TCP→WS fallback），而非简单 poll
  - 后台轮询周期中（30s tick），若不连接也触发重连
  - 新增 `addImmediatePoll()` 供前台使用：已连接直接 poll，否则触发重连
- [x] **WSClient**：新增 `forceReconnect(url, roomKey)` 方法，完整重置状态+重连

### 4. 鸿蒙端 SDK 适配
- [x] **CryptoModule.ets**：
  - KDF API 升级：`KdfSpec` → `HKDFSpec`，算法名 `HKDF|SHA-256|HMAC` → `HKDF|SHA256|EXTRACT_AND_EXPAND`
  - GCM 解密/加密参数增加 `algName: 'GcmParamsSpec'`
  - 适配 HarmonyOS API 12+ 的新密码框架接口

### 5. 诊断日志增强
- [x] **TCPClient.ets**：增加接收消息类型日志 + JSON 解析失败时打印前 50 字符
- [x] **SyncManager.ets**：在 `handleRemoteMessage` 和 `writeClipboardText` 入口增加日志

### 6. 文档完善
- [x] **README.md**：新增功能总表、每个文件的职责注释、FAQ（8 个常见问题），项目结构从 7 个文件展开为完整文件清单
- [x] **.mcp.json**：配置 `codegraph` 和 `codegraph-arkts` 两个 MCP 服务器（代码图索引）

## 文件变更清单

| 文件 | 变更说明 |
|------|---------|
| `ClipboardSync/mac/ClipboardSync/DiscoveryService.swift` | **大改**：多网卡广播重构 (+100/-40)；`onDeviceFound` 回调增加 `senderIP` |
| `ClipboardSync/mac/ClipboardSync/SyncManager.swift` | P1-1: IP→设备名映射；P1-2: `hasRelayConfig` 纯局域网跳过中继；`generateRoomKeyOnly()` |
| `ClipboardSync/harmony/.../SyncManager.ets` | 熄屏主动重连 `ensureConnectionOnWakeup()`；后台轮询断线重连；诊断日志 |
| `ClipboardSync/harmony/.../EntryAbility.ets` | 移除后台启动的前置连接条件 |
| `ClipboardSync/harmony/.../CryptoModule.ets` | KDF API 升级适配 HarmonyOS API 12+；GCM 参数增加 `algName` |
| `ClipboardSync/harmony/.../TCPClient.ets` | 接收消息诊断日志 |
| `ClipboardSync/harmony/.../WSClient.ets` | 新增 `forceReconnect()` 方法 |
| `README.md` | 功能表 + FAQ + 完整文件清单 |
| `.ai/HANDOFF.md` | 下班交接更新 |
| `.mcp.json` | 新增 codegraph / codegraph-arkts MCP 服务器 |
| `开发计划/改进计划.md` | **新增**：29 功能确认 + 3 级改进项 |
| `开发计划/剪贴板同步测试.md` | **新增**：8 大类 50+ 条测试用例 |
| `开发计划/功能确认.md` | **新增**：使用场景 + 追求目标 |

## 编译状态
- ⚠️ **Mac 端**：改动未编译验证（Swift 文件改动了 `DiscoveryService.swift` 和 `SyncManager.swift`）
- ⚠️ **鸿蒙端**：改动未编译验证（涉及 ArkTS API 变更，需在 DevEco Studio 中验证）

## 工作断点
- **正在做**: P1 体验优化刚完成编码，下一步是编译验证 + 真机测试
- **卡在哪里**: 无阻塞问题
- **下一步**:
  1. **Mac 端编译验证**：Xcode build 确保 `DiscoveryService.swift` 多网卡改动无编译错误
  2. **鸿蒙端编译验证**：DevEco Studio build 确保 `CryptoModule.ets` API 变更兼容（注意：`HKDFSpec` 和 `EXTRACT_AND_EXPAND` 是 API 12+ 的新接口，需确认目标设备版本）
  3. **P1-3 真机验证**：公司环境测试 Mac 有线 + 手机 WiFi，验证多网卡广播是否能正确发现
  4. **P1-1 验证**：连接后 Mac 菜单栏是否显示设备名而非 IP
  5. **P1-2 验证**：纯局域网用户 Mac 端不再显示"中继已断开"或"等待设备加入"
  6. **鸿蒙后台重连验证**：手机熄屏→亮屏，是否自动重连并拉取剪贴板
  7. 如果有余力，P2-1（TCP 应用层心跳）和 P2-2（消息序列号）也是高价值项

## 关键决策
- **多网卡广播实现**：采用"每个接口独立 socket + bind 到接口 IP"方案，比单一 socket + 设置 `IP_BOUND_IF` 更可靠，虽然 socket 数量多了但隔离性更好
- **纯局域网模式判断**：通过"是否存在 relay_config.json 或用户手动设过 host"判断，而非零配置默认不连。这样一旦用户配过中继就能自动恢复，而新用户不会误连
- **Room Key 始终生成**：即使纯局域网模式也要生成 roomKey，因为 TCP 连接的 `roomKeyInfo` 交换（双 Mac 场景设备匹配）依赖它
- **熄屏恢复策略从 poll 改为 reconnect**：之前只是 poll 已存在的连接，现在主动重连后再 poll，覆盖了 TCP 连接在熄屏期间断开的情况
- `GcmParamsSpec.algName` 是 ArkTS 框架在较新 API 版本中强制要求的字段，缺失会导致运行时错误

## 待清理
- [ ] **代码未提交**：所有改动在工作树中未 commit，需编译通过后提交
- [ ] Mac 端待编译验证
- [ ] 鸿蒙端待编译验证（特别是 CryptoModule API 兼容性）
- [ ] 真机测试 P1-3 多网卡场景（这是你公司的实际痛点）
