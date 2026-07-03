// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "ClipboardSync",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "ClipboardSync", targets: ["ClipboardSync"])
    ],
    targets: [
        .executableTarget(
            name: "ClipboardSync",
            path: "ClipboardSync",
            exclude: ["Info.plist", "Info-dev.plist", "start.sh"]
        )
    ]
)
