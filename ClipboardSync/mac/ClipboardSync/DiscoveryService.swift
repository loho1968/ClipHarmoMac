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

    /// 发现设备回调：deviceId, senderIP, port
    var onDeviceFound: ((String, String, UInt16) -> Void)?

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
        for sock in broadcastSocks {
            close(sock)
        }
        broadcastSocks.removeAll()
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

        print("[Discovery] Received ping from \(senderIP), deviceId=\(msg.deviceId)")

        // 过滤自身广播
        if msg.deviceId == ProtocolConst.deviceId {
            print("[Discovery] Ignoring own broadcast")
            return
        }

        // 去重：已发现设备不再重复回调
        let isNewDevice = !foundDevices.contains(msg.deviceId)
        if isNewDevice {
            foundDevices.insert(msg.deviceId)
            print("[Discovery] Found new device: \(msg.deviceId) at \(senderIP)")

            // 发现设备，回调通知（含 IP 地址，供 SyncManager 映射设备名）
            DispatchQueue.main.async { [weak self] in
                self?.onDeviceFound?(msg.deviceId, senderIP, ProtocolConst.wsPort)
            }
        }

        // 仅对新设备发起TCP发现（已完成的不再重复，否则会导致鸿蒙端反复重连）
        if !tcpDiscoveryDone.contains(msg.deviceId) {
            self.connectDiscoveryTCP(toIP: senderIP, deviceId: msg.deviceId)
        }
    }

    // MARK: - 发送广播

    /// 所有活跃接口的广播发送 socket（多网卡场景下每个接口一个）
    private var broadcastSocks: [Int32] = []

    private func startBroadcasting() {
        // 为所有活跃网络接口创建广播发送 socket
        createBroadcastSockets()

        broadcastTimer = Timer.scheduledTimer(
            withTimeInterval: ProtocolConst.broadcastInterval,
            repeats: true
        ) { [weak self] _ in
            self?.sendBroadcast()
        }
        sendBroadcast()
    }

    /// 获取所有活跃的非回环 IPv4 接口地址
    /// 返回 (接口名称, IP 地址字符串) 列表
    private func activeInterfaceAddresses() -> [(String, String)] {
        var result: [(String, String)] = []
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let first = ifaddr else { return result }
        defer { freeifaddrs(ifaddr) }

        for ptr in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let flags = Int32(ptr.pointee.ifa_flags)
            // 仅活跃、非回环接口
            guard (flags & IFF_UP) != 0 && (flags & IFF_RUNNING) != 0 else { continue }
            guard (flags & IFF_LOOPBACK) == 0 else { continue }
            guard let sa = ptr.pointee.ifa_addr else { continue }
            guard sa.pointee.sa_family == sa_family_t(AF_INET) else { continue }

            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            getnameinfo(ptr.pointee.ifa_addr, socklen_t(sa.pointee.sa_len),
                       &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST)
            let ip = String(cString: host)
            let name = String(cString: ptr.pointee.ifa_name)
            result.append((name, ip))
        }
        return result
    }

    /// 为每个活跃网络接口创建一个绑定到该接口 IP 的广播 socket
    private func createBroadcastSockets() {
        let interfaces = activeInterfaceAddresses()
        if interfaces.isEmpty {
            print("[Discovery] No active interfaces found, falling back to INADDR_ANY")
            createFallbackSocket()
            return
        }

        for (ifName, ip) in interfaces {
            let sock = socket(AF_INET, SOCK_DGRAM, 0)
            if sock < 0 {
                print("[Discovery] Failed to create socket for \(ifName) (\(ip))")
                continue
            }

            var broadcastEnable: Int32 = 1
            setsockopt(sock, SOL_SOCKET, SO_BROADCAST, &broadcastEnable,
                       socklen_t(MemoryLayout.size(ofValue: broadcastEnable)))

            var reuse: Int32 = 1
            setsockopt(sock, SOL_SOCKET, SO_REUSEADDR, &reuse,
                       socklen_t(MemoryLayout.size(ofValue: reuse)))
            setsockopt(sock, SOL_SOCKET, SO_REUSEPORT, &reuse,
                       socklen_t(MemoryLayout.size(ofValue: reuse)))

            // 绑定到该接口的 IP 地址，确保广播从该接口发出
            var bindAddr = sockaddr_in()
            bindAddr.sin_family = sa_family_t(AF_INET)
            bindAddr.sin_port = ProtocolConst.broadcastPort.bigEndian
            inet_pton(AF_INET, ip, &bindAddr.sin_addr)

            if bind(sock, sockaddr_cast(&bindAddr), socklen_t(MemoryLayout.size(ofValue: bindAddr))) < 0 {
                print("[Discovery] Bind failed for \(ifName) (\(ip)), errno: \(errno)")
                close(sock)
                continue
            }

            broadcastSocks.append(sock)
            print("[Discovery] Broadcast socket created: \(ifName) (\(ip)), fd=\(sock)")
        }

        // 如果所有接口绑定都失败，回退到 INADDR_ANY
        if broadcastSocks.isEmpty {
            print("[Discovery] All interface binds failed, falling back to INADDR_ANY")
            createFallbackSocket()
        }
    }

    /// 回退方案：创建一个绑定到 INADDR_ANY 的 socket（兼容旧行为）
    private func createFallbackSocket() {
        let sock = socket(AF_INET, SOCK_DGRAM, 0)
        if sock < 0 {
            print("[Discovery] Fallback socket creation failed")
            return
        }

        var broadcastEnable: Int32 = 1
        setsockopt(sock, SOL_SOCKET, SO_BROADCAST, &broadcastEnable,
                   socklen_t(MemoryLayout.size(ofValue: broadcastEnable)))
        var reuse: Int32 = 1
        setsockopt(sock, SOL_SOCKET, SO_REUSEADDR, &reuse,
                   socklen_t(MemoryLayout.size(ofValue: reuse)))
        setsockopt(sock, SOL_SOCKET, SO_REUSEPORT, &reuse,
                   socklen_t(MemoryLayout.size(ofValue: reuse)))

        var bindAddr = sockaddr_in()
        bindAddr.sin_family = sa_family_t(AF_INET)
        bindAddr.sin_port = ProtocolConst.broadcastPort.bigEndian
        bindAddr.sin_addr = in_addr(s_addr: INADDR_ANY.bigEndian)

        if bind(sock, sockaddr_cast(&bindAddr), socklen_t(MemoryLayout.size(ofValue: bindAddr))) < 0 {
            print("[Discovery] Fallback bind failed, errno: \(errno)")
            close(sock)
            return
        }

        broadcastSocks.append(sock)
        print("[Discovery] Fallback broadcast socket created (INADDR_ANY), fd=\(sock)")
    }

    /// 用于发送广播的独立队列（不能和 recvfrom 共用 queue，否则 send 被阻塞）
    private let sendQueue = DispatchQueue(label: "com.clipboardsync.discovery-send")

    private func sendBroadcast() {
        guard !broadcastSocks.isEmpty else { return }

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

        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = ProtocolConst.broadcastPort.bigEndian
        addr.sin_addr = in_addr(s_addr: INADDR_BROADCAST.bigEndian)

        // 通过每个接口的 socket 分别发送广播
        for sock in broadcastSocks {
            let sent = data.withUnsafeBytes { rawBufferPointer -> Int in
                if let baseAddress = rawBufferPointer.baseAddress {
                    return sendto(sock, baseAddress, data.count, 0,
                                  sockaddr_cast(&addr),
                                  socklen_t(MemoryLayout.size(ofValue: addr)))
                }
                return -1
            }
            if sent < 0 {
                print("[Discovery] sendBroadcast on fd=\(sock) failed, errno: \(errno)")
            }
        }
        print("[Discovery] Broadcast sent via \(broadcastSocks.count) interface(s), deviceId=\(ProtocolConst.deviceId)")
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