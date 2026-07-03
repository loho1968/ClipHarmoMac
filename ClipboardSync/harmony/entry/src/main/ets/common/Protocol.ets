import { util } from '@kit.ArkTS'

// 通信协议常量
export class ProtocolConst {
  // 应用版本号
  static readonly APP_VERSION: string = '1.0.0 (build 1)'
  static readonly BROADCAST_PORT: number = 19876
  static readonly WS_PORT: number = 19877
  static readonly DISCOVERY_TCP_PORT: number = 19878
  static readonly BROADCAST_INTERVAL: number = 3000
  static readonly CLIPBOARD_POLL_INTERVAL: number = 500
  static readonly DEVICE_ID: string = 'Harmony-' + Math.floor(Math.random() * 9000 + 1000)
}

// 消息类型枚举
export enum MessageType {
  CLIPBOARD_TEXT = 'clipboardText',
  CLIPBOARD_IMAGE = 'clipboardImage',
  CLIPBOARD_FILE = 'clipboardFile',
  CLIPBOARD_DATA_CHUNK = 'clipboardDataChunk',
  PING = 'ping',
  PONG = 'pong',
  // Mac → 手机，TCP 连接建立后自动发送 roomKey 和 relayHost
  ROOM_KEY_INFO = 'roomKeyInfo'
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
}
