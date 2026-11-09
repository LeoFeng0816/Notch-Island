import Foundation
import Combine

/// UI language selectable at runtime, independent from the macOS system language.
enum AppLanguage: String, CaseIterable, Identifiable {
    case system
    case english = "en"
    case traditionalChinese = "zh-Hant"
    case simplifiedChinese = "zh-Hans"

    var id: String { rawValue }

    /// Concrete language after resolving `.system` against the user's preferred languages.
    var resolved: AppLanguage {
        guard self == .system else { return self }
        for identifier in Locale.preferredLanguages {
            let lower = identifier.lowercased()
            if lower.hasPrefix("zh-hant") || lower.hasPrefix("zh-tw") || lower.hasPrefix("zh-hk") || lower.hasPrefix("zh-mo") {
                return .traditionalChinese
            }
            if lower.hasPrefix("zh") { return .simplifiedChinese }
            if lower.hasPrefix("en") { return .english }
        }
        return .english
    }

    /// Short label used in the island's language switcher.
    var shortLabel: String {
        switch self {
        case .system: return "Auto"
        case .english: return "EN"
        case .traditionalChinese: return "繁"
        case .simplifiedChinese: return "简"
        }
    }

    /// Name written in its own language (so users can always find theirs).
    var nativeName: String {
        switch self {
        case .system: return ""
        case .english: return "English"
        case .traditionalChinese: return "繁體中文"
        case .simplifiedChinese: return "简体中文"
        }
    }
}

enum L10nKey: CaseIterable {
    case appName, nowPlaying, timer
    case nothingPlaying, playHint, permissionNeeded, openSettings
    case start, pause, resume, reset
    case ready, running, paused, timesUp, done
    case minuteShort
    case language, followSystem, quit
    case expandIsland, collapseIsland, quickTimer, stopTimer
    case hoverHint, notchDetected, virtualNotch
    case musicApp
    // Pages & widgets
    case activities, widgets, customize, noWidgets, noWidgetsHint
    case battery, weather, stocks, stopwatch, lap
    case charging, charged, onBattery, pluggedIn, noBattery, lowPowerMode, timeLeft, timeToFull, calculating
    case chooseCity, feelsLike, highLow, weatherAttribution, updatedAt, unavailable, loading, refresh, lastData
    case wxClear, wxPartlyCloudy, wxCloudy, wxFog, wxDrizzle, wxRain, wxSnow, wxThunder, wxUnknown
    case addTickers, addAPIKey, asOf, stocksAttribution
    case errOffline, errTimeout, errNetwork, errServer, errRateLimited, errInvalidResponse, errNotFound, errMissingKey, errInvalidKey
    // Settings
    case settingsMenu, settingsTitle, general, widgetsSection, widgetsHint, moveUp, moveDown, usesNetwork
    case weatherSection, city, search, searching, selectedCity, noCitySelected, clear, temperatureUnit, celsius, fahrenheit, weatherPrivacy
    case stocksSection, tickerPlaceholder, add, remove, tickerInvalid, tickerDuplicate, tickerLimit
    case apiKey, apiKeySaved, apiKeyMissing, save, getFreeKey, stocksNote
    case deviceSection, modelIdentifier, display, notch, notchSize, firstSeen, deviceNote, redetect, builtIn, external
    case startStopwatch, stopStopwatch
    case dailyCloses, clickToRefresh, percentCharged, degrees, errKeychain, daysShort
    case allDay, automationAllowed, automationDenied, automationNotAsked, automationUnknown
    case browserNotInstalled, browserNotRunning, calendarAllow, calendarDenied, calendarGranted
    case calendarNotAsked, calendarPrivacy, calendarWidget, calendarWriteOnly, chromeMedia
    case clockHint, clockWidget, currentLocation, hoursOffset, jsDisabled
    case locDenied, locNetwork, locRestricted, locServicesOff, locTimeout, locUnavailable
    case localTime, locationPrivacy, mediaPrivacy, mediaSection, needsPermission
    case noEventsToday, noUpcomingEvents, nowUntil, safariMedia, searchTimeZone, stockSource
    case today, tomorrow, untitledEvent, widgetLimit, yahooAttribution, yahooNote, yahooOption, yesterday
    case locating, updateLocation, useCurrentLocation, alphaVantageOption, calendarRange
    case rangeToday, allowAutomation, moreEvents, rangeDays, chromeJSHelp, safariJSHelp, showAllDay
    case browserJSHint, browserAutomationHint, setUp, weatherUseLocation, chooseCityInstead, browserNeedsAutomation, controlFailed
    case ytmAppNotVisible, ytmAppNotVisibleShort, diagChecked, diagTabs, diagUnreadable, diagAppRunning, diagShowing, diagNothing
    case diagTime, timeFromPlayerBar, timeFromElement, timeAd, timeNone
    case timeFromPlayerAPI, widgetLimitTitle, widgetLimitMessage, ok, listSeparator, timerMinutes, timerLess, timerMore
    case systemNowPlaying, systemNPOff, systemNPWorks, systemNPRestricted, systemNPNoData
    case mediaKeysToggle, mediaKeysGranted, mediaKeysNeedAccess, mediaKeysNote, previousTrack, playPause, nextTrack, skipUnavailable
    case controlSending, controlNoEffect, mediaKeysStaleGrant
    case qaClipboard, qaScreenshot, qaScreenRecord, qaShazam, close, cancel, toastCopied, toastPasted, toastCancelled, toastPermission, toastFailed, screenshotCopied, recordToolbarHelp, recordToolbarFailed, pasteNeedsPermission, pasteAllowed, clipboardClear, clipboardClearConfirm, clipboardOff, clipboardOffHint, clipboardTurnOn, clipboardEmpty, clipboardFooter, clipboardImage, clipboardText, clipboardFiles, clipboardPasteHint, clipboardHistoryToggle, clipboardRetention, clipboardCount, clipboardPrivacy, retention1, retention3, retention7, retention30, shazamPrivacy, shazamStart, shazamCancelled, shazamListening, shazamMic, shazamSystemAudio, shazamOpen, shazamCopy, shazamAgain, shazamNoMatch, shazamMicDenied, shazamNoSource, shazamNetwork, shazamService, shazamCatalogFailed, shazamRetrying, shazamSystemFallback, shazamSystemGuide, onboardingTitle, onboardingMenu, onboardingIntro, onboardingPermissions, onboardingPermissionsFooter, onboardingDone, permGranted, permNotGranted, permDenied, permAllow, permKeystrokes, permKeystrokesWhy, permScreen, permScreenWhy, permMicrophone, permMicrophoneWhy, permNotifications, permNotificationsWhy, permAutomation, permAutomationWhy, permSystemAudio, permSystemAudioWhy, permLocationCalendar, permLocationCalendarWhy
    case audioLevelsToggle, audioLevelsOff, audioLevelsUnsupported, audioLevelsIdle, audioLevelsRunning, audioLevelsSilent, audioLevelsFailed, audioLevelsNote
    case stockSearchPlaceholder, stockSearchEmpty, exchange, allExchanges, addTypedTicker, errUnsupportedQuery
    case controlCenterToggle, controlCenterNote, controlCenterPermission, controlCenterUnavailable, controlCenterUncertain
    case playbackPosition, seekFailed
    case back, toastCaptureBusy, screenshotOpenSystem, screenshotToolbarFailed
    case shazamSystemOpen, shazamSystemUnavailable, shazamShortcut, shazamShortcutName, shazamShortcutHelp
    case shazamShortcutRun, shazamShortcutGallery, shazamShortcutRunning, shazamShortcutFinished, shazamShortcutFailed
    case audDTitle, audDDisclosure, audDToken, audDTrial, audDPreparing, audDListening, audDSending
    case audDCancelled, audDNoAudio, audDMissingToken, audDNoMatch
    case captureToolRefused, captureToolNoImage, captureToolFailed, captureAdviceStaleGrant, captureAdviceNotGranted, captureAdviceUnknown
    case recordNeedsGrant, recordFallbackHelp, screenshotFallbackHelp, recordWithQuickTime, recordOpenScreenshot, openPrivacySettings
    case toastPickRecordMode, toastQuickTimeRequested, recordQuickTimeDenied
    case shazamSystemListening, shazamSystemUncertain, shazamSystemNeedsAX, shazamSystemMissing
    case audDSummary, audDUploadSystem, audDUploadMic, audDSetup, audDNeedsConsent, audDReady, audDNetwork, audDInvalidToken
    case audDLimit, audDServiceError, audDBadResponse, audDSetupTitle, audDConsentCheck, audDTokenReplace, audDTokenStored
    case audDTokenNone, audDSave, audDRemoveToken, audDTokenRejected
}

@MainActor
final class LanguageSettings: ObservableObject {
    static let shared = LanguageSettings()
    private static let defaultsKey = "NotchIsland.language"

    @Published var language: AppLanguage {
        didSet { UserDefaults.standard.set(language.rawValue, forKey: Self.defaultsKey) }
    }

    private init() {
        let stored = UserDefaults.standard.string(forKey: Self.defaultsKey)
        language = stored.flatMap(AppLanguage.init(rawValue:)) ?? .system
    }

    func t(_ key: L10nKey) -> String {
        let entry = Self.table[key] ?? ("?", "?", "?")
        switch language.resolved {
        case .traditionalChinese: return entry.hant
        case .simplifiedChinese: return entry.hans
        default: return entry.en
        }
    }

    /// Fills `%@` placeholders in order.
    func t(_ key: L10nKey, _ args: String...) -> String {
        var result = t(key)
        for arg in args {
            guard let range = result.range(of: "%@") else { break }
            result.replaceSubrange(range, with: arg)
        }
        return result
    }

    var locale: Locale {
        switch language.resolved {
        case .traditionalChinese: return Locale(identifier: "zh_Hant_TW")
        case .simplifiedChinese: return Locale(identifier: "zh_Hans_CN")
        default: return Locale(identifier: "en_US")
        }
    }

    /// Language code passed to the geocoder so city names come back localized.
    var providerLanguage: String { language.resolved == .english ? "en" : "zh" }

    func time(_ date: Date) -> String {
        date.formatted(Date.FormatStyle(date: .omitted, time: .shortened).locale(locale))
    }

    func duration(minutes: Int) -> String {
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = minutes >= 60 ? [.hour, .minute] : [.minute]
        formatter.unitsStyle = .abbreviated
        var calendar = Calendar.current
        calendar.locale = locale
        formatter.calendar = calendar
        return formatter.string(from: TimeInterval(minutes * 60)) ?? "\(minutes)"
    }

    static var missingKeys: [L10nKey] { L10nKey.allCases.filter { table[$0] == nil } }

    func displayName(_ lang: AppLanguage) -> String {
        lang == .system ? t(.followSystem) : lang.nativeName
    }

    private static let table: [L10nKey: (en: String, hant: String, hans: String)] = [
        .appName: ("Notch Island", "瀏海島", "刘海岛"),
        .nowPlaying: ("Now Playing", "正在播放", "正在播放"),
        .timer: ("Timer", "計時器", "计时器"),
        .nothingPlaying: ("Nothing playing", "目前沒有播放", "当前没有播放"),
        .playHint: ("Play something in Music, Spotify, or a supported browser", "在「音樂」、Spotify 或支援的瀏覽器播放", "在“音乐”、Spotify 或支持的浏览器播放"),
        .permissionNeeded: ("Allow Automation access to show music", "請允許「自動化」權限以顯示音樂", "请允许“自动化”权限以显示音乐"),
        .openSettings: ("Open Settings", "打開設定", "打开设置"),
        .start: ("Start", "開始", "开始"),
        .pause: ("Pause", "暫停", "暂停"),
        .resume: ("Resume", "繼續", "继续"),
        .reset: ("Reset", "重設", "重置"),
        .ready: ("Ready", "就緒", "就绪"),
        .running: ("Running", "計時中", "计时中"),
        .paused: ("Paused", "已暫停", "已暂停"),
        .timesUp: ("Time's up", "時間到", "时间到"),
        .done: ("Done", "完成", "完成"),
        .minuteShort: ("m", "分", "分"),
        .language: ("Language", "語言", "语言"),
        .followSystem: ("Follow System", "跟隨系統", "跟随系统"),
        .quit: ("Quit Notch Island", "結束瀏海島", "退出刘海岛"),
        .expandIsland: ("Expand Island", "展開島嶼", "展开岛屿"),
        .collapseIsland: ("Collapse Island", "收合島嶼", "收起岛屿"),
        .quickTimer: ("Start 5-Minute Timer", "開始 5 分鐘計時", "开始 5 分钟计时"),
        .stopTimer: ("Stop Timer", "停止計時", "停止计时"),
        .hoverHint: ("Click the notch to expand, or hover for 1 second", "點擊瀏海立即展開，或停留 1 秒", "点击刘海立即展开，或停留 1 秒"),
        .notchDetected: ("Notch display detected", "已偵測到瀏海螢幕", "已检测到刘海屏幕"),
        .virtualNotch: ("No notch: using a virtual island", "無瀏海：使用虛擬島嶼", "无刘海：使用虚拟岛屿"),
        .musicApp: ("Music", "音樂", "音乐"),
        .activities: ("Activities", "即時活動", "实时活动"),
        .widgets: ("Widgets", "小工具", "小组件"),
        .customize: ("Customize…", "自訂…", "自定义…"),
        .noWidgets: ("No widgets yet", "尚未加入小工具", "尚未添加小组件"),
        .noWidgetsHint: ("Choose battery, weather, stocks or stopwatch in Settings.", "在設定中選擇電池、天氣、股價或碼表。", "在设置中选择电池、天气、股价或秒表。"),
        .battery: ("Battery", "電池", "电池"),
        .weather: ("Weather", "天氣", "天气"),
        .stocks: ("Stocks", "股價", "股价"),
        .stopwatch: ("Stopwatch", "碼表", "秒表"),
        .lap: ("Lap", "分圈", "计次"),
        .charging: ("Charging", "充電中", "充电中"),
        .charged: ("Fully charged", "已充飽", "已充满"),
        .onBattery: ("On battery", "使用電池", "使用电池"),
        .pluggedIn: ("Plugged in, not charging", "已接電源，未充電", "已接电源，未充电"),
        .noBattery: ("No battery", "沒有電池", "没有电池"),
        .lowPowerMode: ("Low Power", "低耗電", "低电量"),
        .timeLeft: ("%@ left", "剩餘 %@", "剩余 %@"),
        .timeToFull: ("Full in %@", "%@ 後充飽", "%@ 后充满"),
        .calculating: ("Estimating…", "估算中…", "估算中…"),
        .chooseCity: ("Choose a city in Settings", "請在設定中選擇城市", "请在设置中选择城市"),
        .feelsLike: ("Feels %@", "體感 %@", "体感 %@"),
        .highLow: ("H:%@ L:%@", "高 %@ 低 %@", "高 %@ 低 %@"),
        .weatherAttribution: ("Weather data by Open-Meteo.com", "天氣資料：Open-Meteo.com", "天气数据：Open-Meteo.com"),
        .updatedAt: ("Updated %@", "%@ 更新", "%@ 更新"),
        .unavailable: ("Unavailable", "無法取得", "无法获取"),
        .loading: ("Loading…", "載入中…", "加载中…"),
        .refresh: ("Refresh", "重新整理", "刷新"),
        .lastData: ("Last data %@", "上次資料 %@", "上次数据 %@"),
        .wxClear: ("Clear", "晴朗", "晴朗"),
        .wxPartlyCloudy: ("Partly cloudy", "局部多雲", "局部多云"),
        .wxCloudy: ("Cloudy", "陰天", "阴天"),
        .wxFog: ("Fog", "霧", "雾"),
        .wxDrizzle: ("Drizzle", "毛毛雨", "毛毛雨"),
        .wxRain: ("Rain", "雨", "雨"),
        .wxSnow: ("Snow", "雪", "雪"),
        .wxThunder: ("Thunderstorm", "雷雨", "雷雨"),
        .wxUnknown: ("Unknown", "未知", "未知"),
        .addTickers: ("Add tickers in Settings", "請在設定中加入股票代號", "请在设置中添加股票代码"),
        .addAPIKey: ("Add a free Alpha Vantage key in Settings", "請在設定中加入免費 Alpha Vantage 金鑰", "请在设置中添加免费 Alpha Vantage 密钥"),
        .asOf: ("As of %@", "截至 %@", "截至 %@"),
        .stocksAttribution: ("Alpha Vantage · not real-time", "Alpha Vantage・非即時", "Alpha Vantage・非实时"),
        .errOffline: ("You're offline", "目前沒有網路連線", "当前没有网络连接"),
        .errTimeout: ("The provider timed out", "資料來源逾時", "数据源超时"),
        .errNetwork: ("Network error", "網路錯誤", "网络错误"),
        .errServer: ("Provider is unavailable", "資料來源暫時無法使用", "数据源暂时不可用"),
        .errRateLimited: ("Request limit reached, try later", "已達請求上限，請稍後再試", "已达请求上限，请稍后再试"),
        .errInvalidResponse: ("Unexpected data from provider", "資料來源回傳格式異常", "数据源返回格式异常"),
        .errNotFound: ("Not found", "找不到", "找不到"),
        .errMissingKey: ("API key missing", "缺少 API 金鑰", "缺少 API 密钥"),
        .errInvalidKey: ("API key was rejected", "API 金鑰無效", "API 密钥无效"),
        .settingsMenu: ("Settings…", "設定…", "设置…"),
        .settingsTitle: ("Notch Island Settings", "瀏海島設定", "刘海岛设置"),
        .general: ("General", "一般", "通用"),
        .widgetsSection: ("Widgets", "小工具", "小组件"),
        .widgetsHint: ("Shown in the expanded island when nothing is live, or via the Widgets tab. Drag or use the arrows to reorder.", "沒有即時活動時，展開的島嶼會顯示小工具；有活動時可切換到「小工具」分頁。拖曳或使用箭頭調整順序。", "没有实时活动时，展开的岛屿会显示小组件；有活动时可切换到“小组件”分页。拖动或使用箭头调整顺序。"),
        .moveUp: ("Move up", "上移", "上移"),
        .moveDown: ("Move down", "下移", "下移"),
        .usesNetwork: ("Uses network", "會連網", "会联网"),
        .weatherSection: ("Weather", "天氣", "天气"),
        .city: ("City", "城市", "城市"),
        .search: ("Search", "搜尋", "搜索"),
        .searching: ("Searching…", "搜尋中…", "搜索中…"),
        .selectedCity: ("Selected: %@", "已選擇：%@", "已选择：%@"),
        .noCitySelected: ("No city selected", "尚未選擇城市", "尚未选择城市"),
        .clear: ("Clear", "清除", "清除"),
        .temperatureUnit: ("Temperature unit", "溫度單位", "温度单位"),
        .celsius: ("Celsius (°C)", "攝氏（°C）", "摄氏（°C）"),
        .fahrenheit: ("Fahrenheit (°F)", "華氏（°F）", "华氏（°F）"),
        .weatherPrivacy: ("Choose a city or use your current location. Weather requests are sent to Open-Meteo while the widget is enabled.", "選擇城市或使用目前位置。開啟天氣小工具時會向 Open-Meteo 取得天氣。", "选择城市或使用当前位置。开启天气小组件时会向 Open-Meteo 获取天气。"),
        .stocksSection: ("Stocks", "股價", "股价"),
        .tickerPlaceholder: ("Ticker, e.g. AAPL", "股票代號，例如 AAPL", "股票代码，例如 AAPL"),
        .add: ("Add", "加入", "添加"),
        .remove: ("Remove", "移除", "移除"),
        .tickerInvalid: ("Use letters, digits, “.” or “-” (max 15).", "只能使用英文字母、數字、「.」或「-」（最多 15 字）。", "只能使用英文字母、数字、“.”或“-”（最多 15 个字符）。"),
        .tickerDuplicate: ("Already added.", "已經加入過了。", "已经添加过了。"),
        .tickerLimit: ("Up to 3 tickers (free API quota).", "最多 3 個代號（免費 API 配額限制）。", "最多 3 个代码（免费 API 配额限制）。"),
        .apiKey: ("Alpha Vantage API key", "Alpha Vantage API 金鑰", "Alpha Vantage API 密钥"),
        .apiKeySaved: ("Saved in your Keychain", "已儲存在鑰匙圈", "已保存在钥匙串"),
        .apiKeyMissing: ("Not set — quotes stay off", "尚未設定，不會取得股價", "尚未设置，不会获取股价"),
        .save: ("Save", "儲存", "保存"),
        .getFreeKey: ("Get a free key…", "申請免費金鑰…", "申请免费密钥…"),
        .stocksNote: ("Quotes come from Alpha Vantage's documented TIME_SERIES_DAILY API: the latest daily close, its change versus the previous close, and a chart of the real last 30 closes. Free keys allow about 25 requests a day, so quotes refresh every 3 hours (manual refresh at most every 5 minutes) and show the latest trading day — they are not real-time.", "股價來自 Alpha Vantage 有正式文件的 TIME_SERIES_DAILY API：最新每日收盤價、相對前一日收盤的漲跌，以及最近 30 個實際收盤價畫成的走勢圖。免費金鑰每天約 25 次請求，因此每 3 小時自動更新（手動更新最快每 5 分鐘一次），並標示最近交易日——不是即時報價。", "股价来自 Alpha Vantage 有正式文档的 TIME_SERIES_DAILY API：最新每日收盘价、相对前一日收盘的涨跌，以及最近 30 个实际收盘价绘制的走势图。免费密钥每天约 25 次请求，因此每 3 小时自动更新（手动更新最快每 5 分钟一次），并标示最近交易日——不是实时报价。"),
        .dailyCloses: ("%@-day closes", "近 %@ 日收盤", "近 %@ 日收盘"),
        .daysShort: ("%@D", "%@日", "%@日"),
        .clickToRefresh: ("Click to refresh", "點一下重新整理", "点一下刷新"),
        .percentCharged: ("%@ percent", "百分之 %@", "百分之 %@"),
        .degrees: ("%@ degrees", "%@ 度", "%@ 度"),
        .errKeychain: ("Can't read the API key from Keychain (locked or waiting for permission)", "無法從鑰匙圈讀取 API 金鑰（已鎖定或等待授權）", "无法从钥匙串读取 API 密钥（已锁定或等待授权）"),
        .deviceSection: ("This Mac", "這台 Mac", "这台 Mac"),
        .modelIdentifier: ("Model identifier", "機型識別碼", "机型标识符"),
        .display: ("Display", "顯示器", "显示器"),
        .notch: ("Notch", "瀏海", "刘海"),
        .notchSize: ("%@ × %@ pt", "%@ × %@ pt", "%@ × %@ pt"),
        .firstSeen: ("First launch on this Mac", "首次在這台 Mac 啟動", "首次在这台 Mac 启动"),
        .deviceNote: ("The notch is measured from what macOS reports for the screen, not from a model list, and re-measured whenever displays change.", "瀏海尺寸取自 macOS 回報的螢幕資訊，而不是機型對照表；顯示器變更時會重新測量。", "刘海尺寸取自 macOS 报告的屏幕信息，而不是机型对照表；显示器变更时会重新测量。"),
        .redetect: ("Re-detect", "重新偵測", "重新检测"),
        .builtIn: ("Built-in", "內建", "内建"),
        .external: ("External", "外接", "外接"),
        .startStopwatch: ("Start Stopwatch", "開始碼表", "开始秒表"),
        .stopStopwatch: ("Reset Stopwatch", "重設碼表", "重置秒表"),
        .allDay: ("All day", "全天", "全天"),
        .automationAllowed: ("Automation allowed", "已允許自動化", "已允许自动化"),
        .automationDenied: ("Automation denied", "自動化權限遭拒", "自动化权限被拒绝"),
        .automationNotAsked: ("Permission not requested", "尚未請求權限", "尚未请求权限"),
        .automationUnknown: ("Permission status unknown", "權限狀態未知", "权限状态未知"),
        .browserNotInstalled: ("Browser not installed", "未安裝瀏覽器", "未安装浏览器"),
        .browserNotRunning: ("Browser not running", "瀏覽器尚未開啟", "浏览器尚未打开"),
        .calendarAllow: ("Allow calendar access", "允許存取行事曆", "允许访问日历"),
        .calendarDenied: ("Calendar access denied", "行事曆權限遭拒", "日历权限被拒绝"),
        .calendarGranted: ("Calendar access allowed", "已允許存取行事曆", "已允许访问日历"),
        .calendarNotAsked: ("Calendar access not requested", "尚未請求行事曆權限", "尚未请求日历权限"),
        .calendarPrivacy: ("Calendar events stay on this Mac. Access is requested only when you choose to allow it.", "行事曆活動只留在這台 Mac，只有選擇允許時才會請求權限。", "日历活动只留在这台 Mac，只有选择允许时才会请求权限。"),
        .calendarWidget: ("Calendar", "行事曆", "日历"),
        .calendarWriteOnly: ("Full calendar access is required to show events", "顯示活動需要完整行事曆權限", "显示活动需要完整日历权限"),
        .chromeMedia: ("Google Chrome — YouTube, YouTube Music and its web app", "Google Chrome — YouTube、YouTube Music 及其網頁 App", "Google Chrome — YouTube、YouTube Music 及其网页 App"),
        .clockHint: ("Local time is always shown. Add up to %@ more time zones; with none, the widget shows an analog clock.", "一定會顯示本地時間；最多可再加入 %@ 個時區，沒有加入時小工具顯示指針時鐘。", "始终显示本地时间；最多可再添加 %@ 个时区，未添加时小组件显示指针时钟。"),
        .clockWidget: ("Clock", "時鐘", "时钟"),
        .currentLocation: ("Current Location", "目前位置", "当前位置"),
        .hoursOffset: ("%@ hours", "%@ 小時", "%@ 小时"),
        .jsDisabled: ("Allow JavaScript from Apple Events in your browser's developer settings.", "請在瀏覽器的開發者設定中允許 Apple Events 執行 JavaScript。", "请在浏览器的开发者设置中允许 Apple Events 执行 JavaScript。"),
        .locDenied: ("Location access denied", "定位權限遭拒", "定位权限被拒绝"),
        .locNetwork: ("Location network error", "定位網路錯誤", "定位网络错误"),
        .locRestricted: ("Location access restricted", "定位權限受到限制", "定位权限受到限制"),
        .locServicesOff: ("Location Services are off", "定位服務已關閉", "定位服务已关闭"),
        .locTimeout: ("Location request timed out", "取得位置逾時", "获取位置超时"),
        .locUnavailable: ("Location unavailable", "無法取得位置", "无法获取位置"),
        .localTime: ("Local time", "當地時間", "当地时间"),
        .locationPrivacy: ("With your permission, an approximate location is sent to Open-Meteo to obtain weather.", "經你允許後，概略位置會傳送至 Open-Meteo 以取得天氣。", "经你允许后，概略位置会发送至 Open-Meteo 以获取天气。"),
        .mediaPrivacy: ("Off by default. When on, the browser itself filters tabs: only https://music.youtube.com and https://www.youtube.com/watch|shorts pages are returned and read with a fixed, read-only script; other tabs' addresses never reach Notch Island. Nothing is logged or stored; playback is never started automatically. macOS has no public system-wide Now Playing API, so other sites and apps are not shown.", "預設關閉。開啟後由瀏覽器自己篩選分頁：只回傳 https://music.youtube.com 與 https://www.youtube.com/watch、shorts 頁面，並以固定的唯讀腳本讀取；其他分頁的網址不會傳到瀏海島。不記錄、不儲存，也不會自動開始播放。macOS 沒有公開的全系統「正在播放」API，因此其他網站與 App 不會顯示。", "默认关闭。开启后由浏览器自己筛选标签页：只返回 https://music.youtube.com 与 https://www.youtube.com/watch、shorts 页面，并以固定的只读脚本读取；其他标签页的网址不会传到刘海岛。不记录、不存储，也不会自动开始播放。macOS 没有公开的全系统“正在播放”API，因此其他网站与 App 不会显示。"),
        .mediaSection: ("Media", "媒體", "媒体"),
        .needsPermission: ("Permission needed", "需要授權", "需要授权"),
        .noEventsToday: ("No events today", "今天沒有活動", "今天没有活动"),
        .noUpcomingEvents: ("No upcoming events", "近期沒有活動", "近期没有活动"),
        .nowUntil: ("Now until %@", "進行中，至 %@", "进行中，至 %@"),
        .safariMedia: ("Safari — YouTube and YouTube Music", "Safari — YouTube 和 YouTube Music", "Safari — YouTube 和 YouTube Music"),
        .searchTimeZone: ("Search time zones", "搜尋時區", "搜索时区"),
        .stockSource: ("Stock data source", "股價資料來源", "股价数据来源"),
        .today: ("Today", "今天", "今天"),
        .tomorrow: ("Tomorrow", "明天", "明天"),
        .untitledEvent: ("Untitled event", "未命名活動", "未命名活动"),
        .widgetLimit: ("Show up to %@ widgets", "最多顯示 %@ 個小工具", "最多显示 %@ 个小组件"),
        .yahooAttribution: ("Yahoo Finance · prices may be delayed", "Yahoo Finance・報價可能延遲", "Yahoo Finance・报价可能延迟"),
        .yahooNote: ("Yahoo Finance is an unofficial source and may limit requests or become unavailable. Prices can be delayed.", "Yahoo Finance 為非官方資料來源，可能限流或停止服務，報價可能延遲。", "Yahoo Finance 为非官方数据源，可能限流或停止服务，报价可能延迟。"),
        .yahooOption: ("Yahoo Finance", "Yahoo Finance", "Yahoo Finance"),
        .yesterday: ("Yesterday", "昨天", "昨天"),
        .locating: ("Finding location…", "正在取得位置…", "正在获取位置…"),
        .updateLocation: ("Update location", "更新位置", "更新位置"),
        .useCurrentLocation: ("Use current location", "使用目前位置", "使用当前位置"),
        .alphaVantageOption: ("Alpha Vantage", "Alpha Vantage", "Alpha Vantage"),
        .calendarRange: ("Show events", "顯示活動範圍", "显示活动范围"),
        .rangeToday: ("Today", "今天", "今天"),
        .allowAutomation: ("Allow Automation", "允許自動化", "允许自动化"),
        .moreEvents: ("%@ more", "另有 %@ 項", "另有 %@ 项"),
        .rangeDays: ("Next %@ days", "未來 %@ 天", "未来 %@ 天"),
        .chromeJSHelp: ("Setup: 1) click Allow Automation and confirm the macOS prompt; 2) in Chrome's menu bar choose View › Developer › Allow JavaScript from Apple Events. Without step 2 only the presence of a YouTube tab is known, so nothing is shown as playing.", "設定：1) 按「允許自動化」並在 macOS 提示中允許；2) 在 Chrome 選單列選擇「顯示方式 › 開發人員 › 允許 Apple 事件中的 JavaScript」（英文為 View › Developer › Allow JavaScript from Apple Events）。沒有完成第 2 步時只知道有 YouTube 分頁，不會顯示為播放中。", "设置：1) 点“允许自动化”并在 macOS 提示中允许；2) 在 Chrome 菜单栏选择“显示 › 开发者 › 允许 Apple 事件中的 JavaScript”（英文为 View › Developer › Allow JavaScript from Apple Events）。未完成第 2 步时只知道有 YouTube 标签页，不会显示为播放中。"),
        .safariJSHelp: ("Setup: 1) click Allow Automation and confirm the macOS prompt; 2) Safari › Settings › Advanced › turn on “Show features for web developers”; 3) choose Develop › Allow JavaScript from Apple Events.", "設定：1) 按「允許自動化」並在 macOS 提示中允許；2) Safari › 設定 › 進階 › 開啟「顯示網頁開發者功能」；3) 選擇「開發 › 允許來自 Apple 事件的 JavaScript」。", "设置：1) 点“允许自动化”并在 macOS 提示中允许；2) Safari › 设置 › 高级 › 打开“显示网页开发者功能”；3) 选择“开发 › 允许来自 Apple 事件的 JavaScript”。"),
        .showAllDay: ("Show all-day events", "顯示全天活動", "显示全天活动"),
        .browserJSHint: ("YouTube tab found in %@. Turn on “Allow JavaScript from Apple Events” to show its playback.", "在 %@ 找到 YouTube 分頁。開啟「允許 Apple 事件中的 JavaScript」才能顯示播放狀態。", "在 %@ 找到 YouTube 标签页。开启“允许 Apple 事件中的 JavaScript”才能显示播放状态。"),
        .browserAutomationHint: ("Notch Island isn't allowed to control %@. Allow it in System Settings › Privacy & Security › Automation.", "瀏海島沒有控制 %@ 的權限。請到「系統設定 › 隱私權與安全性 › 自動化」允許。", "刘海岛没有控制 %@ 的权限。请到“系统设置 › 隐私与安全 › 自动化”允许。"),
        .setUp: ("Set Up…", "設定…", "设置…"),
        .ytmAppNotVisible: ("The YouTube Music app (PWA) is open, but Chrome reported no music.youtube.com tab to Apple Events, so its playback can't be read. Play it in a regular Chrome tab to show it here.", "YouTube Music App（PWA）已開啟，但 Chrome 沒有透過 Apple 事件回報任何 music.youtube.com 分頁，因此無法讀取它的播放狀態。請改在一般 Chrome 分頁播放才能顯示。", "YouTube Music App（PWA）已打开，但 Chrome 没有通过 Apple 事件报告任何 music.youtube.com 标签页，因此无法读取它的播放状态。请改在普通 Chrome 标签页播放才能显示。"),
        .ytmAppNotVisibleShort: ("YouTube Music app not readable — may not be what you hear", "無法讀取 YouTube Music App，這可能不是你正在聽的內容", "无法读取 YouTube Music App，这可能不是你正在听的内容"),
        .diagChecked: ("Checked %@", "%@ 檢查", "%@ 检查"),
        .diagTabs: ("%@: %@ tab(s), %@ playing", "%@：%@ 個分頁，%@ 個播放中", "%@：%@ 个标签页，%@ 个播放中"),
        .diagUnreadable: ("%@ unreadable", "%@ 個無法讀取", "%@ 个无法读取"),
        .diagAppRunning: ("YouTube Music app open", "YouTube Music App 已開啟", "YouTube Music App 已打开"),
        .diagShowing: ("showing: %@", "顯示：%@", "显示：%@"),
        .diagNothing: ("nothing", "無", "无"),
        .diagTime: ("time from %@ (%@ media elements on page)", "時間來源：%@（頁面上 %@ 個媒體元素）", "时间来源：%@（页面上 %@ 个媒体元素）"),
        .timeFromPlayerBar: ("player's visible time", "播放器顯示的時間", "播放器显示的时间"),
        .timeFromElement: ("player element", "播放器元素", "播放器元素"),
        .timeAd: ("ad playing (hidden)", "播放廣告中（不顯示）", "播放广告中（不显示）"),
        .timeNone: ("unavailable", "無法取得", "无法获取"),
        .timeFromPlayerAPI: ("YouTube player", "YouTube 播放器", "YouTube 播放器"),
        .widgetLimitTitle: ("Up to %@ widgets at a time", "一次最多 %@ 個小工具", "一次最多 %@ 个小组件"),
        .widgetLimitMessage: ("“%@” wasn't added because the island shows at most %@ widgets side by side. Currently on: %@. Turn one of them off first, then turn this one on again.", "「%@」沒有加入，因為島嶼一次最多並排顯示 %@ 個小工具。目前開啟：%@。請先關閉其中一個，再重新開啟這個小工具。", "“%@”没有添加，因为岛屿一次最多并排显示 %@ 个小组件。当前开启：%@。请先关闭其中一个，再重新开启这个小组件。"),
        .ok: ("OK", "好", "好"),
        .previousTrack: ("Previous track", "上一首", "上一首"),
        .playPause: ("Play/Pause", "播放/暫停", "播放/暂停"),
        .nextTrack: ("Next track", "下一首", "下一首"),
        .qaClipboard: ("Clipboard", "剪貼簿", "剪贴板"),
        .qaScreenshot: ("Screenshot", "截圖", "截图"),
        .qaScreenRecord: ("Record", "錄影", "录屏"),
        .qaShazam: ("Shazam", "Shazam", "Shazam"),
        .close: ("Close", "關閉", "关闭"),
        .cancel: ("Cancel", "取消", "取消"),
        .toastCopied: ("Copied", "已複製", "已复制"),
        .toastPasted: ("Pasted", "已貼上", "已粘贴"),
        .toastCancelled: ("Cancelled", "已取消", "已取消"),
        .toastPermission: ("Permission", "需授權", "需授权"),
        .toastFailed: ("Failed", "失敗", "失败"),
        .screenshotCopied: ("Screenshot copied to the clipboard.", "截圖已複製到剪貼簿。", "截图已复制到剪贴板。"),
        .back: ("Back", "返回", "返回"),
        .toastCaptureBusy: ("Capture open", "擷取中", "捕获中"),
        .screenshotOpenSystem: ("Open Screenshot", "開啟「截圖」", "打开“截图”"),
        .screenshotToolbarFailed: ("Couldn’t open Screenshot. Press Control–Shift–Command–4, then select the area to copy.", "無法開啟「截圖」。按下 Control–Shift–Command–4，再框選要複製的範圍。", "无法打开“截图”。按下 Control–Shift–Command–4，再框选要复制的范围。"),
        .recordToolbarFailed: ("Couldn’t open Screenshot. Press Shift-Command-5 to open its recording controls.", "無法開啟「截圖」。按下 ⇧⌘5 可開啟錄影工具列。", "无法打开“截图”。按下 ⇧⌘5 可打开录屏工具栏。"),
        .pasteNeedsPermission: ("Copied. To paste automatically into the app you were using, allow Notch Island to send keystrokes (System Settings › Privacy & Security › Accessibility); otherwise press ⌘V.", "已複製。若要自動貼到原本使用的 App，請允許瀏海島傳送按鍵（系統設定 › 隱私權與安全性 › 輔助使用）；否則請按 ⌘V。", "已复制。若要自动粘贴到原来使用的 App，请允许刘海岛发送按键（系统设置 › 隐私与安全 › 辅助功能）；否则请按 ⌘V。"),
        .pasteAllowed: ("Clicking an item pastes it into the app you were using.", "點一下紀錄會貼到原本使用的 App。", "点一下记录会粘贴到原来使用的 App。"),
        .clipboardClear: ("Clear history", "清除紀錄", "清除记录"),
        .clipboardClearConfirm: ("Clear all?", "全部清除？", "全部清除？"),
        .clipboardOff: ("Clipboard history is off", "剪貼簿紀錄已關閉", "剪贴板记录已关闭"),
        .clipboardOffHint: ("When on, copied text, images and files are kept on this Mac for %@ and then deleted. Password-manager and concealed items are never kept.", "開啟後，複製的文字、圖片和檔案只保存在這台 Mac %@，之後自動刪除。密碼管理器與標記為隱藏的內容一律不保存。", "开启后，复制的文本、图片和文件只保存在这台 Mac %@，之后自动删除。密码管理器与标记为隐藏的内容一律不保存。"),
        .clipboardTurnOn: ("Turn On", "開啟", "开启"),
        .clipboardEmpty: ("Nothing copied yet.", "還沒有複製任何內容。", "还没有复制任何内容。"),
        .clipboardFooter: ("Kept %@ · only on this Mac · click to paste", "保存 %@・只在這台 Mac・點一下貼上", "保存 %@・只在这台 Mac・点一下粘贴"),
        .clipboardImage: ("Image", "圖片", "图片"),
        .clipboardText: ("Text", "文字", "文本"),
        .clipboardFiles: ("Files", "檔案", "文件"),
        .clipboardPasteHint: ("Paste into the app you were using", "貼到原本使用的 App", "粘贴到原来使用的 App"),
        .clipboardHistoryToggle: ("Keep clipboard history", "保存剪貼簿紀錄", "保存剪贴板记录"),
        .clipboardRetention: ("Keep for", "保存期限", "保存期限"),
        .clipboardCount: ("%@ items saved", "已保存 %@ 筆", "已保存 %@ 条"),
        .clipboardPrivacy: ("Off by default. Up to 50 recent items (text ≤ 100 KB, images ≤ 8 MB, ≤ 20 files) are kept only on this Mac (owner-only files) and deleted after the chosen period. Copies from password managers, or marked concealed/transient by the app, are never kept. Nothing is uploaded or logged.", "預設關閉。最多保存 50 筆最近紀錄（文字 ≤ 100 KB、圖片 ≤ 8 MB、≤ 20 個檔案），只存在這台 Mac（僅本人可讀），超過期限自動刪除。從密碼管理器複製、或被 App 標記為隱藏／暫時的內容一律不保存。不會上傳或寫入日誌。", "默认关闭。最多保存 50 条最近记录（文本 ≤ 100 KB、图片 ≤ 8 MB、≤ 20 个文件），只存在这台 Mac（仅本人可读），超过期限自动删除。从密码管理器复制、或被 App 标记为隐藏／临时的内容一律不保存。不会上传或写入日志。"),
        .retention1: ("1 day", "1 天", "1 天"),
        .retention3: ("3 days", "3 天", "3 天"),
        .retention7: ("7 days", "7 天", "7 天"),
        .retention30: ("30 days", "30 天", "30 天"),
        .shazamPrivacy: ("ShazamKit sends audio signatures (not recordings) to Apple to identify music; needs internet. Notch Island doesn't store or upload audio.", "ShazamKit 會把音訊特徵（不是錄音）傳給 Apple 辨識音樂，需要網路。瀏海島不儲存也不上傳音訊。", "ShazamKit 会把音频特征（不是录音）发送给 Apple 识别音乐，需要网络。刘海岛不存储也不上传音频。"),
        .shazamStart: ("Choose audio to identify a song", "選擇要辨識的音訊來源", "选择要识别的音频来源"),
        .shazamCancelled: ("Stopped listening.", "已停止聆聽。", "已停止聆听。"),
        .shazamListening: ("Listening…", "聆聽中…", "聆听中…"),
        .shazamMic: ("Microphone", "麥克風", "麦克风"),
        .shazamSystemAudio: ("This Mac's audio", "這台 Mac 的聲音", "这台 Mac 的声音"),
        .shazamOpen: ("Open", "開啟", "打开"),
        .shazamCopy: ("Copy", "複製", "复制"),
        .shazamAgain: ("Choose Audio Source", "選擇音訊來源", "选择音频来源"),
        .shazamNoMatch: ("No match found in 30 seconds.", "30 秒內找不到符合的歌曲。", "30 秒内找不到匹配的歌曲。"),
        .shazamMicDenied: ("Microphone access is off.", "麥克風權限已關閉。", "麦克风权限已关闭。"),
        .shazamNoSource: ("No audio source could be started.", "無法啟動任何音訊來源。", "无法启动任何音频来源。"),
        .shazamNetwork: ("Couldn't reach Shazam — check your internet connection.", "無法連線到 Shazam，請檢查網路。", "无法连接到 Shazam，请检查网络。"),
        .shazamService: ("ShazamKit returned error %@ and couldn't finish.", "ShazamKit 回報錯誤 %@，無法完成辨識。", "ShazamKit 返回错误 %@，无法完成识别。"),
        .shazamCatalogFailed: ("The Shazam catalog couldn’t complete the request (202). This build may need a ShazamKit-enabled App ID.", "Shazam 曲庫無法完成比對（202）。這個版本可能需要啟用 ShazamKit 的 App ID。", "Shazam 曲库无法完成匹配（202）。此版本可能需要启用 ShazamKit 的 App ID。"),
        .shazamRetrying: ("Catalog returned error 202 — still retrying.", "曲庫回報錯誤 202，仍在重試。", "曲库返回错误 202，仍在重试。"),
        .shazamShortcut: ("Shazam Shortcut…", "Shazam 捷徑…", "Shazam 快捷指令…"),
        .shazamShortcutName: ("Exact shortcut name", "捷徑的完整名稱", "快捷指令的完整名称"),
        .shazamShortcutHelp: ("Enter the name of your Shazam shortcut. If needed, add one from the Shortcuts Gallery first. Shortcuts handles the audio and cancellation. Add a text output to see the song here.", "輸入你的 Shazam 捷徑名稱。若還沒有，先從「捷徑」的捷徑資料庫加入。音訊與停止由「捷徑」處理。加入文字輸出後即可在此查看曲名。", "输入你的 Shazam 快捷指令名称。如还没有，先从“快捷指令”的快捷指令中心添加。音频与停止由“快捷指令”处理。添加文本输出后可在这里查看曲名。"),
        .shazamShortcutRun: ("Run Shortcut", "執行捷徑", "运行快捷指令"),
        .shazamShortcutGallery: ("Open Gallery", "開啟捷徑資料庫", "打开快捷指令中心"),
        .shazamShortcutRunning: ("Running in Shortcuts… Use Shortcuts to stop it.", "捷徑正在執行，可在「捷徑」停止。", "快捷指令正在运行，可在“快捷指令”停止。"),
        .shazamShortcutFinished: ("The shortcut finished without text output. Check Shortcuts for its result.", "捷徑已完成，沒有傳回文字。請在「捷徑」查看結果。", "快捷指令已完成，未返回文本。请在“快捷指令”查看结果。"),
        .shazamShortcutFailed: ("The shortcut failed or was cancelled. Check its name and actions in Shortcuts.", "捷徑失敗或已取消。請在「捷徑」確認名稱與動作。", "快捷指令失败或已取消。请在“快捷指令”检查名称和操作。"),
        .audDTrial: ("Trial and pricing", "試用與費用", "试用与费用"),
        .audDPreparing: ("Preparing the selected source…", "正在準備選定的音源…", "正在准备选定的音源…"),
        .audDSending: ("Sending the clip to AudD…", "正在把音訊片段傳給 AudD…", "正在向 AudD 发送音频片段…"),
        .audDNoAudio: ("Couldn’t capture at least 3 s of sound from this source; nothing was uploaded (silence is never sent).", "無法從這個音源取得至少 3 秒的聲音，沒有上傳任何內容（靜音不會送出）。", "无法从此音源获取至少 3 秒的声音，没有上传任何内容（静音不会发送）。"),
        .shazamSystemOpen: ("Recognize with macOS", "用 macOS 辨識音樂", "用 macOS 识别音乐"),
        .shazamSystemFallback: ("“Recognize with macOS” presses Recognize Music in Control Center for you (needs Accessibility). macOS listens and shows the result in Control Center; it doesn't come back to Notch Island.", "「用 macOS 辨識音樂」會替你按下控制中心的「辨識音樂」（需要輔助使用權限）。由 macOS 聆聽，結果顯示在控制中心，不會回到瀏海島。", "“用 macOS 识别音乐”会替你点按控制中心的“识别音乐”（需要辅助功能权限）。由 macOS 聆听，结果显示在控制中心，不会回到刘海岛。"),
        .shazamSystemUnavailable: ("Couldn’t press Recognize Music in Control Center. Open Control Center › Recognize Music yourself, or try a Shortcut.", "無法替你按下控制中心的「辨識音樂」。請自行打開「控制中心」›「辨識音樂」，或改用捷徑。", "无法替你点按控制中心的“识别音乐”。请自行打开“控制中心”›“识别音乐”，或改用快捷指令。"),
        .shazamSystemListening: ("macOS is listening (Control Center shows “Listening…”). The result appears in Control Center and doesn't come back to Notch Island.", "macOS 正在聆聽（控制中心顯示「聆聽中」）。結果會顯示在控制中心，不會回到瀏海島。", "macOS 正在聆听（控制中心显示“正在听取”）。结果会显示在控制中心，不会回到刘海岛。"),
        .shazamSystemUncertain: ("Recognize Music was pressed, but Notch Island couldn't confirm that macOS started listening. Check Control Center.", "已按下「辨識音樂」，但瀏海島無法確認 macOS 已開始聆聽。請查看控制中心。", "已点按“识别音乐”，但刘海岛无法确认 macOS 已开始聆听。请查看控制中心。"),
        .shazamSystemNeedsAX: ("To press Recognize Music for you, allow Notch Island under Privacy & Security › Accessibility. Nothing is granted automatically.", "要替你按下「辨識音樂」，需在「隱私權與安全性」›「輔助使用」允許瀏海島。不會自動授權。", "要替你点按“识别音乐”，需在“隐私与安全”›“辅助功能”允许刘海岛。不会自动授权。"),
        .shazamSystemMissing: ("Recognize Music isn't in Control Center. Add it under System Settings › Control Center (or Control Center › Edit Controls), then try again.", "控制中心沒有「辨識音樂」。請到「系統設定」›「控制中心」（或控制中心的「編輯控制項目」）加入後再試。", "控制中心没有“识别音乐”。请到“系统设置”›“控制中心”（或控制中心的“编辑控制”）添加后再试。"),
        .recordToolbarHelp: ("Opens the macOS recording toolbar in video mode. Nothing records until you click Record.", "開啟 macOS 錄影工具列（已切到錄影模式）。按下「錄製」前不會開始錄影。", "打开 macOS 录屏工具栏（已切到录屏模式）。点按“录制”前不会开始录制。"),
        .captureToolRefused: ("The macOS capture tool reported that capturing isn't allowed.", "macOS 擷取工具回報「不允許擷取」。", "macOS 捕获工具报告“不允许捕获”。"),
        .captureToolNoImage: ("The macOS capture tool reported that it couldn't read the screen.", "macOS 擷取工具回報無法讀取畫面。", "macOS 捕获工具报告无法读取屏幕。"),
        .captureToolFailed: ("The macOS capture tool stopped unexpectedly (status %@). The cause is unknown; it doesn't indicate a permission problem.", "macOS 擷取工具意外結束（狀態 %@）。原因不明，並不代表權限問題。", "macOS 捕获工具意外结束（状态 %@）。原因不明，并不代表权限问题。"),
        .captureAdviceStaleGrant: ("macOS reports that this copy of Notch Island has no Screen & System Audio Recording permission. This copy is ad-hoc signed, so macOS identifies it by its exact build: a permission given to an earlier build or DMG doesn't carry over, even if the old switch still looks on. Likely fix: in Privacy & Security › Screen & System Audio Recording, remove Notch Island, add this copy again, then reopen it.", "macOS 回報「目前這個」瀏海島沒有「螢幕與系統錄音」權限。這個版本是 ad-hoc 簽章，macOS 以確切的建置內容辨識它；給先前建置或舊 DMG 的授權不會沿用，即使設定中的開關看起來仍是開啟。可能的解法：到「隱私權與安全性」›「螢幕與系統錄音」移除瀏海島，再加入目前這份 App，然後重新開啟瀏海島。", "macOS 报告“当前这个”刘海岛没有“录屏与系统录音”权限。此版本为 ad-hoc 签名，macOS 按确切的构建内容识别它；授予先前构建或旧 DMG 的权限不会沿用，即使设置中的开关看起来仍是打开的。可能的解决方法：到“隐私与安全”›“录屏与系统录音”移除刘海岛，再添加当前这个 App，然后重新打开刘海岛。"),
        .captureAdviceNotGranted: ("macOS reports that Notch Island has no Screen & System Audio Recording permission.", "macOS 回報瀏海島沒有「螢幕與系統錄音」權限。", "macOS 报告刘海岛没有“录屏与系统录音”权限。"),
        .captureAdviceUnknown: ("macOS reports that the permission is granted, so the cause can't be determined.", "macOS 回報已授予權限，因此無法判斷原因。", "macOS 报告已授予权限，因此无法判断原因。"),
        .recordNeedsGrant: ("Notch Island can only open the recording toolbar directly when macOS reports its Screen & System Audio Recording permission. It doesn't right now, so nothing was opened.", "只有在 macOS 回報瀏海島已有「螢幕與系統錄音」權限時，才能直接開啟錄影工具列。目前沒有，所以沒有開啟任何工具。", "只有在 macOS 报告刘海岛已有“录屏与系统录音”权限时，才能直接打开录屏工具栏。目前没有，所以没有打开任何工具。"),
        .recordFallbackHelp: ("Other ways that work without that permission: QuickTime opens the same toolbar in recording mode (macOS asks once whether Notch Island may control QuickTime). Screenshot opens in the mode you used last: click Record Entire Screen or Record Selected Portion (screen icons with a dot), then Record. Shortcut: ⇧⌘5.", "不需要該權限的其他方式：QuickTime 會以錄影模式開啟同一個工具列（macOS 會詢問一次是否允許瀏海島控制 QuickTime）。「截圖」會開在你上次使用的模式：請按「錄製整個螢幕」或「錄製所選部分」（帶圓點的螢幕圖示），再按「錄製」。快捷鍵：⇧⌘5。", "无需该权限的其他方式：QuickTime 会以录屏模式打开同一个工具栏（macOS 会询问一次是否允许刘海岛控制 QuickTime）。“截图”会以你上次使用的模式打开：请点按“录制整个屏幕”或“录制所选部分”（带圆点的屏幕图标），再点按“录制”。快捷键：⇧⌘5。"),
        .screenshotFallbackHelp: ("You can use the macOS Screenshot toolbar instead; it has its own permission. Hold Control while capturing to copy the image.", "也可以改用 macOS「截圖」工具列，它有自己的權限。擷取時按住 Control 即可複製。", "也可以改用 macOS“截图”工具栏，它有自己的权限。捕获时按住 Control 即可复制。"),
        .recordWithQuickTime: ("Record with QuickTime", "用 QuickTime 錄影", "用 QuickTime 录屏"),
        .recordOpenScreenshot: ("Open Screenshot", "開啟「截圖」", "打开“截图”"),
        .openPrivacySettings: ("Open Privacy Settings", "開啟隱私權設定", "打开隐私设置"),
        .toastPickRecordMode: ("Pick a Record button", "請選錄影按鈕", "请选录屏按钮"),
        .toastQuickTimeRequested: ("Asked QuickTime", "已請 QuickTime 開啟", "已请 QuickTime 打开"),
        .recordQuickTimeDenied: ("macOS didn't allow Notch Island to control QuickTime Player (you can change this in Privacy & Security › Automation). You can open Screenshot instead and click Record Entire Screen or Record Selected Portion.", "macOS 不允許瀏海島控制 QuickTime Player（可在「隱私權與安全性」›「自動化」更改）。你可以改開「截圖」，再按「錄製整個螢幕」或「錄製所選部分」。", "macOS 不允许刘海岛控制 QuickTime Player（可在“隐私与安全”›“自动化”更改）。你可以改为打开“截图”，再点按“录制整个屏幕”或“录制所选部分”。"),
        .audDTitle: ("AudD…", "AudD…", "AudD…"),
        .audDSummary: ("Third-party AudD: uploads up to 10 s of the source you pick. Your own token; may use paid quota.", "第三方 AudD：上傳你所選音源最多 10 秒。使用你自己的金鑰，可能消耗付費額度。", "第三方 AudD：上传你所选音源最多 10 秒。使用你自己的密钥，可能消耗付费额度。"),
        .audDUploadSystem: ("Upload 10 s of Mac audio", "上傳 10 秒 Mac 聲音", "上传 10 秒 Mac 声音"),
        .audDUploadMic: ("Upload 10 s of mic", "上傳 10 秒麥克風", "上传 10 秒麦克风"),
        .audDSetup: ("Privacy & Token…", "隱私與金鑰…", "隐私与密钥…"),
        .audDSetupTitle: ("AudD music recognition (third party)", "AudD 音樂辨識（第三方服務）", "AudD 音乐识别（第三方服务）"),
        .audDDisclosure: ("What happens: when you click an Upload button, Notch Island records up to 10 seconds from that source only (this Mac's audio output or the microphone) and uploads it as a WAV file to AudD (api.audd.io), a third-party service not affiliated with Notch Island or Apple. Everything audible is included, such as voices in the room or other apps' sounds. AudD's privacy policy applies to the upload.\n\nOn this Mac: the clip is kept in memory only, never written to disk, and dropped after the request or when you cancel. Your token is stored in the macOS Keychain and only sent to api.audd.io.\n\nCost: you need your own AudD account and token. AudD's pricing page (checked 9 Nov 2026) lists a trial for new accounts where available: 300 requests within 14 days, no card, stops when used up. Afterwards each request uses your paid plan's quota (plans from US$5/month). Notch Island can't see your balance.", "會發生什麼：你按下「上傳」按鈕時，瀏海島只從該音源（這台 Mac 的聲音輸出或麥克風）錄下最多 10 秒，並以 WAV 檔上傳到 AudD（api.audd.io）。AudD 是與瀏海島及 Apple 無關的第三方服務。片段包含所有聽得到的聲音，例如房間裡的人聲或其他 App 的聲音。上傳內容適用 AudD 的隱私權政策。\n\n在這台 Mac 上：片段只存在記憶體，不寫入磁碟，請求結束或你取消後即丟棄。金鑰存放在 macOS 鑰匙圈，只會傳給 api.audd.io。\n\n費用：你需要自己的 AudD 帳號與金鑰。AudD 定價頁（2026-11-09 查閱）寫明新帳號在可提供的地區有試用：14 天內 300 次、不需信用卡、用完即停止。之後每次辨識都會消耗你付費方案的額度（方案每月 5 美元起）。瀏海島無法查看你的剩餘額度。", "会发生什么：你点按“上传”按钮时，刘海岛只从该音源（这台 Mac 的声音输出或麦克风）录下最多 10 秒，并以 WAV 文件上传到 AudD（api.audd.io）。AudD 是与刘海岛及 Apple 无关的第三方服务。片段包含所有能听到的声音，例如房间里的人声或其他 App 的声音。上传内容适用 AudD 的隐私政策。\n\n在这台 Mac 上：片段只存在内存，不写入磁盘，请求结束或你取消后即丢弃。密钥存放在 macOS 钥匙串，只会发送给 api.audd.io。\n\n费用：你需要自己的 AudD 账户和密钥。AudD 定价页（2026-11-09 查阅）写明新账户在可提供的地区有试用：14 天内 300 次、无需信用卡、用完即停止。之后每次识别都会消耗你付费方案的额度（方案每月 5 美元起）。刘海岛无法查看你的剩余额度。"),
        .audDConsentCheck: ("I understand and agree to upload clips to AudD", "我了解並同意將片段上傳到 AudD", "我了解并同意将片段上传到 AudD"),
        .audDToken: ("AudD API token", "AudD API 金鑰", "AudD API 密钥"),
        .audDTokenReplace: ("New token (leave blank to keep the saved one)", "新金鑰（留空則保留已儲存的金鑰）", "新密钥（留空则保留已保存的密钥）"),
        .audDTokenStored: ("A token is saved in Keychain.", "鑰匙圈中已儲存金鑰。", "钥匙串中已保存密钥。"),
        .audDTokenNone: ("No token saved.", "尚未儲存金鑰。", "尚未保存密钥。"),
        .audDSave: ("Save", "儲存", "保存"),
        .audDRemoveToken: ("Remove Token", "移除金鑰", "移除密钥"),
        .audDTokenRejected: ("The token wasn't saved: it must be a single word without spaces, or Keychain refused it.", "金鑰未儲存：必須是不含空白的一段文字，或鑰匙圈拒絕寫入。", "密钥未保存：必须是不含空格的一段文字，或钥匙串拒绝写入。"),
        .audDNeedsConsent: ("Read Privacy & Token… and agree before anything is uploaded.", "上傳前請先閱讀「隱私與金鑰…」並同意。", "上传前请先阅读“隐私与密钥…”并同意。"),
        .audDMissingToken: ("Save your own AudD token under Privacy & Token… first.", "請先在「隱私與金鑰…」儲存你自己的 AudD 金鑰。", "请先在“隐私与密钥…”保存你自己的 AudD 密钥。"),
        .audDReady: ("Ready. Nothing is recorded until you click Upload.", "已就緒。按下「上傳」前不會錄音。", "已就绪。点按“上传”前不会录音。"),
        .audDListening: ("Recording up to 10 s in memory for AudD…", "正在把最多 10 秒錄進記憶體，準備傳給 AudD…", "正在把最多 10 秒录进内存，准备发送给 AudD…"),
        .audDCancelled: ("Stopped and discarded. If the upload had already started, AudD may have received the clip.", "已停止並丟棄。若上傳已開始，AudD 可能已收到片段。", "已停止并丢弃。如果上传已开始，AudD 可能已收到片段。"),
        .audDNetwork: ("Couldn’t reach AudD. Check your connection; nothing was matched.", "無法連線到 AudD。請檢查網路，這次沒有結果。", "无法连接到 AudD。请检查网络，这次没有结果。"),
        .audDInvalidToken: ("AudD rejected the token (error 900). Replace it under Privacy & Token….", "AudD 拒絕這個金鑰（錯誤 900）。請在「隱私與金鑰…」更換。", "AudD 拒绝该密钥（错误 900）。请在“隐私与密钥…”更换。"),
        .audDLimit: ("AudD reports the request limit is reached (error %@): the trial or plan quota may be used up.", "AudD 回報已達請求上限（錯誤 %@），試用或方案額度可能已用完。", "AudD 报告已达请求上限（错误 %@），试用或方案额度可能已用完。"),
        .audDServiceError: ("AudD returned error %@; no result.", "AudD 回報錯誤 %@，沒有結果。", "AudD 返回错误 %@，没有结果。"),
        .audDBadResponse: ("AudD's answer couldn't be read (HTTP %@); no result.", "無法解讀 AudD 的回應（HTTP %@），沒有結果。", "无法解读 AudD 的响应（HTTP %@），没有结果。"),
        .audDNoMatch: ("AudD found no match.", "AudD 找不到符合的歌曲。", "AudD 找不到匹配的歌曲。"),
        .shazamSystemGuide: ("Apple's Guide", "Apple 官方教學", "Apple 官方教程"),
        .onboardingTitle: ("Welcome to Notch Island", "歡迎使用瀏海島", "欢迎使用刘海岛"),
        .onboardingMenu: ("Welcome Guide…", "歡迎導覽…", "欢迎导览…"),
        .onboardingIntro: ("Choose your language and which features may use system permissions. Nothing is requested until you press Allow, and you can change everything later in Settings. Your existing settings are kept.", "選擇語言，以及哪些功能可以使用系統權限。在你按下「允許」之前不會請求任何權限，之後也可以在設定中更改。既有設定都會保留。", "选择语言，以及哪些功能可以使用系统权限。在你按下“允许”之前不会请求任何权限，之后也可以在设置中更改。现有设置都会保留。"),
        .onboardingPermissions: ("Permissions", "權限", "权限"),
        .onboardingPermissionsFooter: ("Each permission is only used for the feature described. Some are asked by macOS the first time you use that feature.", "每項權限只用於所述功能。有些權限會在你第一次使用該功能時由 macOS 詢問。", "每项权限只用于所述功能。有些权限会在你第一次使用该功能时由 macOS 询问。"),
        .onboardingDone: ("Done", "完成", "完成"),
        .permGranted: ("Allowed", "已允許", "已允许"),
        .permNotGranted: ("Not allowed yet", "尚未允許", "尚未允许"),
        .permDenied: ("Denied", "已拒絕", "已拒绝"),
        .permAllow: ("Allow…", "允許…", "允许…"),
        .permKeystrokes: ("Send keystrokes (Accessibility)", "傳送按鍵（輔助使用）", "发送按键（辅助功能）"),
        .permKeystrokesWhy: ("Pastes a clipboard item into the app you were using (⌘V), and sends media keys if you turn that on.", "把剪貼簿紀錄貼到原本使用的 App（⌘V），以及在開啟時傳送媒體鍵。", "把剪贴板记录粘贴到原来使用的 App（⌘V），以及在开启时发送媒体键。"),
        .permScreen: ("Screen Recording", "螢幕錄製", "屏幕录制"),
        .permScreenWhy: ("Lets the Screenshot button capture the area you select.", "讓「截圖」按鈕擷取你選取的範圍。", "让“截图”按钮捕获你选取的范围。"),
        .permMicrophone: ("Microphone", "麥克風", "麦克风"),
        .permMicrophoneWhy: ("Used only while Shazam is listening (up to 30 seconds).", "只在 Shazam 聆聽時使用（最多 30 秒）。", "只在 Shazam 聆听时使用（最多 30 秒）。"),
        .permNotifications: ("Notifications", "通知", "通知"),
        .permNotificationsWhy: ("Optional: a system notification for screenshots and permission problems.", "選用：截圖完成或權限問題時顯示系統通知。", "可选：截图完成或权限问题时显示系统通知。"),
        .permAutomation: ("Automation", "自動化", "自动化"),
        .permAutomationWhy: ("Asked by macOS when you first use Music/Spotify or browser media controls.", "在你第一次使用「音樂」／Spotify 或瀏覽器媒體控制時，由 macOS 詢問。", "在你第一次使用“音乐”／Spotify 或浏览器媒体控制时，由 macOS 询问。"),
        .permSystemAudio: ("System Audio Recording", "系統音訊錄製", "系统音频录制"),
        .permSystemAudioWhy: ("Asked by macOS the first time Shazam listens to this Mac's audio or real audio levels are turned on. Audio stays in memory.", "在 Shazam 第一次聆聽這台 Mac 的聲音、或開啟真實音量時，由 macOS 詢問。音訊只在記憶體中處理。", "在 Shazam 第一次聆听这台 Mac 的声音、或开启真实音量时，由 macOS 询问。音频只在内存中处理。"),
        .permLocationCalendar: ("Location & Calendar", "定位與行事曆", "定位与日历"),
        .permLocationCalendarWhy: ("Asked only when you turn on the Weather (current location) or Calendar widget.", "只在你開啟天氣（目前位置）或行事曆小工具時詢問。", "只在你开启天气（当前位置）或日历小组件时询问。"),
        .controlSending: ("Sending to the player…", "正在傳送到播放器…", "正在发送到播放器…"),
        .audioLevelsToggle: ("Show real audio levels", "顯示真實音訊音量", "显示真实音频音量"),
        .audioLevelsOff: ("Off — the bars play a decorative animation that is not linked to the sound (no audio is accessed).", "已關閉：音波長條是裝飾動畫，不代表實際聲音（不會存取任何音訊）。", "已关闭：音波条是装饰动画，不代表实际声音（不会访问任何音频）。"),
        .audioLevelsUnsupported: ("Needs macOS 14.2 or later (Core Audio process taps).", "需要 macOS 14.2 以上（Core Audio 程序擷取）。", "需要 macOS 14.2 以上（Core Audio 进程捕获）。"),
        .audioLevelsIdle: ("On — starts when something plays.", "已開啟：開始播放時啟用。", "已开启：开始播放时启用。"),
        .audioLevelsRunning: ("Receiving system audio levels — the bars follow the sound.", "正在接收系統音訊音量，音波長條會跟隨聲音。", "正在接收系统音频音量，音波条会跟随声音。"),
        .audioLevelsSilent: ("Only silence is arriving while media plays — System Audio Recording may be denied (System Settings › Privacy & Security › Screen & System Audio Recording), or the source is muted. The bars show the decorative animation meanwhile.", "播放中卻只收到靜音：可能未允許「系統音訊錄製」（系統設定 › 隱私權與安全性 › 螢幕與系統音訊錄製），或音源已靜音。此時音波長條顯示的是裝飾動畫。", "播放中却只收到静音：可能未允许“系统音频录制”（系统设置 › 隐私与安全 › 屏幕与系统音频录制），或音源已静音。此时音波条显示的是装饰动画。"),
        .audioLevelsFailed: ("Couldn't start system audio capture (permission denied or audio device unavailable). The bars show the decorative animation.", "無法啟動系統音訊擷取（權限遭拒或音訊裝置無法使用），音波長條顯示的是裝飾動畫。", "无法启动系统音频捕获（权限被拒或音频设备不可用），音波条显示的是装饰动画。"),
        .audioLevelsNote: ("Off by default, the bars play a decorative animation in the album cover's colours that is not linked to the sound. When on, Notch Island uses macOS's public Core Audio tap to measure the system's output (all apps except itself) while media plays, and the bars then follow those real levels. macOS asks once for System Audio Recording. Audio is analysed in memory only — never recorded, stored or sent.", "預設關閉時，音波長條是使用專輯封面顏色的裝飾動畫，不代表實際聲音。開啟後，瀏海島會在播放時以 macOS 公開的 Core Audio 擷取功能量測系統輸出（除本 App 外的所有 App），長條改為跟隨實際音量。macOS 會詢問一次「系統音訊錄製」權限。音訊只在記憶體中分析，不會錄製、儲存或傳送。", "默认关闭时，音波条是使用专辑封面颜色的装饰动画，不代表实际声音。开启后，刘海岛会在播放时以 macOS 公开的 Core Audio 捕获功能测量系统输出（除本 App 外的所有 App），音波条改为跟随实际音量。macOS 会询问一次“系统音频录制”权限。音频只在内存中分析，不会录制、存储或发送。"),
        .stockSearchPlaceholder: ("Search company or ticker (e.g. Apple, TSM, 2330.TW)", "搜尋公司或代號（例如 Apple、TSM、2330.TW）", "搜索公司或代码（例如 Apple、TSM、2330.TW）"),
        .stockSearchEmpty: ("No matching listings.", "找不到符合的股票。", "找不到匹配的股票。"),
        .exchange: ("Exchange", "交易所", "交易所"),
        .allExchanges: ("All exchanges", "所有交易所", "所有交易所"),
        .addTypedTicker: ("Add “%@” as typed", "直接加入「%@」", "直接添加“%@”"),
        .errUnsupportedQuery: ("This source only searches Latin letters and tickers — try an English name (e.g. TSMC) or a ticker like 2330.TW.", "這個資料來源只能用英文或代號搜尋，請改用英文名稱（例如 TSMC）或代號（例如 2330.TW）。", "这个数据源只能用英文或代码搜索，请改用英文名称（例如 TSMC）或代码（例如 2330.TW）。"),
        .controlCenterToggle: ("Control playback through Control Center", "透過控制中心操作播放", "通过控制中心操作播放"),
        .controlCenterNote: ("Uses Accessibility to operate Now Playing. The panel may open when you press a control. For YouTube Music, Notch Island can skip tracks directly in a recognized Chrome web app.", "使用輔助使用功能操作系統「播放中」。按下控制鍵時可能會開啟控制中心。瀏海島可直接在辨識到的 Chrome YouTube Music 網頁 App 內切歌。", "使用辅助功能操作系统“播放中”。按下控制键时可能会打开控制中心。刘海岛可直接在识别到的 Chrome YouTube Music 网页应用内切歌。"),
        .controlCenterPermission: ("Allow Notch Island in System Settings › Privacy & Security › Accessibility.", "請在「系統設定 › 隱私權與安全性 › 輔助使用」允許瀏海島。", "请在“系统设置 › 隐私与安全 › 辅助功能”允许刘海岛。"),
        .controlCenterUnavailable: ("Couldn't find that button in Control Center. Open Now Playing and try again.", "找不到控制中心的這個按鈕。請開啟「播放中」面板後再試。", "找不到控制中心的此按钮。请打开“播放中”面板后重试。"),
        .controlCenterUncertain: ("The player didn’t confirm the command. Check playback before trying again.", "播放器未確認指令。請先確認播放狀態，再試一次。", "播放器未确认指令。请先确认播放状态，再试一次。"),
        .skipUnavailable: ("Couldn't find an available skip button in YouTube Music.", "找不到 YouTube Music 中可用的切歌按鈕。", "找不到 YouTube Music 中可用的切歌按钮。"),
        .playbackPosition: ("Playback position", "播放進度", "播放进度"),
        .seekFailed: ("Couldn't jump to that position.", "無法跳到指定位置。", "无法跳到指定位置。"),
        .mediaKeysStaleGrant: ("Permission was given to an earlier build. This build is ad-hoc signed, so macOS treats it as a new app: in System Settings › Privacy & Security › Accessibility, remove Notch Island (−) and add it again (+), or turn it off and on.", "權限是授予先前的版本。這個版本是 ad-hoc 簽章，macOS 會把它視為新的 App：請到「系統設定 › 隱私權與安全性 › 輔助使用」移除瀏海島（−）再重新加入（+），或把它關閉後再開啟。", "权限是授予先前的版本。这个版本是 ad-hoc 签名，macOS 会把它视为新的 App：请到“系统设置 › 隐私与安全 › 辅助功能”移除刘海岛（−）再重新添加（+），或把它关闭后再开启。"),
        .controlNoEffect: ("The player didn't change — it may not be the one receiving the command.", "播放器沒有變化，可能不是接收指令的那個播放器。", "播放器没有变化，可能不是接收指令的那个播放器。"),
        .listSeparator: (", ", "、", "、"),
        .timerMinutes: ("%@ minutes", "%@ 分鐘", "%@ 分钟"),
        .timerLess: ("1 minute less", "減少 1 分鐘", "减少 1 分钟"),
        .timerMore: ("1 minute more", "增加 1 分鐘", "增加 1 分钟"),
        .systemNowPlaying: ("System Now Playing (like Control Center)", "系統「正在播放」（同控制中心）", "系统“正在播放”（同控制中心）"),
        .systemNPOff: ("Off — only the sources below are used.", "已關閉，只使用下方的來源。", "已关闭，只使用下方的来源。"),
        .systemNPWorks: ("Working: showing what macOS reports as Now Playing (%@).", "運作中：顯示 macOS 回報的正在播放（%@）。", "运行中：显示 macOS 报告的正在播放（%@）。"),
        .systemNPRestricted: ("Not available on this macOS (%@): Apple doesn't share system Now Playing with third-party apps (since macOS 15.4), and there is no public API. Notch Island uses Music, Spotify and the browser sources below instead.", "這個 macOS（%@）無法使用：自 macOS 15.4 起 Apple 不再把系統「正在播放」提供給第三方 App，也沒有公開 API。瀏海島改用下方的「音樂」、Spotify 與瀏覽器來源。", "这个 macOS（%@）无法使用：自 macOS 15.4 起 Apple 不再把系统“正在播放”提供给第三方 App，也没有公开 API。刘海岛改用下方的“音乐”、Spotify 与浏览器来源。"),
        .systemNPNoData: ("No system Now Playing data right now (nothing playing, or macOS withholds it).", "目前沒有系統「正在播放」資料（沒有播放，或 macOS 不提供）。", "当前没有系统“正在播放”数据（没有播放，或 macOS 不提供）。"),
        .mediaKeysToggle: ("Control playback with system media keys", "以系統媒體鍵控制播放", "以系统媒体键控制播放"),
        .mediaKeysGranted: ("Permission granted: play/pause and next/previous act like the keyboard's media keys.", "已授權：播放/暫停與上一首/下一首會像鍵盤媒體鍵一樣運作。", "已授权：播放/暂停与上一首/下一首会像键盘媒体键一样运作。"),
        .mediaKeysNeedAccess: ("Needs permission: allow Notch Island in System Settings › Privacy & Security › Accessibility.", "需要授權：請在「系統設定 › 隱私權與安全性 › 輔助使用」允許瀏海島。", "需要授权：请在“系统设置 › 隐私与安全 › 辅助功能”允许刘海岛。"),
        .mediaKeysNote: ("Off by default. When on, the island's buttons send the same play/pause, next and previous keys as your keyboard, so macOS delivers them to whatever is currently playing (e.g. YouTube Music in Chrome, Music, Spotify) — no browser JavaScript setup needed for control. Requires macOS's permission to post events (shown under Accessibility); it is requested only when you turn this on, and only these three keys are ever sent.", "預設關閉。開啟後，島上的按鈕會送出與鍵盤相同的播放/暫停、下一首、上一首按鍵，macOS 會交給目前正在播放的來源（例如 Chrome 裡的 YouTube Music、「音樂」、Spotify），控制時不需要設定瀏覽器 JavaScript。需要 macOS 的「傳送事件」權限（列在「輔助使用」中），只在你開啟時才會請求，而且只會送出這三個按鍵。", "默认关闭。开启后，岛上的按钮会发送与键盘相同的播放/暂停、下一首、上一首按键，macOS 会交给当前正在播放的来源（例如 Chrome 里的 YouTube Music、“音乐”、Spotify），控制时不需要设置浏览器 JavaScript。需要 macOS 的“发送事件”权限（列在“辅助功能”中），只在你开启时才会请求，而且只会发送这三个按键。"),
        .controlFailed: ("Couldn't send that to the player (tab closed or no such button).", "無法傳送到播放器（分頁已關閉或沒有該按鈕）。", "无法发送到播放器（标签页已关闭或没有该按钮）。"),
        .browserNeedsAutomation: ("Allow Notch Island to control %@ to show YouTube playback (Settings › Browser media).", "允許瀏海島控制 %@ 才能顯示 YouTube 播放（設定 › 瀏覽器媒體）。", "允许刘海岛控制 %@ 才能显示 YouTube 播放（设置 › 浏览器媒体）。"),
        .weatherUseLocation: ("Click to use your approximate location, or choose a city in Settings.", "點一下使用概略位置，或在設定中選擇城市。", "点一下使用大致位置，或在设置中选择城市。"),
        .chooseCityInstead: ("Choose a city in Settings instead.", "也可以改在設定中選擇城市。", "也可以改在设置中选择城市。"),
    ]
}
