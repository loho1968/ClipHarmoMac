* Aim to build all functionality using SwiftUI unless there is a feature that is only supported in AppKit.
* Design UI in a way that is idiomatic for the macOS platform and follows Apple Human Interface Guidelines.
* Use SF Symbols for iconography.
* Use the most modern macOS APIs. Since there is no backward compatibility constraint, this app can target the latest macOS version with the newest APIs.
* Use the most modern Swift language features and conventions. Target Swift 6 and use Swift concurrency (async/await, actors) and Swift macros where applicable.
* 全部用中文回答。
* Swift 项目修改完成后，使用 `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift build --package-path /Users/loho/Developer/ClipHarmoMac/ClipboardSync/mac` 进行编译，然后修复所有编译错误。
* HarmonyOS (ArkTS) 项目位于 `ClipboardSync/harmony/`。已配置 `deveco-cli` 工具链：
  - 编译：`devecocli build --project-path ClipboardSync/harmony`
  - 运行：`devecocli run --project-path ClipboardSync/harmony`
  - 日志：`devecocli log --project-path ClipboardSync/harmony --level E --tail 50`
  - 设备：`devecocli device list`
  - 文档：`devecocli docs search <关键词>`
  - 语法检查已通过 `deveco-mcp` 在 `.mcp.json` 中配置
  - 语法检查失败时（DevEco 路径映射不匹配等），应跳过检查，直接手动验证代码逻辑