import Foundation
import AppKit
import Combine
import CoreWLAN
import UserNotifications

/// 同步管理器，协调各模块
class SyncManager: ObservableObject {
    @Published var status: SyncStatus = .disconnected
    @Published var connectedDevice: String?
    @Published var lastSyncTime: Date?
    @Published var syncHistory: [SyncRecord] = []
    @Published var launchAtLogin: Bool = LaunchAgentManager.isEnabled {
        didSet {
            if launchAtLogin != oldValue {
                if launchAtLogin {
                    LaunchAgentManager.enable()
                } else {
                    LaunchAgentManager.disable()
                }
            }
        }
    }

    /// 当前连接模式
    @Published var connectionMode: ConnectionMode = .none

    /// Room Key（用于中继配对）
    @Published var roomKey: String = ""

    /// 中继配对状态描述
    @Published var relayStatusText: String = ""

    /// 中继已配对的设备 ID
    @Published var relayPairedDeviceId: String?

    /// 中继服务器主机（IP 或域名），修改后自动重连
    @Published var relayServerHost: String = RelayConfig.currentHost

    private let discovery = DiscoveryService()
    private let server = TCPServer()
    private let clipboard = ClipboardMonitor()
    private let wsClient = WSClient()
    private let networkMonitor = NetworkMonitor()

    // 去重：记录最近发送的消息时间戳，避免回环
    private var lastSentTimestamp: Double = 0
    // 标记正在处理远端消息，防止 ClipboardMonitor 级联触发
    private var isProcessingRemote: Bool = false

    enum SyncStatus: String {
        case disconnected = "未连接"
        case discovering = "搜索设备中"
        case connected = "已连接"
    }

    /// 连接模式
    enum ConnectionMode: String {
        case none = "无"
        case lan = "局域网"
        case relay = "云中继"
    }

    struct SyncRecord: Identifiable {
        let id = UUID()
        let content: String
        let time: Date
        let direction: Direction

        enum Direction {
            case sent
            case received
        }
    }

    init() {
        setupCallbacks()
        setupWSCallbacks()
    }

    func start() {
        status = .discovering
        connectionMode = .none
        server.start()
        discovery.start()
        clipboard.start()
        startRelayIfNeeded()
        startNetworkMonitor()
    }

    func stop() {
        networkMonitor.stop()
        discovery.stop()
        server.stop()
        clipboard.stop()
        wsClient.disconnect()
        status = .disconnected
        connectionMode = .none
        connectedDevice = nil
        relayPairedDeviceId = nil
    }

    // MARK: - 网络感知

    private func startNetworkMonitor() {
        networkMonitor.onNetworkChange = { [weak self] in
            guard let self else { return }
            print("[SyncManager] Network changed, restarting LAN services...")
            // 重启 LAN 发现和 TCP 服务，让手机在新网络中找到 Mac
            self.restartLANServices()
        }
        networkMonitor.start()
    }

    /// 重启局域网相关服务（WiFi 切换后调用）
    private func restartLANServices() {
        discovery.stop()
        server.stop()
        // 短暂延迟后重启，确保旧 socket 完全释放
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            guard let self else { return }
            self.server.start()
            self.discovery.start()
            print("[SyncManager] LAN services restarted")
        }
    }

    private func setupCallbacks() {
        // 发现设备（UDP 广播仅用于确认对方在线，不改变连接状态）
        discovery.onDeviceFound = { [weak self] deviceId, port in
            DispatchQueue.main.async {
                // UDP 发现不代表 TCP 已连接，仅更新设备名（若已 TCP 连接）
                if self?.status == .connected && self?.connectedDevice == nil {
                    self?.connectedDevice = deviceId
                }
                print("[SyncManager] UDP discovered \(deviceId), TCP status: \(self?.status.rawValue ?? "nil")")
            }
        }

        // TCP 客户端连接
        server.onClientConnected = { [weak self] remoteAddr in
            DispatchQueue.main.async {
                self?.status = .connected
                self?.connectedDevice = remoteAddr
                self?.connectionMode = .lan
            }
        }

        server.onClientDisconnected = { [weak self] in
            DispatchQueue.main.async {
                if self?.server.connectedCount == 0 {
                    // LAN 断开，检测中继是否可用
                    if self?.wsClient.isConnected == true {
                        self?.connectionMode = .relay
                        self?.status = .connected
                    } else {
                        self?.status = .discovering
                        self?.connectionMode = .none
                    }
                    self?.connectedDevice = nil
                }
            }
        }

        // 收到远端消息
        server.onMessageReceived = { [weak self] msg in
            self?.handleRemoteMessage(msg)
        }

        // 本地剪贴板变化
        clipboard.onClipboardChanged = { [weak self] text, imageData, metadata, fileURL in
            self?.handleLocalClipboardChange(text: text, imageData: imageData, metadata: metadata, fileURL: fileURL)
        }
    }

    // MARK: - 中继连接

    private func setupWSCallbacks() {
        wsClient.onConnected = { [weak self] in
            DispatchQueue.main.async {
                guard let self else { return }
                print("[SyncManager] WS onConnected, lanCount=\(self.server.connectedCount)")
                // 仅当 LAN 未连接时才切换到 relay 模式
                if self.server.connectedCount == 0 {
                    self.connectionMode = .relay
                    self.status = .connected
                }
                self.relayPairedDeviceId = self.wsClient.pairedDeviceId
                self.relayStatusText = self.wsClient.pairedDeviceId != nil
                    ? "已配对: \(self.wsClient.pairedDeviceId!)"
                    : "等待设备加入..."
            }
        }

        wsClient.onDisconnected = { [weak self] in
            DispatchQueue.main.async {
                guard let self else { return }
                print("[SyncManager] WS onDisconnected, mode=\(self.connectionMode.rawValue)")
                if self.connectionMode == .relay {
                    self.connectionMode = (self.server.connectedCount > 0) ? .lan : .none
                    self.status = (self.server.connectedCount > 0) ? .connected : .discovering
                }
                self.relayPairedDeviceId = nil
                self.relayStatusText = "中继已断开"
            }
        }

        wsClient.onMessageReceived = { [weak self] msg in
            self?.handleRemoteMessage(msg)
        }

        wsClient.onPaired = { [weak self] deviceId in
            DispatchQueue.main.async {
                guard let self else { return }
                self.relayPairedDeviceId = deviceId
                self.relayStatusText = "已配对: \(deviceId)"
                if self.server.connectedCount == 0 {
                    self.connectionMode = .relay
                    self.status = .connected
                }
            }
        }

        wsClient.onPeerGone = { [weak self] _ in
            DispatchQueue.main.async {
                self?.relayPairedDeviceId = nil
                self?.relayStatusText = "配对设备已离线"
            }
        }

        wsClient.onError = { [weak self] errorMsg in
            DispatchQueue.main.async {
                self?.relayStatusText = "中继错误: \(errorMsg)"
            }
        }
    }

    private func startRelayIfNeeded() {
        let savedKey = RelayConfig.sharedDefaults.string(forKey: RelayConfig.roomKeyDefaultsKey) ?? ""
        let currentHost = RelayConfig.currentHost
        print("[SyncManager] startRelay: savedKey=\(savedKey.isEmpty ? "(empty)" : savedKey) host=\(currentHost)")
        if !savedKey.isEmpty {
            roomKey = savedKey
            wsClient.connect(to: RelayConfig.serverURL, roomKey: savedKey)
        } else {
            // 首次使用，生成 Room Key
            generateAndSaveRoomKey()
        }
    }

    private func generateAndSaveRoomKey() {
        let chars = "ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789"
        let key = String((0..<RelayConfig.roomKeyLength).map { _ in chars.randomElement()! })
        RelayConfig.sharedDefaults.set(key, forKey: RelayConfig.roomKeyDefaultsKey)
        roomKey = key
        relayStatusText = "Room Key 已生成，等待连接中继"
        // 自动连接中继
        wsClient.connect(to: RelayConfig.serverURL, roomKey: key)
    }

    /// 更新中继服务器地址并重连
    func updateRelayHost(_ host: String) {
        let trimmed = host.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        RelayConfig.currentHost = trimmed
        relayServerHost = trimmed
        relayStatusText = "服务器地址已更新，重连中..."
        // 断开旧连接，用新地址重连
        wsClient.disconnect()
        if !roomKey.isEmpty {
            wsClient.connect(to: RelayConfig.serverURL, roomKey: roomKey)
        }
    }

    /// 重新生成 Room Key（用户主动操作）
    func regenerateRoomKey() {
        wsClient.disconnect()
        relayPairedDeviceId = nil
        let chars = "ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789"
        let key = String((0..<RelayConfig.roomKeyLength).map { _ in chars.randomElement()! })
        RelayConfig.sharedDefaults.set(key, forKey: RelayConfig.roomKeyDefaultsKey)
        roomKey = key
        relayStatusText = "Room Key 已更新，等待新配对"
        wsClient.connect(to: RelayConfig.serverURL, roomKey: key)
    }

    /// 生成二维码 JSON 数据，包含配对码、中继服务器地址和局域网 IP
    func qrCodeData() -> String {
        var dict: [String: Any] = [
            "v": 1,
            "rk": roomKey,
            "rh": RelayConfig.currentHost,
        ]
        // 附上局域网 IP（手机在同一 WiFi 下可直连）
        if let localIP = SyncManager.getLocalIPAddress() {
            dict["ip"] = localIP
        }
        guard let jsonData = try? JSONSerialization.data(withJSONObject: dict),
              let jsonString = String(data: jsonData, encoding: .utf8) else {
            return ""
        }
        return jsonString
    }

    /// 生成仅含局域网 IP 的二维码数据（中继不可用时扫码直连）
    func lanQRCodeData() -> String {
        guard let localIP = SyncManager.getLocalIPAddress() else { return "" }
        let dict: [String: Any] = ["v": 1, "ip": localIP]
        guard let jsonData = try? JSONSerialization.data(withJSONObject: dict),
              let jsonString = String(data: jsonData, encoding: .utf8) else {
            return ""
        }
        return jsonString
    }

    /// 获取本机局域网 IP 地址
    static func getLocalIPAddress() -> String? {
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let first = ifaddr else { return nil }
        defer { freeifaddrs(ifaddr) }
        for ptr in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let flags = Int32(ptr.pointee.ifa_flags)
            guard (flags & IFF_UP) != 0 && (flags & IFF_RUNNING) != 0 else { continue }
            guard (flags & IFF_LOOPBACK) == 0 else { continue }
            guard let sa = ptr.pointee.ifa_addr else { continue }
            guard sa.pointee.sa_family == sa_family_t(AF_INET) else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            getnameinfo(ptr.pointee.ifa_addr, socklen_t(sa.pointee.sa_len),
                       &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST)
            return String(cString: host)
        }
        return nil
    }

    private func handleRemoteMessage(_ msg: SyncMessage) {
        print("[SyncManager] ← received type=\(msg.type.rawValue) from=\(msg.deviceId) ts=\(msg.timestamp) lastSentTs=\(lastSentTimestamp)")

        // 去重检查：忽略自己刚发出去的消息回环
        if msg.timestamp <= lastSentTimestamp && msg.deviceId == ProtocolConst.deviceId {
            print("[SyncManager] ✗ dedup rejected self-echo")
            return
        }

        isProcessingRemote = true
        defer { isProcessingRemote = false }

        switch msg.type {
        case .clipboardText:
            clipboard.writeText(msg.content)
            addRecord(msg.content, direction: .received)
            sendReceivedNotification(preview: msg.content, filePath: nil)
            // 降级检测：检查 clipboardText 是否包含验证码
            if let code = VerificationCodeHandler.extractCode(from: msg.content) {
                VerificationCodeHandler.handle(code: code, sender: nil)
            }
        case .clipboardImage:
            // 检查是否为分片传输
            if let totalChunks = msg.totalChunks, totalChunks > 1 {
                handleChunk(msg)
            } else if let data = Data(base64Encoded: msg.content) {
                // 写图片到剪贴板
                clipboard.writeImage(data)
                // 同时保存图片文件到磁盘
                let imageFileName = msg.fileName ?? imageFileName(for: msg)
                let savedPath = saveReceivedData(data, fileName: imageFileName)
                addRecord("[图片]", direction: .received)
                sendReceivedNotification(preview: "📷 图片", filePath: savedPath)
            }
        case .clipboardFile:
            // 检查是否为分片传输
            if let totalChunks = msg.totalChunks, totalChunks > 1 {
                handleChunk(msg)
            } else if let data = Data(base64Encoded: msg.content) {
                let savedPath = saveReceivedData(data, fileName: msg.fileName ?? "unknown_file")
                // 写入剪贴板（文件 URL）
                if let path = savedPath {
                    DispatchQueue.main.async { [weak self] in
                        self?.isProcessingRemote = true
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.writeObjects([URL(fileURLWithPath: path) as NSURL])
                        self?.isProcessingRemote = false
                    }
                }
                addRecord("[文件] \(msg.fileName ?? "")", direction: .received)
                sendReceivedNotification(preview: "📁 \(msg.fileName ?? "文件")", filePath: savedPath)
            }
        case .clipboardDataChunk:
            handleChunk(msg)
        case .clipboardPoll:
            handleClipboardPoll()
        case .ping, .pong:
            break
        case .verificationCode:
            // 手机自动提取验证码并发送到 Mac
            VerificationCodeHandler.handle(code: msg.content, sender: msg.smsSender)
            addRecord(msg.content + " (验证码)", direction: .received)
            sendReceivedNotification(preview: "🔐 验证码: \(msg.content)", filePath: nil)
        case .roomKeyInfo:
            // Mac 端忽略（仅发送 roomKeyInfo 给手机，不接收）
            break
        }

        DispatchQueue.main.async {
            self.lastSyncTime = Date()
        }
    }

    private func handleLocalClipboardChange(text: String?, imageData: Data?, metadata: ClipboardImageMetadata?, fileURL: URL?) {
        // 级联防护：远端写入剪贴板触发的本地变化不应回传
        guard !isProcessingRemote else {
            print("[SyncManager] local change suppressed (remote in progress)")
            return
        }

        if let text = text {
            // 文字 → 自动发送（保持现有行为）
            print("[SyncManager] → text copied, auto-sending...")
            let timestamp = Date().timeIntervalSince1970
            lastSentTimestamp = timestamp
            let currentSSID = CWWiFiClient.shared().interface()?.ssid()
            let msg = SyncMessage(
                type: .clipboardText,
                content: text,
                timestamp: timestamp,
                deviceId: ProtocolConst.deviceId,
                mimeType: "text/plain",
                networkSSID: currentSSID
            )
            sendOrBroadcast(msg)
            addRecord(text, direction: .sent)
            // 清除旧的图片/文件暂存
            clearPendingContent()
        } else if let imageData = imageData, let meta = metadata {
            // 图片 → 暂存，等待用户手动发送
            print("[SyncManager] → image copied, pending send: \(meta.fileSize / 1024)KB")
            pendingImageData = imageData
            pendingImageMetadata = meta
            pendingFileURL = nil
            sendProgress = "准备发送图片 (\(meta.fileSize / 1024)KB, \(meta.width)×\(meta.height))"
        } else if let fileURL = fileURL {
            // 文件 → 暂存，等待用户手动发送
            print("[SyncManager] → file copied, pending send: \(fileURL.lastPathComponent)")
            pendingFileURL = fileURL
            pendingImageData = nil
            pendingImageMetadata = nil
            let fileSize = (try? FileManager.default.attributesOfItem(atPath: fileURL.path)[.size] as? Int) ?? 0
            sendProgress = "准备发送文件: \(fileURL.lastPathComponent) (\(fileSize / 1024)KB)"
        }
    }

    /// 清除暂存的内容
    func clearPendingContent() {
        pendingImageData = nil
        pendingImageMetadata = nil
        pendingFileURL = nil
        sendProgress = ""
        isSendingContent = false
    }

    /// 用户手动触发发送暂存的图片或文件
    func sendPendingContent() {
        guard !isSendingContent else { return }

        if let imageData = pendingImageData, let meta = pendingImageMetadata {
            sendPendingImage(data: imageData, meta: meta)
        } else if let fileURL = pendingFileURL {
            sendPendingFile(url: fileURL)
        }
    }

    /// 发送暂存的图片
    private func sendPendingImage(data: Data, meta: ClipboardImageMetadata) {
        isSendingContent = true
        let totalChunks = Int(ceil(Double(data.count) / Double(Self.chunkSize)))
        let chunkInfo = totalChunks > 1 ? " (共 \(totalChunks) 片)" : ""
        sendProgress = "正在发送图片\(chunkInfo)..."

        let timestamp = Date().timeIntervalSince1970
        lastSentTimestamp = timestamp
        let currentSSID = CWWiFiClient.shared().interface()?.ssid()
        let msg = SyncMessage(
            type: .clipboardImage,
            content: "",
            timestamp: timestamp,
            deviceId: ProtocolConst.deviceId,
            mimeType: "image/jpeg",
            networkSSID: currentSSID,
            fileName: meta.fileName,
            fileSize: meta.fileSize,
            imageWidth: meta.width,
            imageHeight: meta.height,
            format: meta.format
        )
        sendWithChunking(basePayload: msg, rawData: data, onChunkSent: { [weak self] index, total in
            DispatchQueue.main.async {
                self?.sendProgress = "正在发送图片... (\(index + 1)/\(total))"
            }
        }, onComplete: { [weak self] in
            DispatchQueue.main.async {
                self?.sendProgress = "图片已发送 ✓"
                self?.isSendingContent = false
                self?.addRecord("[图片]", direction: .sent)
                // 3 秒后自动清除发送状态
                DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                    if self?.sendProgress == "图片已发送 ✓" {
                        self?.clearPendingContent()
                    }
                }
            }
        })
    }

    /// 发送暂存的文件
    private func sendPendingFile(url: URL) {
        guard let fileData = try? Data(contentsOf: url) else {
            sendProgress = "读取文件失败"
            isSendingContent = false
            return
        }

        isSendingContent = true
        let totalChunks = Int(ceil(Double(fileData.count) / Double(Self.chunkSize)))
        let chunkInfo = totalChunks > 1 ? " (共 \(totalChunks) 片)" : ""
        sendProgress = "正在发送文件\(chunkInfo)..."

        let timestamp = Date().timeIntervalSince1970
        lastSentTimestamp = timestamp
        let msg = SyncMessage(
            type: .clipboardFile,
            content: "",
            timestamp: timestamp,
            deviceId: ProtocolConst.deviceId,
            mimeType: nil,
            networkSSID: nil,
            fileName: url.lastPathComponent,
            fileSize: fileData.count
        )
        sendWithChunking(basePayload: msg, rawData: fileData, onChunkSent: { [weak self] index, total in
            DispatchQueue.main.async {
                self?.sendProgress = "正在发送文件... (\(index + 1)/\(total))"
            }
        }, onComplete: { [weak self] in
            DispatchQueue.main.async {
                self?.sendProgress = "文件已发送 ✓"
                self?.isSendingContent = false
                self?.addRecord("[文件] \(url.lastPathComponent)", direction: .sent)
                DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                    if self?.sendProgress == "文件已发送 ✓" {
                        self?.clearPendingContent()
                    }
                }
            }
        })
    }

    /// 根据当前连接模式选择发送途径：LAN 优先，中继后备
    private func sendOrBroadcast(_ msg: SyncMessage) {
        if server.connectedCount > 0 {
            server.broadcast(msg)
        } else if wsClient.isConnected {
            wsClient.sendRelay(msg)
        }
    }

    private func addRecord(_ content: String, direction: SyncRecord.Direction) {
        let record = SyncRecord(content: content, time: Date(), direction: direction)
        DispatchQueue.main.async {
            self.syncHistory.insert(record, at: 0)
            if self.syncHistory.count > 50 {
                self.syncHistory = Array(self.syncHistory.prefix(50))
            }
        }
    }

    // MARK: - 剪贴板拉取（手机亮屏请求）

    private func handleClipboardPoll() {
        print("[SyncManager] ← received clipboardPoll")
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            let pasteboard = NSPasteboard.general

            if let text = pasteboard.string(forType: .string), !text.isEmpty {
                let timestamp = Date().timeIntervalSince1970
                let msg = SyncMessage(
                    type: .clipboardText,
                    content: text,
                    timestamp: timestamp,
                    deviceId: ProtocolConst.deviceId,
                    mimeType: "text/plain"
                )
                self.sendOrBroadcast(msg)
                print("[SyncManager] clipboardPoll: sending text (\(text.count) chars)")
                return
            }

            if let tiffData = pasteboard.data(forType: .tiff),
               let bitmap = NSBitmapImageRep(data: tiffData),
               let jpegData = bitmap.representation(using: .jpeg, properties: [:]) {
                let base64 = jpegData.base64EncodedString()
                let timestamp = Date().timeIntervalSince1970
                let msg = SyncMessage(
                    type: .clipboardImage,
                    content: base64,
                    timestamp: timestamp,
                    deviceId: ProtocolConst.deviceId,
                    mimeType: "image/jpeg",
                    fileSize: jpegData.count,
                    imageWidth: bitmap.pixelsWide,
                    imageHeight: bitmap.pixelsHigh,
                    format: "jpeg"
                )
                self.sendOrBroadcast(msg)
                print("[SyncManager] clipboardPoll: sending image (\(jpegData.count) bytes)")
            }
        }
    }

    // MARK: - 分片传输

    /// 分片大小：256KB 原始数据
    private static let chunkSize = 256 * 1024
    /// 分片阈值：超过 500KB 启动分片
    private static let chunkThreshold = 500 * 1024
    /// 分片超时：30 秒
    private static let chunkTimeout: TimeInterval = 30

    /// 分片接收缓冲
    private struct TransferBuffer {
        let transferId: String
        let totalChunks: Int
        var chunks: [Int: String]  // chunkIndex → base64
        var metadata: SyncMessage   // 首片消息（含 type, mimeType, fileName 等）
        var timestamp: Date
    }

    private var transferBuffers: [String: TransferBuffer] = [:]
    private var chunkCleanupTimer: Timer?

    /// 启动分片超时清理定时器
    private func startChunkCleanup() {
        chunkCleanupTimer?.invalidate()
        chunkCleanupTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            self?.cleanupExpiredChunks()
        }
    }

    /// 清理超时的分片缓冲
    private func cleanupExpiredChunks() {
        let now = Date()
        let expired = transferBuffers.filter { now.timeIntervalSince($0.value.timestamp) > Self.chunkTimeout }
        for (id, _) in expired {
            print("[SyncManager] Chunk transfer \(id) timed out, discarded")
            transferBuffers.removeValue(forKey: id)
        }
    }

    /// 处理分片消息
    private func handleChunk(_ msg: SyncMessage) {
        guard let transferId = msg.transferId,
              let chunkIndex = msg.chunkIndex,
              let totalChunks = msg.totalChunks else {
            print("[SyncManager] Invalid chunk message, missing transferId/chunkIndex/totalChunks")
            return
        }

        // 初始化定时器（首次分片时）
        if chunkCleanupTimer == nil {
            startChunkCleanup()
        }

        var buffer = transferBuffers[transferId] ?? TransferBuffer(
            transferId: transferId,
            totalChunks: totalChunks,
            chunks: [:],
            metadata: msg,
            timestamp: Date()
        )

        // 更新首片元数据（只有首片带完整 metadata）
        if chunkIndex == 0 && msg.type != .clipboardDataChunk {
            buffer.metadata = msg
        }

        buffer.chunks[chunkIndex] = msg.content
        buffer.timestamp = Date()

        print("[SyncManager] Chunk received: \(transferId.prefix(8))... [\(chunkIndex + 1)/\(totalChunks)], collected \(buffer.chunks.count)/\(totalChunks)")

        if buffer.chunks.count == totalChunks {
            // 所有分片到齐，按序组装
            var fullBase64 = ""
            for i in 0..<totalChunks {
                guard let chunk = buffer.chunks[i] else {
                    print("[SyncManager] Missing chunk \(i) for transfer \(transferId), discarding")
                    transferBuffers.removeValue(forKey: transferId)
                    return
                }
                fullBase64 += chunk
            }

            guard let fullData = Data(base64Encoded: fullBase64) else {
                print("[SyncManager] Failed to decode assembled base64 for transfer \(transferId)")
                transferBuffers.removeValue(forKey: transferId)
                return
            }

            transferBuffers.removeValue(forKey: transferId)
            print("[SyncManager] Chunk assembly complete: \(transferId.prefix(8))..., \(fullData.count) bytes")

            // 根据原始消息类型分发
            let metadata = buffer.metadata
            switch metadata.type {
            case .clipboardImage:
                clipboard.writeImage(fullData)
                let imageFileName = metadata.fileName ?? imageFileName(for: metadata)
                let savedPath = saveReceivedData(fullData, fileName: imageFileName)
                addRecord("[图片]", direction: .received)
                sendReceivedNotification(preview: "📷 图片", filePath: savedPath)
            case .clipboardFile:
                let savedPath = saveReceivedData(fullData, fileName: metadata.fileName ?? "unknown_file")
                if let path = savedPath {
                    DispatchQueue.main.async { [weak self] in
                        self?.isProcessingRemote = true
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.writeObjects([URL(fileURLWithPath: path) as NSURL])
                        self?.isProcessingRemote = false
                    }
                }
                addRecord("[文件] \(metadata.fileName ?? "")", direction: .received)
                sendReceivedNotification(preview: "📁 \(metadata.fileName ?? "文件")", filePath: savedPath)
            default:
                print("[SyncManager] Unknown chunk base type: \(metadata.type.rawValue)")
            }
        } else {
            transferBuffers[transferId] = buffer
        }
    }

    // MARK: - 分片发送

    /// 将大数据分片发送（>500KB 自动分片，否则单条发送）
    /// - Parameters:
    ///   - onChunkSent: 每发送一个分片后回调 (当前索引, 总分片数)
    ///   - onComplete: 全部发送完成后回调
    private func sendWithChunking(basePayload: SyncMessage, rawData: Data,
                                  onChunkSent: ((Int, Int) -> Void)? = nil,
                                  onComplete: (() -> Void)? = nil) {
        guard rawData.count > Self.chunkThreshold else {
            // 不超过阈值，直接发送
            onChunkSent?(0, 1)
            sendOrBroadcast(basePayload)
            onComplete?()
            return
        }

        let transferId = UUID().uuidString
        let totalChunks = Int(ceil(Double(rawData.count) / Double(Self.chunkSize)))

        print("[SyncManager] Chunking \(rawData.count) bytes → \(totalChunks) chunks (transferId: \(transferId.prefix(8))...)")

        for i in 0..<totalChunks {
            let start = i * Self.chunkSize
            let end = min(start + Self.chunkSize, rawData.count)
            let chunk = rawData.subdata(in: start..<end)
            let base64 = chunk.base64EncodedString()

            if i == 0 {
                // 首片使用原始 type，带完整元数据
                var msg = basePayload
                msg = SyncMessage(
                    type: basePayload.type,
                    content: base64,
                    timestamp: msg.timestamp,
                    deviceId: msg.deviceId,
                    mimeType: msg.mimeType,
                    networkSSID: msg.networkSSID,
                    roomKey: msg.roomKey,
                    relayHost: msg.relayHost,
                    smsSender: msg.smsSender,
                    transferId: transferId,
                    chunkIndex: 0,
                    totalChunks: totalChunks,
                    fileName: msg.fileName,
                    fileSize: msg.fileSize,
                    imageWidth: msg.imageWidth,
                    imageHeight: msg.imageHeight,
                    format: msg.format,
                    fileCount: msg.fileCount
                )
                sendOrBroadcast(msg)
            } else {
                let chunkMsg = SyncMessage(
                    type: .clipboardDataChunk,
                    content: base64,
                    timestamp: Date().timeIntervalSince1970,
                    deviceId: ProtocolConst.deviceId,
                    mimeType: nil,
                    networkSSID: nil,
                    transferId: transferId,
                    chunkIndex: i,
                    totalChunks: totalChunks
                )
                sendOrBroadcast(chunkMsg)
            }

            onChunkSent?(i, totalChunks)

            // 最后一片发送完后触发完成回调
            if i == totalChunks - 1 {
                onComplete?()
            }
        }
    }

    /// 发送图片消息（对外接口，无进度回调的简化版）
    func sendImageMessage(_ msg: SyncMessage, rawData: Data) {
        sendWithChunking(basePayload: msg, rawData: rawData)
    }

    // MARK: - 文件接收

    /// 根据消息的 mimeType 生成合适的图片文件名
    private func imageFileName(for msg: SyncMessage) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd_HHmmss"
        let timestamp = formatter.string(from: Date())
        // 根据 mimeType 确定扩展名
        let ext: String
        if let mime = msg.mimeType?.lowercased() {
            if mime.contains("png") {
                ext = "png"
            } else if mime.contains("jpeg") || mime.contains("jpg") {
                ext = "jpeg"
            } else if mime.contains("gif") {
                ext = "gif"
            } else if mime.contains("webp") {
                ext = "webp"
            } else {
                ext = msg.format ?? "jpeg"
            }
        } else {
            ext = msg.format ?? "jpeg"
        }
        return "clipboard_\(timestamp).\(ext)"
    }

    /// 将接收到的文件数据写入磁盘（不操作剪贴板），返回保存的文件路径（nil 表示失败）
    @discardableResult
    private func saveReceivedData(_ data: Data, fileName: String) -> String? {
        let saveDir = SaveDirectoryManager.shared.currentDirectory
        try? FileManager.default.createDirectory(at: saveDir, withIntermediateDirectories: true)

        var fileURL = saveDir.appendingPathComponent(fileName)
        // 重名处理：若已存在则追加序号
        let baseName = fileURL.deletingPathExtension().lastPathComponent
        let ext = fileURL.pathExtension
        var counter = 1
        while FileManager.default.fileExists(atPath: fileURL.path) {
            let newName = ext.isEmpty ? "\(baseName) (\(counter))" : "\(baseName) (\(counter)).\(ext)"
            fileURL = saveDir.appendingPathComponent(newName)
            counter += 1
        }

        do {
            try data.write(to: fileURL)
            print("[SyncManager] File saved: \(fileURL.path)")
            return fileURL.path
        } catch {
            print("[SyncManager] Failed to write file: \(error)")
            return nil
        }
    }

    /// 收到远程内容时触发（用于菜单栏弹窗等视觉反馈）
    var onContentReceived: (() -> Void)?

    /// 最近一次接收的文件路径（用于 UI 显示操作按钮）
    @Published var lastReceivedFilePath: String?
    /// 最近一次接收的文件名
    @Published var lastReceivedFileName: String?

    // MARK: - 暂存待发（图片/文件不自动发送，需用户手动触发）
    /// 暂存的图片数据
    @Published var pendingImageData: Data?
    /// 暂存的图片元数据
    @Published var pendingImageMetadata: ClipboardImageMetadata?
    /// 暂存的文件 URL
    @Published var pendingFileURL: URL?
    /// 发送进度描述
    @Published var sendProgress: String = ""
    /// 是否正在发送中
    @Published var isSendingContent: Bool = false

    // MARK: - 系统通知

    /// 收到远端内容时发送系统通知
    /// - Parameters:
    ///   - preview: 通知正文预览
    ///   - filePath: 若为文件/图片，传入保存路径以启用「打开文件」「打开文件目录」操作按钮
    /// 是否支持系统通知
    private var supportsNotifications: Bool {
        Bundle.main.bundleIdentifier != nil
    }

    /// 收到远端内容时发送系统通知（双通道：UN 优先，NS 后备）
    private func sendReceivedNotification(preview: String, filePath: String?) {
        // 记录最近文件 + 自动弹窗
        DispatchQueue.main.async { [weak self] in
            self?.lastReceivedFilePath = filePath
            self?.lastReceivedFileName = filePath.map { URL(fileURLWithPath: $0).lastPathComponent }
            self?.onContentReceived?()
        }

        guard supportsNotifications else {
            print("[Notify] ⚠️ 跳过 (swift run)")
            return
        }

        let body = preview.count > 200 ? String(preview.prefix(200)) + "…" : preview
        let id = UUID().uuidString

        DispatchQueue.main.async {
            // === 通道 1: UNUserNotificationCenter ===
            let unContent = UNMutableNotificationContent()
            unContent.title = "ClipboardSync"
            unContent.body = body
            unContent.sound = .default
            if let path = filePath {
                unContent.userInfo = ["filePath": path]
                unContent.categoryIdentifier = NotificationCategory.fileReceived
            }
            let unRequest = UNNotificationRequest(identifier: id, content: unContent, trigger: nil)
            UNUserNotificationCenter.current().add(unRequest) { error in
                if let error {
                    print("[Notify-UN] ❌ \(error.localizedDescription)")
                } else {
                    print("[Notify-UN] ✅ \"\(body)\"")
                }
            }

            // === 通道 2: NSUserNotificationCenter（后备） ===
            let ns = NSUserNotification()
            ns.identifier = id
            ns.title = "ClipboardSync"
            ns.informativeText = body
            ns.soundName = NSUserNotificationDefaultSoundName
            if let path = filePath {
                ns.userInfo = ["filePath": path]
                ns.hasActionButton = true
                ns.actionButtonTitle = "打开文件"
                ns.otherButtonTitle = "关闭"
                ns.additionalActions = [NSUserNotificationAction(identifier: "openFolder", title: "打开目录")]
            }
            NSUserNotificationCenter.default.deliver(ns)
            print("[Notify-NS] ✅ \"\(body)\"")
        }
    }
}
