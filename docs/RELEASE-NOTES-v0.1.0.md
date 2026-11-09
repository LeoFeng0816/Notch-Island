# Notch Island v0.1.0

[繁體中文](#繁體中文) · [English](#english)

## 繁體中文

**已知限制：Shazam 歌曲辨識目前暫時無法使用。** 系統控制中心及其他備援辨識流程仍待實機驗證，請勿依賴這些功能。

**權限與隱私：**系統權限用於使用者選擇的功能；目前程式不會將私人資料上傳至 Notch Island 自有伺服器。部分選用功能會連線第三方：天氣與股價查詢會傳送位置或代號，AudD 只有在明確同意並開始辨識後才上傳短音訊，ShazamKit 則向 Apple 傳送音訊特徵。詳見 README 的隱私說明。

首個公開版本，提供瀏海區域的音樂與計時活動、可自訂小工具、剪貼簿歷史、截圖與錄影入口，以及三種介面語言。

**安裝：**下載 `NotchIsland-0.1.0.dmg`，開啟後依箭頭將 Notch Island 拖至 Applications，再從「應用程式」開啟。此版本僅以 ad-hoc 簽章，**未經 Apple 公證**；若你信任來源，macOS 阻擋時請依 [Apple 的說明](https://support.apple.com/zh-tw/102445)在「隱私權與安全性」個別允許此 App。

**SHA-256：** `cc041f6e59d38637fcb27a790e0f3ab00353abe280afe74f0230de2160a23ebc`

**驗證與限制：**874 項離線測試通過；DMG 掛載、排版資料與 Apple Silicon 自我測試通過，Intel 切片僅完成靜態檢查。實際 Finder 安裝流程、截圖、錄影與系統音樂辨識仍需在解鎖的 Mac 實機驗證。ShazamKit 曾回傳錯誤 202；AudD 僅以合成音訊及模擬網路測試，需要自行提供金鑰及同意音訊上傳。詳情和權限說明見[繁體中文 README](../README.md)。

## English

**Known issue: Shazam song recognition is temporarily unavailable.** The system Control Center and alternative recognition flows still require real-device testing and should not be relied on.

**Permissions and privacy:** Permissions support user-selected features; the current app does not upload private data to a Notch Island-owned server. Some optional features use third-party services: weather and stock queries send a location or ticker, AudD uploads a short audio clip only after explicit consent and initiation, and ShazamKit sends audio signatures to Apple. See the README for details.

The first public version includes music and timer activities around the notch, configurable widgets, clipboard history, screenshot and screen-recording entry points, and three interface languages.

**Installation:** Download `NotchIsland-0.1.0.dmg`, open it, and drag Notch Island to Applications using the arrow. Open the app from Applications. This build is ad-hoc signed and **not notarized by Apple**; if you trust its source and macOS blocks it, follow [Apple's instructions](https://support.apple.com/en-us/102445) to allow this app individually in Privacy & Security.

**SHA-256:** `cc041f6e59d38637fcb27a790e0f3ab00353abe280afe74f0230de2160a23ebc`

**Verification and limitations:** 874 offline tests passed; the DMG mount, layout metadata, and Apple silicon self-test passed. The Intel slice was checked statically only. The Finder installation flow, screenshot, screen recording, and system music recognition still require real-device testing on an unlocked Mac. ShazamKit returned error 202 during development; AudD has only been tested with synthetic audio and mocked network responses and requires your own token and consent to upload audio. See the [English README](../README.en.md) for details and permissions.
