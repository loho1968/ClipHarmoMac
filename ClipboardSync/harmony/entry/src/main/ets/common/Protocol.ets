import { util } from '@kit.ArkTS'
import { preferences } from '@kit.ArkData'

// 通信协议常量
export class ProtocolConst {
  // 应用版本号（每次发版修改，页面底部会显示）
  static readonly APP_VERSION: string = '1.1.0 (build 3)'
  static readonly BROADCAST_PORT: number = 19876
  static readonly WS_PORT: number = 19877
  static readonly DISCOVERY_TCP_PORT: number = 19878
  static readonly BROADCAST_INTERVAL: number = 3000
  static readonly CLIPBOARD_POLL_INTERVAL: number = 500

  // 设备唯一标识存储键（存放在 clipboardsync_relay 偏好文件中）
  static readonly DEVICE_ID_STORAGE_KEY: string = 'clipboardsync_device_id'

  // 已持久化的设备 ID（loadDeviceId 成功后非空）
  private static _deviceId: string = ''
  // 进程内回退 ID：loadDeviceId 尚未调用时保证本进程内取值稳定
  private static _fallbackDeviceId: string = 'Harmony-' + Math.floor(Math.random() * 9000 + 1000)
  private static _devicePrefs: preferences.Preferences | null = null

  /**
   * 设备唯一标识：首次生成后持久化，此后每次启动保持不变。
   * （此前每次进程启动随机生成，导致中继服务器无法按 deviceId
   * 踢掉残留旧连接、Mac 端"已配对"显示的编号每次重启都变）
   */
  static get DEVICE_ID(): string {
    return ProtocolConst._deviceId.length > 0
      ? ProtocolConst._deviceId
      : ProtocolConst._fallbackDeviceId
  }

  /**
   * 创建（或复用）设备 ID 所在的偏好文件实例
   * @param context 应用上下文
   * @returns 偏好文件实例，创建失败时返回 null
   */
  private static createDevicePrefs(context: Context): preferences.Preferences | null {
    try {
      return preferences.getPreferencesSync(context, { name: 'clipboardsync_relay' })
    } catch (_e) {
      console.error('[ProtocolConst] createDevicePrefs: prefs creation failed')
      return null
    }
  }

  /**
   * 加载或生成并持久化设备唯一标识
   * 应在 EntryAbility.onCreate 中调用（早于所有网络连接建立）
   * @param context 应用上下文
   * @returns 无
   */
  static loadDeviceId(context: Context): void {
    if (ProtocolConst._deviceId.length > 0) {
      return
    }
    let prefs: preferences.Preferences | null = ProtocolConst._devicePrefs
    if (prefs === null) {
      prefs = ProtocolConst.createDevicePrefs(context)
      if (prefs === null) {
        console.error('[ProtocolConst] loadDeviceId: using fallback id')
        return
      }
      ProtocolConst._devicePrefs = prefs
    }
    const saved: string = prefs.getSync(ProtocolConst.DEVICE_ID_STORAGE_KEY, '') as string
    if (saved.length > 0) {
      ProtocolConst._deviceId = saved
      console.info('[ProtocolConst] DeviceId loaded: ' + saved)
      return
    }
    const generated: string = 'Harmony-' + Math.floor(Math.random() * 9000 + 1000)
    prefs.putSync(ProtocolConst.DEVICE_ID_STORAGE_KEY, generated)
    prefs.flush()
    ProtocolConst._deviceId = generated
    console.info('[ProtocolConst] DeviceId generated and persisted: ' + generated)
  }
}

// 消息类型枚举
export enum MessageType {
  CLIPBOARD_TEXT = 'clipboardText',
  CLIPBOARD_IMAGE = 'clipboardImage',
  CLIPBOARD_FILE = 'clipboardFile',
  CLIPBOARD_DATA_CHUNK = 'clipboardDataChunk',
  CLIPBOARD_POLL = 'clipboardPoll',
  PING = 'ping',
  PONG = 'pong',
  // Mac → 手机，TCP 连接建立后自动发送 roomKey 和 relayHost
  ROOM_KEY_INFO = 'roomKeyInfo',
  // ECDH P-256 公钥交换（content 为空，publicKey 字段携带公钥）
  KEY_EXCHANGE = 'keyExchange'
}

// 传输消息结构
export interface SyncMessage {
  type: MessageType
  content: string
  timestamp: number
  deviceId: string
  mimeType?: string
  networkSSID?: string
  // roomKeyInfo 消息携带：Mac 的配对码和中继服务器地址
  roomKey?: string
  relayHost?: string
  // keyExchange 消息携带：ECDH P-256 公钥（Base64）
  publicKey?: string
  // 分片字段
  transferId?: string
  chunkIndex?: number
  totalChunks?: number
  // 图片/文件元数据
  fileName?: string
  fileSize?: number
  imageWidth?: number
  imageHeight?: number
  format?: string
  fileCount?: number
}

// ============================================================
// 中继服务器配置
// ============================================================

export class RelayConfig {
  static readonly HEARTBEAT_INTERVAL: number = 30000
  static readonly RECONNECT_BASE_DELAY: number = 1000
  static readonly RECONNECT_MAX_DELAY: number = 30000
  static readonly ROOM_KEY_STORAGE_KEY: string = 'clipboardsync_room_key'
  static readonly HOST_STORAGE_KEY: string = 'clipboardsync_relay_host'
  static readonly ROOM_KEY_LENGTH: number = 6

  private static _defaultHost: string = 'localhost'
  private static _defaultPort: number = 8443
  private static _wsPath: string = '/ws'
  private static _configLoaded: boolean = false

  /**
   * 从 rawfile/relay_config.json 加载中继服务器默认配置
   * 应在 App 启动时（EntryAbility.onCreate）调用一次
   * 配置文件不存在时回退到 localhost:8443
   */
  static async loadConfig(context: Context): Promise<void> {
    if (RelayConfig._configLoaded) {
      return
    }
    try {
      const rawData = await context.resourceManager.getRawFileContent('relay_config.json')
      const decoder = new util.TextDecoder('utf-8')
      const text = decoder.decode(rawData)
      const config = JSON.parse(text) as Record<string, Object>
      if (config.relay) {
        const relay = config.relay as Record<string, Object>
        RelayConfig._defaultHost = (relay.defaultHost as string) || 'localhost'
        RelayConfig._defaultPort = (relay.defaultPort as number) || 8443
        RelayConfig._wsPath = (relay.wsPath as string) || '/ws'
      }
      console.info('[RelayConfig] Config loaded: host=' + RelayConfig._defaultHost)
    } catch (_e) {
      console.info('[RelayConfig] No config file found, using defaults: localhost:8443')
    }
    RelayConfig._configLoaded = true
  }

  static get DEFAULT_HOST(): string {
    return RelayConfig._defaultHost
  }

  static get DEFAULT_PORT(): number {
    return RelayConfig._defaultPort
  }

  static get WS_PATH(): string {
    return RelayConfig._wsPath
  }

  /**
   * 根据主机（IP 或域名）构建 WebSocket URL
   * @param host IP 地址或域名
   * @returns 完整的 ws:// URL
   */
  static buildURL(host: string): string {
    return 'ws://' + host + ':' + RelayConfig.DEFAULT_PORT + RelayConfig.WS_PATH
  }
}

// 中继层 action 类型
export enum RelayAction {
  AUTH = 'auth',
  AUTH_OK = 'auth_ok',
  RELAY = 'relay',
  PING = 'ping',
  PONG = 'pong',
  PAIRED = 'paired',
  PEER_GONE = 'peer_gone',
  // 服务端回执：发送的房间内无其他设备，消息未被任何人收到
  RELAY_NO_PEER = 'relay_no_peer',
  ERROR = 'error'
}

// 中继层消息（WebSocket JSON 协议）
export interface RelayMessage {
  action: string
  roomKey?: string
  deviceId?: string
  fromDeviceId?: string
  pairedDeviceId?: string
  payload?: SyncMessage
  message?: string
  roomDeviceCount?: number
  // relay_no_peer 回执携带：被丢弃的消息类型
  type?: string
}
