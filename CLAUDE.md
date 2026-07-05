* Aim to build all functionality using SwiftUI unless there is a feature that is only supported in AppKit.
* Design UI in a way that is idiomatic for the macOS platform and follows Apple Human Interface Guidelines.
* Use SF Symbols for iconography.
* Use the most modern macOS APIs. Since there is no backward compatibility constraint, this app can target the latest macOS version with the newest APIs.
* Use the most modern Swift language features and conventions. Target Swift 6 and use Swift concurrency (async/await, actors) and Swift macros where applicable.
* 全部用中文回答。
* Swift 项目修改完成后，使用 `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift build --package-path /Users/loho/Developer/ClipHarmoMac/ClipboardSync/mac` 进行编译，然后修复所有编译错误。