# 图片剪贴板 — macOS 端开发计划

## 当前状态

macOS 端已实现图片剪贴板的**基础**读写和传输：
- `ClipboardMonitor.swift`：读取 NSPasteboard TIFF → PNG Data → base64
- `SyncManager.swift`：构建 `SyncMessage(type: .clipboardImage, content: base64String)`
- `ClipboardMonitor.writeImage(_:)`：接收 base64 → NSImage → 写入剪贴板

**缺失**：
- 无压缩（Retina 截图 PNG 可达 20MB）
- 无大小限制
- 无分片支持（中继限制 2MB，TCP 缓冲 64KB）
- 无文件剪贴板支持

---

## Phase 1：图片压缩 + 元数据

### 1.1 图片压缩（`ClipboardMonitor.swift`）

在读取剪贴板图片后、发送前，增加压缩步骤：

```
NSPasteboard TIFF 数据
  → NSBitmapImageRep 获取原始宽高
  → 计算缩放比例（长边 > 1920px 时等比缩放）
  → 缩放后的 NSImage
  → JPEG 编码（quality=0.80）
  → Data（通常 100KB~800KB）
  → base64 字符串
```

关键代码位置：`checkClipboard()` 方法中的图片读取分支（约第 58-72 行）。

### 1.2 SyncMessage 扩展（`Protocol.swift`）

在 `SyncMessage` 结构体中增加以下可选字段：

```swift
var imageWidth: Int?      // 图片宽度（压缩后）
var imageHeight: Int?     // 图片高度（压缩后）
var fileSize: Int?        // 压缩后字节数
var format: String?       // "jpeg" | "png"
var fileName: String?     // 自动生成，如 "clipboard_20260702_143021.jpeg"
```

### 1.3 大小检查

- 压缩后 Data.count > **20MB** → 放弃发送，日志记录 `[ClipboardMonitor] Image too large after compression: X MB`
- 压缩后 Data.count ≤ **500KB** → 单条消息发送（不分片）
- 压缩后 Data.count > **500KB** → 进入分片发送流程（Phase 2）

---

## Phase 2：分片传输

### 2.1 SyncMessage 分片字段（`Protocol.swift`）

```swift
var transferId: String?    // UUID
var chunkIndex: Int?       // 0-based
var totalChunks: Int?      // 总分片数
```

### 2.2 新增 MessageType

```swift
case clipboardDataChunk    // 分片数据（图片和文件共用）
```

### 2.3 分片发送逻辑（`SyncManager.swift`）

```
compressedData > 500KB:
  transferId = UUID().uuidString
  chunkSize = 256KB (262144 bytes)
  totalChunks = ceil(data.count / chunkSize)
  
  for i in 0..<totalChunks:
    chunk = data.subdata(in: i*chunkSize..<min((i+1)*chunkSize, data.count))
    if i == 0:
      发送 clipboardImage 消息（含全部元数据 + chunk[0]）
    else:
      发送 clipboardDataChunk 消息（transferId + chunkIndex + content）
```

### 2.4 分片接收缓冲（`SyncManager.swift`）

```swift
// 缓冲结构
struct TransferBuffer {
    let transferId: String
    let totalChunks: Int
    var chunks: [Int: Data]
    let metadata: TransferMetadata  // mimeType, fileName, fileSize 等
    let timestamp: Date
}

// 接收逻辑
var transferBuffers: [String: TransferBuffer] = [:]
var cleanupTimer: Timer?  // 每 30 秒扫描清理超时缓冲

func handleDataChunk(_ msg: SyncMessage) {
    // 1. lookup transferId in transferBuffers（不存在则创建）
    // 2. 存入 chunks[msg.chunkIndex]
    // 3. 检查 chunks.count == totalChunks
    //    → 按序拼接 Data
    //    → 根据原始 type（image/file）写入剪贴板
    //    → 移除缓冲区
}
```

### 2.5 基础设施调整

**TCPServer.swift**：
- `NWConnection.receive` 的 `maximumLength`：`65536` → `1048576`（1MB）

---

## Phase 3：文件剪贴板支持

### 3.1 文件检测（`ClipboardMonitor.swift`）

在 `checkClipboard()` 中增加 `.fileURL` 类型检测：

```swift
// 优先级：fileURL > image > string
if let urls = pasteboard.readObjects(forClasses: [NSURL.self]) {
    let fileURLs = urls.compactMap { $0 as? URL }.filter { $0.isFileURL }
    if !fileURLs.isEmpty {
        handleFileClipboard(fileURLs)
    }
}
```

### 3.2 大小检查

```swift
let MAX_SINGLE_FILE = 50 * 1024 * 1024      // 50MB
let MAX_TOTAL_SIZE = 100 * 1024 * 1024       // 100MB
let MAX_FILE_COUNT = 20

// 超限 → 日志警告 → return（不发送）
```

### 3.3 文件读取与发送

```swift
for url in fileURLs {
    let data = try Data(contentsOf: url)
    // 小文件（≤ 500KB）→ 单条 clipboardFile 消息
    // 大文件 → 自动分片
}
```

### 3.4 文件接收与写入

```swift
func writeFile(_ msg: SyncMessage) {
    let saveDir = SaveDirectoryManager.shared.currentDirectory
    try? FileManager.default.createDirectory(at: saveDir, withIntermediateDirectories: true)
    let fileURL = saveDir.appendingPathComponent(msg.fileName!)
    // 重名处理：若已存在则追加序号 " (1)", " (2)" ...
    let finalURL = resolveConflict(fileURL)
    try data.write(to: finalURL)
    // 写入剪贴板
    NSPasteboard.general.clearContents()
    NSPasteboard.general.writeObjects([finalURL as NSURL])
}
```

---

## Phase 4：保存目录管理

### 4.1 需求

接收到图片或文件后，需要保存到用户指定的目录（而非临时目录）。同时支持：
- 记住上次使用的目录
- 用户可在设置中选择保存目录
- 可将当前目录设为默认

### 4.2 新增 `SaveDirectoryManager`（`SaveDirectoryManager.swift`）

```swift
import Foundation

@Observable
final class SaveDirectoryManager {
    static let shared = SaveDirectoryManager()

    private let defaultsKey = "saveDirectory_bookmark"
    private let defaultDir = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Downloads/ClipboardSync")

    var currentDirectory: URL {
        // 1. 先读 UserDefaults 中保存的安全书签（记住的上次目录）
        if let data = UserDefaults.standard.data(forKey: defaultsKey),
           var isStale = false,
           let url = try? URL(resolvingBookmarkData: data,
                              options: .withSecurityScope,
                              bookmarkDataIsStale: &isStale) {
            return isStale ? defaultDir : url
        }
        return defaultDir
    }

    func setDirectory(_ url: URL) {
        // 2. 用户选择新目录 → 创建安全书签（remember）
        guard let bookmark = try? url.bookmarkData(
            options: .withSecurityScope,
            includingResourceValuesForKeys: nil
        ) else { return }
        UserDefaults.standard.set(bookmark, forKey: defaultsKey)
    }

    func setAsDefault(_ url: URL) {
        // 3. 将当前目录标记为默认（同 setDirectory，只是语义不同）
        setDirectory(url)
    }

    func resetToDefault() {
        UserDefaults.standard.removeObject(forKey: defaultsKey)
    }
}
```

### 4.3 UI 入口（`MainView.swift`）

在主界面增加「保存目录」设置行：

```swift
// 在 MainView 中增加：
Button("保存位置: \(saveDirManager.currentDirectory.lastPathComponent)") {
    let panel = NSOpenPanel()
    panel.canChooseDirectories = true
    panel.canChooseFiles = false
    panel.canCreateDirectories = true
    panel.message = "选择图片/文件接收后的保存目录"
    if panel.runModal() == .OK, let url = panel.url {
        saveDirManager.setDirectory(url)
    }
}

Button("恢复默认目录") {
    saveDirManager.resetToDefault()
}
```

### 4.4 行为规则

| 场景 | 行为 |
|------|------|
| 首次使用 | 默认保存到 `~/Downloads/ClipboardSync/` |
| 用户选择新目录 | 记住（持久化到 UserDefaults 安全书签）→ 后续使用该目录 |
| 用户点击「设为默认」| 同记住逻辑（当前目录固化） |
| 用户点击「恢复默认」| 回到 `~/Downloads/ClipboardSync/` |
| 目录不可访问（已删除） | 回退到默认目录 + 日志警告 |
| 文件名冲突 | 自动追加序号 `" (1)"`，不覆盖已有文件 |

---

## 涉及文件清单

| 文件 | Phase | 改动概要 |
|------|-------|---------|
| `Protocol.swift` | 1-2 | 新增 `clipboardDataChunk` 类型、SyncMessage 字段 |
| `ClipboardMonitor.swift` | 1, 3 | 图片压缩、文件读写、大小检查 |
| `SyncManager.swift` | 2-3 | 分片收发、文件消息路由 |
| `TCPServer.swift` | 2 | 接收缓冲扩容 |
| `SaveDirectoryManager.swift` | 4 | **新增**：保存目录管理、安全书签 |
| `MainView.swift` | 4 | 保存目录设置 UI |

---

## 验证方式

1. **编译**：`DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift build --package-path /Users/loho/Developer/HarmonyAndMac/ClipboardSync/mac`
2. **图片压缩**：打印压缩前后大小对比日志
3. **端到端**：Mac 复制截图 → 手机粘贴（需手机端同步完成）
4. **文件复制**：Mac 复制文件 → 检查是否正确构建 clipboardFile 消息
5. **保存目录**：选择自定义目录 → 接收文件 → 确认文件保存在所选目录 → 重启应用 → 确认目录记忆生效
6. **默认恢复**：点击恢复默认 → 确认文件再次保存到 `~/Downloads/ClipboardSync/`
