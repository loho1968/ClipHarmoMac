import Foundation

/// 通信协议常量
enum ProtocolConst {
    /// 应用版本号
    static let appVersion = "1.0.0 (build 1)"
    /// UDP 广播端口
    static let broadcastPort: UInt16 = 19876
    /// TCP 数据服务端口
    static let wsPort: UInt16 = 19877
    /// TCP 发现端口（鸿蒙端监听，Mac连接告知IP）
    static let discoveryTcpPort: UInt16 = 19878
    /// 广播间隔（秒）
    static let broadcastInterval: TimeInterval = 3
    /// 剪贴板轮询间隔（秒）
    static let clipboardPollInterval: TimeInterval = 0.5
    /// 设备标识
    static let deviceId = Host.current().localizedName ?? "Mac-\(Int.random(in: 1000...9999))"
}

/// 消息类型
enum MessageType: String, Codable {
    case clipboardText
    case clipboardImage
    case clipboardFile
    case clipboardDataChunk
    case clipboardPoll
    case ping
    case pong
    /// Mac → 手机，TCP 连接建立后自动发送 roomKey 和 relayHost
    case roomKeyInfo
    /// 手机 → Mac，自动提取的短信验证码
    case verificationCode
    /// ECDH P-256 公钥交换（content 为空，publicKey 字段携带公钥）
    case keyExchange
}

/// 传输消息
struct SyncMessage: Codable {
    let type: MessageType
    var content: String
    let timestamp: Double
    let deviceId: String
    let mimeType: String?
    let networkSSID: String?  // Mac 当前 WiFi SSID（用于手机端网络匹配）
    var roomKey: String? = nil     // roomKeyInfo 消息携带：Mac 的配对码
    var relayHost: String? = nil   // roomKeyInfo 消息携带：中继服务器地址
    var smsSender: String? = nil   // verificationCode 消息携带：短信发送者号码
    var publicKey: String? = nil    // keyExchange 消息携带：ECDH P-256 公钥（Base64）

    // 分片传输字段（图片和文件共用）
    var transferId: String? = nil   // UUID，标识一次传输会话
    var chunkIndex: Int? = nil      // 0-based 分片索引
    var totalChunks: Int? = nil     // 总分片数（nil 或 1 表示非分片）

    // 图片/文件元数据
    var fileName: String? = nil     // 文件名（如 "screenshot_20260702_143021.jpeg"）
    var fileSize: Int? = nil        // 压缩后字节数
    var imageWidth: Int? = nil      // 图片宽度（仅 clipboardImage）
    var imageHeight: Int? = nil     // 图片高度（仅 clipboardImage）
    var format: String? = nil       // "jpeg" | "png"（仅 clipboardImage）
    var fileCount: Int? = nil       // 批量文件数量（仅 clipboardFile）

    var data: Data? {
        try? JSONEncoder().encode(self)
    }

    static func fromData(_ data: Data) -> SyncMessage? {
        try? JSONDecoder().decode(SyncMessage.self, from: data)
    }
}

// MARK: - 中继服务器配置

/// 中继服务器配置常量
enum RelayConfig {
    /// 默认服务器主机（IP 或域名）—— 从配置文件加载
    static let defaultHost: String = RelayConfig._config.host
    /// 服务器端口
    static let defaultPort: Int = RelayConfig._config.port
    /// WebSocket 路径
    static let wsPath: String = RelayConfig._config.wsPath
    /// 心跳间隔（秒）
    static let heartbeatInterval: TimeInterval = 30
    /// 重连基础延迟（秒）
    static let reconnectBaseDelay: TimeInterval = 1
    /// 重连最大延迟（秒）
    static let reconnectMaxDelay: TimeInterval = 30
    /// Room Key 持久化 Key
    static let roomKeyDefaultsKey = "com.clipboardsync.roomKey"
    /// 服务器主机持久化 Key
    static let hostDefaultsKey = "com.clipboardsync.relayHost"
    /// Room Key 长度
    static let roomKeyLength = 6

    // MARK: - 配置加载

    private struct RelayValues {
        let host: String
        let port: Int
        let wsPath: String
    }

    private static let _config: RelayValues = RelayConfig.loadFromBundle()

    /// 从 ~/.clipboardsync/relay_config.json 读取默认值，不存在则回退 localhost
    private static func loadFromBundle() -> RelayValues {
        let fallback = RelayValues(host: "localhost", port: 8443, wsPath: "/ws")

        // 读取用户主目录下的配置文件（可选，不存在时用兜底值）
        let homeConfigURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".clipboardsync")
            .appendingPathComponent("relay_config.json")

        guard let data = try? Data(contentsOf: homeConfigURL),
              let values = parseConfig(data) else {
            print("[RelayConfig] No config at ~/.clipboardsync/relay_config.json, using fallback: \(fallback.host):\(fallback.port)")
            return fallback
        }
        print("[RelayConfig] Loaded config from ~/.clipboardsync/relay_config.json: host=\(values.host)")
        return values
    }

    private static func parseConfig(_ data: Data) -> RelayValues? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let relay = json["relay"] as? [String: Any] else { return nil }
        let host = relay["defaultHost"] as? String ?? "localhost"
        let port = relay["defaultPort"] as? Int ?? 8443
        let wsPath = relay["wsPath"] as? String ?? "/ws"
        return RelayValues(host: host, port: port, wsPath: wsPath)
    }

    /// 共享 UserDefaults（统一 debug/release 的持久化，不受 Bundle Identifier 影响）
    static let sharedDefaults = UserDefaults(suiteName: "com.clipboardsync.shared")!

    /// 当前配置的服务器主机（IP 或域名），优先读取持久化值，否则使用配置文件默认值
    static var currentHost: String {
        get {
            sharedDefaults.string(forKey: hostDefaultsKey) ?? defaultHost
        }
        set {
            sharedDefaults.set(newValue, forKey: hostDefaultsKey)
        }
    }

    /// 根据当前配置组装的服务器 URL
    static var serverURL: URL {
        URL(string: "ws://\(currentHost):\(defaultPort)\(wsPath)")!
    }
}

// MARK: - 中继层消息协议

/// 中继层 action 类型
enum RelayAction: String {
    case auth = "auth"
    case authOk = "auth_ok"
    case relay = "relay"
    case ping = "ping"
    case pong = "pong"
    case paired = "paired"
    case peerGone = "peer_gone"
    case error = "error"
}

/// 中继层消息（WebSocket JSON 协议）
/// 不同 action 携带不同字段，可选字段在不需要时为 nil
struct RelayMessage: Codable {
    let action: String
    let roomKey: String?
    let deviceId: String?
    let fromDeviceId: String?
    let pairedDeviceId: String?
    let payload: SyncMessage?
    let message: String?
    let roomDeviceCount: Int?

    // MARK: 客户端→服务端 便捷构造

    /// 认证并加入房间
    static func clientAuth(roomKey: String, deviceId: String) -> RelayMessage {
        RelayMessage(
            action: RelayAction.auth.rawValue,
            roomKey: roomKey,
            deviceId: deviceId,
            fromDeviceId: nil,
            pairedDeviceId: nil,
            payload: nil,
            message: nil,
            roomDeviceCount: nil
        )
    }

    /// 转发剪贴板消息
    static func clientRelay(roomKey: String, deviceId: String, payload: SyncMessage) -> RelayMessage {
        RelayMessage(
            action: RelayAction.relay.rawValue,
            roomKey: roomKey,
            deviceId: deviceId,
            fromDeviceId: nil,
            pairedDeviceId: nil,
            payload: payload,
            message: nil,
            roomDeviceCount: nil
        )
    }

    /// 心跳
    static func clientPing(deviceId: String) -> RelayMessage {
        RelayMessage(
            action: RelayAction.ping.rawValue,
            roomKey: nil,
            deviceId: deviceId,
            fromDeviceId: nil,
            pairedDeviceId: nil,
            payload: nil,
            message: nil,
            roomDeviceCount: nil
        )
    }
}
