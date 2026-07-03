import Foundation
import Network
import CoreWLAN

/// UDP 广播发现模块
/// 使用 BSD Socket 实现局域网设备发现
class DiscoveryService {
    private var broadcastTimer: Timer?
    private var listenerSocketFd: Int32 = -1
    private let queue = DispatchQueue(label: "com.clipboardsync.discovery")
    private var foundDevices: Set<String> = []  // 已发现设备去重
    private var tcpDiscoveryDone: Set<String> = []  // 已完成TCP发现的设备，避免重复触发

    var onDeviceFound: ((String, UInt16) -> Void)?

    func start() {
        startBSDListener()
        startBroadcasting()
    }

    func stop() {
        broadcastTimer?.invalidate()
        broadcastTimer = nil
        foundDevices.removeAll()
        tcpDiscoveryDone.removeAll()
        if listenerSocketFd >= 0 {
            close(listenerSocketFd)
            listenerSocketFd = -1
        }
    }

    // MARK: - 监听广播

    private func startBSDListener() {
        queue.async { [weak self] in
            guard let self = self else { return }

            let sock = socket(AF_INET, SOCK_DGRAM, 0)
            if sock < 0 {
                print("[Discovery] Failed to create UDP socket")
                return
            }

            var addr = sockaddr_in()
            addr.sin_family = sa_family_t(AF_INET)
            addr.sin_port = ProtocolConst.broadcastPort.bigEndian
            addr.sin_addr = in_addr(s_addr: INADDR_ANY.bigEndian)

            var reuse: Int32 = 1
            setsockopt(sock, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout.size(ofValue: reuse)))
            setsockopt(sock, SOL_SOCKET, SO_REUSEPORT, &reuse, socklen_t(MemoryLayout.size(ofValue: reuse)))

            if bind(sock, self.sockaddr_cast(&addr), socklen_t(MemoryLayout.size(ofValue: addr))) < 0 {
                print("[Discovery] Failed to bind UDP socket on port \(ProtocolConst.broadcastPort), errno: \(errno)")
                close(sock)
                return
            }

            self.listenerSocketFd = sock
            print("[Discovery] UDP listener bound on port \(ProtocolConst.broadcastPort)")

            let bufSize = 1024
            let buf = UnsafeMutablePointer<UInt8>.allocate(capacity: bufSize)
            defer { buf.deallocate() }

            while self.listenerSocketFd == sock {
                var senderAddr = sockaddr_in()
                var senderLen = socklen_t(MemoryLayout.size(ofValue: senderAddr))
                let recvLen = recvfrom(sock, buf, bufSize, 0, self.sockaddr_cast(&senderAddr), &senderLen)
                if recvLen > 0 {
                    let data = Data(bytes: buf, count: recvLen)
                    let senderIP = self.ipAddressString(from: senderAddr)
                    self.handleBroadcastData(data, senderIP: senderIP)
                }
            }
        }
    }

    private func handleBroadcastData(_ data: Data, senderIP: String) {
        guard let msg = SyncMessage.fromData(data), msg.type == .ping else { return }

        // 过滤自身广播
        if msg.deviceId == ProtocolConst.deviceId { return }

        // 去重：已发现设备不再重复回调
        let isNewDevice = !foundDevices.contains(msg.deviceId)
        if isNewDevice {
            foundDevices.insert(msg.deviceId)
            print("[Discovery] Found new device: \(msg.deviceId) at \(senderIP)")

            // 发现设备，回调通知
            DispatchQueue.main.async { [weak self] in
                self?.onDeviceFound?(msg.deviceId, ProtocolConst.wsPort)
            }
        }

        // 仅对新设备发起TCP发现（已完成的不再重复，否则会导致鸿蒙端反复重连）
        if !tcpDiscoveryDone.contains(msg.deviceId) {
            self.connectDiscoveryTCP(toIP: senderIP, deviceId: msg.deviceId)
        }
    }

    // MARK: - 发送广播

    private func startBroadcasting() {
        broadcastTimer = Timer.scheduledTimer(
            withTimeInterval: ProtocolConst.broadcastInterval,
            repeats: true
        ) { [weak self] _ in
            self?.sendBroadcast()
        }
        sendBroadcast()
    }

    /// 用于发送广播的独立队列（不能和 recvfrom 共用 queue，否则 send 被阻塞）
    private let sendQueue = DispatchQueue(label: "com.clipboardsync.discovery-send")

    private func sendBroadcast() {
        let currentSSID = CWWiFiClient.shared().interface()?.ssid()
        let msg = SyncMessage(
            type: .ping,
            content: "discover",
            timestamp: Date().timeIntervalSince1970,
            deviceId: ProtocolConst.deviceId,
            mimeType: nil,
            networkSSID: currentSSID
        )

        guard let data = msg.data else { return }

        sendQueue.async {
            let sock = socket(AF_INET, SOCK_DGRAM, 0)
            if sock < 0 {
                print("[Discovery] sendBroadcast: failed to create socket")
                return
            }
            defer { close(sock) }

            var broadcastEnable: Int32 = 1
            setsockopt(sock, SOL_SOCKET, SO_BROADCAST, &broadcastEnable, socklen_t(MemoryLayout.size(ofValue: broadcastEnable)))

            var addr = sockaddr_in()
            addr.sin_family = sa_family_t(AF_INET)
            addr.sin_port = ProtocolConst.broadcastPort.bigEndian
            addr.sin_addr = in_addr(s_addr: INADDR_BROADCAST.bigEndian)

            let sent = data.withUnsafeBytes { rawBufferPointer -> Int in
                if let baseAddress = rawBufferPointer.baseAddress {
                    return sendto(sock, baseAddress, data.count, 0,
                                  self.sockaddr_cast(&addr),
                                  socklen_t(MemoryLayout.size(ofValue: addr)))
                }
                return -1
            }
            if sent < 0 {
                print("[Discovery] sendBroadcast failed, errno: \(errno)")
            }
        }
    }

    // MARK: - TCP 发现连接

    /// TCP连接鸿蒙端的发现服务端口19878，让鸿蒙端从连接中获取Mac的IP
    private func connectDiscoveryTCP(toIP: String, deviceId: String) {
        // 标记该设备的TCP发现已完成，后续UDP广播不再重复触发
        tcpDiscoveryDone.insert(deviceId)
        // 注意：不能用 self.queue，因为 queue 被 startBSDListener 的 recvfrom while 循环阻塞
        let tcpQueue = DispatchQueue(label: "com.clipboardsync.discovery-tcp")

        let connection = NWConnection(
            host: NWEndpoint.Host(toIP),
            port: NWEndpoint.Port(rawValue: ProtocolConst.discoveryTcpPort)!,
            using: .tcp
        )

        connection.stateUpdateHandler = { state in
            switch state {
            case .ready:
                print("[Discovery] TCP discovery connected to \(toIP):\(ProtocolConst.discoveryTcpPort)")
                // 连接成功后立即关闭，鸿蒙端已从连接获取到Mac IP
                connection.cancel()
            case .failed(let error):
                print("[Discovery] TCP discovery failed to \(toIP): \(error)")
                connection.cancel()
            case .cancelled:
                break
            default:
                break
            }
        }

        connection.start(queue: tcpQueue)
    }

    // MARK: - Helper

    private func sockaddr_cast(_ ptr: UnsafeMutablePointer<sockaddr_in>) -> UnsafeMutablePointer<sockaddr> {
        ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { $0 }
    }

    /// 从 sockaddr_in 提取 IP 地址字符串
    private func ipAddressString(from addr: sockaddr_in) -> String {
        var addrCopy = addr
        let buffer = UnsafeMutablePointer<CChar>.allocate(capacity: Int(INET_ADDRSTRLEN))
        inet_ntop(AF_INET, &addrCopy.sin_addr, buffer, socklen_t(INET_ADDRSTRLEN))
        let ipString = String(cString: buffer)
        buffer.deallocate()
        return ipString
    }
}