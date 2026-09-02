# 工作交接 — 2026-09-02（晚间 · 本机 /Users/loho）

> 本交接供明日/下次接班使用；接班流程见 `.ai/接班继续.md`。
> 注意：公司机用户名为 `lh`，本机（家里）用户名为 `loho`，仓库中绝对路径以本机为准。

## 机器信息

- 主机名 `loho.local`（本机 /Users/loho）；远端 origin = github.com/loho1968/ClipHarmoMac.git
- 工作树：本次交接提交后将干净 ✅（`./signing/`、`rawfile/relay_config.json` 等按设计不入库）

## 今日完成（均已提交并推送）

### 环境与工具链
- [x] codegraph（根索引）/ codegraph-arkts（`ClipboardSync/harmony` 独立索引）已 init + sync 至最新
- [x] Mac `swift build` ✅；鸿蒙 `devecocli build` ✅（签名用工程内 `./signing` 相对路径，材料不入库）
- [x] `.mcp.json` 路径改为本机 /Users/loho（deveco-mcp PROJECT_PATH、codegraph-arkts 路径）

### 中继服务器（ssh tencent / 110.42.225.37）
- [x] 修复重大部署问题：线上 PM2 一直跑老目录 `/opt/clipboardsync-relay`（旧代码、无 relay_no_peer）→ 已迁移到正式部署目录 `/opt/harmony-and-mac/relay-server` 并 `pm2 save`
- [x] `bash relay-server/deploy/push.sh` 实测跑通（六步全绿）；脚本新增「重启前校验 PM2 运行目录」防回归（红/绿双路径验证）；顺带修 macOS bash 3.2 变量后跟全角字符的解析 bug

### 真机明文回归（HUAWEI Mate 80 RS · API 26 Beta2）
- [x] Mac→手机：LAN 与 5G 中继均 ✅（含中文明文）
- [x] 手机→Mac：「手动发送」✅；**「复制自动推送」经 READ_PASTEBOARD 打通后 ✅**
- [x] 乱码根因定位：**残留旧版 Mac 进程仍在加密** → 彻底重启 Mac App 后明文正常（教训：先 `pgrep -fl ClipboardSync` 确认只有新实例）
- [x] 自动推送受限根因：鸿蒙 API12+ 剪贴板读取权限管控 → 已在 **AGC 申请并审批通过 READ_PASTEBOARD**，代码声明 + 启动申请 + **新 Profile（ACL 含权限）** 后实测可用
- [ ] 图片/文件/验证码 的 UI 全流程 **未测**（需人工点按，另约时间）

## 今日代码改动（git log）

| 提交 | 内容 |
|---|---|
| `bbc458e` | fix(deploy): push.sh 运行目录校验防回归 |
| `12cd43c` | chore: 加密禁用现状文档同步 + mcp 本机路径 + 签名改 `./signing` |
| `1128b8c` | fix(harmony): 剪贴板空读重试（防瞬时读空丢文本） |
| `c95d59a` | docs: 真机明文回归记录 + README 自动推限制说明（初版） |
| `1e806d1` | feat(harmony): 声明并申请 READ_PASTEBOARD |
| `82b2f7a` | docs: 自动推送已打通，更新 README 与回归记录 |
| （本次）| chore: 下班交接 + build-profile 更新到含权限的 Profile |

## 编译/运行状态

- ⚠️ 手机 App 当前安装的是含 READ_PASTEBOARD 的新版（已在真机验证自动推送）；**请勿用旧 Profile 覆盖 `./signing/`**
- Mac App 运行中（当前 /Applications 内为最新明文版 release）
- 中继线上运行新代码（含 relay_no_peer），Mac 在房间 3YQD68 待命

## 明日第一件事（优先级）

1. [P0] **图片/文件/验证码 真机 UI 全流程回归**：Mac 复制图片→「待发送」手动发送；手机选择图片/文件发 Mac；短信验证码自动推 Mac 剪贴板+通知
2. [P1] 后台静默自动推送是否受系统进一步限制（可选实测：ClipboardSync 不在前台时在其它 App 复制，观察 Mac 是否收到）
3. [P2] `devecocli run` 直装报 "artifact not signed"（其判定问题，暂用 DevEco Run 安装）

## 备忘 / 注意

- 公司机（lh）pull 后：`.mcp.json`、`build-profile.json5`、鸿蒙 rawfile 中继配置都需按公司机路径/签名再适配（机器相关文件未本地化，当前策略是各机自理）
- `./signing/ClipboardSyncPasteDebug.p7b` 是含 READ_PASTEBOARD 的 Profile（本地文件，勿删；换机需从 AGC 重新下载）
- 详细排障过程见 `.ai/回归记录-2026-09-02-真机明文测试.md`
