import { UIAbility, AbilityConstant, Want, bundleManager, wantAgent, WantAgent } from '@kit.AbilityKit'
import { window } from '@kit.ArkUI'
import { backgroundTaskManager } from '@kit.BackgroundTasksKit'
import { getSharedSyncManager, SyncStatus } from '../model/SyncManager'
import { RelayConfig } from '../common/Protocol'

export default class EntryAbility extends UIAbility {
  private isBackgroundRunning: boolean = false

  onCreate(want: Want, launchParam: AbilityConstant.LaunchParam): void {
    console.info('[ClipboardSync] EntryAbility onCreate')
    // 预加载中继服务器配置（从 rawfile/relay_config.json）
    RelayConfig.loadConfig(this.context)
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
        backgroundTaskManager.BackgroundMode.DATA_TRANSFER,
        agent
      )

      this.isBackgroundRunning = true
      console.info('[ClipboardSync] Background running started (DATA_TRANSFER)')
    } catch (err) {
      console.error('[ClipboardSync] startBackgroundRunning failed: ' + JSON.stringify(err))
    }
  }

  private async stopBackgroundRunning(): Promise<void> {
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
}
