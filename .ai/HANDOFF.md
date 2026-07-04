# 工作交接 — 2025-07-04

## 机器信息
- **主机名**: `loho.local`
- **分支**: `main`
- **最后提交**: `3dea67e` — feat: 鸿蒙端文件分享+后台轮询
- **工作树**: 干净 ✅

## 今日完成
- [x] **PROJECT.md 状态审计**：发现文档严重滞后，P0/P1 大部分已实现但未标记，已更新对齐
- [x] **TCP 连接看门狗修复**（P0）：鸿蒙端 `on('connect')` 事件和 `connect().then()` 不可靠导致连接已建立但状态不更新，新增看门狗定时器 + `getRemoteAddress()` 备用检测
- [x] **本机 IP 二维码按钮**：状态卡片行新增始终可见的 QR 按钮，解决不同子网无法 UDP 广播的问题
- [x] **图片/文件改为暂存待发**：复制后不再自动发送（防止其他操作误触发），打开菜单栏手动点击"发送到手机"，显示分片发送进度
- [x] **ClipboardMonitor 增加文件检测**：支持 Finder 复制文件 → 检测 `NSURL` 类型
- [x] **鸿蒙端文件分享到 Mac**：支持其他 App 分享文件/图片到 ClipboardSync → 转发 Mac
- [x] **鸿蒙端后台轮询**：熄屏恢复后加速同步（power.isActive 检测 + 30 秒定时 POLL）
- [x] **诊断日志增强**：手机端 UI 显示发现过程日志，帮助排查连接问题

## 文件变更清单
| 文件 | 变更说明 |
|------|---------|
| `ClipboardSync/mac/ClipboardSync/ClipboardMonitor.swift` | 新增文件 URL 检测；回调增加 `fileURL` 参数 |
| `ClipboardSync/mac/ClipboardSync/SyncManager.swift` | 图片/文件改为暂存待发；`sendWithChunking` 支持进度回调；新增 `sendPendingContent()`/`clearPendingContent()` |
| `ClipboardSync/mac/ClipboardSync/MainView.swift` | 新增暂存待发卡片 UI + 本机 IP 二维码按钮 |
| `ClipboardSync/mac/ClipboardSync/Protocol.swift` | 协议同步 |
| `ClipboardSync/harmony/.../TCPClient.ets` | 连接看门狗：`markConnected()` 统一入口 + `startWatchdog()` + `checkSocketState()` |
| `ClipboardSync/harmony/.../SyncManager.ets` | 诊断日志中文化；文件分享接收 `handleSharedContent`；后台轮询 |
| `ClipboardSync/harmony/.../Protocol.ets` | 协议同步 |
| `ClipboardSync/harmony/.../EntryAbility.ets` | 分享入口 `onNewWant` |
| `ClipboardSync/harmony/.../Index.ets` | 状态卡片显示 `discoveryLog` |
| `ClipboardSync/PROJECT.md` | 功能状态表更新对齐实际代码 |
| `.ai/HANDOFF.md` | 下班交接更新 |

## 编译状态
✅ **Mac 端编译通过**（仅有预存 `NSUserNotification` 弃用警告）
⚠️ 鸿蒙端需在 DevEco Studio 中验证编译

## 工作断点
- **正在做**: 稳定性修复 + 用户体验打磨阶段
- **卡在哪里**: 无阻塞问题
- **下一步**:
  1. 鸿蒙端编译验证 + 真机测试 TCP 看门狗和文件分享
  2. 真机测试暂存待发流程（Mac 复制图片→菜单栏点击发送→手机接收）
  3. 考虑是否增加中继通道的图片/文件支持（目前仅 TCP 有分片发送）

## 关键决策
- 图片/文件发送从自动改为手动触发，防止其他应用复制图片时误同步到手机
- TCP 连接状态不再仅依赖 `on('connect')` 事件，增加看门狗兜底
- 本机 IP 二维码按钮始终可见，不再受连接模式限制

## 待清理
- [x] 无 stash
- [x] 代码已全部提交
- [ ] 鸿蒙端需真机测试验证
