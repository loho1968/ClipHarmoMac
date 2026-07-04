import { UIAbility, AbilityConstant, Want, bundleManager, wantAgent, WantAgent } from '@kit.AbilityKit'
import { window } from '@kit.ArkUI'
import { backgroundTaskManager } from '@kit.BackgroundTasksKit'
import { notificationManager } from '@kit.NotificationKit'
import { getSharedSyncManager, SyncStatus, ConnectionMode } from '../model/SyncManager'
import { RelayConfig } from '../common/Protocol'

const NOTIFICATION_ID: number = 1001

export default class EntryAbility extends UIAbility {
  private isBackgroundRunning: boolean = false
  private isNotificationPublished: boolean = false

  onCreate(want: Want, launchParam: AbilityConstant.LaunchParam): void {
    console.info('[ClipboardSync] EntryAbility onCreate')
    RelayConfig.loadConfig(this.context)
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
    })
  }

  onWindowStageDestroy(): void {
    console.info('[ClipboardSync] EntryAbility onWindowStageDestroy')
  }

  onForeground(): void {
    console.info('[ClipboardSync] EntryAbility onForeground')
    this.stopBackgroundRunning()
    getSharedSyncManager().onAppForeground()
  }

  onBackground(): void {
    console.info('[ClipboardSync] EntryAbility onBackground')
    this.startBackgroundRunning()
  }

  private async startBackgroundRunning(): Promise<void> {
    const syncManager = getSharedSyncManager()
    if (syncManager.status === SyncStatus.DISCONNECTED) {
      console.info('[ClipboardSync] Sync not started, skip background running')
      return
    }
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
