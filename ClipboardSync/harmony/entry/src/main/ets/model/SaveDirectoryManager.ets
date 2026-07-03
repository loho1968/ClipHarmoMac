import { preferences } from '@kit.ArkData'

export class SaveDirectoryManager {
  private static instance: SaveDirectoryManager
  private static readonly KEY_SAVE_DIR: string = 'save_directory_path'
  private static readonly DEFAULT_DIR_NAME: string = 'ClipboardSync'
  private _context: Context | null = null
  private _initialized: boolean = false

  static getInstance(): SaveDirectoryManager {
    if (!SaveDirectoryManager.instance) {
      SaveDirectoryManager.instance = new SaveDirectoryManager()
    }
    return SaveDirectoryManager.instance
  }

  init(context: Context): void {
    if (this._initialized) {
      return
    }
    this._context = context
    this._initialized = true
  }

  getCurrentDirectory(): string {
    if (!this._context) {
      return '/data/storage/el2/base/files/' + SaveDirectoryManager.DEFAULT_DIR_NAME
    }
    const prefs: preferences.Preferences = preferences.getPreferencesSync(this._context, { name: 'clipboard_sync_settings' })
    const saved: string = prefs.getSync(SaveDirectoryManager.KEY_SAVE_DIR, '') as string
    if (saved.length > 0) {
      return saved
    }
    return this._context.filesDir + '/' + SaveDirectoryManager.DEFAULT_DIR_NAME
  }

  setDirectory(path: string): void {
    if (!this._context) {
      return
    }
    const prefs: preferences.Preferences = preferences.getPreferencesSync(this._context, { name: 'clipboard_sync_settings' })
    prefs.putSync(SaveDirectoryManager.KEY_SAVE_DIR, path)
    prefs.flush()
  }

  setAsDefault(path: string): void {
    this.setDirectory(path)
  }

  resetToDefault(): void {
    if (!this._context) {
      return
    }
    const prefs: preferences.Preferences = preferences.getPreferencesSync(this._context, { name: 'clipboard_sync_settings' })
    prefs.deleteSync(SaveDirectoryManager.KEY_SAVE_DIR)
    prefs.flush()
  }
}
