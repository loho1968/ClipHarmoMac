import { UIAbility, AbilityConstant, Want, bundleManager, wantAgent, WantAgent, abilityAccessCtrl, Permissions, PermissionRequestResult } from '@kit.AbilityKit'
import { BusinessError } from '@kit.BasicServicesKit'
import { window } from '@kit.ArkUI'
import { backgroundTaskManager } from '@kit.BackgroundTasksKit'
import { notificationManager } from '@kit.NotificationKit'
import { getSharedSyncManager, SyncStatus, ConnectionMode } from '../model/SyncManager'
import { RelayConfig, ProtocolConst } from '../common/Protocol'
import { hilog } from '@kit.PerformanceAnalysisKit'

const NOTIFICATION_ID: number = 1001
const TAG: string = 'ClipHarmoMac'
const DOMAIN: number = 0x0000

export default class EntryAbility extends UIAbility {
  private isBackgroundRunning: boolean = false
  private isNotificationPublished: boolean = false
  private clipboardPermissionRequested: boolean = false

  // READ_PASTEBOARD 为受限 user_grant 权限：module.json5 已声明 + profile(AGC) 已下发后，
  // 在此向用户弹窗申请一次。授权后程序化 getData() 才可读到剪贴板（否则静默返回空，自动推送不可用）。
  private requestClipboardPermission(): void {
    if (this.clipboardPermissionRequested) {
      return
    }
    this.clipboardPermissionRequested = true
    const atManager = abilityAccessCtrl.createAtManager()
    const permission: Permissions = 'ohos.permission.READ_PASTEBOARD'
    try {
      const granted: abilityAccessCtrl.GrantStatus =
        atManager.checkAccessTokenSync(this.context.applicationInfo.accessTokenId, permission)
      if (granted === abilityAccessCtrl.GrantStatus.PERMISSION_GRANTED) {
        console.info('[ClipboardSync] READ_PASTEBOARD already granted')
        return
      }
    } catch (e) {
      console.error('[ClipboardSync] checkAccessTokenSync error: ' + JSON.stringify(e))
    }
    atManager.requestPermissionsFromUser(this.context, [permission],
      (err: BusinessError, data: PermissionRequestResult) => {
        if (err) {
          console.error('[ClipboardSync] request READ_PASTEBOARD fail: ' + err.message)
          this.clipboardPermissionRequested = false // 允许下次再申请
          return
        }
        const granted: boolean = data.authResults.length > 0 && data.authResults[0] === 0
        console.info('[ClipboardSync] READ_PASTEBOARD request result granted=' + granted)
      })
  }

  onCreate(want: Want, launchParam: AbilityConstant.LaunchParam): void {
    console.info('[ClipboardSync] EntryAbility onCreate')
    RelayConfig.loadConfig(this.context)
    // 设备唯一标识：首次生成后持久化（必须早于任何网络连接建立）
    ProtocolConst.loadDeviceId(this.context)
    this.handleIncomingWant(want)
  }

  onNewWant(want: Want, launchParam: AbilityConstant.LaunchParam): void {
    console.info('[ClipboardSync] EntryAbility onNewWant')
    this.handleIncomingWant(want)
  }

  private handleIncomingWant(want: Want): void {
    if (!want || want.action !== 'ohos.want.action.sendData') {
      return
    }
    console.info('[ClipboardSync] Received share want, forwarding to SyncManager')
    getSharedSyncManager().handleSharedContent(want)
  }

  onDestroy(): void {
    console.info('[ClipboardSync] EntryAbility onDestroy')
  }

  onWindowStageCreate(windowStage: window.WindowStage): void {
    console.info('[ClipboardSync] EntryAbility onWindowStageCreate')

    windowStage.loadContent('pages/Index', (err) => {
      if (err.code) {
        console.error('[ClipboardSync] Failed to load content: ' + JSON.stringify(err))
        return
      }
      console.info('[ClipboardSync] Loaded content successfully')
      // 等 UI 就绪后再弹权限申请，避免弹窗时机过早
      setTimeout(() => {
        this.requestClipboardPermission()
      }, 500)
    })
  }

  onWindowStageDestroy(): void {
    console.info('[ClipboardSync] EntryAbility onWindowStageDestroy')
  }

  onForeground(): void {
    hilog.error(DOMAIN, TAG, `[LC] ▶️ EntryAbility onForeground at ${new Date().toLocaleTimeString()}`)
    console.info('[ClipboardSync] ▶️ onForeground at ' + new Date().toLocaleTimeString())
    getSharedSyncManager().onAppForeground()
  }

  onBackground(): void {
    hilog.error(DOMAIN, TAG, `[LC] ⏸️ EntryAbility onBackground at ${new Date().toLocaleTimeString()}`)
    console.info('[ClipboardSync] ⏸️ onBackground at ' + new Date().toLocaleTimeString())
    void this.startBackgroundRunning()
  }

  private async startBackgroundRunning(): Promise<void> {
    if (this.isBackgroundRunning) {
      return
    }

    try {
      const bundleInfo = bundleManager.getBundleInfoForSelfSync(
        bundleManager.BundleFlag.GET_BUNDLE_INFO_WITH_APPLICATION
      )

      const wantAgentInfo: wantAgent.WantAgentInfo = {
        wants: [{
          bundleName: bundleInfo.name,
          abilityName: 'EntryAbility'
        }],
        actionType: wantAgent.OperationType.START_ABILITY,
        requestCode: 0,
        actionFlags: [wantAgent.WantAgentFlags.UPDATE_PRESENT_FLAG]
      }

      const agent: WantAgent = await wantAgent.getWantAgent(wantAgentInfo)

      await backgroundTaskManager.startBackgroundRunning(
        this.context,
        backgroundTaskManager.BackgroundMode.MULTI_DEVICE_CONNECTION,
        agent
      )

      this.isBackgroundRunning = true
      console.info('[ClipboardSync] Background running started (MULTI_DEVICE_CONNECTION)')

      await this.publishNotification(agent)
    } catch (err) {
      console.error('[ClipboardSync] startBackgroundRunning failed: ' + JSON.stringify(err))
    }
  }

  private async stopBackgroundRunning(): Promise<void> {
    await this.cancelNotification()

    if (!this.isBackgroundRunning) {
      return
    }

    try {
      await backgroundTaskManager.stopBackgroundRunning(this.context)
      this.isBackgroundRunning = false
      console.info('[ClipboardSync] Background running stopped')
    } catch (err) {
      console.error('[ClipboardSync] stopBackgroundRunning failed: ' + JSON.stringify(err))
    }
  }

  private async publishNotification(agent: WantAgent): Promise<void> {
    try {
      const syncManager = getSharedSyncManager()
      let modeText: string = '未知'
      if (syncManager.connectionMode === ConnectionMode.LAN) {
        modeText = '局域网'
      } else if (syncManager.connectionMode === ConnectionMode.RELAY) {
        modeText = '云中继'
      }

      const request: notificationManager.NotificationRequest = {
        id: NOTIFICATION_ID,
        content: {
          notificationContentType: notificationManager.ContentType
            .NOTIFICATION_CONTENT_BASIC_TEXT,
          normal: {
            title: 'ClipboardSync',
            text: '剪贴板同步正在运行 · ' + modeText
          }
        },
        isOngoing: true,
        wantAgent: agent
      }

      await notificationManager.publish(request)
      this.isNotificationPublished = true
      console.info('[ClipboardSync] Notification published')
    } catch (err) {
      console.error('[ClipboardSync] publishNotification failed: ' + JSON.stringify(err))
    }
  }

  private async cancelNotification(): Promise<void> {
    if (!this.isNotificationPublished) {
      return
    }

    try {
      await notificationManager.cancel(NOTIFICATION_ID)
      this.isNotificationPublished = false
      console.info('[ClipboardSync] Notification cancelled')
    } catch (err) {
      console.error('[ClipboardSync] cancelNotification failed: ' + JSON.stringify(err))
    }
  }
}
