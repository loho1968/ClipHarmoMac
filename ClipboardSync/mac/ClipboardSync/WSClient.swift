import Foundation

/// WebSocket 中继客户端
/// 使用 URLSessionWebSocketTask (macOS 13+)
/// 负责连接/认证/心跳/重连/消息收发
class WSClient: NSObject, URLSessionWebSocketDelegate {

    // MARK: - 公开回调

    var onConnected: (() -> Void)?
    var onDisconnected: (() -> Void)?
    var onMessageReceived: ((SyncMessage) -> Void)?
    var onPaired: ((String) -> Void)?
    var onPeerGone: ((String) -> Void)?
    /// 发送被丢弃回执（房间内无其他设备），参数为被丢弃的消息类型
    var onNoPeer: ((String) -> Void)?
    var onAuthResult: ((Bool, String?) -> Void)?
    var onError: ((String) -> Void)?

    // MARK: - 公开属性

    private(set) var isConnected: Bool = false
    private(set) var isConnecting: Bool = false
    private(set) var roomKey: String = ""
    private(set) var pairedDeviceId: String?
    private(set) var connectionMode: ConnectionMode = .disconnected
    /// 是否正在自动重连（供外部 UI 判断状态提示）
    var isRetrying: Bool { shouldReconnect && !isConnected && !isConnecting }

    enum ConnectionMode {
        case disconnected
        case connecting
        case waitingForPair
        case paired
    }

    // MARK: - 私有状态

    private var webSocketTask: URLSessionWebSocketTask?
    private lazy var urlSession: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 300
        // 绕过系统代理（Shadowrocket / Clash 等会剥离 WebSocket 的 Upgrade 头）
        config.connectionProxyDictionary = [:]
        return URLSession(configuration: config, delegate: self, delegateQueue: nil)
    }()
    private var heartbeatTimer: Timer?
    private var reconnectAttempt: Int = 0
    private var reconnectTimer: Timer?
    private var shouldReconnect: Bool = true
    private let queue = DispatchQueue(label: "com.clipboardsync.wsclient")
    private var targetURL: URL?

    // MARK: - 初始化

    override init() {
        super.init()
    }

    // MARK: - 公开方法

    /// 连接并认证到中继服务器
    func connect(to url: URL, roomKey: String) {
        if isConnected || isConnecting {
            clipLog("[WSClient]connect() skipped: already connected/connecting")
            return
        }
        self.targetURL = url
        self.roomKey = roomKey
        self.shouldReconnect = true
        clipLog("[WSClient]Connecting to \(url.absoluteString) with roomKey=\(roomKey)")
        doConnect(url: url)
    }

    /// 强制重连（网络恢复后调用），重置重试计数器并立即连接
    func forceReconnect() {
        guard let url = targetURL, !roomKey.isEmpty else {
            clipLog("[WSClient] forceReconnect() skipped: missing url or roomKey")
            return
        }
        clipLog("[WSClient] forceReconnect() to \(url.absoluteString)")
        cleanup()
        webSocketTask?.cancel(with: .normalClosure, reason: nil)
        webSocketTask = nil
        isConnected = false
        isConnecting = false
        shouldReconnect = true
        doConnect(url: url)
    }

    /// 断开连接（取消重连）
    func disconnect() {
        clipLog("[WSClient]disconnect()")
        shouldReconnect = false
        cleanup()
        webSocketTask?.cancel(with: .normalClosure, reason: nil)
        webSocketTask = nil
        isConnected = false
        isConnecting = false
        connectionMode = .disconnected
    }

    /// 通过中继发送剪贴板消息
    func sendRelay(_ message: SyncMessage) {
        guard isConnected else {
            clipLog("[WSClient] sendRelay() failed: not connected")
            return
        }
        let relayMsg = RelayMessage.clientRelay(
            roomKey: roomKey,
            deviceId: ProtocolConst.deviceId,
            payload: message
        )
        sendJSON(relayMsg)
    }

    /// 发送应用层心跳
    func sendPing() {
        guard isConnected else { return }
        let pingMsg = RelayMessage.clientPing(deviceId: ProtocolConst.deviceId)
        sendJSON(pingMsg)
    }

    // MARK: - 私有方法

    private func doConnect(url: URL) {
        isConnecting = true
        connectionMode = .connecting
        clipLog("[WSClient] ═══ doConnect ═══")
        clipLog("[WSClient]   url = \(url.absoluteString)")
        clipLog("[WSClient]   roomKey = \(roomKey)")
        // 显式设置 WebSocket 握手头，防止 URLSessionWebSocketTask 在某些
        // macOS 版本（如 Darwin 25.x）上漏发 Upgrade/Connection 头
        var request = URLRequest(url: url)
        request.setValue("websocket", forHTTPHeaderField: "Upgrade")
        request.setValue("Upgrade", forHTTPHeaderField: "Connection")
        webSocketTask = urlSession.webSocketTask(with: request)
        webSocketTask?.resume()
        // auth 在 urlSession(_:webSocketTask:didOpenWithProtocol:) 回调中发送
        startReceiving()
    }

    // MARK: - URLSessionWebSocketDelegate

    /// WebSocket 握手成功、连接打开后回调 —— 此时发送 auth 认证消息
    func urlSession(_ session: URLSession,
                    webSocketTask: URLSessionWebSocketTask,
                    didOpenWithProtocol proto: String?) {
        clipLog("[WSClient] WebSocket opened, protocol: \(proto ?? "none"), sending auth...")
        let authMsg = RelayMessage.clientAuth(roomKey: roomKey, deviceId: ProtocolConst.deviceId)
        sendJSON(authMsg)
    }

    /// WebSocket 关闭回调 —— 统一走 handleDisconnect 重连逻辑
    func urlSession(_ session: URLSession,
                    webSocketTask: URLSessionWebSocketTask,
                    didCloseWith closeCode: URLSessionWebSocketTask.CloseCode,
                    reason: Data?) {
        clipLog("[WSClient] WebSocket closed: code=\(closeCode.rawValue)")
        // 防止与 receive 回调中的 handleDisconnect 重复触发
        guard isConnected || isConnecting else { return }
        handleDisconnect(error: nil)
    }

    private func sendJSON(_ message: RelayMessage) {
        guard let data = try? JSONEncoder().encode(message),
              let jsonStr = String(data: data, encoding: .utf8) else {
            clipLog("[WSClient] Failed to encode RelayMessage")
            return
        }
        let wsMsg = URLSessionWebSocketTask.Message.string(jsonStr)
        webSocketTask?.send(wsMsg) { [weak self] error in
            if let error = error {
                clipLog("[WSClient]Send error: \(error.localizedDescription)")
                self?.handleDisconnect(error: error)
            }
        }
    }

    private func startReceiving() {
        webSocketTask?.receive { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let message):
                switch message {
                case .string(let text):
                    self.handleTextMessage(text)
                case .data(let data):
                    if let text = String(data: data, encoding: .utf8) {
                        self.handleTextMessage(text)
                    }
                @unknown default:
                    break
                }
                self.startReceiving()  // 递归接收下一条
            case .failure(let error):
                clipLog("[WSClient]Receive failed: \(error.localizedDescription)")
                self.handleDisconnect(error: error)
            }
        }
    }

    private func handleTextMessage(_ text: String) {
        guard let data = text.data(using: .utf8),
              let msg = try? JSONDecoder().decode(RelayMessage.self, from: data) else {
            clipLog("[WSClient] Failed to decode relay message")
            return
        }
        routeMessage(msg)
    }

    /// 按 action 路由消息到对应回调
    private func routeMessage(_ msg: RelayMessage) {
        switch msg.action {
        case RelayAction.authOk.rawValue:
            let pid = msg.pairedDeviceId
            let roomCount = msg.roomDeviceCount
            clipLog("[WSClient] ═══ AUTH_OK received ═══")
            clipLog("[WSClient]   pairedDeviceId = \(pid ?? "nil")")
            clipLog("[WSClient]   roomDeviceCount = \(roomCount ?? -1)")
            clipLog("[WSClient]   isRetrying = \(isRetrying)")
            isConnected = true
            isConnecting = false
            reconnectAttempt = 0
            pairedDeviceId = pid
            let mode: ConnectionMode = (pid != nil) ? .paired : .waitingForPair
            connectionMode = mode
            clipLog("[WSClient]   → mode = \(mode)")
            startHeartbeat()

            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.onAuthResult?(true, self.pairedDeviceId)
                if let pid = pid {
                    clipLog("[WSClient]   → calling onPaired(\(pid))")
                    self.onPaired?(pid)
                }
                clipLog("[WSClient]   → calling onConnected()")
                self.onConnected?()
            }

        case RelayAction.relay.rawValue:
            if let payload = msg.payload {
                DispatchQueue.main.async { [weak self] in
                    self?.onMessageReceived?(payload)
                }
            }

        case RelayAction.paired.rawValue:
            if let pid = msg.pairedDeviceId {
                pairedDeviceId = pid
                connectionMode = .paired
                DispatchQueue.main.async { [weak self] in
                    self?.onPaired?(pid)
                }
            }

        case RelayAction.peerGone.rawValue:
            pairedDeviceId = nil
            connectionMode = .waitingForPair
            if let fid = msg.fromDeviceId {
                DispatchQueue.main.async { [weak self] in
                    self?.onPeerGone?(fid)
                }
            }

        case RelayAction.pong.rawValue:
            break  // 心跳响应，无需处理

        case RelayAction.relayNoPeer.rawValue:
            // 房间内无其他设备：消息已被服务端丢弃（典型原因：两端配对码不一致）
            pairedDeviceId = nil
            connectionMode = .waitingForPair
            let droppedType = msg.type ?? "消息"
            clipLog("[WSClient] relay_no_peer: 房间内无其他设备，\(droppedType) 未被送达")
            DispatchQueue.main.async { [weak self] in
                self?.onNoPeer?(droppedType)
            }

        case RelayAction.error.rawValue:
            let errorMsg = msg.message ?? "未知中继错误"
            clipLog("[WSClient]Server error: \(errorMsg)")
            DispatchQueue.main.async { [weak self] in
                self?.onError?(errorMsg)
            }

        default:
            clipLog("[WSClient] Unknown action: \(msg.action)")
        }
    }

    private func handleDisconnect(error: Error?) {
        // 防止 didClose delegate 与 receive error 重复触发
        guard isConnected || isConnecting else {
            clipLog("[WSClient] handleDisconnect ignored: already disconnected (isConnected=\(isConnected), isConnecting=\(isConnecting))")
            return
        }
        clipLog("[WSClient] ═══ Disconnected ═══")
        clipLog("[WSClient]   error = \(error?.localizedDescription ?? "normal")")
        clipLog("[WSClient]   shouldReconnect = \(self.shouldReconnect)")
        clipLog("[WSClient]   reconnectAttempt = \(self.reconnectAttempt)")
        isConnected = false
        isConnecting = false
        stopHeartbeat()
        webSocketTask = nil

        DispatchQueue.main.async { [weak self] in
            self?.onDisconnected?()
        }

        if shouldReconnect {
            scheduleReconnect()
        }
    }

    // MARK: - 心跳

    private func startHeartbeat() {
        stopHeartbeat()
        DispatchQueue.main.async { [weak self] in
            self?.heartbeatTimer = Timer.scheduledTimer(
                withTimeInterval: RelayConfig.heartbeatInterval,
                repeats: true
            ) { [weak self] _ in
                self?.sendPing()
            }
        }
    }

    private func stopHeartbeat() {
        heartbeatTimer?.invalidate()
        heartbeatTimer = nil
    }

    // MARK: - 重连

    /// 指数退避重连：1s → 2s → 4s → 8s → 16s（最大 30s）
    private func scheduleReconnect() {
        let delay = min(
            RelayConfig.reconnectBaseDelay * pow(2.0, Double(reconnectAttempt)),
            RelayConfig.reconnectMaxDelay
        )
        reconnectAttempt += 1
        clipLog("[WSClient]Reconnect in \(Int(delay))s (attempt \(self.reconnectAttempt))")

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.reconnectTimer?.invalidate()
            self.reconnectTimer = Timer.scheduledTimer(
                withTimeInterval: delay,
                repeats: false
            ) { [weak self] _ in
                guard let self, self.shouldReconnect, let url = self.targetURL else { return }
                self.webSocketTask?.cancel(with: .normalClosure, reason: nil)
                self.webSocketTask = nil
                self.doConnect(url: url)
            }
        }
    }

    // MARK: - 清理

    private func cleanup() {
        stopHeartbeat()
        reconnectTimer?.invalidate()
        reconnectTimer = nil
        reconnectAttempt = 0
    }
}
