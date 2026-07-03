import { SyncManager, SyncStatus, SyncRecord, ConnectionMode, getSharedSyncManager } from '../model/SyncManager'
import { NetworkProfile } from '../model/NetworkContextManager'
import { ProtocolConst } from '../common/Protocol'
import { pasteboard } from '@kit.BasicServicesKit'
import { router } from '@kit.ArkUI'
import { SaveDirectoryManager } from '../model/SaveDirectoryManager'
import { picker } from '@kit.CoreFileKit'
import { common } from '@kit.AbilityKit'

export interface QRResultHolder {
  data: string
}

export const qrResultHolder: QRResultHolder = { data: '' }

@Entry
@Component
struct Index {
  @State syncStatus: SyncStatus = SyncStatus.DISCONNECTED
  @State connectedDevice: string = ''
  @State history: SyncRecord[] = []
  @State manualIp: string = ''
  @State profiles: NetworkProfile[] = []
  @State showRememberPrompt: boolean = false
  @State rememberSSID: string = ''
  @State rememberIP: string = ''
  @State rememberMacId: string = ''
  // 中继状态
  @State connectionMode: ConnectionMode = ConnectionMode.NONE
  @State roomKey: string = ''
  @State relayStatusText: string = ''
  @State relayPairedDeviceId: string = ''
  @State relayInputText: string = ''
  // 服务器地址编辑
  @State relayServerHost: string = ''
  @State isEditingHost: boolean = false
  @State editHostText: string = ''

  // 手动发送降级方案
  @State manualSendText: string = ''

  // 保存目录设置
  @State saveDir: string = ''

  private syncManager: SyncManager = getSharedSyncManager()

  aboutToAppear(): void {
    // 传入 Context（供后台任务 + 网络感知使用）
    const ctx = this.getUIContext().getHostContext()
    if (ctx) {
      this.syncManager.setContext(ctx)
      SaveDirectoryManager.getInstance().init(ctx)
      this.saveDir = SaveDirectoryManager.getInstance().getCurrentDirectory()
    }

    // 绑定状态变化回调
    this.syncManager.onStateChange = () => {
      this.syncStatus = this.syncManager.status
      this.connectedDevice = this.syncManager.connectedDevice
      this.history = [...this.syncManager.history]
      this.connectionMode = this.syncManager.connectionMode
      this.roomKey = this.syncManager.roomKey
      this.relayStatusText = this.syncManager.relayStatusText
      this.relayServerHost = this.syncManager.relayServerHost
      this.relayPairedDeviceId = this.syncManager.relayPairedDeviceId
    }

    // "记住此网络" 提示回调
    this.syncManager.onAskRememberNetwork = (ssid: string, macIP: string, macDeviceId: string) => {
      this.rememberSSID = ssid
      this.rememberIP = macIP
      this.rememberMacId = macDeviceId
      this.showRememberPrompt = true
    }

    // 加载已保存的网络 Profile 列表
    this.loadProfiles()

    // 自动启动同步
    this.syncManager.start()
  }

  aboutToDisappear(): void {
    this.syncManager.stop()
  }

  onPageShow(): void {
    // 处理扫码页面返回的结果
    if (qrResultHolder.data.length > 0) {
      const result = qrResultHolder.data
      qrResultHolder.data = ''
      this.handleScanResult(result)
    }
  }

  private async loadProfiles(): Promise<void> {
    try {
      this.profiles = await this.syncManager.networkManager.getAllProfiles()
    } catch (_e) {
      // ignore
    }
  }

  build() {
    Navigation() {
      Column({ space: 0 }) {
        // 顶部状态卡片
        this.StatusCard()

        Divider().margin({ top: 12, bottom: 12 })

        // 记住此网络 提示（条件显示）
        if (this.showRememberPrompt) {
          this.RememberPrompt()
          Divider().margin({ top: 12, bottom: 12 })
        }

        // 已知网络列表
        this.NetworkSection()

        Divider().margin({ top: 12, bottom: 12 })

        // 云中继配对区域
        this.RelaySection()

        Divider().margin({ top: 12, bottom: 12 })

        // 手动连接区域（备选）
        this.ManualConnectSection()

        Divider().margin({ top: 12, bottom: 12 })

        // 手动发送（降级方案，无需读剪贴板权限）
        this.ManualSendSection()

        Divider().margin({ top: 12, bottom: 12 })

        // 图片发送
        this.ImageSendSection()

        Divider().margin({ top: 12, bottom: 12 })

        // 保存目录设置
        this.SaveDirectorySection()

        Divider().margin({ top: 12, bottom: 12 })

        // 同步历史
        this.HistorySection()

        // 版本号
        Text('v' + ProtocolConst.APP_VERSION)
          .fontSize(10)
          .fontColor('#CCCCCC')
          .width('100%')
          .textAlign(TextAlign.Center)
          .margin({ top: 8 })
      }
      .width('100%')
      .height('100%')
      .padding(16)
    }
    .title('剪贴板同步')
    .titleMode(NavigationTitleMode.Mini)
  }

  // ============ 记住此网络 提示 ============

  @Builder
  RememberPrompt() {
    Column({ space: 8 }) {
      Row({ space: 4 }) {
        Image($r('sys.symbol.wifi'))
          .width(14)
          .height(14)
          .fillColor('#FF9800')
        Text('发现新网络')
          .fontSize(13)
          .fontWeight(FontWeight.Medium)
      }

      Text('在 "' + this.rememberSSID + '" 记住这台 Mac？下次自动连接 ' + this.rememberIP)
        .fontSize(12)
        .fontColor('#666666')
        .maxLines(2)

      Row({ space: 8 }) {
        Button('忽略')
          .fontSize(12)
          .height(28)
          .backgroundColor('#E0E0E0')
          .onClick(() => {
            this.showRememberPrompt = false
          })

        Button('记住')
          .fontSize(12)
          .height(28)
          .backgroundColor('#FF9800')
          .onClick(() => {
            this.showRememberPrompt = false
            const name = this.rememberSSID.length > 0 ? this.rememberSSID : '未知网络'
            this.syncManager.saveCurrentNetwork(name)
            this.loadProfiles()
          })
      }
      .width('100%')
      .justifyContent(FlexAlign.End)
    }
    .width('100%')
    .padding(12)
    .borderRadius(10)
    .backgroundColor('#FFF3E0')
  }

  // ============ 已知网络管理 ============

  @Builder
  NetworkSection() {
    Column({ space: 6 }) {
      Row({ space: 8 }) {
        Text('已知网络')
          .fontSize(13)
          .fontWeight(FontWeight.Medium)

        Blank()

        Text(this.profiles.length.toString() + ' 个')
          .fontSize(11)
          .fontColor('#999999')
      }
      .width('100%')
      .padding({ left: 12, right: 12, top: 8, bottom: 6 })

      if (this.profiles.length === 0) {
        Text('暂无已保存的网络，首次连接后提示保存')
          .fontSize(11)
          .fontColor('#CCCCCC')
          .padding({ left: 12, right: 12, bottom: 8 })
      } else {
        List({ space: 2 }) {
          ForEach(this.profiles, (profile: NetworkProfile) => {
            ListItem() {
              this.ProfileItem(profile)
            }
          }, (profile: NetworkProfile) => profile.id)
        }
        .width('100%')
        .height(160)
      }
    }
    .width('100%')
    .borderRadius(12)
    .backgroundColor('#F5F5F5')
  }

  @Builder
  ProfileItem(profile: NetworkProfile) {
    Row({ space: 8 }) {
      Column({ space: 2 }) {
        Text(profile.name)
          .fontSize(12)
          .fontWeight(FontWeight.Medium)
        Text(profile.ssid + ' · ' + profile.macIP)
          .fontSize(10)
          .fontColor('#999999')
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)

      if (profile.autoConnect) {
        Text('自动')
          .fontSize(9)
          .fontColor('#4CAF50')
          .padding({ left: 4, right: 4, top: 1, bottom: 1 })
          .border({ width: 1, color: '#4CAF50', radius: 4 })
      }

      Button('删除')
        .fontSize(10)
        .height(24)
        .backgroundColor('#FF5252')
        .onClick(() => {
          this.syncManager.forgetNetwork(profile.ssid)
          this.loadProfiles()
        })
    }
    .width('100%')
    .padding({ left: 12, right: 12, top: 6, bottom: 6 })
  }

  // ============ 云中继配对 ============

  @Builder
  RelaySection() {
    Column({ space: 8 }) {
      // 标题行
      Row({ space: 8 }) {
        Text('云中继')
          .fontSize(13)
          .fontWeight(FontWeight.Medium)
        if (this.connectionMode === ConnectionMode.RELAY && this.relayPairedDeviceId.length > 0) {
          Image($r('sys.symbol.checkmark_circle'))
            .width(12)
            .height(12)
            .fillColor('#4CAF50')
          Text('中继在线')
            .fontSize(10)
            .fontColor('#4CAF50')
        } else if (this.connectionMode === ConnectionMode.LAN) {
          Text('局域网优先')
            .fontSize(10)
            .fontColor('#999999')
        }
        Blank()
      }
      .width('100%')

      // Room Key 输入/显示
      if (this.roomKey.length === 0) {
        // 无已保存的 Room Key → 显示输入框
        Row({ space: 8 }) {
          TextInput({ placeholder: '输入 6 位配对码', text: this.relayInputText })
            .layoutWeight(1)
            .height(32)
            .fontSize(12)
            .maxLength(6)
            .type(InputType.Normal)
            .onChange((value: string) => {
              this.relayInputText = value.toUpperCase()
            })

          Button('连接中继')
            .fontSize(11)
            .height(32)
            .enabled(this.relayInputText.length === 6)
            .onClick(() => {
              if (this.relayInputText.length === 6) {
                this.syncManager.setRoomKey(this.relayInputText)
              }
            })

          Button('扫码')
            .fontSize(11)
            .height(32)
            .onClick(() => {
              this.startScan()
            })
        }
        .width('100%')
      } else {
        // 有 Room Key → 显示配对码
        Row({ space: 6 }) {
          Text('配对码:')
            .fontSize(10)
            .fontColor('#999999')
          Text(this.roomKey)
            .fontSize(16)
            .fontWeight(FontWeight.Bold)
            .fontFamily('monospace')

          Button('复制')
            .fontSize(9)
            .height(24)
            .onClick(() => {
              try {
                const pboard = pasteboard.getSystemPasteboard()
                const data = pasteboard.createData(pasteboard.MIMETYPE_TEXT_PLAIN, this.roomKey)
                pboard.setDataSync(data)
              } catch (_e) {
                // ignore
              }
            })

          Button('扫码')
            .fontSize(9)
            .height(24)
            .onClick(() => {
              this.startScan()
            })

          Blank()

          Button('清除')
            .fontSize(9)
            .height(24)
            .backgroundColor('#FF5252')
            .onClick(() => {
              this.syncManager.clearRoomKey()
              this.relayInputText = ''
            })
        }
        .width('100%')
      }

      // 中继状态文字
      if (this.relayStatusText.length > 0) {
        Text(this.relayStatusText)
          .fontSize(10)
          .fontColor('#999999')
      }

      // 服务器地址编辑行
      Row({ space: 4 }) {
        if (this.isEditingHost) {
          TextInput({ placeholder: 'IP 或域名', text: $$this.editHostText })
            .layoutWeight(1)
            .height(24)
            .fontSize(10)
          Button('确定')
            .fontSize(9)
            .height(24)
            .onClick(() => {
              this.syncManager.updateRelayHost(this.editHostText)
              this.isEditingHost = false
            })
          Button('取消')
            .fontSize(9)
            .height(24)
            .backgroundColor('#E0E0E0')
            .onClick(() => {
              this.isEditingHost = false
            })
        } else {
          Text('服务器: ' + this.relayServerHost)
            .fontSize(10)
            .fontColor('#999999')
            .maxLines(1)
          Button('修改')
            .fontSize(9)
            .height(24)
            .onClick(() => {
              this.editHostText = this.relayServerHost
              this.isEditingHost = true
            })
        }
      }
      .width('100%')
    }
    .width('100%')
    .padding(12)
    .borderRadius(10)
    .backgroundColor('#F0F8FF')
  }

  // ============ 状态卡片 ============

  @Builder
  StatusCard() {
    Column({ space: 8 }) {
      Row({ space: 8 }) {
        Circle()
          .width(10)
          .height(10)
          .fill(this.statusColor)

        Text(this.syncStatus)
          .fontSize(16)
          .fontWeight(FontWeight.Medium)

        Blank()

        if (this.connectedDevice) {
          Text(this.connectedDevice)
            .fontSize(12)
            .fontColor('#999999')
        }
      }
      .width('100%')

      if (this.syncStatus === SyncStatus.DISCOVERING) {
        Text('正在搜索局域网中的 Mac 设备...')
          .fontSize(12)
          .fontColor('#999999')
      } else if (this.syncStatus === SyncStatus.CONNECTED) {
        Row({ space: 4 }) {
          Image($r('sys.symbol.checkmark_circle'))
            .width(14)
            .height(14)
            .fillColor('#4CAF50')
          Text('已连接，剪贴板将自动同步')
            .fontSize(12)
            .fontColor('#4CAF50')
        }
      }

      // 操作按钮
      Row({ space: 12 }) {
        Button(this.syncStatus === SyncStatus.CONNECTED ? '断开' : '重新搜索')
          .fontSize(13)
          .height(32)
          .onClick(() => {
            if (this.syncStatus === SyncStatus.CONNECTED) {
              this.syncManager.stop()
            } else {
              this.syncManager.stop()
              this.syncManager.start()
            }
          })

      }
      .width('100%')
      .justifyContent(FlexAlign.End)
    }
    .width('100%')
    .padding(16)
    .borderRadius(12)
    .backgroundColor('#F5F5F5')
  }

  // ============ 手动连接 ============

  @Builder
  ManualConnectSection() {
    Column({ space: 8 }) {
      Text('手动连接')
        .fontSize(14)
        .fontWeight(FontWeight.Medium)

      Row({ space: 8 }) {
        TextInput({ placeholder: '输入 Mac 的 IP 地址', text: $$this.manualIp })
          .layoutWeight(1)
          .height(36)
          .fontSize(13)
          .type(InputType.Normal)

        Button('扫码')
          .fontSize(11)
          .height(36)
          .onClick(() => {
            this.startScan()
          })

        Button('连接')
          .fontSize(13)
          .height(36)
          .enabled(this.manualIp.length > 0)
          .onClick(() => {
            if (this.manualIp.length > 0) {
              this.syncManager.connectManual(this.manualIp)
            }
          })
      }
    }
    .width('100%')
    .padding(16)
    .borderRadius(12)
    .backgroundColor('#F5F5F5')
  }

  // ============ 手动发送（降级方案） ============

  @Builder
  ManualSendSection() {
    Column({ space: 8 }) {
      Text('手动发送（降级方案）')
        .fontSize(14)
        .fontWeight(FontWeight.Medium)

      Text('无需剪贴板读取权限，在此处粘贴文字后点"发送"即可同步到 Mac')
        .fontSize(10)
        .fontColor('#999999')
        .maxLines(2)

      Row({ space: 8 }) {
        TextInput({ placeholder: '在此处粘贴文字...', text: $$this.manualSendText })
          .layoutWeight(1)
          .height(36)
          .fontSize(13)
          .type(InputType.Normal)
          .maxLength(500)

        Button('发送')
          .fontSize(13)
          .height(36)
          .width(60)
          .enabled(this.manualSendText.length > 0)
          .onClick(() => {
            if (this.manualSendText.length > 0) {
              this.syncManager.manualSendText(this.manualSendText)
              this.manualSendText = ''
            }
          })
      }
      .width('100%')
    }
    .width('100%')
    .padding(16)
    .borderRadius(12)
    .backgroundColor('#FFF8E1')
  }

  // ============ 图片发送 ============

  @Builder
  ImageSendSection() {
    Column({ space: 8 }) {
      Text('图片发送')
        .fontSize(14)
        .fontWeight(FontWeight.Medium)

      Text('从相册或文件中选择图片，发送到 Mac 端')
        .fontSize(10)
        .fontColor('#999999')

      Button('选择图片')
        .fontSize(13)
        .height(36)
        .width(120)
        .onClick(() => {
          this.syncManager.selectAndSendImage()
        })
    }
    .width('100%')
    .padding(16)
    .borderRadius(12)
    .backgroundColor('#F5F5F5')
  }

  // ============ 保存目录设置 ============

  @Builder
  SaveDirectorySection() {
    Column({ space: 8 }) {
      Text('保存位置')
        .fontSize(14)
        .fontWeight(FontWeight.Medium)

      Row({ space: 6 }) {
        Text(this.saveDir)
          .fontSize(11)
          .fontColor('#666666')
          .maxLines(2)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .layoutWeight(1)

        Button('选择')
          .fontSize(11)
          .height(28)
          .onClick(() => {
            this.selectSaveDirectory()
          })

        Button('默认')
          .fontSize(11)
          .height(28)
          .backgroundColor('#E0E0E0')
          .onClick(() => {
            SaveDirectoryManager.getInstance().resetToDefault()
            this.saveDir = SaveDirectoryManager.getInstance().getCurrentDirectory()
          })
      }
      .width('100%')
    }
    .width('100%')
    .padding(16)
    .borderRadius(12)
    .backgroundColor('#F5F5F5')
  }

  // ============ 同步历史 ============

  @Builder
  HistorySection() {
    Column({ space: 8 }) {
      Text('同步历史')
        .fontSize(14)
        .fontWeight(FontWeight.Medium)

      if (this.history.length === 0) {
        Column({ space: 8 }) {
          Text('暂无同步记录')
            .fontSize(13)
            .fontColor('#999999')
          Text('复制文字后将自动同步到对端')
            .fontSize(11)
            .fontColor('#CCCCCC')
        }
        .width('100%')
        .height(120)
        .justifyContent(FlexAlign.Center)
      } else {
        List({ space: 4 }) {
          ForEach(this.history, (record: SyncRecord) => {
            ListItem() {
              this.HistoryItem(record)
            }
          }, (record: SyncRecord) => record.id)
        }
        .width('100%')
        .layoutWeight(1)
      }
    }
    .width('100%')
    .layoutWeight(1)
  }

  @Builder
  HistoryItem(record: SyncRecord) {
    Row({ space: 8 }) {
      Image(record.direction === 'sent' ? $r('sys.symbol.arrow_up') : $r('sys.symbol.arrow_down'))
        .width(14)
        .height(14)
        .fillColor(record.direction === 'sent' ? '#2196F3' : '#4CAF50')

      Text(record.content)
        .fontSize(13)
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .layoutWeight(1)

      Text(record.time)
        .fontSize(10)
        .fontColor('#CCCCCC')
    }
    .width('100%')
    .padding({ left: 12, right: 12, top: 8, bottom: 8 })
    .borderRadius(8)
    .backgroundColor(Color.White)
  }

  // ============ 扫码 ============

  private startScan(): void {
    qrResultHolder.data = ''
    router.pushUrl({
      url: 'pages/ScanPage'
    })
  }

  // ============ 选择保存目录 ============

  private async selectSaveDirectory(): Promise<void> {
    try {
      const ctx = this.getUIContext().getHostContext() as common.UIAbilityContext
      const options = new picker.DocumentSelectOptions()
      options.maxSelectNumber = 1
      const documentPicker = new picker.DocumentViewPicker(ctx)
      const result: string[] = await documentPicker.select(options)
      if (result.length > 0) {
        SaveDirectoryManager.getInstance().setDirectory(result[0])
        this.saveDir = result[0]
      }
    } catch (_e) {
      console.error('[Index] selectSaveDirectory failed')
    }
  }

  private handleScanResult(result: string): void {
    console.info('[Index] handleScanResult: ' + result)
    this.syncManager.processQRCode(result)
  }

  // ============ 辅助 ============

  private get statusColor(): string {
    switch (this.syncStatus) {
      case SyncStatus.CONNECTED:
        return '#4CAF50'
      case SyncStatus.DISCOVERING:
        return '#FF9800'
      case SyncStatus.DISCONNECTED:
        return '#CCCCCC'
      default:
        return '#CCCCCC'
    }
  }
}
