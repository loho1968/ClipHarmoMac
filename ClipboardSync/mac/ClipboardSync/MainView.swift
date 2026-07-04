import SwiftUI

struct MainView: View {
    @ObservedObject var syncManager: SyncManager
    @State private var isEditingHost: Bool = false
    @State private var editHostText: String = ""
    @State private var showQRCode: Bool = false
    @State private var showLANQRCode: Bool = false

    var body: some View {
        VStack(spacing: 0) {
            // 顶部状态卡片
            statusCard

            Divider()

            // 云中继配对卡片
            relayCard

            Divider()

            // 同步历史
            if syncManager.syncHistory.isEmpty {
                emptyView
            } else {
                historySection
            }
        }
        .frame(width: 340, height: 520)

        // 底部版本号
        HStack {
            Spacer()
            Text("v\(ProtocolConst.appVersion)")
                .font(.system(size: 9))
                .foregroundColor(Color(nsColor: .tertiaryLabelColor))
            Spacer()
        }
        .padding(.bottom, 6)
    }

    // MARK: - 状态卡片

    private var statusCard: some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                // 状态指示灯
                ZStack {
                    Circle()
                        .fill(statusColor.opacity(0.2))
                        .frame(width: 28, height: 28)
                    Circle()
                        .fill(statusColor)
                        .frame(width: 12, height: 12)
                }

                // 状态文字
                VStack(alignment: .leading, spacing: 2) {
                    Text(syncManager.status.rawValue)
                        .font(.system(size: 14, weight: .semibold))

                    if syncManager.status == .connected {
                        Text("剪贴板将自动同步")
                            .font(.system(size: 11))
                            .foregroundColor(.green)
                    } else if syncManager.status == .discovering {
                        Text("搜索局域网中的设备...")
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                    } else {
                        Text("点击刷新重新搜索")
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                    }
                }

                Spacer()

                // 连接的设备信息
                if let device = syncManager.connectedDevice {
                    VStack(alignment: .trailing, spacing: 2) {
                        Image(systemName: "iphone.and.arrow.forward")
                            .font(.system(size: 16))
                            .foregroundColor(.green)
                        Text(device)
                            .font(.system(size: 9))
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                    }
                }
            }

            // 操作按钮行
            HStack {
                if let lastSync = syncManager.lastSyncTime {
                    HStack(spacing: 4) {
                        Image(systemName: "clock")
                            .font(.system(size: 9))
                        Text("最近同步: \(lastSync, style: .time)")
                            .font(.system(size: 10))
                    }
                    .foregroundColor(.secondary)
                }

                Spacer()

                // IP 二维码按钮（始终可见，不同子网时手机扫码直连）
                Button(action: {
                    showLANQRCode = true
                }) {
                    HStack(spacing: 4) {
                        Image(systemName: "qrcode")
                            .font(.system(size: 10))
                        Text("本机IP")
                            .font(.system(size: 11))
                    }
                }
                .buttonStyle(.plain)
                .foregroundColor(.accentColor)
                .help("显示本机 IP 二维码，手机扫码即可直连")
                .popover(isPresented: $showLANQRCode, arrowEdge: .bottom) {
                    lanQRPopover
                }

                Button(action: {
                    syncManager.stop()
                    syncManager.start()
                }) {
                    HStack(spacing: 4) {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 10))
                        Text("刷新")
                            .font(.system(size: 11))
                    }
                }
                .buttonStyle(.plain)
                .foregroundColor(.accentColor)

                if syncManager.status == .connected {
                    Button(action: {
                        syncManager.stop()
                    }) {
                        HStack(spacing: 4) {
                            Image(systemName: "xmark")
                                .font(.system(size: 10))
                            Text("断开")
                                .font(.system(size: 11))
                        }
                    }
                    .buttonStyle(.plain)
                    .foregroundColor(.red)
                }
            }

            // 开机自启开关
            Divider()
            HStack {
                Image(systemName: "power")
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
                Text("开机自启")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                Spacer()
                Toggle("", isOn: $syncManager.launchAtLogin)
                    .toggleStyle(.switch)
                    .scaleEffect(0.75)
                    .frame(width: 36)
            }

            // 最近接收文件操作
            if let filePath = syncManager.lastReceivedFilePath {
                Divider()
                VStack(spacing: 4) {
                    HStack {
                        Image(systemName: "doc")
                            .font(.system(size: 9))
                            .foregroundColor(.blue)
                        Text(syncManager.lastReceivedFileName ?? "文件")
                            .font(.system(size: 10))
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer()
                    }
                    HStack(spacing: 6) {
                        Button("打开文件") {
                            NSWorkspace.shared.open(URL(fileURLWithPath: filePath))
                        }
                        .buttonStyle(.plain)
                        .font(.system(size: 10))
                        .foregroundColor(.accentColor)

                        Button("在访达中显示") {
                            let dirPath = (filePath as NSString).deletingLastPathComponent
                            NSWorkspace.shared.selectFile(filePath, inFileViewerRootedAtPath: dirPath)
                        }
                        .buttonStyle(.plain)
                        .font(.system(size: 10))
                        .foregroundColor(.accentColor)

                        Spacer()

                        Button("✕") {
                            syncManager.lastReceivedFilePath = nil
                        }
                        .buttonStyle(.plain)
                        .font(.system(size: 9))
                        .foregroundColor(.secondary)
                    }
                }
                .padding(.vertical, 2)
            }

            // 保存目录设置
            Divider()
            HStack {
                Image(systemName: "folder")
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
                Text("保存位置")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                Spacer()
                Text(saveDirectoryDisplayName)
                    .font(.system(size: 9))
                    .foregroundColor(Color(nsColor: .tertiaryLabelColor))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Menu {
                    Button("选择目录...") {
                        SaveDirectoryManager.shared.promptChooseDirectory { _ in }
                    }
                    if SaveDirectoryManager.shared.hasCustomDirectory {
                        Button("恢复默认目录") {
                            SaveDirectoryManager.shared.resetToDefault()
                        }
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .font(.system(size: 10))
                }
                .buttonStyle(.plain)
                .foregroundColor(.accentColor)
            }

            // 退出按钮
            Divider()
            Button(action: {
                NSApplication.shared.terminate(nil)
            }) {
                HStack(spacing: 4) {
                    Image(systemName: "rectangle.portrait.and.arrow.right")
                        .font(.system(size: 10))
                    Text("退出")
                        .font(.system(size: 11))
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 4)
            }
            .buttonStyle(.plain)
            .foregroundColor(.red)
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
        .padding(.horizontal, 12)
        .padding(.top, 12)
    }

    // MARK: - 云中继卡片

    private var relayCard: some View {
        VStack(spacing: 6) {
            // 标题行
            HStack(spacing: 6) {
                Image(systemName: "cloud")
                    .font(.system(size: 10))
                    .foregroundColor(.blue)
                Text("云中继")
                    .font(.system(size: 12, weight: .medium))
                Spacer()
                relayModeIndicator
            }

            // Room Key 行
            HStack(spacing: 6) {
                Text("配对码:")
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
                Text(syncManager.roomKey.isEmpty ? "生成中..." : syncManager.roomKey)
                    .font(.system(size: 14, weight: .bold, design: .monospaced))
                    .foregroundColor(syncManager.roomKey.isEmpty ? .secondary : .primary)

                if !syncManager.roomKey.isEmpty {
                    Button(action: {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(syncManager.roomKey, forType: .string)
                    }) {
                        Image(systemName: "doc.on.doc")
                            .font(.system(size: 10))
                    }
                    .buttonStyle(.plain)
                    .foregroundColor(.accentColor)
                    .help("复制配对码")

                    Button(action: {
                        showQRCode = true
                    }) {
                        Image(systemName: "qrcode")
                            .font(.system(size: 10))
                    }
                    .buttonStyle(.plain)
                    .foregroundColor(.accentColor)
                    .help("显示配对二维码")
                    .popover(isPresented: $showQRCode, arrowEdge: .bottom) {
                        qrCodePopover
                    }
                }

                Spacer()

                Button(action: {
                    syncManager.regenerateRoomKey()
                }) {
                    Image(systemName: "arrow.triangle.2.circlepath")
                        .font(.system(size: 10))
                }
                .buttonStyle(.plain)
                .foregroundColor(.secondary)
                .help("重新生成配对码")
            }

            // 服务器地址编辑行
            HStack(spacing: 4) {
                Image(systemName: "server.rack")
                    .font(.system(size: 9))
                    .foregroundColor(.secondary)
                if isEditingHost {
                    TextField("IP 或域名", text: $editHostText)
                        .textFieldStyle(.plain)
                        .font(.system(size: 11))
                        .onSubmit {
                            syncManager.updateRelayHost(editHostText)
                            isEditingHost = false
                        }
                    Button("确定") {
                        syncManager.updateRelayHost(editHostText)
                        isEditingHost = false
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 10))
                    .foregroundColor(.accentColor)
                    Button("取消") {
                        isEditingHost = false
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
                } else {
                    Text(syncManager.relayServerHost)
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                    Button(action: {
                        editHostText = syncManager.relayServerHost
                        isEditingHost = true
                    }) {
                        Image(systemName: "pencil")
                            .font(.system(size: 8))
                    }
                    .buttonStyle(.plain)
                    .foregroundColor(.secondary)
                }
            }

            // 中继状态文字
            if !syncManager.relayStatusText.isEmpty {
                Text(syncManager.relayStatusText)
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
        .padding(.horizontal, 12)
        .padding(.top, 6)
    }

    @ViewBuilder
    private var relayModeIndicator: some View {
        if syncManager.connectionMode == .relay {
            HStack(spacing: 4) {
                Circle()
                    .fill(Color.green)
                    .frame(width: 6, height: 6)
                Text("中继在线")
                    .font(.system(size: 10))
                    .foregroundColor(.green)
            }
        } else if syncManager.connectionMode == .lan {
            HStack(spacing: 4) {
                Text("局域网优先")
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
            }
        }
    }

    // MARK: - 二维码弹窗

    private var qrCodePopover: some View {
        let qrString = syncManager.qrCodeData()
        let qrImage = QRCodeGenerator.generate(from: qrString, size: 180)

        return VStack(spacing: 10) {
            Text("扫描完成配对")
                .font(.system(size: 12, weight: .medium))

            if let image = qrImage {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.none)
                    .frame(width: 180, height: 180)
            } else {
                Text("二维码生成失败")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                    .frame(width: 180, height: 180)
            }

            Text("配对码: \(syncManager.roomKey)")
                .font(.system(size: 10, design: .monospaced))
                .foregroundColor(.secondary)

            Text("服务器: \(syncManager.relayServerHost)")
                .font(.system(size: 9))
                .foregroundColor(Color(nsColor: .tertiaryLabelColor))
        }
        .padding(16)
        .frame(width: 220)
    }

    private var lanQRPopover: some View {
        let qrString = syncManager.lanQRCodeData()
        let qrImage = QRCodeGenerator.generate(from: qrString, size: 180)

        return VStack(spacing: 10) {
            Text("局域网直连")
                .font(.system(size: 12, weight: .medium))

            if let image = qrImage {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.none)
                    .frame(width: 180, height: 180)
            } else {
                Text("二维码生成失败")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                    .frame(width: 180, height: 180)
            }

            if let ip = SyncManager.getLocalIPAddress() {
                Text("本机 IP: \(ip)")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(.secondary)
            } else {
                Text("未获取到局域网 IP")
                    .font(.system(size: 11))
                    .foregroundColor(.orange)
            }

            Text("手机扫码后自动 TCP 直连")
                .font(.system(size: 9))
                .foregroundColor(Color(nsColor: .tertiaryLabelColor))
        }
        .padding(16)
        .frame(width: 220)
    }

    private var statusColor: Color {
        switch syncManager.status {
        case .connected: return .green
        case .discovering: return .orange
        case .disconnected: return .gray
        }
    }

    /// 保存目录的简短显示名称
    private var saveDirectoryDisplayName: String {
        let dir = SaveDirectoryManager.shared.currentDirectory
        return dir.lastPathComponent
    }

    // MARK: - 空状态

    private var emptyView: some View {
        VStack(spacing: 12) {
            Spacer()
            Image(systemName: "arrow.left.arrow.right.clipboard")
                .font(.system(size: 36))
                .foregroundColor(.secondary.opacity(0.5))
            Text("暂无同步记录")
                .font(.system(size: 14))
                .foregroundColor(.secondary)
            Text("复制文字后将自动同步到对端设备")
                .font(.system(size: 11))
                .foregroundColor(Color(nsColor: .tertiaryLabelColor))
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - 同步历史

    private var historySection: some View {
        VStack(spacing: 0) {
            // 标题栏
            HStack {
                Text("同步历史")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(.secondary)
                Spacer()
                Text("\(syncManager.syncHistory.count) 条")
                    .font(.system(size: 10))
                    .foregroundColor(Color(nsColor: .tertiaryLabelColor))
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)
            .padding(.bottom, 4)

            // 列表
            List(syncManager.syncHistory) { record in
                HStack(spacing: 8) {
                    // 方向图标
                    ZStack {
                        Circle()
                            .fill(record.direction == .sent ? Color.blue.opacity(0.1) : Color.green.opacity(0.1))
                            .frame(width: 24, height: 24)
                        Image(systemName: record.direction == .sent ? "arrow.up" : "arrow.down")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundColor(record.direction == .sent ? .blue : .green)
                    }

                    // 内容
                    VStack(alignment: .leading, spacing: 1) {
                        Text(record.content)
                            .font(.system(size: 12))
                            .lineLimit(2)

                        Text(record.direction == .sent ? "发送到手机" : "从手机接收")
                            .font(.system(size: 9))
                            .foregroundColor(Color(nsColor: .tertiaryLabelColor))
                    }

                    Spacer()

                    // 时间
                    Text(record.time, style: .time)
                        .font(.system(size: 10))
                        .foregroundColor(Color(nsColor: .tertiaryLabelColor))
                }
                .padding(.vertical, 3)
            }
            .listStyle(.plain)
        }
    }
}
