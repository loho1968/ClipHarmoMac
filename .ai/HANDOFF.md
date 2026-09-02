# 工作交接 — 2026-09-02

## 机器信息
- **主机名**: `loho.local`
- **分支**: `main`
- **远端**: origin = github.com/loho1968/ClipHarmoMac.git（push 已配置）
- **工作树**: 本次提交后将干净 ✅（工具目录未入库，见"待清理"）

## 今日完成

### 环境核对（无代码产出）
- [x] devecocli 1.3.1 可用；HUAWEI Mate 80 RS 真机在线（serial 5YZ0225C02003196）+ TripleFold 模拟器
- [x] codegraph / codegraph-arkts 索引为最新（根索引 /Users/lh/Developer/ClipHarmoMac/.codegraph，sync = Already up to date）
- [x] 确认发布通道：`bash relay-server/deploy/push.sh` 走 `~/.ssh/config` 的 `tencent` 别名（root@110.42.225.37）
- [x] 通读 README / CONTEXT / DECISIONS / PROJECT / HANDOFF 与三端代码结构，产出《项目熟悉报告》

### 代码改动（⚠️ 尚未编译验证）
- [x] **全局禁用端到端加密，统一明文**：此前多次出现两端 HKDF 派生密钥不同步 → 乱码 Bug。
  局域网 / 云中继下现在都传明文；encrypt/decrypt 与 keyExchange 代码保留但不再触发。

## 文件变更清单

| 文件 | 变更说明 |
|------|---------|
| `ClipboardSync/mac/ClipboardSync/CryptoModule.swift` | `shouldEncrypt(messageType:)` 恒返回 `false`（原来是 switch 返回 true） |
| `ClipboardSync/harmony/entry/src/main/ets/model/SyncManager.ets` | `shouldEncryptType(type:)` 恒返回 `false`（原来 4 类内容需加密） |
| `.ai/HANDOFF.md` | 本文档 |

## 编译状态
⚠️ **两端均未编译验证**（swift build / devecocli build 都没跑）

## 工作断点
- **正在做**: 加密禁用（明文方案）—— 代码已改完，未编译、未上真机
- **下一步**（回家后优先）:
  1. Mac 编译：`DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift build --package-path /Users/lh/Developer/ClipHarmoMac/ClipboardSync/mac`（注意路径是 lh 不是 loho）
  2. 鸿蒙编译：`devecocli build --project-path ClipboardSync/harmony`
  3. 真机全流程测试（Mate 80 RS 在线；5G 场景走 ssh tencent 中继验证）

## 待清理 / 备忘
- [x] 两处代码改动已提交推送
- [ ] 两端编译验证 + 真机测试（明文方案回归：文本/图片/文件/验证码、LAN + 5G 中继）
- 协议侧不对称（疑似遗留，后续可清理）：`MessageType.verificationCode` / `smsSender` 只在 Swift 侧（Protocol.swift），鸿蒙 Protocol.ets 没有
- Mac 端 `ProtocolConst.deviceId` 每次启动随机（鸿蒙已持久化），如需"踢旧连接/版本可辨识"完善可仿照鸿蒙持久化
- 未入库的本地工具目录（git status 会显示 ??，属正常）：harmony 下 `.claude/.codebuddy/.codex/.cursor/.deveco/.opencode/.qoder/.trae/.trae-cn`，若嫌吵可加 .gitignore
