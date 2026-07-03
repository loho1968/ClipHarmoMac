import { wifiManager } from '@kit.ConnectivityKit'
import { preferences } from '@kit.ArkData'

// 网络位置配置
export interface NetworkProfile {
  id: string
  name: string
  ssid: string
  bssid: string
  macIP: string
  autoConnect: boolean
  createdAt: number
  lastSeen: number
  // 双 Mac 场景：该网络对应的 Mac 的配对码和中继服务器
  roomKey?: string
  relayHost?: string
}

// WiFi 网络变更事件
export interface NetworkChangeEvent {
  ssid: string
  bssid: string
  isConnected: boolean
}

/**
 * 网络环境管理器
 * 监听 WiFi 切换，匹配已知 Profile，自动触发连接
 */
export class NetworkContextManager {
  private store: preferences.Preferences | null = null
  private isMonitoring: boolean = false
  private currentSSID: string = ''

  // 匹配到已知网络时回调
  onNetworkMatched?: (profile: NetworkProfile) => void
  // WiFi 断开时回调
  onNetworkLost?: () => void

  async init(context: Context): Promise<void> {
    try {
      this.store = preferences.getPreferencesSync(context, { name: 'network_profiles' })
      console.info('[NetworkCtx] Preferences initialized')
    } catch (e) {
      console.error('[NetworkCtx] Init failed: ' + JSON.stringify(e))
    }
  }

  startMonitoring(): void {
    if (this.isMonitoring) {
      return
    }
    this.isMonitoring = true

    try {
      wifiManager.on('wifiConnectionChange', (state: number) => {
        console.info('[NetworkCtx] wifiConnectionChange state=' + state)
        // state: 0=disconnected, 1=connected
        if (state === 1) {
          this.onWifiConnected()
        } else {
          this.currentSSID = ''
          this.onNetworkLost?.()
        }
      })
      console.info('[NetworkCtx] WiFi monitoring started')
    } catch (e) {
      console.error('[NetworkCtx] startMonitoring failed: ' + JSON.stringify(e))
    }
  }

  stopMonitoring(): void {
    this.isMonitoring = false
    try {
      wifiManager.off('wifiConnectionChange')
    } catch (_e) {
      // ignore
    }
  }

  /**
   * 获取当前 WiFi 信息并尝试匹配 Profile
   */
  private async onWifiConnected(): Promise<void> {
    try {
      const linkedInfo: wifiManager.WifiLinkedInfo = await wifiManager.getLinkedInfo()
      const ssid: string = linkedInfo.ssid || ''
      const bssid: string = linkedInfo.bssid || ''

      console.info('[NetworkCtx] WiFi connected: ssid=' + ssid + ' bssid=' + bssid)

      if (ssid.length === 0) {
        return
      }

      this.currentSSID = ssid

      // 查找匹配的 Profile
      const profile = await this.findMatchingProfile(ssid, bssid)
      if (profile && profile.autoConnect) {
        console.info('[NetworkCtx] Matched profile: ' + profile.name + ' -> ' + profile.macIP)
        this.onNetworkMatched?.(profile)
      }
    } catch (e) {
      console.error('[NetworkCtx] onWifiConnected error: ' + JSON.stringify(e))
    }
  }

  /**
   * 获取当前 SSID（同步查询缓存值，启动时可能为空）
   */
  getCurrentSSID(): string {
    return this.currentSSID
  }

  /**
   * 刷新当前 WiFi 信息（供外部主动调用）
   */
  async refreshCurrentNetwork(): Promise<void> {
    await this.onWifiConnected()
  }

  // ============ Profile CRUD ============

  async saveProfile(profile: NetworkProfile): Promise<void> {
    const profiles = await this.getAllProfiles()
    const idx = profiles.findIndex((p: NetworkProfile) => p.id === profile.id)
    if (idx !== -1) {
      profiles[idx] = profile
    } else {
      profiles.push(profile)
    }
    await this.persistProfiles(profiles)
    console.info('[NetworkCtx] Profile saved: ' + profile.name + ' ssid=' + profile.ssid)
  }

  /**
   * 保存或更新 Profile（按 ssid 去重）
   */
  async upsertProfile(ssid: string, bssid: string, macIP: string, name: string): Promise<NetworkProfile> {
    const profiles = await this.getAllProfiles()
    const existing = profiles.find((p: NetworkProfile) => p.ssid === ssid)
    const now = Date.now()

    let profile: NetworkProfile
    if (existing) {
      existing.bssid = bssid
      existing.macIP = macIP
      existing.name = name
      existing.lastSeen = now
      profile = existing
    } else {
      profile = {
        id: 'p_' + now.toString(),
        name: name,
        ssid: ssid,
        bssid: bssid,
        macIP: macIP,
        autoConnect: true,
        createdAt: now,
        lastSeen: now
      }
      profiles.push(profile)
    }

    await this.persistProfiles(profiles)
    this.currentSSID = ssid
    console.info('[NetworkCtx] Profile upserted: ' + name + ' ssid=' + ssid + ' ip=' + macIP)
    return profile
  }

  /**
   * 更新已知 Profile 的 IP（DHCP 变更时）
   */
  async updateProfileIP(ssid: string, newIP: string): Promise<void> {
    const profiles = await this.getAllProfiles()
    const idx = profiles.findIndex((p: NetworkProfile) => p.ssid === ssid)
    if (idx !== -1) {
      profiles[idx].macIP = newIP
      profiles[idx].lastSeen = Date.now()
      await this.persistProfiles(profiles)
      console.info('[NetworkCtx] Profile IP updated: ' + ssid + ' -> ' + newIP)
    }
  }

  /**
   * 更新已知 Profile 的 roomKey 和 relayHost（双 Mac 场景）
   * Mac 通过 TCP 连接自动发送 roomKeyInfo 后调用
   */
  async updateProfileRoomKey(ssid: string, roomKey: string, relayHost: string): Promise<void> {
    if (ssid.length === 0 || roomKey.length === 0) {
      return
    }
    const profiles = await this.getAllProfiles()
    const idx = profiles.findIndex((p: NetworkProfile) => p.ssid === ssid)
    if (idx !== -1) {
      profiles[idx].roomKey = roomKey
      profiles[idx].relayHost = relayHost
      profiles[idx].lastSeen = Date.now()
      await this.persistProfiles(profiles)
      console.info('[NetworkCtx] Profile roomKey updated: ' + ssid + ' -> ' + roomKey)
    }
  }

  async deleteProfile(id: string): Promise<void> {
    let profiles = await this.getAllProfiles()
    profiles = profiles.filter((p: NetworkProfile) => p.id !== id)
    await this.persistProfiles(profiles)
    console.info('[NetworkCtx] Profile deleted: ' + id)
  }

  async getProfileBySSID(ssid: string): Promise<NetworkProfile | null> {
    const profiles = await this.getAllProfiles()
    const found = profiles.find((p: NetworkProfile) => p.ssid === ssid)
    return found || null
  }

  async getAllProfiles(): Promise<NetworkProfile[]> {
    if (!this.store) {
      return []
    }
    try {
      const raw: string = this.store.getSync('profiles', '[]') as string
      return JSON.parse(raw) as NetworkProfile[]
    } catch (_e) {
      return []
    }
  }

  private async findMatchingProfile(ssid: string, bssid: string): Promise<NetworkProfile | null> {
    const profiles = await this.getAllProfiles()
    // 精确匹配：SSID + BSSID
    for (let i = 0; i < profiles.length; i++) {
      const p: NetworkProfile = profiles[i]
      if (p.ssid === ssid && p.bssid === bssid && p.bssid.length > 0) {
        return p
      }
    }
    // 模糊匹配：仅 SSID
    for (let i = 0; i < profiles.length; i++) {
      const p: NetworkProfile = profiles[i]
      if (p.ssid === ssid) {
        return p
      }
    }
    return null
  }

  private async persistProfiles(profiles: NetworkProfile[]): Promise<void> {
    if (!this.store) {
      return
    }
    try {
      this.store.putSync('profiles', JSON.stringify(profiles))
      this.store.flush()
    } catch (e) {
      console.error('[NetworkCtx] persist failed: ' + JSON.stringify(e))
    }
  }
}
