import Foundation

/// WebSocket 中继客户端
/// 使用 URLSessionWebSocketTask (macOS 13+)
/// 负责连接/认证/心跳/重连/消息收发
class WSClient {

    // MARK: - 公开回调

    var onConnected: (() -> Void)?
    var onDisconnected: (() -> Void)?
    var onMessageReceived: ((SyncMessage) -> Void)?
    var onPaired: ((String) -> Void)?
    var onPeerGone: ((String) -> Void)?
    var onAuthResult: ((Bool, String?) -> Void)?
    var onError: ((String) -> Void)?

    // MARK: - 公开属性

    private(set) var isConnected: Bool = false
    private(set) var isConnecting: Bool = false
    private(set) var roomKey: String = ""
    private(set) var pairedDeviceId: String?
    private(set) var connectionMode: ConnectionMode = .disconnected

    enum ConnectionMode {
        case disconnected
        case connecting
        case waitingForPair
        case paired
    }

    // MARK: - 私有状态

    private var webSocketTask: URLSessionWebSocketTask?
    private var urlSession: URLSession
    private var heartbeatTimer: Timer?
    private var reconnectAttempt: Int = 0
    private var reconnectTimer: Timer?
    private var shouldReconnect: Bool = true
    private let queue = DispatchQueue(label: "com.clipboardsync.wsclient")
    private var targetURL: URL?

    // MARK: - 初始化

    init() {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 300
        self.urlSession = URLSession(configuration: config)
    }

    // MARK: - 公开方法

    /// 连接并认证到中继服务器
    func connect(to url: URL, roomKey: String) {
        if isConnected || isConnecting {
            print("[WSClient]connect() skipped: already connected/connecting")
            return
        }
        self.targetURL = url
        self.roomKey = roomKey
        self.shouldReconnect = true
        print("[WSClient]Connecting to \(url.absoluteString) with roomKey=\(roomKey)")
        doConnect(url: url)
    }

    /// 断开连接（取消重连）
    func disconnect() {
        print("[WSClient]disconnect()")
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
            print("[WSClient] sendRelay() failed: not connected")
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
        webSocketTask = urlSession.webSocketTask(with: url)
        webSocketTask?.resume()

        // 连接后立即发送 auth 消息
        let authMsg = RelayMessage.clientAuth(roomKey: roomKey, deviceId: ProtocolConst.deviceId)
        sendJSON(authMsg)
        startReceiving()
    }

    private func sendJSON(_ message: RelayMessage) {
        guard let data = try? JSONEncoder().encode(message),
              let jsonStr = String(data: data, encoding: .utf8) else {
            print("[WSClient] Failed to encode RelayMessage")
            return
        }
        let wsMsg = URLSessionWebSocketTask.Message.string(jsonStr)
        webSocketTask?.send(wsMsg) { [weak self] error in
            if let error = error {
                print("[WSClient]Send error: \(error.localizedDescription)")
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
                print("[WSClient]Receive failed: \(error.localizedDescription)")
                self.handleDisconnect(error: error)
            }
        }
    }

    private func handleTextMessage(_ text: String) {
        guard let data = text.data(using: .utf8),
              let msg = try? JSONDecoder().decode(RelayMessage.self, from: data) else {
            print("[WSClient] Failed to decode relay message")
            return
        }
        routeMessage(msg)
    }

    /// 按 action 路由消息到对应回调
    private func routeMessage(_ msg: RelayMessage) {
        switch msg.action {
        case RelayAction.authOk.rawValue:
            print("[WSClient]AUTH_OK received, pairedDeviceId=\(msg.pairedDeviceId ?? "nil")")
            isConnected = true
            isConnecting = false
            reconnectAttempt = 0
            pairedDeviceId = msg.pairedDeviceId
            let mode: ConnectionMode = (msg.pairedDeviceId != nil) ? .paired : .waitingForPair
            connectionMode = mode
            startHeartbeat()

            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.onAuthResult?(true, self.pairedDeviceId)
                if let pid = msg.pairedDeviceId {
                    self.onPaired?(pid)
                }
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

        case RelayAction.error.rawValue:
            let errorMsg = msg.message ?? "未知中继错误"
            print("[WSClient]Server error: \(errorMsg)")
            DispatchQueue.main.async { [weak self] in
                self?.onError?(errorMsg)
            }

        default:
            print("[WSClient] Unknown action: \(msg.action)")
        }
    }

    private func handleDisconnect(error: Error?) {
        print("[WSClient]Disconnected: \(error?.localizedDescription ?? "normal"), shouldReconnect=\(self.shouldReconnect)")
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
        print("[WSClient]Reconnect in \(Int(delay))s (attempt \(self.reconnectAttempt))")

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
