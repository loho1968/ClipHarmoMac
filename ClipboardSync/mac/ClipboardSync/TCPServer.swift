import Foundation
import Network

/// TCP 服务端，使用换行符分隔 JSON 消息
/// Mac 端作为服务端监听，鸿蒙端作为客户端连接
class TCPServer {
    private var listener: NWListener?
    private var connections: [NWConnection] = []
    private let queue = DispatchQueue(label: "com.clipboardsync.tcpserver")
    private let port: UInt16

    /// 缓冲区，处理 TCP 粘包
    private var buffers: [ObjectIdentifier: String] = [:]

    var onClientConnected: ((String) -> Void)?
    var onClientDisconnected: (() -> Void)?
    var onMessageReceived: ((SyncMessage) -> Void)?

    init(port: UInt16 = ProtocolConst.wsPort) {
        self.port = port
    }

    func start() {
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        guard let nwPort = NWEndpoint.Port(rawValue: port) else { return }

        do {
            listener = try NWListener(using: params, on: nwPort)
        } catch {
            print("Failed to create TCP listener: \(error)")
            return
        }

        listener?.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                print("TCP server ready on port \(self?.port ?? 0)")
            case .failed(let err):
                print("TCP server failed: \(err)")
            default:
                break
            }
        }

        listener?.newConnectionHandler = { [weak self] conn in
            self?.handleNewConnection(conn)
        }

        listener?.start(queue: queue)
    }

    func stop() {
        listener?.cancel()
        connections.forEach { $0.cancel() }
        connections.removeAll()
        buffers.removeAll()
    }

    func broadcast(_ message: SyncMessage) {
        guard let data = message.data else { return }
        // 每条消息以换行符结尾
        let framedData = data + Data([0x0A])  // '\n'
        for conn in connections {
            send(on: conn, data: framedData)
        }
    }

    var connectedCount: Int {
        return connections.count
    }

    // MARK: - Private

    private func handleNewConnection(_ connection: NWConnection) {
        let connId = ObjectIdentifier(connection)
        buffers[connId] = ""
        connections.append(connection)
        print("[TCPServer] New client connected from \(getRemoteAddress(connection)), total: \(connections.count)")

        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                let remoteAddr = self?.getRemoteAddress(connection) ?? "unknown"
                DispatchQueue.main.async {
                    self?.onClientConnected?(remoteAddr)
                }
                // 自动向手机发送 roomKey 信息（用于双 Mac 场景自动切换）
                self?.sendRoomKeyInfo(on: connection)
            case .failed, .cancelled:
                self?.removeConnection(connection)
            default:
                break
            }
        }

        connection.start(queue: queue)
        receive(on: connection)
    }

    /// 向新连接的手机发送 roomKey 信息，用于 NetworkProfile 自动记录
    private func sendRoomKeyInfo(on connection: NWConnection) {
        let roomKey = RelayConfig.sharedDefaults.string(forKey: RelayConfig.roomKeyDefaultsKey) ?? ""
        let relayHost = RelayConfig.currentHost

        guard !roomKey.isEmpty else {
            print("[TCPServer] No roomKey to share")
            return
        }

        let msg = SyncMessage(
            type: .roomKeyInfo,
            content: "",
            timestamp: Date().timeIntervalSince1970,
            deviceId: ProtocolConst.deviceId,
            mimeType: nil,
            networkSSID: nil,
            roomKey: roomKey,
            relayHost: relayHost
        )
        guard let data = msg.data else { return }
        let framedData = data + Data([0x0A])
        send(on: connection, data: framedData)
        print("[TCPServer] Sent roomKeyInfo to \(getRemoteAddress(connection))")
    }

    private func removeConnection(_ connection: NWConnection) {
        let connId = ObjectIdentifier(connection)
        buffers.removeValue(forKey: connId)
        connections.removeAll { $0 === connection }
        DispatchQueue.main.async { [weak self] in
            self?.onClientDisconnected?()
        }
    }

    private func receive(on connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1048576) { [weak self] data, _, isComplete, error in
            if let data = data, !data.isEmpty {
                self?.processIncomingData(data, from: connection)
            }

            if let error = error {
                print("Receive error: \(error)")
                self?.removeConnection(connection)
                return
            }

            if isComplete {
                self?.removeConnection(connection)
                return
            }

            self?.receive(on: connection)
        }
    }

    private func processIncomingData(_ data: Data, from connection: NWConnection) {
        guard let text = String(data: data, encoding: .utf8) else {
            print("[TCPServer] ← received non-UTF8 data (\(data.count) bytes)")
            return
        }

        print("[TCPServer] ← \(data.count) bytes: \(text.prefix(100))")

        let connId = ObjectIdentifier(connection)
        buffers[connId, default: ""] += text

        // 按换行符分割消息
        while let newlineRange = buffers[connId]?.range(of: "\n") {
            let line = String(buffers[connId]![..<newlineRange.lowerBound])
            buffers[connId] = String(buffers[connId]![newlineRange.upperBound...])

            if !line.isEmpty,
               let msgData = line.data(using: .utf8),
               let msg = SyncMessage.fromData(msgData) {
                DispatchQueue.main.async { [weak self] in
                    self?.onMessageReceived?(msg)
                }
            }
        }
    }

    private func send(on connection: NWConnection, data: Data) {
        connection.send(content: data, completion: .contentProcessed { [weak self] error in
            if let error = error {
                print("Send error: \(error)")
                self?.removeConnection(connection)
            }
        })
    }

    private func getRemoteAddress(_ connection: NWConnection) -> String {
        let endpoint = connection.currentPath?.remoteEndpoint
        if case .hostPort(let host, _) = endpoint {
            switch host {
            case .ipv4(let addr):
                return addr.debugDescription
            case .ipv6(let addr):
                return addr.debugDescription
            default:
                break
            }
        }
        return "unknown"
    }
}
