import { router } from '@kit.ArkUI'
import { scanCore, scanBarcode } from '@kit.ScanKit'
import { qrResultHolder } from './Index'
import { BusinessError } from '@kit.BasicServicesKit'

@Entry
@Component
struct ScanPage {

  aboutToAppear(): void {
    const options: scanBarcode.ScanOptions = {
      scanTypes: [scanCore.ScanType.QR_CODE]
    }
    try {
      const context = this.getUIContext().getHostContext()
      scanBarcode.startScanForResult(context, options)
        .then((result: scanBarcode.ScanResult) => {
          if (result && result.originalValue) {
            qrResultHolder.data = result.originalValue
          }
          router.back()
        })
        .catch((err: BusinessError) => {
          console.error('[ScanPage] Scan error: ' + JSON.stringify(err))
          router.back()
        })
    } catch (err) {
      console.error('[ScanPage] Failed to start scan: ' + JSON.stringify(err))
      router.back()
    }
  }

  build() {
    Column() {
    }
    .width('100%')
    .height('100%')
    .backgroundColor(Color.Black)
  }
}
