import AppKit
import ShazamKit
import AVFoundation
import SwiftUI
import Foundation
import JavaScriptCore
import CoreLocation
import EventKit
import CoreAudio

// Minimal test runner compiled together with the app sources (see run_tests.sh).
// Pass --live to also hit the real Open-Meteo / Alpha Vantage (demo key) endpoints.

var failures = 0
var checks = 0
var currentTest = ""

@MainActor func expect(_ condition: @autoclosure () -> Bool, _ message: String, file: String = #fileID, line: Int = #line) {
    checks += 1
    if !condition() {
        failures += 1
        print("  ✗ [\(currentTest)] \(message) (\(file):\(line))")
    }
}

@MainActor func test(_ name: String, _ body: () async throws -> Void) async {
    currentTest = name
    do { try await body() } catch {
        failures += 1
        print("  ✗ [\(name)] threw \(error)")
    }
    print("• \(name)")
}

func freshDefaults(_ name: String = #function) -> UserDefaults {
    let suite = "NotchIslandTests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defaults.removePersistentDomain(forName: suite)
    return defaults
}

final class Clock { var now = Date(timeIntervalSince1970: 1_800_000_000) }

/// Scripted HTTP client: counts requests and answers from a closure.
final class MockHTTP: HTTPClient, @unchecked Sendable {
    private let lock = NSLock()
    private var _urls: [URL] = []
    let handler: @Sendable (URL) throws -> (Data, Int)
    init(_ handler: @escaping @Sendable (URL) throws -> (Data, Int)) { self.handler = handler }
    var urls: [URL] { lock.withLock { _urls } }
    func get(_ url: URL) async throws -> (Data, Int) {
        lock.withLock { _urls.append(url) }
        do { return try handler(url) } catch { throw ProviderError(error) }
    }
}

let forecastJSON = Data("""
{"current":{"time":"2026-11-07T17:30","temperature_2m":22.7,"apparent_temperature":24.1,"weather_code":2,"is_day":0},
 "daily":{"temperature_2m_max":[26.4],"temperature_2m_min":[22.0]}}
""".utf8)
let quoteJSON = Data("""
{"Meta Data":{"2. Symbol":"IBM","3. Last Refreshed":"2026-11-06"},
 "Time Series (Daily)":{
  "2026-11-06":{"1. open":"242.92","4. close":"245.0000"},
  "2026-11-05":{"1. open":"255.92","4. close":"247.1100"},
  "2026-11-04":{"1. open":"255.00","4. close":"254.3200"}}}
""".utf8)
let taipei = Place(name: "Taipei", admin: nil, country: "Taiwan", latitude: 25.05, longitude: 121.53, timezone: "Asia/Taipei")

await test("music recognition: system default and explicit third-party choice") {
    expect(MusicRecognitionMode.resolve("system") == .system, "system option invokes the system path")
    expect(MusicRecognitionMode.resolve("audd") == .audd, "third-party option opens AudD")
    expect(MusicRecognitionMode.resolve("") == .system, "missing preference defaults to system")
    expect(MusicRecognitionMode.resolve("unknown") == .system, "unknown preference cannot silently choose third-party")
    let lang = LanguageSettings.shared
    let saved = lang.language
    defer { lang.language = saved }
    lang.language = .traditionalChinese
    expect(lang.t(.qaShazam) == "音樂辨識", "Traditional Chinese quick action")
    lang.language = .simplifiedChinese
    expect(lang.t(.qaShazam) == "音乐识别", "Simplified Chinese quick action")
    lang.language = .english
    expect(lang.t(.qaShazam) == "Music Recognition", "English quick action")
}

await test("music recognition: quick action feedback, guidance never jumps to AudD, honest labels") {
    // Blue only fades (opacity); Reduce Motion keeps a short dissolve rather than snapping.
    expect(QuickActionsBar.flashFade(fadingIn: true, reduceMotion: true) > 0 && QuickActionsBar.flashFade(fadingIn: false, reduceMotion: true) > 0,
           "reduce motion still dissolves, never snaps")
    expect(QuickActionsBar.flashFade(fadingIn: true, reduceMotion: true) <= QuickActionsBar.flashFade(fadingIn: true, reduceMotion: false)
           && QuickActionsBar.flashFade(fadingIn: false, reduceMotion: true) < QuickActionsBar.flashFade(fadingIn: false, reduceMotion: false),
           "reduce motion shortens the fades")
    expect(QuickActionsBar.feedbackDuration(reduceMotion: true) < QuickActionsBar.feedbackDuration(reduceMotion: false), "shorter hold with reduce motion")
    expect(QuickActionsBar.recognitionBlue == 0x0058BD, "Shazam-style blue")
    let page = try String(contentsOfFile: "Sources/NotchIsland/IslandPages.swift", encoding: .utf8)
    let bar = page.components(separatedBy: "struct QuickActionsBar")[1].components(separatedBy: "struct SubpageHeader")[0]
    expect(!bar.contains("scaleEffect") && !bar.contains("offset("), "the button flash has no movement")
    expect(bar.contains("model.startSystemRecognition") && bar.contains("model.subpage = .audd"),
           "system mode tries macOS directly; AudD mode only opens its page")
    expect(!bar.contains("recognition.start") && !bar.contains("audd?.start"), "the quick action never starts an AudD capture")
    let guidance = page.components(separatedBy: "private var systemRecognition: some View")[1].components(separatedBy: "private var systemRecognitionStatus")[0]
    expect(!guidance.contains("showingAudD") && !guidance.contains("audDTitle"), "macOS guidance offers no AudD shortcut")
    expect(guidance.contains("SystemSettingsLink.open(.accessibility)"), "permission button opens Privacy & Security › Accessibility")
    expect(page.contains("scaleEffect(reduceMotion ? 1 :"), "ShazamKit pulse honors Reduce Motion")
    let lang = LanguageSettings.shared
    let saved = lang.language
    defer { lang.language = saved }
    for language in [AppLanguage.english, .traditionalChinese, .simplifiedChinese] {
        lang.language = language
        let result = lang.t(.shazamShortcutResult, "Song — Artist")
        expect(result.contains("Song — Artist") && result != "Song — Artist", "\(language): shortcut output is labelled as the shortcut's")
        expect(lang.t(.shazamShortcutResult, "100% real").contains("100% real"), "\(language): literal text kept")
        let notSelected = lang.t(.audDNotSelected)
        expect(notSelected.contains("AudD") && notSelected.contains(lang.t(.recognitionSettings)), "\(language): says where to choose AudD")
        for key in [L10nKey.shazamSystemFallback, .shazamSystemUnavailable, .shazamSystemNeedsAX, .shazamSystemNotExposed] {
            let text = lang.t(key)
            // Apple's own Control Center wording (MusicRecognition.loctable on macOS 27).
            expect(text.contains(language == .english ? "Recognize Music" : (language == .traditionalChinese ? "辨識音樂" : "识别音乐")),
                   "\(language) \(key): uses the system's control name")
            expect(!["recognized", "已辨識", "已识别"].contains(where: text.contains), "\(language) \(key): never claims a result")
        }
    }
}

// MARK: - Localization

await test("localization: every key has en/zh-Hant/zh-Hans and switching works") {
    expect(LanguageSettings.missingKeys.isEmpty, "missing keys: \(LanguageSettings.missingKeys)")
    let lang = LanguageSettings.shared
    let saved = lang.language
    defer { lang.language = saved }
    lang.language = .english
    expect(lang.t(.weather) == "Weather", "en")
    expect(lang.t(.timeLeft, "2 hr") == "2 hr left", "en placeholder")
    lang.language = .traditionalChinese
    expect(lang.t(.weather) == "天氣", "zh-Hant")
    expect(lang.t(.errOffline) == "目前沒有網路連線", "zh-Hant error")
    lang.language = .simplifiedChinese
    expect(lang.t(.weather) == "天气", "zh-Hans")
    expect(lang.providerLanguage == "zh", "geocoder language")
}

// MARK: - Notch geometry

await test("geometry: notch measured from auxiliary areas in screen space") {
    let frame = NSRect(x: 0, y: 0, width: 1512, height: 982)
    let g = NotchGeometry.compute(frame: frame, visibleFrame: NSRect(x: 0, y: 0, width: 1512, height: 950),
                                  safeAreaTop: 32,
                                  leftArea: NSRect(x: 0, y: 950, width: 662, height: 32),
                                  rightArea: NSRect(x: 847, y: 950, width: 665, height: 32),
                                  fallbackMenuBarHeight: 24)
    expect(g.hasNotch, "has notch")
    expect(g.notchRect == NSRect(x: 662, y: 950, width: 185, height: 32), "rect \(g.notchRect)")
}

await test("geometry: other sizes and an offset screen adapt without a model table") {
    // A larger scaled resolution on a screen placed left of the primary display.
    let frame = NSRect(x: -1800, y: 0, width: 1800, height: 1169)
    let g = NotchGeometry.compute(frame: frame, visibleFrame: frame, safeAreaTop: 38,
                                  leftArea: NSRect(x: -1800, y: 1131, width: 800, height: 38),
                                  rightArea: NSRect(x: -790, y: 1131, width: 790, height: 38),
                                  fallbackMenuBarHeight: 24)
    expect(g.hasNotch && g.notchRect.width == 210 && g.notchRect.minX == -1000 && g.notchRect.height == 38,
           "rect \(g.notchRect)")
    // Areas reported in a different space: fall back to widths only.
    let h = NotchGeometry.compute(frame: frame, visibleFrame: frame, safeAreaTop: 38,
                                  leftArea: NSRect(x: 0, y: 0, width: 800, height: 38),
                                  rightArea: NSRect(x: 5000, y: 0, width: 790, height: 38),
                                  fallbackMenuBarHeight: 24)
    expect(h.hasNotch && h.notchRect.width == 210 && h.notchRect.minX == -1000, "width fallback \(h.notchRect)")
}

await test("geometry: external / no-notch screens get a virtual zone") {
    let frame = NSRect(x: 0, y: 0, width: 2560, height: 1440)
    let g = NotchGeometry.compute(frame: frame, visibleFrame: NSRect(x: 0, y: 0, width: 2560, height: 1415),
                                  safeAreaTop: 0, leftArea: nil, rightArea: nil, fallbackMenuBarHeight: 24)
    expect(!g.hasNotch, "no notch")
    expect(g.notchRect.width == NotchGeometry.virtualNotchWidth && g.notchRect.midX == 1280 && g.notchRect.height == 25,
           "virtual \(g.notchRect)")
    // Auto-hidden menu bar → system thickness.
    let hidden = NotchGeometry.compute(frame: frame, visibleFrame: frame, safeAreaTop: 0, leftArea: nil, rightArea: nil,
                                       fallbackMenuBarHeight: 24)
    expect(hidden.notchRect.height == 24, "fallback height")
    // Implausible areas (e.g. a bogus inset) are rejected instead of drawing a huge island.
    let bogus = NotchGeometry.compute(frame: frame, visibleFrame: frame, safeAreaTop: 30,
                                      leftArea: NSRect(x: 0, y: 0, width: 100, height: 30),
                                      rightArea: NSRect(x: 2460, y: 0, width: 100, height: 30),
                                      fallbackMenuBarHeight: 24)
    expect(!bogus.hasNotch, "bogus rejected")
}

await test("geometry: live screens (reporting only)") {
    for screen in NSScreen.screens {
        let g = NotchGeometry(screen: screen)
        print("    screen '\(g.screenName)' builtIn=\(g.isBuiltIn) frame=\(g.screenFrame) notch=\(g.hasNotch) \(g.notchRect)")
        expect(g.notchRect.width > 0 && g.notchRect.height > 0, "positive notch rect")
        expect(g.notchRect.maxY == g.screenFrame.maxY, "notch at top edge")
    }
}

// MARK: - Device

await test("device: model recorded on first launch only") {
    let d = freshDefaults()
    let clock = Clock()
    let first = DeviceInfo.detect(defaults: d, model: "Mac17,3", now: clock.now)
    expect(first.isFirstLaunchOnModel, "first launch")
    clock.now += 3600
    let second = DeviceInfo.detect(defaults: d, model: "Mac17,3", now: clock.now)
    expect(!second.isFirstLaunchOnModel && second.firstLaunch == first.firstLaunch, "second launch keeps date")
    let migrated = DeviceInfo.detect(defaults: d, model: "Mac99,1", now: clock.now)
    expect(migrated.isFirstLaunchOnModel, "new model re-detected")
    let real = DeviceInfo.currentModelIdentifier()
    print("    hw.model = \(real)")
    expect(real.hasPrefix("Mac") || real.contains("Book") || real.contains(","), "plausible model id")
}

// MARK: - Timer & stopwatch

await test("timer: selected duration persists") {
    let d = freshDefaults()
    let timer = CountdownTimer(defaults: d)
    expect(timer.selectedDuration == 300, "default 5 min")
    timer.adjust(minutes: 2)
    expect(CountdownTimer(defaults: d).selectedDuration == 420, "persisted 7 min")
    timer.start(minutes: 25)
    expect(timer.phase == .running, "running")
    timer.pause()
    expect(timer.phase == .paused, "paused")
    timer.reset()
    expect(timer.phase == .idle && CountdownTimer(defaults: d).selectedDuration == 1500, "reset keeps 25 min")
}

await test("stopwatch: start/pause/lap/reset with wall clock") {
    let d = freshDefaults()
    let clock = Clock()
    let sw = Stopwatch(defaults: d, now: { clock.now })
    expect(sw.phase == .idle && sw.elapsed() == 0, "idle")
    sw.start(); clock.now += 5
    expect(abs(sw.elapsed() - 5) < 0.001, "5 s")
    sw.lap(); clock.now += 2; sw.lap()
    expect(sw.laps.count == 2 && abs(sw.lapDuration(1) - 2) < 0.001, "laps")
    sw.pause(); clock.now += 100
    expect(abs(sw.elapsed() - 7) < 0.001 && sw.phase == .paused, "paused freezes")
    sw.lap()
    expect(sw.laps.count == 2, "no lap while paused")
    sw.start(); clock.now += 3
    expect(abs(sw.elapsed() - 10) < 0.001, "resume accumulates")
    sw.reset()
    expect(sw.phase == .idle && sw.elapsed() == 0 && sw.laps.isEmpty, "reset")
    expect(Stopwatch.format(62.345, fraction: true) == "1:02.34", "format \(Stopwatch.format(62.345, fraction: true))")
    expect(Stopwatch.format(3723.4, fraction: false) == "1:02:03", "format h")
}

await test("stopwatch: keeps running across relaunch, paused state restored") {
    let d = freshDefaults()
    let clock = Clock()
    let sw = Stopwatch(defaults: d, now: { clock.now })
    sw.start(); clock.now += 10; sw.lap()
    clock.now += 50 // app quit and relaunched a minute later
    let relaunched = Stopwatch(defaults: d, now: { clock.now })
    expect(relaunched.phase == .running && abs(relaunched.elapsed() - 60) < 0.001, "running across relaunch")
    expect(relaunched.laps == [10], "laps restored")
    relaunched.pause()
    clock.now += 500
    let again = Stopwatch(defaults: d, now: { clock.now })
    expect(again.phase == .paused && abs(again.elapsed() - 60) < 0.001, "paused restored")
}

// MARK: - Widget settings

await test("widgets: offline defaults, enable/reorder persisted") {
    let d = freshDefaults()
    let s = WidgetSettings(defaults: d, secrets: MemorySecretStore())
    expect(s.enabledInOrder == [.battery, .timer, .stopwatch], "defaults: offline widgets only (timer included)")
    expect(!s.weatherFetchAllowed && !s.stocksFetchAllowed, "no network by default")
    s.setEnabled(.weather, true)
    s.move(.weather, by: -1)
    s.move(.stopwatch, by: -4)
    s.move(.stopwatch, by: -1) // already first: no-op
    let reloaded = WidgetSettings(defaults: d, secrets: MemorySecretStore())
    expect(reloaded.order == [.stopwatch, .weather, .battery, .stocks, .timer, .calendar, .clock], "order \(reloaded.order)")
    expect(reloaded.enabledInOrder == [.stopwatch, .weather, .battery, .timer], "enabled \(reloaded.enabledInOrder)")
    reloaded.setEnabled(.battery, false)
    expect(WidgetSettings(defaults: d, secrets: MemorySecretStore()).enabledInOrder == [.stopwatch, .weather, .timer], "disable persisted")
    reloaded.move(fromOffsets: IndexSet(integer: 3), toOffset: 0)
    expect(WidgetSettings(defaults: d, secrets: MemorySecretStore()).order.first == .stocks, "drag reorder persisted")
}

await test("widgets: city, unit, tickers and API key") {
    let d = freshDefaults()
    let secrets = MemorySecretStore()
    let s = WidgetSettings(defaults: d, secrets: secrets)
    s.place = taipei
    s.unit = .fahrenheit
    expect(s.addSymbol(" aapl ") == .success("AAPL"), "normalize")
    expect(s.addSymbol("AAPL") == .failure(.duplicate), "duplicate")
    expect(s.addSymbol("bad symbol!") == .failure(.invalid), "invalid")
    expect(s.addSymbol("tsco.lon") == .success("TSCO.LON"), "exchange suffix")
    expect(s.addSymbol("BRK-B") == .success("BRK-B"), "dash")
    expect(s.addSymbol("MSFT") == .failure(.limit), "limit 3")
    s.setStockAPIKey("  secret  ")
    expect(secrets.value == "secret" && s.hasStockAPIKey, "key stored trimmed in secret store")
    expect(d.string(forKey: "NotchIsland.widgets.hasStockKey") == nil || d.bool(forKey: "NotchIsland.widgets.hasStockKey"), "flag only")
    let all = d.dictionaryRepresentation().values.map { "\($0)" }.joined()
    expect(!all.contains("secret"), "API key never written to UserDefaults")
    let r = WidgetSettings(defaults: d, secrets: secrets)
    expect(r.place == taipei && r.unit == .fahrenheit && r.symbols == ["AAPL", "TSCO.LON", "BRK-B"], "reloaded")
    expect(r.stockAPIKey() == "secret", "key readable")
    r.setStockAPIKey(nil)
    expect(secrets.value == nil && !r.hasStockAPIKey, "key removed")
}

// MARK: - Providers

await test("weather provider: success, HTTP, rate limit, bad JSON, offline, not found") {
    let ok = OpenMeteoProvider(client: MockHTTP { _ in (forecastJSON, 200) })
    let wx = try await ok.current(for: taipei, unit: .celsius)
    expect(wx.temperature == 22.7 && wx.high == 26.4 && wx.low == 22.0 && wx.code == 2 && !wx.isDay, "parsed \(wx)")
    let cases: [(MockHTTP, ProviderError)] = [
        (MockHTTP { _ in (Data(), 503) }, .http(503)),
        (MockHTTP { _ in (Data(), 429) }, .rateLimited),
        (MockHTTP { _ in (Data("<html>".utf8), 200) }, .invalidResponse),
        (MockHTTP { _ in (Data("{\"current\":{}}".utf8), 200) }, .invalidResponse),
        (MockHTTP { _ in throw URLError(.notConnectedToInternet) }, .offline),
        (MockHTTP { _ in throw URLError(.timedOut) }, .timeout),
    ]
    for (client, expected) in cases {
        do {
            _ = try await OpenMeteoProvider(client: client).current(for: taipei, unit: .celsius)
            expect(false, "expected \(expected)")
        } catch { expect(ProviderError(error) == expected, "got \(error), expected \(expected)") }
    }
    do {
        _ = try await OpenMeteoProvider(client: MockHTTP { _ in (Data("{\"generationtime_ms\":0.1}".utf8), 200) })
            .searchPlaces("Nowhereville", language: "en")
        expect(false, "expected notFound")
    } catch { expect(ProviderError(error) == .notFound, "geocode not found") }
    let fahrenheit = MockHTTP { _ in (forecastJSON, 200) }
    _ = try await OpenMeteoProvider(client: fahrenheit).current(for: taipei, unit: .fahrenheit)
    expect(fahrenheit.urls.first?.query?.contains("temperature_unit=fahrenheit") == true, "unit passed")
}

await test("stock provider: success and documented error payloads") {
    let q = try AlphaVantageProvider.parse(quoteJSON, symbol: "IBM")
    expect(q.price == 245 && abs(q.change + 2.11) < 1e-9 && abs(q.changePercent + 0.85387) < 1e-4 && q.latestTradingDay == "2026-11-06", "\(q)")
    expect(q.closes == [254.32, 247.11, 245.0], "chart uses the real closes, oldest first: \(q.closes)")
    expect(QuoteFormat.day("2026-11-06", locale: Locale(identifier: "en_US")) == "Nov 6", "en short date")
    expect(QuoteFormat.day("2026-11-06", locale: Locale(identifier: "zh_Hant_TW")) == "11月6日", "zh short date: \(QuoteFormat.day("2026-11-06", locale: Locale(identifier: "zh_Hant_TW")))")
    expect(QuoteFormat.day("garbage", locale: Locale(identifier: "en_US")) == "garbage", "unparseable date shown as-is")
    expect(Sparkline.points([1, 2], in: CGSize(width: 100, height: 10)).count == 2, "sparkline from real points")
    expect(Sparkline.points([5], in: CGSize(width: 100, height: 10)).isEmpty, "no line from a single value")
    // Only the most recent `chartDays` closes are kept for the chart.
    var many: [String: [String: String]] = [:]
    for day in 0..<60 { many[String(format: "2026-%02d-%02d", day / 28 + 1, day % 28 + 1)] = ["4. close": "\(100 + day)"] }
    let long = try AlphaVantageProvider.parse(try JSONSerialization.data(withJSONObject: ["Time Series (Daily)": many]), symbol: "X")
    expect(long.closes.count == AlphaVantageProvider.chartDays && long.closes.last == 159 && long.price == 159, "chart capped, newest last")
    let payloads: [(String, ProviderError)] = [
        ("{\"Time Series (Daily)\":{}}", .notFound),
        ("{\"Note\":\"Thank you for using Alpha Vantage! Our standard API call frequency is 5 calls per minute.\"}", .rateLimited),
        ("{\"Information\":\"Thank you for using Alpha Vantage! Our standard API rate limit is 25 requests per day.\"}", .rateLimited),
        ("{\"Information\":\"The **demo** API key is for demo purposes only. Please claim your free API key.\"}", .invalidAPIKey),
        ("{\"Error Message\":\"the parameter apikey is invalid or missing.\"}", .invalidAPIKey),
        ("{\"Error Message\":\"Invalid API call. Please retry or visit the documentation for GLOBAL_QUOTE.\"}", .notFound),
        ("{\"Time Series (Daily)\":{\"2026-11-06\":{\"4. close\":\"abc\"},\"2026-11-05\":{\"4. close\":\"1\"}}}", .invalidResponse),
        ("{\"Time Series (Daily)\":{\"2026-11-06\":{\"4. close\":\"10\"}}}", .invalidResponse), // no previous close → no change
        ("{\"Meta Data\":{}}", .invalidResponse),
        ("not json", .invalidResponse),
    ]
    for (json, expected) in payloads {
        do { _ = try AlphaVantageProvider.parse(Data(json.utf8), symbol: "X"); expect(false, "expected \(expected) for \(json)") }
        catch { expect(ProviderError(error) == expected, "\(json) → \(error), expected \(expected)") }
    }
}

// MARK: - Data center: network gating & failure states

await test("Yahoo: keyless quotes, encoded symbols and provider errors") {
    let json = """
    {"chart":{"result":[{"meta":{"symbol":"2330.TW","currency":"TWD","regularMarketPrice":105.0,"regularMarketTime":1735804800,"gmtoffset":0},"timestamp":[1735718400,1735804800],"indicators":{"quote":[{"close":[100.0,105.0]}]}}],"error":null}}
    """
    let client = MockHTTP { _ in (Data(json.utf8), 200) }
    let quote = try await YahooFinanceProvider(client: client).quote(symbol: "2330.TW")
    expect(quote.price == 105 && quote.change == 5 && quote.changePercent == 5, "price and change from actual prior close")
    expect(quote.currency == "TWD" && quote.asOf != nil && quote.provider == .yahoo, "provider metadata")
    expect(client.urls.first?.host == "query1.finance.yahoo.com" && !(client.urls.first?.absoluteString.contains("apikey") ?? true), "Yahoo needs no API key")
    expect(YahooFinanceProvider.url(for: "^GSPC")?.absoluteString.contains("%5EGSPC") == true, "index symbol is path encoded")
    do {
        _ = try await YahooFinanceProvider(client: MockHTTP { _ in (Data(), 429) }).quote(symbol: "AAPL")
        expect(false, "429 should fail")
    } catch { expect(ProviderError(error) == .rateLimited, "429 is shown as rate limited") }
    do {
        _ = try await YahooFinanceProvider(client: MockHTTP { _ in (Data(), 404) }).quote(symbol: "UNKNOWN")
        expect(false, "404 should fail")
    } catch { expect(ProviderError(error) == .notFound, "404 is shown as not found") }
}

await test("data center: no network until enabled + configured; failures never show values") {
    let d = freshDefaults()
    let settings = WidgetSettings(defaults: d, secrets: MemorySecretStore())
    settings.setEnabled(.timer, false) // keep room for the widgets under test
    settings.stockProvider = .alphaVantage
    let http = MockHTTP { url in
        url.host == "api.open-meteo.com" ? (forecastJSON, 200) : (quoteJSON, 200)
    }
    let center = WidgetDataCenter(settings: settings, client: http)
    center.stockRequestSpacing = .zero
    center.configurationChanged()
    settings.place = taipei               // city chosen but widget off
    center.configurationChanged()
    _ = settings.addSymbol("IBM")         // ticker but widget off & no key
    center.configurationChanged()
    center.refreshDue()
    await center.waitForIdle()
    expect(http.urls.isEmpty, "no requests while widgets are off (\(http.urls.count))")

    settings.setEnabled(.stocks, true)    // enabled but no key
    center.configurationChanged()
    await center.waitForIdle()
    expect(http.urls.isEmpty, "no stock request without API key")

    settings.setEnabled(.weather, true)
    center.configurationChanged()
    await center.waitForIdle()
    expect(http.urls.count == 1 && http.urls[0].host == "api.open-meteo.com", "weather fetched once")
    expect(center.weather.value?.temperature == 22.7 && center.weather.error == nil && center.weather.fetchedAt != nil, "weather loaded")
    expect(!(http.urls[0].query ?? "").contains("Taipei"), "only coordinates sent for forecasts")

    settings.setStockAPIKey("k")
    center.configurationChanged()
    await center.waitForIdle()
    expect(center.stocks.value?.first?.quote?.price == 245, "quote loaded")

    // Not due yet: periodic refresh must not refetch.
    let before = http.urls.count
    center.refreshDue()
    await center.waitForIdle()
    expect(http.urls.count == before, "fresh data not refetched")

    settings.setEnabled(.weather, false)
    center.configurationChanged()
    expect(center.weather == .empty, "disabled widget clears data")
}

await test("data center: provider failure → visible error, no fabricated value") {
    let d = freshDefaults()
    let settings = WidgetSettings(defaults: d, secrets: MemorySecretStore("k"))
    settings.setEnabled(.timer, false) // keep room for the widgets under test
    settings.stockProvider = .alphaVantage
    settings.setEnabled(.weather, true)
    settings.setEnabled(.stocks, true)
    settings.place = taipei
    _ = settings.addSymbol("AAA"); _ = settings.addSymbol("BBB"); _ = settings.addSymbol("CCC")
    settings.setStockAPIKey("k")
    let http = MockHTTP { url in
        if url.host == "api.open-meteo.com" { throw URLError(.notConnectedToInternet) }
        return (Data("{\"Information\":\"Our standard API rate limit is 25 requests per day.\"}".utf8), 200)
    }
    let center = WidgetDataCenter(settings: settings, client: http)
    center.stockRequestSpacing = .zero
    center.configurationChanged()
    await center.waitForIdle()
    expect(center.weather.error == .offline && center.weather.value == nil && !center.weather.isLoading, "weather offline: \(center.weather)")
    expect(center.stocks.error == .rateLimited, "stocks rate limited")
    expect(center.stocks.value?.allSatisfy { $0.quote == nil } == true, "no quote values")
    let stockRequests = http.urls.filter { $0.host == "www.alphavantage.co" }.count
    expect(stockRequests == 1, "stops after rate limit (\(stockRequests) requests)")
    expect(center.canManuallyRefresh(.weather), "manual retry allowed after failure")
}

await test("data center: partial stock failure keeps other rows, marks failed one") {
    let settings = WidgetSettings(defaults: freshDefaults(), secrets: MemorySecretStore())
    settings.setEnabled(.timer, false) // keep room for the widgets under test
    settings.stockProvider = .alphaVantage
    settings.setEnabled(.stocks, true)
    _ = settings.addSymbol("IBM"); _ = settings.addSymbol("ZZZZ")
    settings.setStockAPIKey("k")
    let http = MockHTTP { url in
        (url.query ?? "").contains("ZZZZ") ? (Data("{\"Error Message\":\"Invalid API call. Please retry or visit the documentation for TIME_SERIES_DAILY.\"}".utf8), 200) : (quoteJSON, 200)
    }
    let center = WidgetDataCenter(settings: settings, client: http)
    center.stockRequestSpacing = .zero
    center.configurationChanged()
    await center.waitForIdle()
    let rows = center.stocks.value ?? []
    expect(rows.count == 2 && rows[0].quote != nil && rows[1].quote == nil && rows[1].error == .notFound, "rows \(rows)")
}

await test("data center: unreadable (locked) Keychain → visible error, no request, main thread free") {
    final class LockedStore: SecretStore, @unchecked Sendable {
        func read() -> String? { nil }
        func readKey() -> Result<String, ProviderError> { .failure(.keychainUnavailable) }
        func write(_ value: String) -> Bool { true }
        func delete() -> Bool { false }
    }
    let settings = WidgetSettings(defaults: freshDefaults(), secrets: LockedStore())
    settings.setEnabled(.timer, false) // keep room for the widgets under test
    settings.stockProvider = .alphaVantage
    settings.setEnabled(.stocks, true)
    _ = settings.addSymbol("IBM")
    settings.setStockAPIKey("k") // flag says a key exists
    let http = MockHTTP { _ in (quoteJSON, 200) }
    let center = WidgetDataCenter(settings: settings, client: http)
    center.configurationChanged()
    expect(center.stocks.isLoading, "key is read asynchronously, not on the call path")
    await center.waitForIdle()
    expect(center.stocks.error == .keychainUnavailable && center.stocks.value == nil, "error shown: \(center.stocks)")
    expect(http.urls.isEmpty, "no request without a readable key")
}

await test("data center: a Keychain read that never returns times out instead of loading forever") {
    final class HangingStore: SecretStore, @unchecked Sendable {
        func read() -> String? { nil }
        func readKey() -> Result<String, ProviderError> { Thread.sleep(forTimeInterval: 3); return .success("late") }
        func write(_ value: String) -> Bool { true }
        func delete() -> Bool { false }
    }
    let settings = WidgetSettings(defaults: freshDefaults(), secrets: HangingStore())
    settings.setEnabled(.timer, false) // keep room for the widgets under test
    settings.setStockAPIKey("k")
    let start = Date()
    let first = await settings.loadStockAPIKey(timeout: .milliseconds(300))
    expect(first == .failure(.keychainUnavailable) && Date().timeIntervalSince(start) < 2, "timed out quickly")
    let second = await settings.loadStockAPIKey(timeout: .milliseconds(300))
    expect(second == .failure(.keychainUnavailable), "no second blocked read while the first is stuck")
}

// MARK: - Battery

await test("battery: IOPowerSources parsing") {
    let laptop: [String: Any] = ["Type": "InternalBattery", "Is Present": true, "Current Capacity": 90, "Max Capacity": 100,
                                 "Is Charging": false, "Power Source State": "Battery Power", "Time to Empty": 245]
    let b = BatteryMonitor.parse(laptop)
    expect(b == BatterySnapshot(percent: 90, isCharging: false, onACPower: false, isCharged: false,
                                minutesToEmpty: 245, minutesToFull: nil), "\(String(describing: b))")
    var charging = laptop
    charging["Is Charging"] = true; charging["Power Source State"] = "AC Power"; charging["Time to Full Charge"] = -1
    expect(BatteryMonitor.parse(charging)?.minutesToFull == nil, "-1 = still estimating, not a fake number")
    expect(BatteryMonitor.parse(["Type": "UPS", "Current Capacity": 50, "Max Capacity": 100]) == nil, "UPS ignored")
    print("    this Mac: \(BatteryMonitor.read())")
}

// MARK: - Layout & hit testing

await test("layout: widgets never occupy the menu bar beside the notch") {
    let frame = NSRect(x: 0, y: 0, width: 1512, height: 982)
    let geometry = NotchGeometry(screenFrame: frame, hasNotch: true,
                                 notchRect: NSRect(x: 662, y: 950, width: 185, height: 32))
    let d = freshDefaults()
    let timer = CountdownTimer(defaults: d)
    let sw = Stopwatch(defaults: d)
    let model = IslandViewModel(geometry: geometry, timer: timer, music: MusicController(), stopwatch: sw)
    model.setExpanded(true)
    expect(model.page == .widgets, "no live activity → widgets page")
    expect(model.neckWidth(for: .expanded, hovering: false) == 185, "neck = physical notch")
    let menuY = 982.0 - 10
    expect(!model.shapeContains(NSPoint(x: 662 - 30, y: menuY)), "menu bar left of notch passes through")
    expect(!model.shapeContains(NSPoint(x: 847 + 30, y: menuY)), "menu bar right of notch passes through")
    expect(model.shapeContains(NSPoint(x: 754, y: menuY)), "notch itself is island")
    expect(model.shapeContains(NSPoint(x: 754 + 250, y: 982 - 60)), "body below the menu bar is island")
    expect(!model.shapeContains(NSPoint(x: 754 + 250, y: menuY)), "body never extends into the menu bar")
    model.page = .activities
    expect(model.neckWidth(for: .expanded, hovering: false) == 185, "switching pages doesn't widen")
    model.setExpanded(false)

    // A real live activity (stopwatch) widens the neck to show compact indicators.
    sw.start()
    for _ in 0..<5 { await Task.yield(); try await Task.sleep(for: .milliseconds(20)) }
    expect(model.mode == .compact && model.isActive, "stopwatch is a live activity")
    expect(model.neckWidth(for: .compact, hovering: false) == 185 + 2 * IslandViewModel.compactSideWidth, "compact width")
    model.setExpanded(true)
    expect(model.page == .activities && model.activityTool == .stopwatch, "expands to activities/stopwatch")
    model.page = .widgets
    // Expanded (with a live activity): only the physical notch is covered in the menu bar,
    // so status items right beside it stay visible and clickable; live info is in the panel.
    expect(model.neckWidth(for: .expanded, hovering: false) == 185, "expanded keeps the menu bar beside the notch free")
    expect(!model.shapeContains(NSPoint(x: 662 - 20, y: menuY)) && !model.shapeContains(NSPoint(x: 847 + 20, y: menuY)),
           "status items next to the notch are clickable while expanded")
    expect(!model.acceptsMouse(at: NSPoint(x: 847 + 20, y: menuY)), "panel doesn't take those clicks")
    expect(model.shapeContains(NSPoint(x: 754, y: menuY)), "notch itself still part of the island")
    model.setExpanded(false)
    for _ in 0..<3 { await Task.yield() }
    expect(model.neckWidth(for: .compact, hovering: false) == model.compactWidth, "compact indicators return after collapsing")
    let window = model.windowFrame
    expect(window.maxY == 982 && abs(window.midX - 754.5) < 0.01, "window top-aligned on notch")
    sw.reset()
}

await test("layout: external screen without notch keeps the menu bar empty when idle") {
    let frame = NSRect(x: 0, y: 0, width: 2560, height: 1440)
    let geometry = NotchGeometry.compute(frame: frame, visibleFrame: NSRect(x: 0, y: 0, width: 2560, height: 1415),
                                         safeAreaTop: 0, leftArea: nil, rightArea: nil, fallbackMenuBarHeight: 24)
    let d = freshDefaults()
    let model = IslandViewModel(geometry: geometry, timer: CountdownTimer(defaults: d), music: MusicController(),
                                stopwatch: Stopwatch(defaults: d))
    expect(!model.shapeContains(NSPoint(x: 1280, y: 1430), mode: .idle), "nothing drawn while idle")
    model.setExpanded(true)
    expect(!model.shapeContains(NSPoint(x: 1280, y: 1430)), "expanded panel floats below the menu bar")
    expect(model.shapeContains(NSPoint(x: 1280, y: 1440 - 25 - 6 - 40)), "panel body hit")
}

// MARK: - Browser media (YouTube / YouTube Music)

await test("browser media: only exact HTTPS YouTube / YouTube Music URLs are accepted") {
    let accepted: [(String, BrowserMedia.Site)] = [
        ("https://music.youtube.com/watch?v=abc&list=x", .youtubeMusic),
        ("https://music.youtube.com/?source=pwa", .youtubeMusic), // installed Chrome web app (PWA) start URL
        ("HTTPS://MUSIC.YOUTUBE.COM/", .youtubeMusic),
        ("https://www.youtube.com/watch?v=dQw4w9WgXcQ", .youtube),
        ("https://m.youtube.com/watch?v=x", .youtube),
        ("https://www.youtube.com/shorts/abc", .youtube),
    ]
    for (url, site) in accepted { expect(BrowserMedia.site(for: url) == site, "accept \(url)") }
    let rejected = [
        "http://music.youtube.com/", "https://music.youtube.com.evil.example/", "https://evil.example/https://music.youtube.com/",
        "https://www.youtube.com/", "https://www.youtube.com/watchlater", "https://www.youtube.com/feed/history",
        "https://music.youtube.com:8443/", "https://user@music.youtube.com/", "https://mail.google.com/", "", "javascript:alert(1)",
    ]
    for url in rejected { expect(BrowserMedia.site(for: url) == nil, "reject \(url)") }
    expect(BrowserMedia.isAllowedArtwork(URL(string: "https://lh3.googleusercontent.com/x=w544")!), "YT Music art host")
    expect(BrowserMedia.isAllowedArtwork(URL(string: "https://i.ytimg.com/vi/x/hqdefault.jpg")!), "YouTube thumbnail host")
    expect(!BrowserMedia.isAllowedArtwork(URL(string: "http://i.ytimg.com/a.jpg")!), "no plain HTTP artwork")
    expect(!BrowserMedia.isAllowedArtwork(URL(string: "https://tracker.example/a.jpg")!), "no arbitrary artwork hosts")
    // The in-browser filter (AppleScript) uses the same prefixes, so other tabs' URLs never reach the app.
    for prefix in BrowserMedia.allowedPrefixes {
        expect(BrowserMedia.listScript(for: .chrome).contains("u starts with \"\(prefix)\""), "Chrome filter has \(prefix)")
        expect(BrowserMedia.listScript(for: .safari).contains("u starts with \"\(prefix)\""), "Safari filter has \(prefix)")
    }
}

await test("browser media: parsing tabs, JS-disabled errors, multiple tabs and selection") {
    let fs = BrowserMedia.fieldSeparator, rs = BrowserMedia.recordSeparator
    let playing = #"{"t":"Song A","r":"Artist A","l":"Album","w":"https://lh3.googleusercontent.com/a=w544","h":true,"p":true,"c":12.5,"d":200,"s":"playing"}"#
    let paused = #"{"t":"","r":"","l":"","w":"https://tracker.example/x.png","h":true,"p":false,"c":3,"d":null,"s":"paused"}"#
    let noMedia = #"{"t":"","r":"","l":"","w":"","h":false,"p":false,"c":null,"d":null,"s":""}"#
    let output = ["11\(fs)https://music.youtube.com/watch?v=a\(fs)Song A - YouTube Music\(fs)\(playing)",
                  "12\(fs)https://www.youtube.com/watch?v=b\(fs)(3) Cool Video - YouTube\(fs)\(paused)",
                  "13\(fs)https://music.youtube.com/\(fs)YouTube Music\(fs)\(noMedia)",
                  "14\(fs)https://evil.example/\(fs)Secret\(fs)\(playing)"].joined(separator: rs) + rs
    let scan = BrowserMedia.parse(output, browser: .chrome)
    expect(scan.supportedTabCount == 3 && scan.issue == nil, "3 supported tabs, the bogus one ignored: \(scan.supportedTabCount)")
    expect(scan.tabs.count == 2, "tab without a media element is not shown")
    let a = scan.tabs[0], b = scan.tabs[1]
    expect(a.title == "Song A" && a.artist == "Artist A" && a.isPlaying && a.duration == 200 && a.position == 12.5 && a.site == .youtubeMusic, "\(a)")
    expect(a.artworkURL?.host == "lh3.googleusercontent.com", "artwork kept from allowed host")
    expect(b.title == "Cool Video" && !b.isPlaying && b.artworkURL == nil && b.duration == nil, "title fallback, unsafe art dropped: \(b)")
    // Selection: playing wins; previously shown playing tab is kept; a paused previous tab stays.
    expect(BrowserMedia.choose(scan.tabs, previous: nil)?.ref == "11", "playing tab chosen")
    expect(BrowserMedia.choose(scan.tabs, previous: (.chrome, "12"))?.ref == "11", "playing beats paused previous")
    var both = scan.tabs; both[1].isPlaying = true
    expect(BrowserMedia.choose(both, previous: (.chrome, "12"))?.ref == "11", "YouTube Music beats a previously shown YouTube video")
    var twoVideos = both; twoVideos[0].site = .youtube; twoVideos[1].sessionState = "playing"
    expect(BrowserMedia.choose(twoVideos, previous: (.chrome, "12"))?.ref == "12", "same kind: keeps the tab already shown")
    expect(BrowserMedia.choose([b], previous: (.chrome, "12"))?.ref == "12", "paused previous tab stays visible")
    expect(BrowserMedia.choose([b], previous: nil) == nil, "a paused tab never seen playing isn't surfaced")
    expect(BrowserMedia.choose([], previous: (.chrome, "11")) == nil, "closed tab → nothing")
    // Error payloads when "Allow JavaScript from Apple Events" is off (real browser wording).
    let chromeOff = "21\(fs)https://music.youtube.com/\(fs)YouTube Music\(fs)ERR:12:Executing JavaScript through AppleScript is turned off. To turn it on, from the menu bar, go to View > Developer > Allow JavaScript from Apple Events.\(rs)"
    let chromeScan = BrowserMedia.parse(chromeOff, browser: .chrome)
    expect(chromeScan.issue == .javascriptDisabled && chromeScan.tabs.isEmpty && chromeScan.supportedTabCount == 1, "Chrome JS off → hint, no fake status")
    let safariOff = "3/1\(fs)https://www.youtube.com/watch?v=x\(fs)Video\(fs)ERR:8:You must enable the 'Allow JavaScript from Apple Events' option in Safari's Develop menu to use 'do JavaScript'.\(rs)"
    expect(BrowserMedia.parse(safariOff, browser: .safari).issue == .javascriptDisabled, "Safari JS off → hint")
    expect(BrowserMedia.parse("", browser: .chrome) == BrowserMedia.Scan(), "no supported tabs")
    expect(BrowserMedia.parse("x\(fs)https://music.youtube.com/\(fs)t\(fs)not json\(rs)", browser: .chrome).tabs.isEmpty, "garbage ignored")
}

await test("browser media: fixed JavaScript runs correctly against a mock YouTube page") {
    func page(_ setup: String) -> JSContext {
        let ctx = JSContext()!
        ctx.evaluateScript("""
        var clicks = {};
        function btn(n){ return { click: function(){ clicks[n]=(clicks[n]||0)+1; }, getAttribute: function(){ return null; }, offsetParent: {} }; }
        var media = { paused: false, ended: false, currentTime: 42.5, duration: 200, muted: false, volume: 1, readyState: 4,
                      closest: function(){ return null; },
                      play: function(){ this.paused = false; }, pause: function(){ this.paused = true; } };
        var buttons = {};
        var document = { querySelector: function(s){ if (s.indexOf('ad-showing') >= 0) return null; if (s.indexOf('video') >= 0) return media; return buttons[s] || null; },
                         querySelectorAll: function(s){ return s === 'video, audio' && media ? [media] : []; } };
        var navigator = { mediaSession: { playbackState: 'playing', metadata: { title: 'Song', artist: 'Artist', album: 'Album',
            artwork: [{src:'https://lh3.googleusercontent.com/a=w60'}, {src:'https://lh3.googleusercontent.com/a=w544'}] } } };
        \(setup)
        """)
        return ctx
    }
    @MainActor func run(_ ctx: JSContext, _ js: String) -> String? {
        let value = ctx.evaluateScript(js)
        expect(ctx.exception == nil, "JS threw: \(String(describing: ctx.exception))")
        return value?.toString()
    }
    let ctx = page("")
    let state = BrowserMedia.parseState(run(ctx, BrowserMedia.readJS) ?? "", browser: .chrome, ref: "1", site: .youtubeMusic, tabTitle: "x")
    expect(state?.title == "Song" && state?.artist == "Artist" && state?.isPlaying == true && state?.position == 42.5 && state?.duration == 200, "read: \(String(describing: state))")
    expect(state?.artworkURL?.absoluteString == "https://lh3.googleusercontent.com/a=w544", "largest artwork")
    expect(state?.isMuted == false && state?.readyState == 4 && state?.sessionState == "playing", "audibility signals")
    // Browser state can change outside the island while Media Session still
    // reports the old state. The next read must reflect the actual element.
    ctx.evaluateScript("media.paused = true")
    let externallyPaused = BrowserMedia.parseState(run(ctx, BrowserMedia.readJS) ?? "", browser: .chrome, ref: "1", site: .youtubeMusic, tabTitle: "x")
    expect(externallyPaused?.isPlaying == false, "external pause is visible even with a stale Media Session")
    ctx.evaluateScript("media.paused = false; media.currentTime += 0.6; navigator.mediaSession.playbackState = 'paused'")
    let externallyResumed = BrowserMedia.parseState(run(ctx, BrowserMedia.readJS) ?? "", browser: .chrome, ref: "1", site: .youtubeMusic, tabTitle: "x")
    expect(externallyResumed?.isPlaying == true, "external resume is visible on the same tab")
    let muted = page("media.volume = 0; media.readyState = 2;")
    let mutedState = BrowserMedia.parseState(run(muted, BrowserMedia.readJS) ?? "", browser: .chrome, ref: "1", site: .youtube, tabTitle: "x")
    expect(mutedState?.isMuted == true && mutedState?.readyState == 2, "volume 0 counts as muted; readyState read")
    let live = page("media.duration = Infinity; media.paused = true; navigator.mediaSession.metadata = null;")
    let liveState = BrowserMedia.parseState(run(live, BrowserMedia.readJS) ?? "", browser: .chrome, ref: "1", site: .youtube, tabTitle: "Live Stream - YouTube")
    expect(liveState?.title == "Live Stream" && liveState?.isPlaying == false && liveState?.duration == nil, "live/paused: \(String(describing: liveState))")
    let empty = page("media = null;")
    expect(BrowserMedia.parseState(run(empty, BrowserMedia.readJS) ?? "", browser: .chrome, ref: "1", site: .youtube, tabTitle: "YouTube") == nil, "no media element → nothing shown")
    let broken = page("navigator = { get mediaSession(){ throw new Error('x'); } };")
    expect(run(broken, BrowserMedia.readJS) == #"{"x":1}"#, "page errors are contained")

    // Controls
    let yt = page("")
    expect(run(yt, BrowserMedia.controlJS(.playPause, site: .youtube)) == "ok" && yt.evaluateScript("media.paused").toBool(), "YouTube pause")
    _ = run(yt, BrowserMedia.controlJS(.playPause, site: .youtube))
    expect(!yt.evaluateScript("media.paused").toBool(), "YouTube resume")
    expect(run(yt, BrowserMedia.controlJS(.next, site: .youtube)) == "none", "no next button → reported, nothing faked")
    _ = run(yt, BrowserMedia.controlJS(.previous, site: .youtube))
    expect(yt.evaluateScript("media.currentTime").toDouble() == 0, "previous without playlist restarts the video")
    let ytm = page("buttons['ytmusic-player-bar #play-pause-button'] = btn('pp'); buttons['ytmusic-player-bar .next-button'] = btn('next'); buttons['ytmusic-player-bar .previous-button'] = btn('prev');")
    for command in [BrowserMedia.Command.playPause, .next, .previous] { expect(run(ytm, BrowserMedia.controlJS(command, site: .youtubeMusic)) == "ok", "YTM \(command)") }
    expect(ytm.evaluateScript("clicks.pp + clicks.next + clicks.prev").toInt32() == 3, "YT Music player-bar buttons clicked")
    expect(ytm.evaluateScript("media.paused").toBool() == false, "YTM uses its own button, not the element")
}

await test("browser media: time comes from the real player, not a preview <video> (7:38 / 9:43 vs 0:57 / 3:39)") {
    /// Mock DOM: `elements` in document order; `selectors` maps exact selectors to nodes,
    /// mimicking the browser's first-match `querySelector`.
    @MainActor func dom(_ setup: String) -> [String: Any]? {
        let ctx = JSContext()!
        ctx.evaluateScript("""
        function el(o){ o.closest = function(){ return o.preview ? {} : null; }; if (o.volume === undefined) o.volume = 1;
            if (o.readyState === undefined) o.readyState = 4; if (o.ended === undefined) o.ended = false; return o; }
        var elements = [], selectors = {};
        var document = { querySelector: function(s){ return Object.prototype.hasOwnProperty.call(selectors, s) ? selectors[s] : null; },
                         querySelectorAll: function(){ return elements; } };
        var navigator = { mediaSession: { playbackState: 'playing', metadata: { title: 'All The Parties', artist: 'Drake', album: '', artwork: [] } } };
        \(setup)
        """)
        let value = ctx.evaluateScript(BrowserMedia.readJS)
        expect(ctx.exception == nil, "JS threw: \(String(describing: ctx.exception))")
        guard let text = value?.toString(), let data = text.data(using: .utf8) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }
    func num(_ o: [String: Any]?, _ k: String) -> Double? { (o?[k] as? NSNumber)?.doubleValue }
    // Reported case: a preview video (9:43, at 7:38) comes first in the DOM and also
    // carries the html5-main-video class; the song (3:39, at 0:57) is the real player.
    let reported = """
    var preview = el({ preview: true, paused: false, muted: true, currentTime: 458, duration: 583 });
    var song = el({ paused: false, muted: false, currentTime: 57.4, duration: 219.2 });
    elements = [preview, song];
    selectors['video.html5-main-video'] = preview;            // what the old first-match code picked
    selectors['ytmusic-player-bar .time-info'] = { textContent: ' 0:57 / 3:39 ' };
    """
    let old = JSContext()!
    old.evaluateScript("function el(o){return o;} var elements=[], selectors={}; var document={querySelector:function(s){return selectors[s]||null;}};" + reported)
    expect(old.evaluateScript("(document.querySelector('video.html5-main-video')||document.querySelector('video, audio')).duration").toDouble() == 583,
           "regression reproduced: the old selector returns the preview's 9:43")
    let a = dom(reported)
    expect(num(a, "c") == 57.4 && num(a, "d") == 219.2 && a?["ts"] as? String == "element" && num(a, "n") == 2 && a?["p"] as? Bool == true,
           "song element chosen (duration matches the player bar): \(String(describing: a))")
    // Same, but the main player is identifiable: it wins even without any visible time.
    let main = dom("""
    var preview = el({ paused: false, muted: false, currentTime: 458, duration: 583 });
    var song = el({ paused: false, muted: false, currentTime: 57, duration: 219 });
    elements = [preview, song]; selectors['#movie_player video.html5-main-video'] = song;
    """)
    expect(num(main, "c") == 57 && num(main, "d") == 219, "#movie_player element wins")
    // Only a wrong element is reachable, but the visible time is known: use the visible time.
    let uiOnly = dom("""
    elements = [el({ paused: false, muted: false, currentTime: 458, duration: 583 })];
    selectors['ytmusic-player-bar .time-info'] = { textContent: '0:57 / 3:39' };
    """)
    expect(num(uiOnly, "c") == 57 && num(uiOnly, "d") == 219 && uiOnly?["ts"] as? String == "ui", "falls back to the player bar's time")
    // Player-bar slider attributes when the text isn't available.
    let slider = dom("""
    elements = [el({ paused: false, muted: false, currentTime: 458, duration: 583 })];
    selectors['ytmusic-player-bar #progress-bar'] = { getAttribute: function(n){ return n === 'aria-valuenow' ? '57' : (n === 'aria-valuemax' ? '219' : null); } };
    """)
    expect(num(slider, "c") == 57 && num(slider, "d") == 219, "slider aria values")
    // Hours, YouTube's own time labels, ads, live streams, garbage text.
    let hours = dom("""
    elements = [el({ paused: false, muted: false, currentTime: 3723, duration: 9999 })];
    selectors['#movie_player .ytp-time-current'] = { textContent: '1:02:03' };
    selectors['#movie_player .ytp-time-duration'] = { textContent: '1:10:00' };
    """)
    expect(num(hours, "c") == 3723 && num(hours, "d") == 4200, "h:mm:ss parsed")
    let youtube = dom("""
    var sidebar = el({ preview: true, paused: false, muted: true, currentTime: 3, duration: 30 });
    var watch = el({ paused: true, muted: false, currentTime: 120, duration: 600 });
    elements = [sidebar, watch]; selectors['#movie_player video'] = watch;
    selectors['#movie_player .ytp-time-current'] = { textContent: '2:00' };
    selectors['#movie_player .ytp-time-duration'] = { textContent: '10:00' };
    """)
    expect(num(youtube, "c") == 120 && num(youtube, "d") == 600 && youtube?["p"] as? Bool == false, "YouTube: paused main player, not the playing preview")
    let ad = dom("""
    elements = [el({ paused: false, muted: false, currentTime: 5, duration: 15 })];
    selectors['#movie_player.ad-showing, .html5-video-player.ad-showing'] = {};
    """)
    expect(ad?["c"] is NSNull && ad?["d"] is NSNull && ad?["ts"] as? String == "ad", "no time during ads")
    let live = dom("""
    elements = [el({ paused: false, muted: false, currentTime: 500, duration: Infinity })];
    selectors['#movie_player .ytp-time-current'] = { textContent: 'LIVE' };
    selectors['#movie_player .ytp-time-duration'] = { textContent: '' };
    """)
    expect(num(live, "c") == 500 && live?["d"] is NSNull, "live stream: no duration, garbage text ignored")
    expect(dom("elements = [];")?["h"] as? Bool == false, "no media element")
    // Swift side: never shows a position past the end; ad → no progress line.
    let impossible = #"{"t":"x","h":true,"p":true,"c":458,"d":219,"s":"playing"}"#
    let state = BrowserMedia.parseState(impossible, browser: .chrome, ref: "1", site: .youtubeMusic, tabTitle: "")
    expect(state?.position == nil && state?.duration == nil, "impossible time dropped")
    let adState = BrowserMedia.parseState(#"{"t":"x","h":true,"p":true,"c":null,"d":null,"ts":"ad","n":1}"#, browser: .chrome, ref: "1", site: .youtube, tabTitle: "")
    expect(adState?.timeSource == "ad" && adState?.position == nil, "ad parsed")
    let fromUI = BrowserMedia.parseState(#"{"t":"x","h":true,"p":true,"c":57,"d":219,"ts":"ui","n":2}"#, browser: .chrome, ref: "1", site: .youtubeMusic, tabTitle: "")
    expect(fromUI?.position == 57 && fromUI?.duration == 219 && fromUI?.timeSource == "ui" && fromUI?.mediaElementCount == 2, "ui source parsed")

    let autoplay = """
    var id = 'new_song';
    document.getElementById = function() {
        return { getVideoData: function(){return {video_id:id};},
                 getCurrentTime: function(){return 242;}, getDuration: function(){return 420;},
                 getPlayerState: function(){return 1;} };
    };
    selectors['ytmusic-player-bar .title[href]'] = {getAttribute:function(){return '/watch?v=new_song';}};
    selectors['ytmusic-player-bar .time-info'] = {textContent:'0:02 / 3:00'};
    """
    let continuousClock = dom(autoplay)
    expect(num(continuousClock, "c") == 2 && num(continuousClock, "d") == 180, "the new song uses its own time even if the backing clock is continuous")
    let mismatched = dom(autoplay + "\nid = 'old_song';")
    expect(mismatched?["c"] is NSNull && mismatched?["d"] is NSNull, "withhold timing until player and bar agree on the item")

    var transition = BrowserMedia.TrackTransition()
    let now = Date()
    expect(transition.position(item: "old", value: 239, duration: 240, at: now) == 239, "ending position")
    expect(transition.position(item: "new", value: 239, duration: 240, at: now.addingTimeInterval(0.5)) == nil, "suppress the old end time after identity changed")
    expect(transition.position(item: "new", value: 1, duration: 240, at: now.addingTimeInterval(1)) == 1, "new position starts a separate timeline")
}

await test("browser seek targets only the original track and clamps to its duration") {
    let ctx = JSContext()!
    ctx.evaluateScript("""
    var id='first', time=0, paused=true, calls=0;
    var player={getVideoData:function(){return {video_id:id};}, getDuration:function(){return 180;},
                seekTo:function(s){time=s;calls++;}};
    var document={getElementById:function(){return player;},querySelector:function(){return null;}};
    """)
    let seek = BrowserMedia.seekJS(seconds: 240, duration: 180, videoID: "first", title: "Song")!
    expect(ctx.evaluateScript(seek)?.toString() == "ok" && ctx.evaluateScript("time === 180 && paused").toBool(), "seek is clamped and does not call play")
    ctx.evaluateScript("id='second'")
    expect(ctx.evaluateScript(seek)?.toString() == "none" && ctx.evaluateScript("calls===1").toBool(), "a drag started before autoplay cannot seek the new song")
    let wrongTimeline = BrowserMedia.seekJS(seconds: 30, duration: 90, videoID: "second", title: "Song")!
    expect(ctx.evaluateScript(wrongTimeline)?.toString() == "none" && ctx.evaluateScript("calls===1").toBool(), "does not seek a continuous media clock when the duration differs")
    expect(BrowserMedia.seekJS(seconds: .infinity, duration: 180, videoID: "first", title: "Song") == nil, "rejects an invalid position")
}

await test("browser media: AppleScript literals round-trip and scripts compile against the real dictionaries") {
    for js in [BrowserMedia.readJS] + [BrowserMedia.Command.playPause, .next, .previous].flatMap({ c in [BrowserMedia.controlJS(c, site: .youtube), BrowserMedia.controlJS(c, site: .youtubeMusic)] }) {
        var error: NSDictionary?
        let value = NSAppleScript(source: "return " + BrowserMedia.appleScriptString(js))?.executeAndReturnError(&error).stringValue
        expect(error == nil && value == js, "AppleScript literal round-trips exactly")
    }
    expect(BrowserMedia.controlScript(for: .chrome, ref: "12; do shell script \"x\"", js: "1") == nil, "Chrome tab ref must be numeric")
    expect(BrowserMedia.controlScript(for: .safari, ref: "1/x", js: "1") == nil, "Safari tab ref must be window/index numbers")
    expect(BrowserMedia.controlScript(for: .chrome, ref: "42", js: "1")?.contains("return \"blocked\"") == true, "URL re-checked before control")
    // Compile (no execution, no Apple Events) against copies of the installed browsers' sdefs.
    let sdefs: [(BrowserMedia.Browser, String)] = [(.chrome, "/Applications/Google Chrome.app/Contents/Resources/scripting.sdef"),
                                                   (.safari, "/Applications/Safari.app/Contents/Resources/Safari.sdef")]
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ni-sdef-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: dir) }
    for (browser, sdef) in sdefs where FileManager.default.fileExists(atPath: sdef) {
        let app = dir.appendingPathComponent("Fake\(browser.rawValue).app/Contents")
        try FileManager.default.createDirectory(at: app.appendingPathComponent("Resources"), withIntermediateDirectories: true)
        try FileManager.default.copyItem(atPath: sdef, toPath: app.appendingPathComponent("Resources/app.sdef").path)
        let plist: [String: Any] = ["CFBundleIdentifier": "local.nitest.fake\(browser.rawValue)", "CFBundlePackageType": "APPL",
                                    "NSAppleScriptEnabled": true, "OSAScriptingDefinition": "app.sdef"]
        try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0).write(to: app.appendingPathComponent("Info.plist"))
        let fakeTell = "tell application \"\(app.deletingLastPathComponent().path)\""
        var scripts = [BrowserMedia.listScript(for: browser)]
        for c in [BrowserMedia.Command.playPause, .next, .previous] {
            scripts.append(BrowserMedia.controlScript(for: browser, ref: browser == .chrome ? "7" : "3/2", js: BrowserMedia.controlJS(c, site: .youtubeMusic))!)
            scripts.append(BrowserMedia.controlScript(for: browser, ref: browser == .chrome ? "7" : "3/2", js: BrowserMedia.controlJS(c, site: .youtube), readBack: true)!)
        }
        scripts.append(BrowserMedia.readTabScript(for: browser, ref: browser == .chrome ? "7" : "3/2")!)
        if browser == .chrome {
            scripts.append(BrowserMedia.readTabScript(for: .chrome, ref: "3/7")!)
            scripts.append(BrowserMedia.controlScript(for: .chrome, ref: "3/7", js: BrowserMedia.controlJS(.pause, site: .youtubeMusic), readBack: true)!)
        }
        for intent in [BrowserMedia.Command.play, .pause] {
            scripts.append(BrowserMedia.controlScript(for: browser, ref: browser == .chrome ? "7" : "3/2", js: BrowserMedia.controlJS(intent, site: .youtubeMusic), readBack: true)!)
        }
        for (i, script) in scripts.enumerated() {
            let file = dir.appendingPathComponent("\(browser.rawValue)-\(i).applescript")
            try script.replacingOccurrences(of: "tell application id \"\(browser.bundleID)\"", with: fakeTell).write(to: file, atomically: true, encoding: .utf8)
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/osacompile")
            process.arguments = ["-o", dir.appendingPathComponent("\(browser.rawValue)-\(i).scpt").path, file.path]
            process.standardError = Pipe()
            try process.run(); process.waitUntilExit()
            expect(process.terminationStatus == 0, "\(browser.rawValue) script \(i) compiles against \(browser.displayName)'s dictionary")
        }
    }
}


await test("browser media: actively playing YouTube Music (PWA) wins over a stale/silent YouTube video") {
    func tab(_ ref: String, _ site: BrowserMedia.Site, _ title: String, playing: Bool, at position: Double,
             muted: Bool = false, session: String = "playing") -> BrowserMedia.TabState {
        BrowserMedia.TabState(browser: .chrome, ref: ref, site: site, title: title, artist: "", album: "", artworkURL: nil,
                              isPlaying: playing, position: position, duration: 300, isMuted: muted, readyState: 4, sessionState: session)
    }
    let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    // Reported case: an unrelated YouTube video tab was shown first (and is enumerated first)
    // while the YouTube Music web app played "All The Parties".
    var history = BrowserMedia.History()
    var previous: (BrowserMedia.Browser, String)? = (.chrome, "101") // the video was shown first
    for scan in 0..<4 {
        let now = t0.addingTimeInterval(Double(scan) * 3)
        let video = tab("101", .youtube, "Claude Cowork vs Codex", playing: true, at: 50 + Double(scan) * 3)
        let music = tab("202", .youtubeMusic, "All The Parties", playing: true, at: 10 + Double(scan) * 3)
        let pick = BrowserMedia.select([video, music], previous: previous, history: &history, now: now)
        expect(pick.tab?.ref == "202" && pick.isPlaying, "scan \(scan): YouTube Music chosen even when both report playing")
        previous = (.chrome, pick.tab?.ref ?? "")
    }
    // Element says "playing" but the position never moves (frozen/stalled tab): not treated as playing.
    history = BrowserMedia.History()
    var last = BrowserMedia.Selection(tab: nil, isPlaying: false)
    for scan in 0..<4 {
        let video = tab("101", .youtube, "Claude Cowork vs Codex", playing: true, at: 50)
        last = BrowserMedia.select([video], previous: (.chrome, "101"), history: &history, now: t0.addingTimeInterval(Double(scan) * 3))
    }
    expect(last.tab?.ref == "101" && !last.isPlaying, "stalled video shown as paused, not as a live activity")
    // ...and a real, advancing music tab beats it immediately.
    let pickAfterStall = BrowserMedia.select([tab("101", .youtube, "Claude Cowork vs Codex", playing: true, at: 50),
                                              tab("202", .youtubeMusic, "All The Parties", playing: true, at: 10)],
                                             previous: (.chrome, "101"), history: &history, now: t0.addingTimeInterval(12))
    expect(pickAfterStall.tab?.ref == "202", "music wins over stalled video")
    // Audibility: a muted playing video loses to audible music, an audible video beats muted music.
    var h = BrowserMedia.History()
    expect(BrowserMedia.select([tab("1", .youtube, "v", playing: true, at: 5, muted: true), tab("2", .youtubeMusic, "m", playing: true, at: 5)],
                               previous: (.chrome, "1"), history: &h, now: t0).tab?.ref == "2", "muted video loses")
    h = BrowserMedia.History()
    expect(BrowserMedia.select([tab("1", .youtube, "v", playing: true, at: 5), tab("2", .youtubeMusic, "m", playing: true, at: 5, muted: true)],
                               previous: nil, history: &h, now: t0).tab?.ref == "1", "audible video beats muted music")
    // Media Session "paused" contradicting the element lowers it below an agreeing tab.
    h = BrowserMedia.History()
    expect(BrowserMedia.select([tab("2", .youtubeMusic, "m", playing: true, at: 5, session: "paused"), tab("1", .youtube, "v", playing: true, at: 5)],
                               previous: nil, history: &h, now: t0).tab?.ref == "1", "session state is a signal")
    // A paused music tab never outranks a genuinely playing video.
    h = BrowserMedia.History()
    let videoOnly = BrowserMedia.select([tab("2", .youtubeMusic, "m", playing: false, at: 5), tab("1", .youtube, "v", playing: true, at: 5)],
                                        previous: (.chrome, "2"), history: &h, now: t0)
    expect(videoOnly.tab?.ref == "1" && videoOnly.isPlaying, "playing video shown when music is paused")
    h = BrowserMedia.History()
    let paused = tab("2", .youtubeMusic, "m", playing: false, at: 5)
    let initial = BrowserMedia.select([paused], previous: nil, history: &h, now: t0)
    expect(initial.tab?.ref == "2" && !initial.isPlaying, "an already paused YouTube Music tab can be resumed on first discovery")
    expect(BrowserMedia.select([paused, tab("3", .youtubeMusic, "other", playing: false, at: 10)],
                               previous: nil, history: &h, now: t0).tab == nil, "does not pick between multiple paused tabs")
}

await test("browser media: progress history — track changes, seeks, closed tabs") {
    let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    func tab(_ title: String, at p: Double, playing: Bool = true) -> BrowserMedia.TabState {
        BrowserMedia.TabState(browser: .chrome, ref: "7", site: .youtubeMusic, title: title, artist: "", album: "",
                              artworkURL: nil, isPlaying: playing, position: p, duration: 200)
    }
    var h = BrowserMedia.History()
    expect(BrowserMedia.progress(of: tab("A", at: 10), history: &h, now: t0) == .unknown, "first sample")
    expect(BrowserMedia.progress(of: tab("A", at: 13), history: &h, now: t0.addingTimeInterval(3)) == .advancing, "advancing")
    expect(BrowserMedia.progress(of: tab("B", at: 0), history: &h, now: t0.addingTimeInterval(6)) == .unknown, "new track starts fresh, no false stall")
    expect(BrowserMedia.progress(of: tab("B", at: 0), history: &h, now: t0.addingTimeInterval(9)) == .unknown, "one still scan isn't a stall yet")
    expect(BrowserMedia.progress(of: tab("B", at: 0), history: &h, now: t0.addingTimeInterval(12)) == .stalled, "two still scans = stalled")
    expect(BrowserMedia.progress(of: tab("B", at: 3), history: &h, now: t0.addingTimeInterval(15)) == .advancing, "recovers when it moves")
    expect(BrowserMedia.progress(of: tab("B", at: 1), history: &h, now: t0.addingTimeInterval(18)) == .unknown, "seek back is not a stall")
    expect(BrowserMedia.progress(of: tab("B", at: 1, playing: false), history: &h, now: t0.addingTimeInterval(21)) == .unknown, "paused is not 'stalled'")
    _ = BrowserMedia.select([tab("B", at: 1)], previous: nil, history: &h, now: t0.addingTimeInterval(24))
    _ = BrowserMedia.select([], previous: nil, history: &h, now: t0.addingTimeInterval(27))
    expect(h.samples.isEmpty, "closed tab forgotten")
}

await test("browser media: YouTube Music web app (PWA) detection and the 'not visible' case") {
    expect(BrowserMedia.isYouTubeMusicApp(bundleIdentifier: "com.google.Chrome.app.cinhimbnkkaeohfgghhklpknlkffjgod",
                                          startURL: "https://music.youtube.com/?source=pwa"), "YT Music shim")
    expect(!BrowserMedia.isYouTubeMusicApp(bundleIdentifier: "com.google.Chrome.app.abc", startURL: "https://www.youtube.com/"), "other PWA")
    expect(!BrowserMedia.isYouTubeMusicApp(bundleIdentifier: "com.example.fake", startURL: "https://music.youtube.com/"), "not a Chrome shim")
    expect(!BrowserMedia.isYouTubeMusicApp(bundleIdentifier: "com.google.Chrome.app.x", startURL: "https://music.youtube.com.evil.example/"), "look-alike host")
    // Read-only check of the shim installed on this Mac (Info.plist only; no AppleScript).
    let shim = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications/Chrome Apps.localized/YouTube Music.app")
    if let bundle = Bundle(url: shim) {
        expect(BrowserMedia.isYouTubeMusicApp(bundleIdentifier: bundle.bundleIdentifier,
                                              startURL: bundle.object(forInfoDictionaryKey: "CrAppModeShortcutURL") as? String),
               "installed YouTube Music.app recognised")
        print("    installed shim: \(bundle.bundleIdentifier ?? "?"), running now: \(BrowserMedia.youtubeMusicAppIsRunning())")
    }
    let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    let paused = BrowserMedia.TabState(browser: .chrome, ref: "101", site: .youtube, title: "Old video", artist: "", album: "",
                                       artworkURL: nil, isPlaying: false, position: 50, duration: 300)
    var h = BrowserMedia.History()
    expect(BrowserMedia.select([paused], previous: (.chrome, "101"), history: &h, now: t0, youtubeMusicAppUnseen: false).tab?.ref == "101",
           "normally a paused previous tab stays")
    h = BrowserMedia.History()
    expect(BrowserMedia.select([paused], previous: (.chrome, "101"), history: &h, now: t0, youtubeMusicAppUnseen: true).tab == nil,
           "PWA running but unreadable: don't surface an old paused video instead of the music")
    var playingVideo = paused; playingVideo.isPlaying = true
    h = BrowserMedia.History()
    expect(BrowserMedia.select([playingVideo], previous: nil, history: &h, now: t0, youtubeMusicAppUnseen: true).isPlaying,
           "a genuinely playing video is still shown (with a warning in the panel)")
    // Scan counts feed the diagnostics; an app window whose script fails is counted, not fatal.
    let fs = BrowserMedia.fieldSeparator, rs = BrowserMedia.recordSeparator
    let json = #"{"t":"All The Parties","r":"Drake","l":"","w":"","h":true,"p":true,"c":10,"d":200,"s":"playing","mu":false,"rs":4}"#
    let out = "202\(fs)https://music.youtube.com/watch?v=x&list=y\(fs)YouTube Music\(fs)\(json)\(rs)" +
              "303\(fs)https://music.youtube.com/?source=pwa\(fs)YouTube Music\(fs)ERR:-1728:Can't get tab\(rs)" +
              "101\(fs)https://www.youtube.com/watch?v=v\(fs)Video - YouTube\(fs)\(json.replacingOccurrences(of: "\"mu\":false", with: "\"mu\":true"))\(rs)"
    let scan = BrowserMedia.parse(out, browser: .chrome)
    expect(scan.musicTabCount == 2 && scan.unreadableCount == 1 && scan.issue == nil && scan.tabs.count == 2, "counts: \(scan.musicTabCount) \(scan.unreadableCount)")
    expect(scan.tabs[0].artist == "Drake" && !scan.tabs[0].isMuted && scan.tabs[1].isMuted && scan.tabs[0].sessionState == "playing", "signals parsed")
    for browser in BrowserMedia.Browser.allCases {
        let script = BrowserMedia.listScript(for: browser)
        expect(script.contains("set ts to tabs of w") && script.components(separatedBy: "try").count > 6,
               "\(browser): per-window/per-tab errors can't abort the whole scan")
    }
}

// MARK: - System media (MediaRemote / media keys)

await test("Control Center: only unambiguous Now Playing transport buttons are selected") {
    typealias Node = ControlCenterMedia.Node<String>
    func node(_ id: String, _ names: [String], press: Bool = false, children: [Node] = []) -> Node {
        Node(element: id, names: names, pressable: press, children: children)
    }
    let unrelated = node("other-play", ["Play"], press: true)
    let zh = node("music", ["播放中"], children: [
        node("pause", ["暫停"], press: true),
        node("next", ["下一首"], press: true),
        node("prev", ["上一首"], press: true)
    ])
    let window = node("window", ["控制中心"], children: [unrelated, zh])
    expect(ControlCenterMedia.target(for: .playPause, in: [window]) == "pause", "ignores a Play action outside the Now Playing region")
    expect(ControlCenterMedia.target(for: .next, in: [window]) == "next", "routes next to the Now Playing button")
    expect(ControlCenterMedia.target(for: .previous, in: [window]) == "prev", "routes previous to the Now Playing button")
    expect(ControlCenterMedia.target(for: .playPause, in: [unrelated]) == nil, "does not click an unscoped Play button")

    let unlabeled = node("unknown", [], children: [
        node("play", ["播放"], press: true), node("skip", ["next"], press: true), node("back", ["previous"], press: true)
    ])
    expect(ControlCenterMedia.target(for: .playPause, in: [unlabeled]) == "play", "recognizes a complete transport group when the OS omits its label")
    expect(ControlCenterMedia.target(for: .playPause, in: [window, unlabeled]) == nil, "does not pick an arbitrary session")
    let disabled = node("music", ["Now Playing"], children: [node("disabled", ["Pause"])])
    expect(ControlCenterMedia.target(for: .playPause, in: [disabled]) == nil, "does not target disabled or non-pressable controls")
    let named = node("music", ["com.apple.controlcenter.nowplaying"], children: [node("pause-cn", ["暂停"], press: true)])
    expect(ControlCenterMedia.target(for: .playPause, in: [named]) == "pause-cn", "accepts a known identifier and simplified Chinese")
    expect(!MusicController(defaults: freshDefaults()).useControlCenter, "direct Control Center control is opt-in")
}

await test("system media: fixture parsing and OS restriction check") {
    let ts = Date(timeIntervalSince1970: 1_800_000_000)
    let info: [String: Any] = ["kMRMediaRemoteNowPlayingInfoTitle": "All The Parties", "kMRMediaRemoteNowPlayingInfoArtist": "Drake",
                               "kMRMediaRemoteNowPlayingInfoAlbum": "For All The Dogs", "kMRMediaRemoteNowPlayingInfoDuration": 219.0,
                               "kMRMediaRemoteNowPlayingInfoElapsedTime": 57.0, "kMRMediaRemoteNowPlayingInfoTimestamp": ts,
                               "kMRMediaRemoteNowPlayingInfoPlaybackRate": 1.0]
    let np = SystemMedia.parse(info, isPlaying: nil)
    expect(np?.title == "All The Parties" && np?.artist == "Drake" && np?.duration == 219 && np?.isPlaying == true, "parsed \(String(describing: np))")
    expect(np?.position(at: ts.addingTimeInterval(3)) == 60, "elapsed extrapolated from its timestamp")
    expect(np?.position(at: ts.addingTimeInterval(1000)) == 219, "never past the end")
    var paused = info; paused["kMRMediaRemoteNowPlayingInfoPlaybackRate"] = 0.0
    expect(SystemMedia.parse(paused, isPlaying: nil)?.isPlaying == false && SystemMedia.parse(paused, isPlaying: nil)?.position(at: ts.addingTimeInterval(60)) == 57, "paused: no extrapolation")
    expect(SystemMedia.parse(info, isPlaying: false)?.isPlaying == false, "explicit is-playing wins over rate")
    var bad = info; bad["kMRMediaRemoteNowPlayingInfoElapsedTime"] = 458.0
    expect(SystemMedia.parse(bad, isPlaying: true)?.elapsed == nil, "impossible elapsed dropped")
    expect(SystemMedia.parse(["kMRMediaRemoteNowPlayingInfoTitle": "  "], isPlaying: true) == nil, "no title → nothing (no fake entry)")
    func v(_ a: Int, _ b: Int) -> OperatingSystemVersion { OperatingSystemVersion(majorVersion: a, minorVersion: b, patchVersion: 0) }
    expect(!SystemMedia.isRestrictedOS(v(14, 6)) && !SystemMedia.isRestrictedOS(v(15, 3)) && SystemMedia.isRestrictedOS(v(15, 4))
           && SystemMedia.isRestrictedOS(v(26, 0)) && SystemMedia.isRestrictedOS(v(27, 0)), "restriction from macOS 15.4")
}

await test("system media: media-key events are built correctly (never posted in tests) and controls are routed") {
    expect(SystemMedia.data1(for: .playPause, down: true) == (16 << 16) | (0xA << 8), "play down")
    expect(SystemMedia.data1(for: .playPause, down: false) == (16 << 16) | (0xB << 8), "play up")
    expect(SystemMedia.data1(for: .next, down: true) >> 16 == 19 && SystemMedia.data1(for: .previous, down: true) >> 16 == 20,
           "next/previous use NX_KEYTYPE_FAST/REWIND — what Apple keyboards' F9/F7 send")
    let events = SystemMedia.events(for: .next)
    expect(events.count == 2 && events.allSatisfy { $0.type == .systemDefined && $0.subtype.rawValue == 8 }, "key down + up, system-defined subtype 8")
    expect(events.map(\.data1) == [SystemMedia.data1(for: .next, down: true), SystemMedia.data1(for: .next, down: false)], "data1 pair")
    expect(SystemMedia.mediaRemoteCommand(.playPause) == 2 && SystemMedia.mediaRemoteCommand(.next) == 4 && SystemMedia.mediaRemoteCommand(.previous) == 5, "MRCommand values")
    typealias R = MusicController.ControlRoute
    func route(_ s: MusicController.Source?, keys: Bool, access: Bool, tab: Bool = false) -> R {
        MusicController.controlRoute(source: s, useMediaKeys: keys, hasMediaKeyAccess: access, hasBrowserTab: tab)
    }
    expect(route(.chrome, keys: true, access: true, tab: true) == .mediaKey, "media keys (granted) control whatever is playing")
    expect(route(nil, keys: true, access: true) == .mediaKey, "…even when nothing is readable (e.g. the PWA)")
    expect(route(.chrome, keys: true, access: false, tab: true) == .browserScript, "no permission → existing path, nothing faked")
    expect(MusicController.controlRoute(source: .chrome, useMediaKeys: true, hasMediaKeyAccess: true,
                                        hasBrowserTab: true, useControlCenter: true, browserSite: .youtubeMusic) == .browserScript,
           "an identified YouTube Music tab receives the command even when the system routes are enabled")
    expect(MusicController.controlRoute(source: nil, useMediaKeys: true, hasMediaKeyAccess: true,
                                        hasBrowserTab: false, useControlCenter: true) == .controlCenter,
           "Control Center stays available without a known player")
    expect(route(.music, keys: false, access: true) == .appleScript && route(.spotify, keys: false, access: false) == .appleScript, "apps")
    expect(route(.system, keys: false, access: false) == .mediaRemote, "system source")
    expect(route(.safari, keys: false, access: false, tab: false) == .unavailable && route(nil, keys: false, access: false) == .unavailable, "nothing to control")
    let m = MusicController(defaults: freshDefaults())
    expect(m.useSystemNowPlaying && !m.useMediaKeys, "defaults: system Now Playing on, media keys off (permission only on request)")
}

await test("browser media: controls use the YouTube player API and never the preview <video>") {
    @MainActor func page(_ setup: String) -> JSContext {
        let ctx = JSContext()!
        ctx.evaluateScript("""
        var calls = [];
        function v(o){ o.play = function(){ o.paused = false; calls.push('play:' + o.name); }; o.pause = function(){ o.paused = true; calls.push('pause:' + o.name); };
            o.closest = function(){ return null; }; return o; }
        var preview = v({ name: 'preview', paused: false, currentTime: 458, duration: 583 });
        var song = v({ name: 'song', paused: false, currentTime: 57, duration: 219 });
        var selectors = { 'video.html5-main-video': preview, '#movie_player video': song };
        var byId = {};
        var document = { getElementById: function(i){ return byId[i] || null; },
                         querySelector: function(s){ return Object.prototype.hasOwnProperty.call(selectors, s) ? selectors[s] : null; },
                         querySelectorAll: function(s){ return s === 'video, audio' ? [preview, song] : []; } };
        var navigator = { mediaSession: { playbackState: 'playing', metadata: { title: 'All The Parties', artist: 'Drake', artwork: [] } } };
        \(setup)
        """)
        return ctx
    }
    @MainActor func run(_ ctx: JSContext, _ js: String) -> String? {
        let r = ctx.evaluateScript(js)?.toString()
        expect(ctx.exception == nil, "JS threw \(String(describing: ctx.exception))")
        return r
    }
    // Without the player API: the main element is toggled, not the preview that matched first.
    let plain = page("")
    expect(run(plain, BrowserMedia.controlJS(.playPause, site: .youtube)) == "ok"
           && plain.evaluateScript("calls.join(',')").toString() == "pause:song", "pauses the song, not the preview")
    // With the player API (what the page's own buttons use).
    let api = """
    var state = 1;
    byId['movie_player'] = { getPlayerState: function(){ return state; }, getCurrentTime: function(){ return 57.5; }, getDuration: function(){ return 219; },
      playVideo: function(){ calls.push('api:play'); state = 1; }, pauseVideo: function(){ calls.push('api:pause'); state = 2; },
      nextVideo: function(){ calls.push('api:next'); }, previousVideo: function(){ calls.push('api:prev'); }, seekTo: function(t){ calls.push('api:seek' + t); } };
    """
    let yt = page(api)
    _ = run(yt, BrowserMedia.controlJS(.playPause, site: .youtubeMusic))
    _ = run(yt, BrowserMedia.controlJS(.playPause, site: .youtubeMusic))
    expect(yt.evaluateScript("calls.join(',')").toString() == "api:pause,api:play", "play/pause through the player API")
    _ = run(yt, BrowserMedia.controlJS(.next, site: .youtubeMusic))
    _ = run(yt, BrowserMedia.controlJS(.previous, site: .youtube))
    expect(yt.evaluateScript("calls.join(',')").toString() == "api:pause,api:play,api:next,api:seek0", "next (no bar button) and restart via the API")
    expect(run(yt, BrowserMedia.controlJS(.next, site: .youtube)) == "none", "single YouTube video has no next: reported, not faked")
    let bar = page(api + "selectors['ytmusic-player-bar .next-button'] = { click: function(){ calls.push('bar:next'); } };")
    _ = run(bar, BrowserMedia.controlJS(.next, site: .youtubeMusic))
    expect(bar.evaluateScript("calls.join(',')").toString() == "bar:next", "YouTube Music queue: player-bar next button preferred")
    // Reading prefers the player API's time and state.
    let read = page(api + "state = 2;")
    let state = BrowserMedia.parseState(run(read, BrowserMedia.readJS) ?? "", browser: .chrome, ref: "1", site: .youtubeMusic, tabTitle: "")
    expect(state?.position == 57.5 && state?.duration == 219 && state?.timeSource == "player" && state?.isPlaying == false,
           "player API time/state used (paused even though an element plays): \(String(describing: state))")
    // The control script tolerates odd windows just like the scan.
    expect(BrowserMedia.controlScript(for: .chrome, ref: "42", js: "1")?.contains("set ts to tabs of w") == true, "control script per-window try")
}

await test("widgets: fifth widget explains the limit (3 languages); timer widget migration") {
    let lang = LanguageSettings.shared
    let saved = lang.language; defer { lang.language = saved }
    let on: [WidgetKind] = [.battery, .weather, .timer, .stopwatch]
    lang.language = .english
    let en = WidgetSettings.limitMessage(trying: .calendar, enabled: on, lang: lang)
    expect(en.contains("“Calendar”") && en.contains("4") && en.contains("Battery, Weather, Timer, Stopwatch") && en.contains("Turn one"), en)
    lang.language = .traditionalChinese
    let hant = WidgetSettings.limitMessage(trying: .calendar, enabled: on, lang: lang)
    expect(hant.contains("「行事曆」") && hant.contains("電池、天氣、計時器、碼表") && hant.contains("請先關閉"), hant)
    lang.language = .simplifiedChinese
    let hans = WidgetSettings.limitMessage(trying: .calendar, enabled: on, lang: lang)
    expect(hans.contains("“日历”") && hans.contains("电池、天气、计时器、秒表") && hans.contains("请先关闭"), hans)
    expect(!lang.t(.widgetLimitTitle, "4").contains("%@"), "title filled")
    // Existing user with room: timer added once; user's later choice respected.
    let d = freshDefaults()
    d.set(["battery", "stopwatch"], forKey: "NotchIsland.widgets.enabled")
    let s = WidgetSettings(defaults: d, secrets: MemorySecretStore())
    expect(s.isEnabled(.timer) && s.enabledInOrder.count == 3, "timer added for existing users with room")
    s.setEnabled(.timer, false)
    expect(!WidgetSettings(defaults: d, secrets: MemorySecretStore()).isEnabled(.timer), "migration runs once; turning it off sticks")
    let full = freshDefaults()
    full.set(["battery", "weather", "stocks", "stopwatch"], forKey: "NotchIsland.widgets.enabled")
    let f = WidgetSettings(defaults: full, secrets: MemorySecretStore())
    expect(!f.isEnabled(.timer) && f.enabledInOrder == [.battery, .weather, .stocks, .stopwatch], "never pushes out a chosen widget")
}

await test("timer: idle timer lives in the widget; Live Activities shows only running tools") {
    expect(IslandViewModel.visibleTools(timerActive: false, stopwatchActive: false).isEmpty, "nothing running → no tool column")
    expect(IslandViewModel.visibleTools(timerActive: true, stopwatchActive: false) == [.timer], "running timer")
    expect(IslandViewModel.visibleTools(timerActive: false, stopwatchActive: true) == [.stopwatch], "running stopwatch only")
    expect(IslandViewModel.visibleTools(timerActive: true, stopwatchActive: true) == [.timer, .stopwatch], "both → switcher")
    expect(IslandViewModel.resolvedTool(.stopwatch, in: [.timer]) == .timer && IslandViewModel.resolvedTool(.timer, in: []) == nil, "resolution")
    let d = freshDefaults()
    let timer = CountdownTimer(defaults: d)
    timer.select(minutes: 10)
    expect(timer.phase == .idle && timer.selectedDuration == 600 && timer.remaining == 600, "widget preset selects without starting")
    let model = IslandViewModel(geometry: NotchGeometry(screenFrame: NSRect(x: 0, y: 0, width: 1512, height: 982), hasNotch: true,
                                                        notchRect: NSRect(x: 662, y: 950, width: 185, height: 32)),
                                timer: timer, music: MusicController(defaults: d), stopwatch: Stopwatch(defaults: d))
    model.setExpanded(true)
    expect(model.page == .widgets, "idle timer → expands to widgets")
    model.setExpanded(false)
    timer.start()
    for _ in 0..<5 { await Task.yield(); try await Task.sleep(for: .milliseconds(20)) }
    expect(model.mode == .compact, "running timer is a live activity")
    model.setExpanded(true)
    expect(model.page == .activities && model.activityTool == .timer, "running timer → Live Activities")
    timer.select(minutes: 1)
    expect(timer.selectedDuration == 600, "presets ignored while running")
    timer.reset()
}


// MARK: - Playback control latency / consistency

await test("control: press → pending → confirmed only when the player reports it") {
    let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    var t = PlaybackCommandTracker()
    let c = t.issue(.playPause, observedPlaying: true, trackKey: "A", now: t0)
    expect(c.expectedPlaying == false && t.isPending && !t.displayedPlaying(observed: true), "button shows the request at once")
    expect(t.observe(isPlaying: true, trackKey: "A", sampledAt: t0.addingTimeInterval(-0.5), now: t0.addingTimeInterval(0.1)) == .none && t.isPending,
           "a sample taken before the press can't revert or confirm it")
    expect(t.delivered(c.id, success: true, now: t0.addingTimeInterval(0.08)) == .none, "delivered")
    expect(t.observe(isPlaying: true, trackKey: "A", sampledAt: t0.addingTimeInterval(0.1), now: t0.addingTimeInterval(0.1)) == .none && t.isPending,
           "player not changed yet → still pending (not reverted, not claimed)")
    expect(t.observe(isPlaying: false, trackKey: "A", sampledAt: t0.addingTimeInterval(0.3), now: t0.addingTimeInterval(0.3)) == .confirmed
           && !t.isPending && !t.displayedPlaying(observed: false), "confirmed by observation")
    expect(t.observe(isPlaying: true, trackKey: "A", sampledAt: t0.addingTimeInterval(5), now: t0.addingTimeInterval(5)) == .none
           && t.displayedPlaying(observed: true), "afterwards the player's own state is shown (outside changes win)")
}

await test("control: failures, delivery timeouts and no visible effect never look like success") {
    let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    var t = PlaybackCommandTracker()
    let a = t.issue(.playPause, observedPlaying: true, trackKey: "A", now: t0)
    expect(t.delivered(a.id, success: false, now: t0.addingTimeInterval(0.1)) == .failed && !t.isPending
           && t.displayedPlaying(observed: true) && t.lastOutcome == .failed, "send failed → back to the real state + failure")
    let b = t.issue(.playPause, observedPlaying: true, trackKey: "A", now: t0)
    _ = t.delivered(b.id, success: true, now: t0.addingTimeInterval(0.1))
    expect(t.expireIfNeeded(now: t0.addingTimeInterval(2.0)) == .none && t.isPending, "inside the confirm window")
    expect(t.observe(isPlaying: true, trackKey: "A", sampledAt: t0.addingTimeInterval(2.7), now: t0.addingTimeInterval(2.7)) == .noEffect
           && !t.isPending && t.displayedPlaying(observed: true), "no change within 2.5 s → 'no effect', real state shown")
    _ = t.issue(.playPause, observedPlaying: false, trackKey: "A", now: t0)
    expect(t.expireIfNeeded(now: t0.addingTimeInterval(3.9)) == .none, "waiting for delivery")
    expect(t.expireIfNeeded(now: t0.addingTimeInterval(4.0)) == .failed && !t.isPending, "hung player → failed after 4 s")
    // Something else changed underneath (another track / source) while a pause was pending.
    let d = t.issue(.playPause, observedPlaying: true, trackKey: "A", now: t0)
    _ = t.delivered(d.id, success: true, now: t0)
    expect(t.observe(isPlaying: true, trackKey: "B", sampledAt: t0.addingTimeInterval(0.5), now: t0.addingTimeInterval(0.5)) == .noEffect
           && !t.isPending, "outside change cancels the pending request")
}

await test("control: rapid taps alternate predictably, stale results are ignored, queued presses coalesce") {
    let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    var t = PlaybackCommandTracker()
    let one = t.issue(.playPause, observedPlaying: true, trackKey: "A", now: t0)
    let two = t.issue(.playPause, observedPlaying: true, trackKey: "A", now: t0.addingTimeInterval(0.1))
    let three = t.issue(.playPause, observedPlaying: true, trackKey: "A", now: t0.addingTimeInterval(0.2))
    expect(one.expectedPlaying == false && two.expectedPlaying == true && three.expectedPlaying == false, "pause → play → pause")
    expect(!t.isCurrent(one.id) && !t.isCurrent(two.id) && t.isCurrent(three.id), "only the latest press is sent if older ones are still queued")
    expect(t.delivered(one.id, success: false, now: t0.addingTimeInterval(0.3)) == .stale && t.isPending && t.lastOutcome == .none,
           "an older command's late failure doesn't cancel the newer press")
    _ = t.delivered(three.id, success: true, now: t0.addingTimeInterval(0.35))
    expect(t.observe(isPlaying: false, trackKey: "A", sampledAt: t0.addingTimeInterval(0.5), now: t0.addingTimeInterval(0.5)) == .confirmed, "final state confirmed")
    // Explicit intents make repeats harmless; media keys can only toggle.
    expect(MusicController.intent(for: .playPause, expectedPlaying: false, route: .browserScript) == .pause
           && MusicController.intent(for: .playPause, expectedPlaying: true, route: .appleScript) == .play
           && MusicController.intent(for: .playPause, expectedPlaying: true, route: .mediaRemote) == .play
           && MusicController.intent(for: .playPause, expectedPlaying: false, route: .mediaKey) == .playPause
           && MusicController.intent(for: .next, expectedPlaying: nil, route: .browserScript) == .next, "intent mapping")
    expect(SystemMedia.mediaRemoteCommand(.play) == 0 && SystemMedia.mediaRemoteCommand(.pause) == 1, "MediaRemote explicit commands")
    // Next/previous confirm when the item changes.
    var n = PlaybackCommandTracker()
    let next = n.issue(.next, observedPlaying: true, trackKey: "A", now: t0)
    _ = n.delivered(next.id, success: true, now: t0)
    expect(next.expectedPlaying == nil && n.displayedPlaying(observed: true), "next doesn't change the play icon")
    expect(n.observe(isPlaying: true, trackKey: "A", sampledAt: t0.addingTimeInterval(0.2), now: t0.addingTimeInterval(0.2)) == .none, "same item: pending")
    expect(n.observe(isPlaying: true, trackKey: "B", sampledAt: t0.addingTimeInterval(0.6), now: t0.addingTimeInterval(0.6)) == .confirmed, "new item: confirmed")
    expect(MusicController.confirmationDelays.first! <= 0.2 && MusicController.confirmationDelays.last! >= PlaybackCommandTracker.confirmWindow,
           "fast first re-check, coverage of the whole window")
}

await test("control: explicit play/pause JS is idempotent; read-back script format") {
    @MainActor func page(_ setup: String) -> JSContext {
        let ctx = JSContext()!
        ctx.evaluateScript("""
        var calls = [];
        var song = { paused: false, ended: false, currentTime: 57, duration: 219, closest: function(){ return null; },
                     play: function(){ this.paused = false; calls.push('el:play'); }, pause: function(){ this.paused = true; calls.push('el:pause'); } };
        var selectors = { '#movie_player video': song }, byId = {};
        var document = { getElementById: function(i){ return byId[i] || null; },
                         querySelector: function(s){ return Object.prototype.hasOwnProperty.call(selectors, s) ? selectors[s] : null; },
                         querySelectorAll: function(){ return [song]; } };
        \(setup)
        """)
        return ctx
    }
    func run(_ ctx: JSContext, _ c: BrowserMedia.Command, _ site: BrowserMedia.Site) -> String? {
        ctx.evaluateScript(BrowserMedia.controlJS(c, site: site))?.toString()
    }
    // YouTube Music button: pressed only when the state differs.
    let ytm = page("selectors['ytmusic-player-bar #play-pause-button'] = { click: function(){ calls.push('bar'); song.paused = !song.paused; } };")
    _ = run(ytm, .pause, .youtubeMusic); _ = run(ytm, .pause, .youtubeMusic)
    expect(ytm.evaluateScript("calls.join(',')").toString() == "bar" && ytm.evaluateScript("song.paused").toBool(), "pause twice → one press")
    _ = run(ytm, .play, .youtubeMusic)
    expect(ytm.evaluateScript("calls.join(',')").toString() == "bar,bar" && !ytm.evaluateScript("song.paused").toBool(), "play → one press")
    // Player API: explicit calls.
    let api = page("byId['movie_player'] = { playVideo: function(){ calls.push('api:play'); }, pauseVideo: function(){ calls.push('api:pause'); } };")
    expect(run(api, .pause, .youtube) == "ok" && run(api, .play, .youtube) == "ok"
           && api.evaluateScript("calls.join(',')").toString() == "api:pause,api:play", "player API play/pause")
    let el = page("")
    _ = run(el, .pause, .youtube); _ = run(el, .pause, .youtube)
    expect(el.evaluateScript("song.paused").toBool() && el.evaluateScript("calls.join(',')").toString() == "el:pause,el:pause", "element pause is idempotent")
    // One round trip returns "result ␟ state".
    let fs = BrowserMedia.fieldSeparator
    let parsed = BrowserMedia.parseControlResult("ok\(fs){\"h\":true}")
    expect(parsed.result == "ok" && parsed.stateJSON == "{\"h\":true}" && BrowserMedia.controlSucceeded(parsed.result), "split")
    expect(BrowserMedia.parseControlResult("gone").stateJSON == nil && !BrowserMedia.controlSucceeded("gone")
           && !BrowserMedia.controlSucceeded("none") && !BrowserMedia.controlSucceeded("blocked"), "failures")
    let script = BrowserMedia.controlScript(for: .chrome, ref: "7", js: BrowserMedia.controlJS(.pause, site: .youtubeMusic), readBack: true)!
    expect(script.contains("with timeout of \(BrowserMedia.controlTimeout) seconds") && script.contains("set s to") && script.contains("return \"blocked\""),
           "timeout, read-back and URL re-check in the control script")
    for (browser, ref) in [(BrowserMedia.Browser.chrome, "7"), (.chrome, "1/7"), (.safari, "1/7")] {
        let music = BrowserMedia.controlScript(for: browser, ref: ref, js: "1", site: .youtubeMusic)!
        expect(music.contains("https://music.youtube.com/") && !music.contains("https://www.youtube.com/watch?"),
               "a YouTube Music command can't run if its tab navigated to YouTube")
    }
    let readOnly = BrowserMedia.readTabScript(for: .safari, ref: "3/1")!
    expect(readOnly.contains("set r to \"ok\"") && !readOnly.contains("pauseVideo") && readOnly.contains("with timeout"), "targeted read sends no command")
    expect(BrowserMedia.listScript(for: .chrome).contains("with timeout of \(BrowserMedia.scanTimeout) seconds"), "scans can't stall the queue forever")
}

await test("control: compiled-script cache reuses compilations") {
    let cache = CompiledScriptCache(capacity: 2)
    let a = cache.script(for: "return 1"), again = cache.script(for: "return 1")
    expect(a != nil && a === again && cache.count == 1, "same instance reused")
    _ = cache.script(for: "return 2"); _ = cache.script(for: "return 3")
    expect(cache.count == 2 && cache.script(for: "return 1") !== a, "bounded (oldest evicted)")
    var error: NSDictionary?
    let start = Date()
    for _ in 0..<20 { _ = cache.script(for: "return 2")?.executeAndReturnError(&error) }
    print("    20 cached executions of a trivial script: \(Int(Date().timeIntervalSince(start) * 1000)) ms (no app targeted)")
    expect(error == nil, "runs")
}


// MARK: - Round 2026-11-08: hover loop, time sources, next/previous, stock search, audio

await test("hover: keep-open zone contains every activation point (no expand/collapse loop)") {
    let frame = NSRect(x: 0, y: 0, width: 1512, height: 982)
    let notch = NSRect(x: 662, y: 950, width: 185, height: 32)
    let d = freshDefaults()
    let sw = Stopwatch(defaults: d)
    let model = IslandViewModel(geometry: NotchGeometry(screenFrame: frame, hasNotch: true, notchRect: notch),
                                timer: CountdownTimer(defaults: d), music: MusicController(defaults: d), stopwatch: sw)
    sw.start()
    for _ in 0..<5 { await Task.yield(); try await Task.sleep(for: .milliseconds(20)) }
    expect(model.mode == .compact, "live activity → compact indicators")
    // The reported spot: pointer resting on the right indicator.
    let right = NSPoint(x: notch.maxX + 30, y: 970)
    expect(model.activationContains(right), "right indicator opens the island")
    // Sample the whole collapsed activation area (incl. hover growth) and check hysteresis.
    var activationPoints: [NSPoint] = []
    model.isHovering = true
    for x in stride(from: notch.minX - 80, through: notch.maxX + 80, by: 4) {
        for y in stride(from: 930.0, through: 982, by: 2) {
            let p = NSPoint(x: x, y: y)
            if model.activationContains(p, mode: .compact) { activationPoints.append(p) }
        }
    }
    model.isHovering = false
    model.setExpanded(true)
    expect(activationPoints.count > 200, "sampled \(activationPoints.count) activation points")
    let escaped = activationPoints.filter { !model.keepOpenContains($0) }
    expect(escaped.isEmpty, "every activation point keeps the expanded island open (escaped: \(escaped.prefix(3)))")
    expect(model.keepOpenContains(right) && !model.acceptsMouse(at: right), "stays open there, but clicks still reach the menu bar")
    expect(!model.keepOpenContains(NSPoint(x: notch.maxX + IslandViewModel.compactSideWidth + 25, y: 970)), "beyond the indicators it still collapses")
    expect(!model.keepOpenContains(NSPoint(x: 100, y: 970)) && !model.keepOpenContains(NSPoint(x: 754, y: 500)), "far away collapses")
    model.setExpanded(false)
    sw.reset()
    for _ in 0..<5 { await Task.yield(); try await Task.sleep(for: .milliseconds(20)) }
    // Idle: notch + strip are inside the keep-open zone too.
    model.setExpanded(true)
    expect(model.keepOpenContains(NSPoint(x: 754, y: 975)) && model.keepOpenContains(NSPoint(x: 754, y: 945)), "idle activation kept")
    expect(!model.keepOpenContains(NSPoint(x: notch.maxX + 30, y: 970)), "no indicators when idle → menu bar beside the notch not kept")
}

await test("time: two sources must agree; stale/continuing timelines stay hidden (auto-advance)") {
    typealias S = BrowserMedia.TimeSample
    let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    func at(_ s: Double) -> Date { t0.addingTimeInterval(s) }
    var r = BrowserMedia.TimeResolver()
    // Song A near its end; player API and player bar agree.
    let a = r.resolve(item: "A", samples: .init(ui: S(position: 216, duration: 219), player: S(position: 216.4, duration: 219), element: nil), isPlaying: true, at: at(0))
    expect(a?.0.position == 216.4 && a?.1 == .player, "agreeing sources → precise player time")
    // Auto-advance to B: element keeps one continuous timeline (222 s in), UI and player show the new song.
    let b1 = r.resolve(item: "B", samples: .init(ui: S(position: 3, duration: 180), player: S(position: 3.2, duration: 180), element: S(position: 222, duration: 600)), isPlaying: true, at: at(6))
    expect(b1?.0.position == 3.2 && b1?.0.duration == 180, "new song's own time, not 222 s stacked on top: \(String(describing: b1))")

    // Player bar lags the title for a moment: sources disagree → hidden, then shown once they agree.
    var lag = BrowserMedia.TimeResolver()
    _ = lag.resolve(item: "A", samples: .init(ui: S(position: 217, duration: 219), player: S(position: 217, duration: 219), element: nil), isPlaying: true, at: at(0))
    expect(lag.resolve(item: "B", samples: .init(ui: S(position: 218, duration: 219), player: S(position: 1, duration: 180), element: nil), isPlaying: true, at: at(1)) == nil,
           "disagreement during the change → hidden")
    expect(lag.resolve(item: "B", samples: .init(ui: S(position: 2, duration: 180), player: S(position: 2.1, duration: 180), element: nil), isPlaying: true, at: at(2))?.0.position == 2.1,
           "shown as soon as they agree")

    // Player API still carries the old song's time, player bar is right: bar wins after two consistent samples.
    var carry = BrowserMedia.TimeResolver()
    _ = carry.resolve(item: "A", samples: .init(ui: S(position: 218, duration: 219), player: S(position: 218, duration: 219), element: nil), isPlaying: true, at: at(0))
    expect(carry.resolve(item: "B", samples: .init(ui: S(position: 1, duration: 200), player: S(position: 220, duration: 400), element: nil), isPlaying: true, at: at(2)) == nil, "one sample isn't enough")
    let barWins = carry.resolve(item: "B", samples: .init(ui: S(position: 2, duration: 200), player: S(position: 221, duration: 400), element: nil), isPlaying: true, at: at(3))
    expect(barWins?.0.position == 2 && barWins?.1 == .ui, "visible bar time after it proved consistent")

    // Only a continuous element timeline is available: never shown for the new song, no time limit.
    var only = BrowserMedia.TimeResolver()
    _ = only.resolve(item: "A", samples: .init(ui: nil, player: nil, element: S(position: 217, duration: 600)), isPlaying: true, at: at(0))
    _ = only.resolve(item: "A", samples: .init(ui: nil, player: nil, element: S(position: 218, duration: 600)), isPlaying: true, at: at(1))
    var shown: [Double] = []
    for k in 0..<20 {
        let v = 222 + Double(k)
        if let res = only.resolve(item: "B", samples: .init(ui: nil, player: nil, element: S(position: v, duration: 600)), isPlaying: true, at: at(5 + Double(k))) { shown.append(res.0.position) }
    }
    expect(shown.isEmpty, "old timeline continuing is hidden even after 20 s (was shown after 2.5 s before): \(shown)")

    // Legit cases still show quickly.
    var fresh = BrowserMedia.TimeResolver()
    expect(fresh.resolve(item: "X", samples: .init(ui: S(position: 95, duration: 240), player: nil, element: nil), isPlaying: true, at: at(0)) == nil, "single source: wait one sample")
    expect(fresh.resolve(item: "X", samples: .init(ui: S(position: 96, duration: 240), player: nil, element: nil), isPlaying: true, at: at(1))?.0.position == 96, "launched mid-song: shown after a consistent sample")
    expect(fresh.resolve(item: "X", samples: .init(ui: S(position: 30, duration: 240), player: S(position: 30.3, duration: 240), element: nil), isPlaying: true, at: at(2))?.0.position == 30.3, "seek: agreeing sources → immediate")
    var same = BrowserMedia.TimeResolver()
    _ = same.resolve(item: "A", samples: .init(ui: S(position: 179, duration: 180), player: S(position: 179, duration: 180), element: nil), isPlaying: true, at: at(0))
    expect(same.resolve(item: "B", samples: .init(ui: S(position: 1, duration: 180), player: S(position: 1, duration: 180), element: nil), isPlaying: true, at: at(2))?.0.position == 1, "same-length next song starting at 0:01 shown")
    expect(same.resolve(item: "B", samples: .init(ui: S(position: 5, duration: 180), player: S(position: 5, duration: 180), element: nil, blocked: true), isPlaying: true, at: at(3)) == nil, "ad / mismatched IDs → hidden")
    var paused = BrowserMedia.TimeResolver()
    _ = paused.resolve(item: "P", samples: .init(ui: S(position: 40, duration: 200), player: nil, element: nil), isPlaying: false, at: at(0))
    expect(paused.resolve(item: "P", samples: .init(ui: S(position: 40, duration: 200), player: nil, element: nil), isPlaying: false, at: at(3))?.0.position == 40, "paused: unchanged time is consistent")
    // Raw sources are parsed from the page JSON.
    let json = #"{"t":"B","h":true,"p":true,"c":222,"d":600,"ts":"element","tu":{"c":3,"d":180},"tp":{"c":3.2,"d":180},"te":{"c":222,"d":600}}"#
    let tab = BrowserMedia.parseState(json, browser: .chrome, ref: "1", site: .youtubeMusic, tabTitle: "")
    expect(tab?.timeSamples?.ui == S(position: 3, duration: 180) && tab?.timeSamples?.player?.position == 3.2 && tab?.timeSamples?.element?.position == 222, "raw sources parsed")
    let blocked = BrowserMedia.parseState(#"{"t":"B","h":true,"p":true,"c":null,"d":null,"ts":"transition","tu":null,"tp":null,"te":null}"#, browser: .chrome, ref: "1", site: .youtubeMusic, tabTitle: "")
    expect(blocked?.timeSamples?.blocked == true, "transition flagged")
}

await test("next/previous: YouTube Music button pressed exactly once, on the element that listens") {
    @MainActor func page(_ setup: String) -> JSContext {
        let ctx = JSContext()!
        ctx.evaluateScript("""
        var actions = [];
        function el(name, attrs, inner){ var o = { name: name, attrs: attrs || {}, inner: inner || null,
            matches: function(s){ return s === 'button' && name.indexOf('button') === 0; },
            querySelector: function(s){ return s === 'button' ? this.inner : null; },
            hasAttribute: function(a){ return Object.prototype.hasOwnProperty.call(this.attrs, a); },
            getAttribute: function(a){ return this.hasAttribute(a) ? this.attrs[a] : null; },
            click: function(){ actions.push('click:' + name); } }; return o; }
        var selectors = {}, byId = {};
        var document = { getElementById: function(i){ return byId[i] || null; },
                         querySelector: function(s){ return Object.prototype.hasOwnProperty.call(selectors, s) ? selectors[s] : null; },
                         querySelectorAll: function(){ return []; } };
        \(setup)
        """)
        return ctx
    }
    func run(_ ctx: JSContext, _ c: BrowserMedia.Command) -> String? { ctx.evaluateScript(BrowserMedia.controlJS(c, site: .youtubeMusic))?.toString() }
    let api = "byId['movie_player'] = { nextVideo: function(){ actions.push('api:next'); }, previousVideo: function(){ actions.push('api:prev'); } };"
    // Earlier layout: yt-icon-button host with an inner <button> that has the listener.
    let modern = page(api + "selectors['ytmusic-player-bar .next-button'] = el('yt-icon-button', {}, el('button-inner'));")
    expect(run(modern, .next) == "ok" && modern.evaluateScript("actions.join(',')").toString() == "click:button-inner", "inner button clicked once, API not also called")
    // Old layout: the host itself is the button.
    let legacy = page(api + "selectors['ytmusic-player-bar .previous-button'] = el('tp-yt-paper-icon-button');")
    expect(run(legacy, .previous) == "ok" && legacy.evaluateScript("actions.join(',')").toString() == "click:tp-yt-paper-icon-button", "host clicked once")
    // Disabled (e.g. no previous item): reported, nothing pressed, no fallback action.
    let disabled = page(api + "selectors['ytmusic-player-bar .next-button'] = el('yt-icon-button', {'aria-disabled':'true'}, el('button-inner'));")
    expect(run(disabled, .next) == "disabled" && disabled.evaluateScript("actions.length").toInt32() == 0, "disabled → no action")
    expect(!BrowserMedia.controlSucceeded("disabled"), "disabled counts as not sent")
    // No button at all: the player API once.
    let none = page(api)
    expect(run(none, .next) == "ok" && none.evaluateScript("actions.join(',')").toString() == "api:next", "fallback API once")
    expect(run(page(""), .previous) == "none", "nothing available → none")
    // The press is confirmed only by the item changing; no automatic second press.
    var t = PlaybackCommandTracker()
    let c = t.issue(.next, observedPlaying: true, trackKey: "A", now: Date(timeIntervalSince1970: 0))
    _ = t.delivered(c.id, success: true, now: Date(timeIntervalSince1970: 0.1))
    expect(t.observe(isPlaying: true, trackKey: "A", sampledAt: Date(timeIntervalSince1970: 3), now: Date(timeIntervalSince1970: 3)) == .noEffect,
           "no change → 'no effect' reported (never re-sent automatically)")
}

await test("YouTube Music mini player: skip clicks the single visible, enabled transport button") {
    let context = JSContext()!
    context.evaluateScript("""
    var actions=[], hosts=[];
    function button(label, enabled, shown) {
        return {disabled:!enabled, getClientRects:()=>shown?[1]:[], getAttribute:a=>a==='aria-label'?label:null,
                click:()=>actions.push(label)};
    }
    function host(buttons, shown=true) { return {getClientRects:()=>shown?[1]:[], querySelectorAll:()=>buttons}; }
    var document={querySelectorAll:()=>hosts};
    function getComputedStyle(){return {visibility:'visible'};}
    var previous=button('上一個',true,true), next=button('下一個',true,true), hidden=button('下一個',true,false);
    hosts=[host([previous,next,hidden]),host([previous,next],false)];
    """)
    func send(_ command: BrowserMedia.Command) -> String? {
        context.evaluateScript(BrowserMedia.controlJS(command, site: .youtubeMusic))?.toString()
    }
    expect(send(.next) == "ok" && send(.previous) == "ok" &&
           context.evaluateScript("actions.join(',')").toString() == "下一個,上一個", "exactly one press in each direction")
    context.evaluateScript("next.disabled=true; actions=[];")
    expect(send(.next) == "disabled" && context.evaluateScript("actions.length").toInt32() == 0, "disabled ends the request")
    context.evaluateScript("hosts=[host([next,next])];")
    expect(send(.next) == "blocked", "two matching buttons are ambiguous")
    context.evaluateScript("hosts=[host([next]),host([next])];")
    expect(send(.next) == "blocked", "two visible transport groups are ambiguous")
    context.evaluateScript("hosts=[host([next])];")
    expect(send(.previous) == "none" && context.evaluateScript("actions.length").toInt32() == 0, "no matching button proves no action was taken")
    context.evaluateScript("var window={matchMedia:q=>({matches:q.includes('standalone')})};")
    expect(send(.previous) == "none-standalone", "only an installed web app can request the exact PWA fallback")
}

await test("YouTube Music AX: skip targets surround the play button; uncertain layouts are ignored") {
    typealias Transport = YouTubeMusicTransport
    func control(_ role: String, _ classes: [String] = [], enabled: Bool = true) -> Transport.Control {
        .init(role: role, classes: classes, enabled: enabled)
    }
    let shuffle = control("AXCheckBox"), previous = control("AXButton"), next = control("AXButton")
    let play = control("AXGroup", ["ytmusicPlayerControlsControlButton", "ytmusicPlayerControlsPlayPauseButton"])
    let repeatButton = control("AXCheckBox")
    let liveShape = [shuffle, previous, play, next, repeatButton]
    expect(Transport.skipButtonIndex(for: .previous, in: liveShape) == 1, "previous immediately before play")
    expect(Transport.skipButtonIndex(for: .next, in: liveShape) == 3, "next immediately after play")
    let disabled = control("AXButton", enabled: false)
    expect(Transport.skipButtonIndex(for: .previous, in: [shuffle, disabled, play, next, repeatButton]) == nil,
           "a disabled skip target is not actionable")
    expect(Transport.skipButtonIndex(for: .previous, in: [shuffle, play, next, repeatButton]) == nil &&
           Transport.skipButtonIndex(for: .next, in: liveShape + [play]) == nil &&
           Transport.skipButtonIndex(for: .next, in: liveShape + [next]) == nil, "missing or duplicated controls are ambiguous")
}

await test("YouTube Music Previous can confirm a restart without changing songs") {
    let time = Date(timeIntervalSince1970: 1_800_000_000), later = time.addingTimeInterval(1)
    var tracker = PlaybackCommandTracker()
    let command = tracker.issue(.previous, observedPlaying: true, trackKey: "A", now: time, position: 42)
    expect(tracker.observe(isPlaying: true, trackKey: "A", sampledAt: later, now: later, position: 0.5) == .none,
           "position reset before delivery can't confirm the press")
    _ = tracker.delivered(command.id, success: true, now: later)
    expect(tracker.observe(isPlaying: true, trackKey: "A", sampledAt: later, now: later, position: 0.5) == .confirmed,
           "a previously advanced song returned to its opening")
    let next = tracker.issue(.next, observedPlaying: true, trackKey: "A", now: time, position: 42)
    _ = tracker.delivered(next.id, success: true, now: later)
    expect(tracker.observe(isPlaying: true, trackKey: "A", sampledAt: later, now: later, position: 0.5) == .none,
           "next still needs to observe a different track")
}

await test("stocks: search parsing, unsupported queries, provider errors") {
    let yahoo = Data(#"""
    {"count":4,"quotes":[
     {"symbol":"TSM","shortname":"Taiwan Semiconductor Manufactur","longname":"Taiwan Semiconductor Manufacturing Company Limited","exchange":"NYQ","exchDisp":"NYSE","quoteType":"EQUITY","typeDisp":"Equity"},
     {"symbol":"2330.TW","shortname":"TAIWAN SEMICONDUCTOR MANUFACTUR","exchange":"TAI","exchDisp":"Taiwan","quoteType":"EQUITY","typeDisp":"Equity"},
     {"symbol":"TSM","shortname":"dup","exchange":"NYQ","exchDisp":"NYSE"},
     {"symbol":"bad symbol!","shortname":"x","exchange":"X","exchDisp":"X"},
     {"shortname":"no symbol"}],"news":[]}
    """#.utf8)
    let matches = try YahooFinanceProvider.parseSearch(yahoo)
    expect(matches.map(\.symbol) == ["TSM", "2330.TW"], "valid, de-duplicated: \(matches.map(\.symbol))")
    expect(matches[0].name.hasPrefix("Taiwan Semiconductor Manufacturing") && matches[0].exchangeName == "NYSE" && matches[1].exchangeName == "Taiwan" && matches[1].name == "TAIWAN SEMICONDUCTOR MANUFACTUR",
           "long name preferred, exchange shown")
    expect(YahooFinanceProvider.isSearchable("TSMC") && !YahooFinanceProvider.isSearchable("台積電") && !YahooFinanceProvider.isSearchable("   ")
           && !YahooFinanceProvider.isSearchable(String(repeating: "a", count: 41)), "searchable text")
    expect(YahooFinanceProvider.searchURL("S&P 500")?.query?.contains("q=S%26P%20500") == true, "query encoded")
    let http = MockHTTP { _ in (Data(), 200) }
    do { _ = try await YahooFinanceProvider(client: http).search("台積電"); expect(false, "should fail") }
    catch { expect(ProviderError(error) == .unsupportedQuery && http.urls.isEmpty, "non-Latin query explained locally, nothing sent") }
    for (status, expected) in [(400, ProviderError.unsupportedQuery), (429, .rateLimited), (503, .http(503))] {
        do { _ = try await YahooFinanceProvider(client: MockHTTP { _ in (Data(), status) }).search("apple"); expect(false, "\(status)") }
        catch { expect(ProviderError(error) == expected, "HTTP \(status) → \(expected)") }
    }
    do { _ = try YahooFinanceProvider.parseSearch(Data("<html>".utf8)); expect(false, "bad") } catch { expect(ProviderError(error) == .invalidResponse, "garbage") }
    let av = Data(#"{"bestMatches":[{"1. symbol":"TSCO.LON","2. name":"Tesco PLC","3. type":"Equity","4. region":"United Kingdom"},{"1. symbol":"TSCDF","2. name":"Tesco plc","3. type":"Equity","4. region":"United States"}]}"#.utf8)
    let avMatches = try AlphaVantageProvider.parseSearch(av)
    expect(avMatches.map(\.symbol) == ["TSCO.LON", "TSCDF"] && avMatches[0].exchangeName == "United Kingdom", "Alpha Vantage SYMBOL_SEARCH")
    do { _ = try AlphaVantageProvider.parseSearch(Data(#"{"Information":"Our standard API rate limit is 25 requests per day."}"#.utf8)); expect(false, "rl") }
    catch { expect(ProviderError(error) == .rateLimited, "AV rate limit") }
    let lang = LanguageSettings.shared
    let saved = lang.language; defer { lang.language = saved }
    for l in [AppLanguage.english, .traditionalChinese, .simplifiedChinese] {
        lang.language = l
        expect(!lang.t(.errUnsupportedQuery).isEmpty && !lang.t(.addTypedTicker, "2330.TW").contains("%@") && lang.t(.addTypedTicker, "2330.TW").contains("2330.TW"), "\(l) strings")
    }
}

await test("stocks: search races — only the latest query's answer is shown") {
    let model = StockSearchModel(debounce: .zero) { query in
        if query == "app" { try await Task.sleep(for: .milliseconds(250)); return [SymbolMatch(symbol: "AAPL", name: "Apple", exchangeCode: "NMS", exchangeName: "NASDAQ", type: "Equity")] }
        if query == "fail" { throw ProviderError.rateLimited }
        if query == "none" { return [] }
        return [SymbolMatch(symbol: "TSM", name: "TSMC", exchangeCode: "NYQ", exchangeName: "NYSE", type: "Equity"),
                SymbolMatch(symbol: "2330.TW", name: "TSMC", exchangeCode: "TAI", exchangeName: "Taiwan", type: "Equity")]
    }
    model.update(query: "app")
    expect(model.phase == .searching, "searching")
    model.update(query: "tsm")
    await model.waitForIdle()
    try await Task.sleep(for: .milliseconds(350)) // the slow, older "app" request finishes now
    expect(model.results.map(\.symbol) == ["TSM", "2330.TW"] && model.phase == .results, "late answer to an older query ignored: \(model.results.map(\.symbol))")
    expect(model.exchanges == ["NYSE", "Taiwan"], "exchanges")
    model.exchangeFilter = "Taiwan"
    expect(model.filtered.map(\.symbol) == ["2330.TW"], "filter by exchange")
    model.update(query: "fail"); await model.waitForIdle()
    expect(model.phase == .failed(.rateLimited) && model.results.isEmpty, "errors shown, no stale list")
    model.update(query: "none"); await model.waitForIdle()
    expect(model.phase == .empty && model.exchangeFilter == nil, "empty; filter reset")
    model.update(query: "  ")
    expect(model.phase == .idle && model.results.isEmpty, "cleared")
}

await test("audio: artwork palette, real-sample band levels, silence detection, opt-in") {
    func image(_ draw: (CGContext) -> Void) -> NSImage {
        let size = 32
        let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: size * 4,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        draw(ctx)
        return NSImage(cgImage: ctx.makeImage()!, size: NSSize(width: size, height: size))
    }
    let split = image { c in
        c.setFillColor(CGColor(srgbRed: 0.9, green: 0.1, blue: 0.1, alpha: 1)); c.fill(CGRect(x: 0, y: 0, width: 20, height: 32))
        c.setFillColor(CGColor(srgbRed: 0.1, green: 0.2, blue: 0.9, alpha: 1)); c.fill(CGRect(x: 20, y: 0, width: 12, height: 32))
    }
    let p = ArtworkPalette.extract(from: split)
    expect(p != nil && p!.primary.r > p!.primary.b && p!.secondary.b > p!.secondary.r, "dominant red, secondary blue: \(String(describing: p))")
    let flat = ArtworkPalette.extract(from: image { c in c.setFillColor(CGColor(srgbRed: 0.2, green: 0.7, blue: 0.3, alpha: 1)); c.fill(CGRect(x: 0, y: 0, width: 32, height: 32)) })
    expect(flat != nil && flat!.secondary.brightness < flat!.primary.brightness, "single colour → darker secondary")
    expect(ArtworkPalette.extract(from: image { _ in }) == nil, "fully transparent → no palette")
    let dark = ArtworkPalette.RGB(r: 0.02, g: 0.02, b: 0.03).clamped(minBrightness: 0.45, maxBrightness: 0.95)
    expect(dark.brightness >= 0.44, "very dark covers lifted for visible bars")

    func sine(_ hz: Double, amp: Float, rate: Double = 48_000) -> [Float] {
        (0..<1024).map { amp * Float(sin(2 * .pi * hz * Double($0) / rate)) }
    }
    let low = AudioLevels.bands(sine(120, amp: 0.5), sampleRate: 48_000)
    let high = AudioLevels.bands(sine(3000, amp: 0.5), sampleRate: 48_000)
    expect(low.firstIndex(of: low.max()!) == 0 && high.firstIndex(of: high.max()!) == 3, "band follows frequency: low \(low), high \(high)")
    expect(AudioLevels.bands([Float](repeating: 0, count: 1024), sampleRate: 48_000).allSatisfy { $0 == 0 }, "silence → zero bars (nothing invented)")
    let quiet = AudioLevels.bands(sine(120, amp: 0.02), sampleRate: 48_000)
    expect(low[0] > quiet[0] && low.allSatisfy { (0...1).contains($0) }, "louder → taller, bounded")
    let smoothed = AudioLevels.smooth(previous: [0, 1], next: [1, 0])
    expect(smoothed[0] > 0.5 && smoothed[1] > 0.5, "fast attack, slower release: \(smoothed)")
    let t0 = Date(timeIntervalSince1970: 0)
    expect(AudioLevelMonitor.classify(lastNonSilent: nil, startedAt: t0, now: t0.addingTimeInterval(2)) == .running, "grace after start")
    expect(AudioLevelMonitor.classify(lastNonSilent: nil, startedAt: t0, now: t0.addingTimeInterval(5)) == .silent, "only silence → reported as silent")
    expect(AudioLevelMonitor.classify(lastNonSilent: t0.addingTimeInterval(9), startedAt: t0, now: t0.addingTimeInterval(10)) == .running, "audio arriving")
    let monitor = AudioLevelMonitor(defaults: freshDefaults())
    expect(!monitor.enabled && monitor.state == .off && monitor.levels == nil, "off by default; no levels → no bars")
    monitor.setEnabled(true, mediaPlaying: false) // nothing playing: no capture started, no prompt
    expect(monitor.state == (AudioLevelMonitor.isSupported ? .idle : .unsupported) && monitor.levels == nil, "enabled but idle until media plays")
    monitor.setEnabled(false, mediaPlaying: false)
    expect(monitor.state == .off, "off again")
    let plist = try String(contentsOfFile: "Resources/Info.plist", encoding: .utf8)
    expect(plist.contains("NSAudioCaptureUsageDescription"), "permission purpose string present")
    for l in ["en", "zh-Hant", "zh-Hans"] {
        let strings = try String(contentsOfFile: "Resources/\(l).lproj/InfoPlist.strings", encoding: .utf8)
        expect(strings.contains("NSAudioCaptureUsageDescription"), "\(l) purpose string")
    }
}


await test("time: a normal new song is never hidden indefinitely (early skip, similar length, late detection)") {
    typealias S = BrowserMedia.TimeSample
    let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    func at(_ s: Double) -> Date { t0.addingTimeInterval(s) }
    func both(_ p: Double, _ d: Double) -> BrowserMedia.TimeSamples { .init(ui: S(position: p, duration: d), player: S(position: p + 0.2, duration: d), element: nil) }
    // Skip A only 3 s in: the old rule matched B (Δ) against 3+Δ forever.
    var early = BrowserMedia.TimeResolver()
    _ = early.resolve(item: "A", samples: both(3, 200), isPlaying: true, at: at(0))
    var shownAt: Double?
    for k in 1...30 where shownAt == nil {
        let delta = Double(k)
        if early.resolve(item: "B", samples: both(delta, 210), isPlaying: true, at: at(1 + delta)) != nil { shownAt = delta }
    }
    expect(shownAt == 1, "early skip: new song shown right away (was hidden for the whole song): \(String(describing: shownAt))")
    // Similar length and the first agreeing sample arrives late (35 s): brief stale window only.
    var late = BrowserMedia.TimeResolver()
    _ = late.resolve(item: "A", samples: both(30, 200), isPlaying: true, at: at(0))
    expect(late.resolve(item: "B", samples: both(35, 200), isPlaying: true, at: at(40)) == nil, "first moment after change: could be the old display → hidden")
    expect(late.resolve(item: "B", samples: both(40, 200), isPlaying: true, at: at(45))?.0.position == 40.2, "after the short window it is shown")
    // Sweep: any previous position/length, similar-length next song, detection lag 0–3 s.
    var stuck: [String] = []
    for prev in stride(from: 0.0, through: 300, by: 7) {
        for lag in [0.0, 1.5, 3] {
            var r = BrowserMedia.TimeResolver()
            let d = 200 + (prev.truncatingRemainder(dividingBy: 3) - 1) // ±1 s of the old length
            _ = r.resolve(item: "A", samples: both(prev, max(prev + 1, 200)), isPlaying: true, at: at(0))
            var ok = false
            for k in 0..<12 where !ok {
                let since = Double(k) // seconds since the change was detected
                ok = r.resolve(item: "B", samples: both(lag + since, d), isPlaying: true, at: at(10 + since)) != nil
                if ok && since > BrowserMedia.TimeResolver.staleDisplayWindow + 1 { ok = false; break }
            }
            if !ok { stuck.append("prev \(prev) lag \(lag)") }
        }
    }
    expect(stuck.isEmpty, "every fresh song is shown within ~5 s: \(stuck.prefix(5))")
    // The continuous-timeline case is still hidden (see the earlier 20 s test) — and seeking B later is fine.
    var seek = BrowserMedia.TimeResolver()
    _ = seek.resolve(item: "A", samples: both(100, 240), isPlaying: true, at: at(0))
    _ = seek.resolve(item: "B", samples: both(1, 180), isPlaying: true, at: at(2))
    expect(seek.resolve(item: "B", samples: both(150, 180), isPlaying: true, at: at(4))?.0.position == 150.2, "seek in the new song shown")
}

await test("audio: allocation-free capture path, cached analyser, sessions, output device") {
    if #available(macOS 14.2, *) {
        expect(SystemAudioTap.outputDeviceSelector == kAudioHardwarePropertyDefaultOutputDevice
               && SystemAudioTap.outputDeviceSelector != kAudioHardwarePropertyDefaultSystemOutputDevice,
               "uses the default output device (music), not the alert/sound-effects device")
    }
    var ring = SampleRing(capacity: 4)
    var out = [Float](repeating: -1, count: 4)
    ring.copyLatest(4, into: &out)
    expect(out == [0, 0, 0, 0], "empty → zero padding")
    for v in 1...6 { ring.append(Float(v)) }
    ring.copyLatest(4, into: &out)
    expect(out == [3, 4, 5, 6], "wrap-around keeps newest, oldest first: \(out)")
    var three = [Float](repeating: 0, count: 3)
    var small = SampleRing(capacity: 8); small.append(7); small.append(8)
    small.copyLatest(3, into: &three)
    expect(three == [0, 7, 8], "partial fill padded at the start")

    // Channel averaging straight from an AudioBufferList.
    let stereo: [Float] = [1, 3, -2, 2, 0.5, 0.5]
    let interleaved = AudioBufferList.allocate(maximumBuffers: 1)
    defer { free(interleaved.unsafeMutablePointer) }
    stereo.withUnsafeBufferPointer { p in
        interleaved[0] = AudioBuffer(mNumberChannels: 2, mDataByteSize: UInt32(stereo.count * 4), mData: UnsafeMutableRawPointer(mutating: p.baseAddress))
        var r = SampleRing(capacity: 8)
        AudioLevels.appendMono(interleaved.unsafePointer, interleaved: true, channels: 2, to: &r)
        var o = [Float](repeating: 0, count: 3); r.copyLatest(3, into: &o)
        expect(o == [2, 0, 0.5], "interleaved stereo averaged: \(o)")
    }
    let left: [Float] = [1, 1, 1], right: [Float] = [3, -1, 0]
    let planar = AudioBufferList.allocate(maximumBuffers: 2)
    defer { free(planar.unsafeMutablePointer) }
    left.withUnsafeBufferPointer { l in right.withUnsafeBufferPointer { rr in
        planar[0] = AudioBuffer(mNumberChannels: 1, mDataByteSize: 12, mData: UnsafeMutableRawPointer(mutating: l.baseAddress))
        planar[1] = AudioBuffer(mNumberChannels: 1, mDataByteSize: 12, mData: UnsafeMutableRawPointer(mutating: rr.baseAddress))
        var r = SampleRing(capacity: 8)
        AudioLevels.appendMono(planar.unsafePointer, interleaved: false, channels: 2, to: &r)
        var o = [Float](repeating: 0, count: 3); r.copyLatest(3, into: &o)
        expect(o == [2, 0, 0.5], "planar channels averaged: \(o)")
    } }

    // Cached analyser: same answers as the one-off path, and cheap enough for 30 Hz.
    let analyzer = LevelAnalyzer(sampleRate: 48_000)!
    let sine = (0..<LevelAnalyzer.size).map { 0.5 * Float(sin(2 * .pi * 120 * Double($0) / 48_000)) }
    let cached = sine.withUnsafeBufferPointer { analyzer.bands($0.baseAddress!) }
    let oneOff = AudioLevels.bands(sine, sampleRate: 48_000)
    expect(zip(cached, oneOff).allSatisfy { abs($0 - $1) < 1e-5 }, "cached analyser matches")
    let start = Date()
    var sink: Float = 0
    for _ in 0..<1000 { sink += sine.withUnsafeBufferPointer { analyzer.bands($0.baseAddress!) }[0] }
    let perFrame = Date().timeIntervalSince(start) / 1000
    print("    analysis: \(String(format: "%.3f", perFrame * 1000)) ms per frame (30 frames/s budget: 33 ms)")
    expect(perFrame < 0.002 && sink > 0, "analysis well under 2 ms per frame")

    // Results from a stopped / older capture session are ignored.
    let monitor = AudioLevelMonitor(defaults: freshDefaults())
    monitor.receive([0.9, 0.9, 0.9, 0.9, 0.9], session: monitor.session - 1)
    expect(monitor.levels == nil && monitor.state == .off, "stale session dropped")
    monitor.receive([0.9, 0.9, 0.9, 0.9, 0.9], session: monitor.session)
    expect(monitor.levels == nil, "no running capture → nothing shown")
    monitor.outputDeviceChanged()
    expect(monitor.state == .off, "device change while off touches nothing")
}


await test("music bars: original animation restored, cover-colour gradient, real levels only when available") {
    // Exactly the original MusicBars formula (4 bars, 0.35 + 0.65·|sin(t·(5.2+1.3i) + 1.7i)|).
    for t in [0.0, 0.37, 1.9, 12.25, 600.5] {
        for i in 0..<MusicBars.barCount {
            let expected = 0.35 + 0.65 * abs(sin(t * (5.2 + Double(i) * 1.3) + Double(i) * 1.7))
            expect(abs(MusicBars.level(index: i, time: t, isPlaying: true, realLevels: nil) - expected) < 1e-12, "bar \(i) at \(t)")
        }
    }
    expect(MusicBars.barCount == 4, "four bars as before")
    expect(MusicBars.height(isPlaying: true, realLevels: nil) == 12, "decorative bars retain original height")
    expect(MusicBars.height(isPlaying: true, realLevels: []) == 12, "empty measurements retain original height")
    expect(MusicBars.height(isPlaying: false, realLevels: [1]) == 12, "paused bars retain original height")
    expect(MusicBars.height(isPlaying: true, realLevels: [1]) == 15, "only live audio bars are taller")
    let samples = stride(from: 0.0, to: 2.0, by: 1 / 30).map { MusicBars.level(index: 0, time: $0, isPlaying: true, realLevels: nil) }
    expect(Set(samples.map { Int($0 * 100) }).count > 20 && samples.min()! >= 0.35 && samples.max()! <= 1, "keeps moving within 35–100 % without audio access")
    expect((0..<4).allSatisfy { MusicBars.level(index: $0, time: 3, isPlaying: false, realLevels: nil) == 0.25 }, "paused → resting at 25 %")
    expect(MusicBars.level(index: 2, time: 3, isPlaying: false, realLevels: [1, 1, 1, 1, 1]) == 0.25, "paused even with real data")
    // Real levels drive the heights only when present (same range).
    expect(MusicBars.level(index: 0, time: 9, isPlaying: true, realLevels: [0, 0.5, 1, 0.2, 0.9]) == 0.35, "silent band → minimum")
    expect(MusicBars.level(index: 2, time: 9, isPlaying: true, realLevels: [0, 0.5, 1, 0.2, 0.9]) == 1, "loud band → full")
    expect(MusicBars.level(index: 3, time: 9, isPlaying: true, realLevels: [0.5]) == 0.35 + 0.65 * 0.5, "fewer bands than bars clamps index")
    expect(MusicBars.level(index: 1, time: 9, isPlaying: true, realLevels: []) == MusicBars.level(index: 1, time: 9, isPlaying: true, realLevels: nil),
           "empty data → original animation")
    // A default monitor provides no levels, so the default view is the original animation.
    expect(AudioLevelMonitor(defaults: freshDefaults()).levels == nil, "default: decorative animation")
    // Colours: cover gradient top→bottom, original green without artwork.
    let palette = ArtworkPalette(primary: .init(r: 0.9, g: 0.2, b: 0.1), secondary: .init(r: 0.1, g: 0.2, b: 0.6))
    expect(MusicBars.colors(for: palette) == [palette.primary.color, palette.secondary.color], "cover gradient")
    expect(MusicBars.colors(for: nil) == [Color.green.opacity(0.9), Color.green.opacity(0.9)], "original green fallback")
    // Wording never claims the default animation follows the sound.
    let lang = LanguageSettings.shared
    let saved = lang.language; defer { lang.language = saved }
    let markers: [AppLanguage: String] = [.english: "decorative", .traditionalChinese: "裝飾動畫", .simplifiedChinese: "装饰动画"]
    for (l, marker) in markers {
        lang.language = l
        for key in [L10nKey.audioLevelsOff, .audioLevelsSilent, .audioLevelsFailed, .audioLevelsNote] {
            expect(lang.t(key).contains(marker), "\(l) \(key) says it's decorative")
        }
    }
}


// MARK: - Quick actions: clipboard, screenshot, recording, Shazam, onboarding, packaging

/// A private, uniquely named pasteboard: tests never read or write the user's clipboard.
@MainActor func privatePasteboard() -> NSPasteboard { NSPasteboard(name: NSPasteboard.Name("NotchIslandTests.\(UUID().uuidString)")) }
func tempDirectory() -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("ni-clip-\(UUID().uuidString)", isDirectory: true)
    return url
}

await test("clipboard: policy skips concealed/transient/password-manager content") {
    expect(ClipboardPolicy.shouldIgnore(types: ["public.utf8-plain-text", "org.nspasteboard.ConcealedType"], frontmostBundleID: nil), "concealed")
    expect(ClipboardPolicy.shouldIgnore(types: ["org.nspasteboard.TransientType"], frontmostBundleID: nil), "transient")
    expect(ClipboardPolicy.shouldIgnore(types: ["org.nspasteboard.AutoGeneratedType"], frontmostBundleID: nil), "auto-generated")
    expect(ClipboardPolicy.shouldIgnore(types: ["com.agilebits.onepassword"], frontmostBundleID: nil), "1Password type")
    expect(ClipboardPolicy.shouldIgnore(types: [ClipboardPolicy.ownMarkerType], frontmostBundleID: nil), "our own paste")
    for bundle in ["com.apple.Passwords", "com.bitwarden.desktop", "com.1password.1password", "com.apple.keychainaccess"] {
        expect(ClipboardPolicy.shouldIgnore(types: ["public.utf8-plain-text"], frontmostBundleID: bundle), "copy from \(bundle)")
    }
    expect(!ClipboardPolicy.shouldIgnore(types: ["public.utf8-plain-text"], frontmostBundleID: "com.apple.Safari"), "normal copy kept")
}

await test("clipboard: off by default; records text/images/files with limits, de-duplication and owner-only files") {
    let pb = privatePasteboard(); defer { pb.releaseGlobally() }
    let dir = tempDirectory(); defer { try? FileManager.default.removeItem(at: dir) }
    var front: String? = "com.apple.TextEdit"
    let store = ClipboardStore(defaults: freshDefaults(), pasteboard: pb, directory: dir, frontmostBundleID: { front })
    expect(!store.enabled && store.retention == .threeDays, "off by default; 3-day retention")
    pb.clearContents(); pb.setString("before enabling", forType: .string)
    expect(store.checkPasteboard() == nil && store.items.isEmpty, "nothing recorded while off")
    store.setEnabled(true)
    expect(store.checkPasteboard() == nil, "what was already on the clipboard isn't recorded")
    pb.clearContents(); pb.setString("hello", forType: .string)
    expect(store.checkPasteboard()?.text == "hello", "text recorded")
    pb.clearContents(); pb.setString("hello", forType: .string)
    _ = store.checkPasteboard()
    expect(store.items.count == 1, "same text again → moved to top, not duplicated")
    pb.clearContents(); pb.setString("secret", forType: .string); pb.setData(Data(), forType: .init("org.nspasteboard.ConcealedType"))
    expect(store.checkPasteboard() == nil && store.items.count == 1, "concealed skipped")
    front = "com.apple.Passwords"
    pb.clearContents(); pb.setString("pw", forType: .string)
    expect(store.checkPasteboard() == nil, "password manager in front → skipped")
    front = "com.apple.TextEdit"
    pb.clearContents(); pb.setString(String(repeating: "x", count: ClipboardPolicy.maxTextBytes + 1), forType: .string)
    expect(store.checkPasteboard() == nil, "over-size text is not kept (never truncated)")
    // Image
    let image = NSImage(size: NSSize(width: 8, height: 6))
    image.lockFocus(); NSColor.red.setFill(); NSRect(x: 0, y: 0, width: 8, height: 6).fill(); image.unlockFocus()
    pb.clearContents(); pb.writeObjects([image])
    let imageItem = store.checkPasteboard()
    expect(imageItem?.kind == .image && imageItem?.imageFile != nil, "image recorded")
    let file = dir.appendingPathComponent(imageItem?.imageFile ?? "missing")
    let filePerms = (try? FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? Int) ?? -1
    let dirPerms = (try? FileManager.default.attributesOfItem(atPath: dir.path)[.posixPermissions] as? Int) ?? -1
    expect(filePerms == 0o600 && dirPerms == 0o700, "owner-only storage (file \(String(filePerms, radix: 8)), dir \(String(dirPerms, radix: 8)))")
    // Files
    let fileURL = dir.appendingPathComponent("note.txt")
    try "x".write(to: fileURL, atomically: true, encoding: .utf8)
    pb.clearContents(); pb.writeObjects([fileURL as NSURL])
    let filesItem = store.checkPasteboard()
    expect(filesItem?.kind == .files && filesItem?.preview == "note.txt", "file reference recorded")
    // Re-copy is ours → not recorded again
    expect(store.copyToPasteboard(store.items.last!), "copy back")
    expect(store.checkPasteboard() == nil, "our own paste isn't re-recorded")
    // Persistence
    let reloaded = ClipboardStore(defaults: freshDefaults(), pasteboard: pb, directory: dir)
    expect(reloaded.items.map(\.id) == store.items.map(\.id), "history reloads from disk")
    // Max items
    for i in 0..<(ClipboardPolicy.maxItems + 5) { pb.clearContents(); pb.setString("item \(i)", forType: .string); _ = store.checkPasteboard() }
    expect(store.items.count == ClipboardPolicy.maxItems && store.items.first?.text == "item \(ClipboardPolicy.maxItems + 4)", "capped at \(ClipboardPolicy.maxItems)")
    store.clear()
    let leftovers = (try? FileManager.default.contentsOfDirectory(atPath: dir.path).filter { $0.hasSuffix(".png") }) ?? []
    expect(store.items.isEmpty && leftovers.isEmpty, "clear removes items and image files")
}

await test("clipboard: retention deletes old items and their files automatically") {
    let pb = privatePasteboard(); defer { pb.releaseGlobally() }
    let dir = tempDirectory(); defer { try? FileManager.default.removeItem(at: dir) }
    let clock = Clock()
    let defaults = freshDefaults()
    let store = ClipboardStore(defaults: defaults, pasteboard: pb, directory: dir, now: { clock.now }, frontmostBundleID: { nil })
    store.setEnabled(true)
    pb.clearContents(); pb.setString("old", forType: .string); _ = store.checkPasteboard()
    let image = NSImage(size: NSSize(width: 4, height: 4)); image.lockFocus(); NSColor.blue.setFill(); NSRect(x: 0, y: 0, width: 4, height: 4).fill(); image.unlockFocus()
    pb.clearContents(); pb.writeObjects([image]); _ = store.checkPasteboard()
    clock.now += 2 * 86_400
    pb.clearContents(); pb.setString("new", forType: .string); _ = store.checkPasteboard()
    clock.now += 1.5 * 86_400 // old ones are now 3.5 days old
    store.purge()
    let pngs = (try? FileManager.default.contentsOfDirectory(atPath: dir.path).filter { $0.hasSuffix(".png") }) ?? []
    expect(store.items.map { $0.text ?? "img" } == ["new"] && pngs.isEmpty, "3-day default: old text + image (and file) removed")
    store.setRetention(.oneDay)
    expect(store.items.isEmpty, "shorter retention purges immediately")
    expect(ClipboardStore(defaults: defaults, pasteboard: pb, directory: dir).retention == .oneDay, "retention persisted")
    expect(ClipboardRetention.allCases.map(\.rawValue) == [1, 3, 7, 30], "choices")
}

await test("clipboard: paste plan never claims success without a target or permission; ⌘V event shape") {
    expect(ClipboardPaste.plan(copied: false, hasTarget: true, targetIsSelf: false, targetTerminated: false, canPostEvents: true) == .failed, "copy failed")
    expect(ClipboardPaste.plan(copied: true, hasTarget: false, targetIsSelf: false, targetTerminated: false, canPostEvents: true) == .copiedOnly(.noTarget), "no target")
    expect(ClipboardPaste.plan(copied: true, hasTarget: true, targetIsSelf: true, targetTerminated: false, canPostEvents: true) == .copiedOnly(.noTarget), "never paste into ourselves")
    expect(ClipboardPaste.plan(copied: true, hasTarget: true, targetIsSelf: false, targetTerminated: true, canPostEvents: true) == .copiedOnly(.noTarget), "target quit")
    expect(ClipboardPaste.plan(copied: true, hasTarget: true, targetIsSelf: false, targetTerminated: false, canPostEvents: false) == .copiedOnly(.needsPermission), "no permission → copy only")
    expect(ClipboardPaste.plan(copied: true, hasTarget: true, targetIsSelf: false, targetTerminated: false, canPostEvents: true) == nil, "go ahead")
    let events = ClipboardPaste.commandVEvents() // built, never posted
    expect(events.count == 2 && events.allSatisfy { $0.flags.contains(.maskCommand) && $0.getIntegerValueField(.keyboardEventKeycode) == 9 }, "⌘V down/up")
}

await test("screencapture diagnostics: classified from the tool's literal messages, cancel is never a permission error") {
    func c(_ status: Int32, _ text: String, _ reason: Process.TerminationReason = .exit) -> CaptureTool.Exit {
        CaptureTool.classify(status: status, reason: reason, diagnostic: text)
    }
    expect(c(0, "") == .finished && c(1, "") == .finished, "quiet exit (image or Esc) → caller checks the result")
    expect(c(1, "No selection to capture. Cancelling\n") == .cancelled, "tool's own cancel message")
    expect(c(0, "canceled") == .cancelled, "canceled")
    expect(c(1, "screencapture: cannot run two interactive screen captures at a time") == .busy, "two captures")
    expect(c(1, "Screen Recording is already running") == .busy, "recording already running")
    expect(c(1, "screencapture not allowed") == .refused && c(1, "Screenshots are not allowed.") == .refused, "explicit refusals")
    for what in ["rect", "display", "window"] {
        expect(c(1, "could not create image from \(what)") == .noImage, "unreadable screen (\(what))")
    }
    expect(c(1, "some other diagnostic") == .failed(1), "unknown text is not guessed")
    expect(c(2, "") == .failed(2), "unexpected status")
    expect(c(15, "", .uncaughtSignal) == .failed(15), "killed")

    let adHoc = CodeIdentity(kind: .adHoc, cdhash: "ab", designatedRequirement: "cdhash H\"ab\"")
    let devID = CodeIdentity(kind: .developerID, designatedRequirement: "identifier \"local.notchisland.app\" and anchor apple generic")
    func shot(_ exit: CaptureTool.Exit, changed: Bool, image: Bool, allowed: Bool, _ identity: CodeIdentity = adHoc) -> ScreenshotAction.Outcome {
        ScreenshotAction.classify(exit, changeCountBefore: 5, changeCountAfter: changed ? 6 : 5, clipboardHasImage: image,
                                  screenCaptureAllowed: allowed, identity: identity)
    }
    expect(ScreenshotAction.arguments == ["-i", "-J", "selection", "-c"], "interactive selection to the clipboard")
    expect(shot(.finished, changed: true, image: true, allowed: true) == .copied, "new image → copied")
    expect(shot(.finished, changed: true, image: true, allowed: false) == .copied, "a real image wins even if the preflight says no")
    expect(shot(.finished, changed: false, image: true, allowed: true) == .cancelled, "old image on the clipboard ≠ success")
    expect(shot(.finished, changed: true, image: false, allowed: true) == .cancelled, "something else copied ≠ screenshot")
    expect(shot(.finished, changed: false, image: false, allowed: false) == .cancelled, "Esc without a grant is still a cancel, not a permission error")
    expect(shot(.cancelled, changed: false, image: false, allowed: false) == .cancelled, "tool cancel without a grant is a cancel")
    expect(shot(.refused, changed: false, image: false, allowed: false) == .refused(.grantProbablyForAnotherBuild), "refused + no grant + ad-hoc → stale-build explanation")
    expect(shot(.refused, changed: false, image: false, allowed: false, devID) == .refused(.notGranted), "stable signature → plain 'not granted'")
    expect(shot(.noImage, changed: false, image: false, allowed: true) == .noImage(.grantedButFailed), "granted but failed → unknown cause")
    expect(shot(.failed(3), changed: false, image: false, allowed: false) == .failed(3), "unknown failure never becomes a permission claim")
    expect(shot(.busy, changed: false, image: false, allowed: true) == .busy, "busy")
}

await test("code identity: ad-hoc builds pin privacy grants to the exact build") {
    expect(CodeIdentity.kind(flags: 0x2, leafSummary: nil) == .adHoc, "ad-hoc flag")
    expect(CodeIdentity.kind(flags: 0x10000, leafSummary: "Developer ID Application: Example (TEAMID1234)") == .developerID, "Developer ID")
    expect(CodeIdentity.kind(flags: 0, leafSummary: "Apple Development: someone@example.com (ABCDE12345)") == .appleDevelopment, "Apple Development")
    expect(CodeIdentity.kind(flags: 0, leafSummary: "Local Signing") == .otherCertificate, "self-made certificate")
    expect(CodeIdentity.kind(flags: nil, leafSummary: nil) == .unsigned, "unsigned")
    expect(CodeIdentity(kind: .adHoc).grantsPinnedToBuild, "ad-hoc → pinned")
    expect(CodeIdentity(kind: .otherCertificate, designatedRequirement: "cdhash H\"00\"").grantsPinnedToBuild, "cdhash requirement → pinned")
    expect(!CodeIdentity(kind: .developerID, designatedRequirement: "identifier \"x\" and anchor apple generic").grantsPinnedToBuild, "Developer ID survives rebuilds")
    expect(CaptureAdvice.from(screenCaptureAllowed: true, identity: CodeIdentity(kind: .adHoc)) == .grantedButFailed, "granted wins")
    let current = CodeIdentity.current() // test runner itself (linker-signed ad-hoc on Apple silicon)
    expect(current.kind != .unknown, "reads this process's own signature without prompting (\(current.kind))")
}

await test("screen recording: direct video toolbar only with a grant; honest QuickTime/Screenshot fallbacks") {
    expect(ScreenRecordingAction.route(screenCaptureAllowed: true) == .captureToolbar, "grant → toolbar in video mode")
    expect(ScreenRecordingAction.route(screenCaptureAllowed: false) == .askForFallback, "no grant → explain, never a silent desktop-only recording")
    let args = ScreenRecordingAction.recordingArguments
    expect(args == ["-i", "-U", "-J", "video", "-p"], "interactive toolbar, starting style video")
    expect(!args.contains("-v") && !args.contains("-V") && !args.contains("-g"), "never starts recording or audio by itself")
    expect(ScreenRecordingAction.quickTimeScript.contains("new screen recording") && ScreenRecordingAction.quickTimeScript.contains("com.apple.QuickTimePlayerX"),
           "QuickTime opens its recording toolbar (does not start recording)")
    expect(ScreenRecordingAction.classifyQuickTime(status: 0, diagnostic: "") == .requested, "delivered")
    expect(ScreenRecordingAction.classifyQuickTime(status: 1, diagnostic: "execution error: Not authorized to send Apple events to QuickTime Player. (-1743)") == .automationDenied, "-1743")
    expect(ScreenRecordingAction.classifyQuickTime(status: 1, diagnostic: "execution error: something (-1712)") == .failed, "timeout is not a denial")
    expect(Bundle(url: ScreenRecordingAction.screenshotApp)?.bundleIdentifier == "com.apple.screenshot.launcher", "native Screenshot utility")
    expect(ScreenRecordingAction.screenRecordingSettings.absoluteString.hasSuffix("Privacy_ScreenCapture"), "settings deep link")
    let lang = LanguageSettings.shared
    let saved = lang.language; defer { lang.language = saved }
    for language in [AppLanguage.english, .traditionalChinese, .simplifiedChinese] {
        lang.language = language
        let stale = lang.t(.captureAdviceStaleGrant), help = lang.t(.recordFallbackHelp), failed = lang.t(.captureToolFailed, "7")
        expect(stale.contains("ad-hoc") && ["Likely", "可能"].contains(where: stale.contains), "\(language) stale-grant text names the cause as likely, not certain")
        expect(["QuickTime"].allSatisfy(help.contains) && ["⇧⌘5"].allSatisfy(help.contains), "\(language) fallback names QuickTime and ⇧⌘5")
        expect(["Record Entire Screen", "錄製整個螢幕", "录制整个屏幕"].contains(where: help.contains), "\(language) says which Screenshot button switches to video")
        expect(failed.contains("7") && !failed.contains("%@"), "\(language) unknown failure shows the status")
        expect(["Nothing records", "不會開始錄影", "不会开始录制"].contains(where: lang.t(.recordToolbarHelp).contains), "\(language) toolbar help says nothing records yet")
    }
}

await test("Control Center Recognize Music: acts only on identified controls, confirms listening") {
    typealias N = ControlCenterMedia.Node<String>
    func step(_ windows: [N]) -> String {
        switch ControlCenterMedia.musicStep(in: windows, labels: .builtIn) {
        case .listening: return "listening"
        case .pressStart(let e): return "start:\(e)"
        case .pressModule(let e): return "module:\(e)"
        case .panelOpen: return "panel"
        case .nothing: return "nothing"
        }
    }
    let module = N(element: "module", names: ["controlcenter-musicrecognition", "Recognize Music"], pressable: true)
    let other = N(element: "wifi", names: ["controlcenter-wifi"], pressable: true)
    expect(step([N(element: "cc", names: [], pressable: false, children: [other, module])]) == "module:module", "presses the identified module")
    expect(step([N(element: "cc", names: [], pressable: false, children: [module, module])]) == "nothing", "two candidates → press nothing")
    expect(step([N(element: "cc", names: [], pressable: false, children: [other])]) == "nothing", "module missing → nothing")
    func panel(_ children: [N]) -> N {
        N(element: "panel", names: [], pressable: false, children: [N(element: "hdr", names: ["musicrecognition-header"], pressable: false)] + children)
    }
    for label in ["Start Listening", "開始聆聽", "开始听取"] {
        expect(step([panel([N(element: "go", names: [label], pressable: true)])]) == "start:go", "presses \(label)")
    }
    expect(step([panel([N(element: "go", names: ["Start Listening"], pressable: false)])]) == "panel", "disabled button → wait, don't press")
    expect(step([panel([N(element: "a", names: ["Start Listening"], pressable: true), N(element: "b", names: ["Start Listening"], pressable: true)])]) == "panel",
           "two start buttons → don't guess")
    expect(step([N(element: "elsewhere", names: [], pressable: false, children: [N(element: "x", names: ["Start Listening"], pressable: true)])]) == "nothing",
           "a Start Listening outside the Recognize Music panel is ignored")
    for text in ["Listening…", "Listening...", "聆聽中⋯", "正在听取…"] {
        let header = N(element: "header", names: ["musicrecognition-header"], pressable: false, value: text)
        expect(step([header]) == "listening", "confirms \(text) in the recognition header")
    }
    let sameNamedSong = N(element: "song", names: ["Listening…"], pressable: false)
    expect(step([sameNamedSong]) == "nothing", "unrelated text never confirms listening")
    expect(step([panel([sameNamedSong])]) == "panel", "song named Listening… does not confirm listening")
    let history = N(element: "history", names: ["musicrecognition-history"], pressable: false,
                    children: [N(element: "song", names: ["Start Listening"], pressable: true)])
    expect(step([panel([history])]) == "panel", "a history item never counts as a start control")
    expect(step([panel([]), panel([])]) == "panel", "ambiguous panels never confirm or start recognition")
}

await test("shazam: 30 s limit, cancel, honest errors, mono buffers") {
    expect(ShazamRecognizer.timeout == 30, "30 seconds")
    expect(ShazamRecognizer.outcomeAtTimeout(lastError: nil) == .noMatch, "no error → no match")
    expect(ShazamRecognizer.outcomeAtTimeout(lastError: .network) == .failed(.network), "error is not shown as 'no match'")
    expect(ShazamRecognizer.failure(for: URLError(.notConnectedToInternet)) == .network, "offline")
    expect(ShazamRecognizer.failure(for: NSError(domain: SHErrorDomain, code: SHError.Code.audioDiscontinuity.rawValue)) == nil, "discontinuity ignored")
    expect(ShazamRecognizer.failure(for: NSError(domain: SHErrorDomain, code: SHError.Code.matchAttemptFailed.rawValue)) == .service(202), "match attempt failed")
    let wrapped = NSError(domain: SHErrorDomain, code: 202, userInfo: [NSUnderlyingErrorKey: URLError(.timedOut) as NSError])
    expect(ShazamRecognizer.failure(for: wrapped) == .network, "network underneath")
    for code in [SHError.Code.signatureInvalid, .signatureDurationInvalid] {
        expect(ShazamRecognizer.failure(for: NSError(domain: SHErrorDomain, code: code.rawValue)) == nil, "silence / short signature \(code.rawValue) keeps listening (not an error)")
    }
    // SHSession.h: catalog-communication errors may be retried → keep listening, report at the limit.
    expect(!ShazamRecognizer.stopsImmediately(.service(202)) && !ShazamRecognizer.stopsImmediately(.network), "202 and network keep retrying")
    expect(!ShazamRecognizer.stopsImmediately(.service(500)) && !ShazamRecognizer.stopsImmediately(.service(600)), "internal / fetch errors retry")
    expect(ShazamRecognizer.stopsImmediately(.service(100)) && ShazamRecognizer.stopsImmediately(.service(300)) && ShazamRecognizer.stopsImmediately(.service(9999)), "format / catalog / unknown errors stop at once")
    expect(ShazamRecognizer.outcomeAtTimeout(lastError: .service(202)) == .failed(.service(202)), "202 seen while listening → error at the limit, not 'no match'")
    expect(ShazamRecognizer.recognizeMusicGuideURL(.traditionalChinese).absoluteString == "https://support.apple.com/zh-tw/118570"
           && ShazamRecognizer.recognizeMusicGuideURL(.simplifiedChinese).absoluteString == "https://support.apple.com/zh-cn/118570"
           && ShazamRecognizer.recognizeMusicGuideURL(.english).absoluteString == "https://support.apple.com/en-us/118570", "Apple's official guide per language")
    expect(ShazamRecognizer.recognizeMusicGuideURL(.system).host == "support.apple.com", "system language resolves to an Apple URL")
    let lang = LanguageSettings.shared
    let savedLanguage = lang.language; defer { lang.language = savedLanguage }
    for language in [AppLanguage.english, .traditionalChinese, .simplifiedChinese] {
        lang.language = language
        let catalog = lang.t(.shazamCatalogFailed), fallback = lang.t(.shazamSystemFallback)
        expect(catalog.contains("202") && !catalog.contains("?"), "\(language) 202 text names the code")
        // Never claims a definite cause: offers both possibilities.
        expect(["may", "可能"].contains(where: catalog.contains), "\(language) 202 text is not a definite diagnosis")
        expect(["Control Center", "控制中心"].contains(where: fallback.contains), "\(language) fallback names Control Center")
        expect(["Look there for the result", "結果會顯示在控制中心", "结果会显示在控制中心"].contains(where: fallback.contains),
               "\(language) fallback says where the result appears")
        expect(lang.t(.shazamService, "500").contains("500"), "\(language) generic error shows its code")
    }
    let buffer = ShazamRecognizer.monoBuffer([0.1, -0.2, 0.3], sampleRate: 48_000)
    expect(buffer?.format.channelCount == 1 && buffer?.format.sampleRate == 48_000 && buffer?.frameLength == 3
           && abs((buffer?.floatChannelData?[0][1] ?? 0) + 0.2) < 1e-6, "mono float buffer")
    expect(ShazamRecognizer.monoBuffer([], sampleRate: 48_000) == nil, "empty → nil")
    let recognizer = ShazamRecognizer()
    expect(recognizer.phase == .idle && !recognizer.isListening, "idle until the user presses Shazam (nothing captured at launch)")
    recognizer.cancel()
    expect(recognizer.phase == .idle, "cancel when idle does nothing")
}

final class MockAudD: URLProtocol {
    static let lock = NSLock()
    static var bodies: [Data] = []
    static var requests: [URLRequest] = []
    static var reply: (status: Int, body: Data)? = (200, Data())
    static func reset(_ status: Int = 200, _ json: String = "{}") { lock.withLock { bodies = []; requests = []; reply = (status, Data(json.utf8)) } }
    static var count: Int { lock.withLock { requests.count } }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        var body = request.httpBody ?? Data()
        if body.isEmpty, let stream = request.httpBodyStream {
            stream.open(); defer { stream.close() }
            var buffer = [UInt8](repeating: 0, count: 65_536)
            while stream.hasBytesAvailable { let n = stream.read(&buffer, maxLength: buffer.count); if n <= 0 { break }; body.append(buffer, count: n) }
        }
        let reply = Self.lock.withLock { () -> (Int, Data)? in Self.requests.append(request); Self.bodies.append(body); return Self.reply }
        guard let (status, data) = reply else { client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet)); return }
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!,
                            cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@MainActor final class SyntheticAudio: AudDAudioSource {
    var samples: [Float]; var rate: Double; var ok = true
    var begun: [ShazamRecognizer.Source] = []; var ended = 0; var lastClip: AudDClip?
    init(seconds: Double = 12, rate: Double = 16_000, amplitude: Float = 0.3) {
        self.rate = rate
        samples = (0..<Int(seconds * rate)).map { amplitude * sin(2 * .pi * 440 * Float($0) / Float(rate)) }
    }
    func begin(_ source: ShazamRecognizer.Source, into clip: AudDClip) -> Bool {
        begun.append(source); lastClip = clip
        if ok { clip.append(samples, rate: rate) }
        return ok
    }
    func end() { ended += 1 }
}

@MainActor func settle(_ r: AudDRecognition, timeout: Double = 3) async {
    let deadline = Date().addingTimeInterval(timeout)
    while (r.phase.busy || r.phase == .idle) && Date() < deadline { try? await Task.sleep(for: .milliseconds(10)) }
}

await test("AudD protocol: WAV/multipart shape, documented error codes, silence never uploaded") {
    let tone = (0..<48_000).map { 0.5 * sin(Float($0) * 0.05) }
    let wav = AudDService.wave(samples: tone, rate: 16_000)
    expect(wav?.count == 44 + 48_000 * 2 && wav.map { String(decoding: $0.prefix(4), as: UTF8.self) } == "RIFF", "16-bit mono WAV")
    expect(wav.map { String(decoding: $0[8..<16], as: UTF8.self) } == "WAVEfmt ", "WAVE header")
    expect(AudDService.wave(samples: [Float](repeating: 0, count: 48_000), rate: 16_000) == nil, "silence → nothing to upload")
    expect(AudDService.wave(samples: Array(tone.prefix(16_000)), rate: 16_000) == nil, "under 3 s → nothing to upload")
    expect(AudDService.wave(samples: [Float](repeating: 0.2, count: 11 * 16_000), rate: 16_000) == nil, "over 10 s is refused")
    let fakeToken = ["TEST", "PLACEHOLDER"].joined(separator: "-") // fake, built at runtime
    let request = AudDService.makeRequest(wav: wav!, token: fakeToken, boundary: "B")
    let body = String(decoding: request.httpBody ?? Data(), as: UTF8.self)
    expect(request.url == URL(string: "https://api.audd.io/") && request.httpMethod == "POST", "POST to the documented HTTPS endpoint")
    expect(request.value(forHTTPHeaderField: "Content-Type") == "multipart/form-data; boundary=B", "multipart")
    expect(body.contains("name=\"api_token\"\r\n\r\n\(fakeToken)\r\n") && body.contains("name=\"file\"; filename=\"clip.wav\""), "token + file fields")
    expect(request.url?.query == nil, "token never in the URL")
    func p(_ json: String, _ status: Int = 200) -> AudDService.Outcome { AudDService.parse(data: Data(json.utf8), httpStatus: status) }
    expect(p(#"{"status":"success","result":{"artist":"A","title":"T","song_link":"https://lis.tn/x"}}"#) == .matched(.init(title: "T", artist: "A", songLink: "https://lis.tn/x")), "match")
    expect(p(#"{"status":"success","result":null}"#) == .noMatch, "no match")
    expect(p(#"{"status":"success","result":{"artist":" ","title":""}}"#) == .badResponse(200), "empty song is not shown as a match")
    expect(p(#"{"status":"error","error":{"error_code":900,"error_message":"x"}}"#) == .invalidToken, "900")
    expect(p(#"{"status":"error","error":{"error_code":901}}"#) == .limitReached(901) && p(#"{"status":"error","error":{"error_code":902}}"#) == .limitReached(902), "901/902 limit")
    expect(p(#"{"status":"error","error":{"error_code":300}}"#) == .serviceError(300), "other code shown")
    expect(p("<html>Bad gateway</html>", 502) == .badResponse(502), "non-JSON")
    expect(AudDService.validToken("  abc123  ") == "abc123" && AudDService.validToken("a b") == nil && AudDService.validToken("") == nil, "token validation")
    let clip = AudDClip(limitSeconds: 2)
    clip.append([Float](repeating: 0.1, count: 50_000), rate: 16_000)
    clip.append([Float](repeating: 0.1, count: 100), rate: 44_100)
    expect(clip.sampleCount == 32_000, "clip capped at its limit; a second rate is rejected")
    clip.discard()
    expect(clip.sampleCount == 0 && clip.isClosed, "discard wipes and closes")
    clip.append([0.5], rate: 16_000)
    expect(clip.sampleCount == 0, "late buffers rejected after discard")
}

await test("AudD flow: consent and token first, user-picked source, one mocked upload, cancel discards (no real network)") {
    let session = AudDService.makeSession(protocolClasses: [MockAudD.self])
    let d = freshDefaults()
    let store = MemorySecretStore()
    let audio = SyntheticAudio()
    var micAsked = 0
    let r = AudDRecognition(secrets: store, defaults: d, session: session, audio: audio, listenDuration: .milliseconds(30),
                            microphoneAccess: { await MainActor.run { micAsked += 1 }; return false })
    MockAudD.reset()
    r.start(source: .systemAudio)
    expect(r.phase == .notSelected && audio.begun.isEmpty && MockAudD.count == 0, "macOS is the default method → AudD refuses before anything")
    expect(r.saveSetup(consent: true, token: "") && r.consented, "consent alone does not select AudD")
    r.start(source: .systemAudio)
    expect(r.phase == .notSelected && audio.begun.isEmpty && MockAudD.count == 0, "consent without choosing AudD still captures nothing")
    r.revokeConsent()
    d.set("unknown", forKey: MusicRecognitionMode.defaultsKey)
    r.start(source: .systemAudio)
    expect(r.phase == .notSelected, "an unknown stored mode never selects AudD")
    d.set(MusicRecognitionMode.audd.rawValue, forKey: MusicRecognitionMode.defaultsKey)
    r.start(source: .systemAudio)
    expect(r.phase == .needsConsent && audio.begun.isEmpty && MockAudD.count == 0, "no consent → no audio, no upload")
    expect(r.saveSetup(consent: true, token: "") && r.consented, "consent saved")
    r.start(source: .systemAudio); await settle(r)
    expect(r.phase == .needsToken && audio.begun.isEmpty && MockAudD.count == 0, "no token → no audio, no upload")
    expect(!r.saveSetup(consent: true, token: "has space") && store.value == nil, "malformed token not stored")
    let placeholder = ["SYNTH", "PLACEHOLDER"].joined(separator: "-") // fake, built at runtime
    expect(r.saveSetup(consent: true, token: " \(placeholder) ") && store.value == placeholder && r.hasToken, "token stored (trimmed) in the secret store")

    r.start(source: .microphone); await settle(r)
    expect(r.phase == .permissionDenied && micAsked == 1 && audio.begun.isEmpty && MockAudD.count == 0, "mic refused → nothing captured or sent")

    MockAudD.reset(200, #"{"status":"success","result":{"artist":"Synthetic Artist","title":"Test Tone","song_link":"https://lis.tn/test"}}"#)
    r.start(source: .systemAudio); await settle(r)
    expect(r.phase == .finished(.matched(.init(title: "Test Tone", artist: "Synthetic Artist", songLink: "https://lis.tn/test"))), "mocked match shown")
    expect(audio.begun == [.systemAudio] && audio.ended >= 1, "only the chosen source, stopped afterwards")
    let body = MockAudD.lock.withLock { MockAudD.bodies.first } ?? Data()
    expect(MockAudD.count == 1 && MockAudD.lock.withLock { MockAudD.requests.first?.url?.host } == "api.audd.io", "exactly one request to AudD")
    expect(body.count <= 44 + 10 * 16_000 * 2 + 600 && body.count > 44 + 3 * 16_000 * 2, "at most 10 s uploaded (12 s offered)")
    expect(String(decoding: body, as: UTF8.self).contains(placeholder), "token in the body")
    expect(r.heldClip == nil && audio.lastClip?.sampleCount == 0 && audio.lastClip?.isClosed == true, "clip dropped after sending")

    MockAudD.reset(200, #"{"status":"error","error":{"error_code":902}}"#)
    r.start(source: .systemAudio); await settle(r)
    expect(r.phase == .finished(.limitReached(902)), "quota error reported, not 'no match'")

    MockAudD.lock.withLock { MockAudD.reply = nil; MockAudD.requests = [] }
    r.start(source: .systemAudio); await settle(r)
    expect(r.phase == .network, "offline → network error, no fake result")

    let silent = SyntheticAudio(amplitude: 0)
    let quiet = AudDRecognition(secrets: store, defaults: d, session: session, audio: silent, listenDuration: .milliseconds(20))
    MockAudD.reset()
    quiet.start(source: .systemAudio); await settle(quiet)
    expect(quiet.phase == .noAudio && MockAudD.count == 0, "silence is never uploaded")

    let unavailable = SyntheticAudio()
    unavailable.ok = false
    let blocked = AudDRecognition(secrets: store, defaults: d, session: session, audio: unavailable)
    blocked.start(source: .systemAudio); await settle(blocked)
    expect(blocked.phase == .sourceUnavailable(.systemAudio) && MockAudD.count == 0,
           "failed source setup is distinct from silence and sends no clip")

    let slow = AudDRecognition(secrets: store, defaults: d, session: session, audio: audio, listenDuration: .seconds(5))
    MockAudD.reset()
    slow.start(source: .systemAudio)
    let deadline = Date().addingTimeInterval(2)
    while slow.phase != .listening && Date() < deadline { try await Task.sleep(for: .milliseconds(5)) }
    expect(slow.phase == .listening && slow.heldClip != nil, "listening holds a clip in memory")
    let held = slow.heldClip
    slow.revokeConsent()
    try await Task.sleep(for: .milliseconds(150))
    expect(!slow.consented && slow.phase == .cancelled && slow.heldClip == nil && held?.sampleCount == 0 && held?.isClosed == true, "revoking consent cancels capture and discards the clip")
    expect(MockAudD.count == 0, "cancel before sending → nothing uploaded")

    expect(r.removeToken() && store.value == nil && !r.hasToken, "token removed")
    r.revokeConsent()
    expect(!r.saveSetup(consent: true, token: "has space") && !r.consented, "rejected setup does not grant new consent")
    r.start(source: .systemAudio)
    expect(r.phase == .needsConsent, "revoked consent blocks again")
    d.set(MusicRecognitionMode.system.rawValue, forKey: MusicRecognitionMode.defaultsKey)
    r.saveSetup(consent: true, token: "")
    r.start(source: .systemAudio)
    expect(r.phase == .notSelected, "switching back to macOS blocks AudD even with consent")
    let lang = LanguageSettings.shared
    let saved = lang.language; defer { lang.language = saved }
    for language in [AppLanguage.english, .traditionalChinese, .simplifiedChinese] {
        lang.language = language
        let text = lang.t(.audDDisclosure)
        for fact in ["api.audd.io", "10", "300", "14"] { expect(text.contains(fact), "\(language) disclosure states \(fact)") }
        expect(["Keychain", "鑰匙圈", "钥匙串"].contains(where: text.contains), "\(language) disclosure says where the token lives")
        expect(["third-party", "第三方"].contains(where: text.contains), "\(language) disclosure says third party")
        expect(["US$5", "5 美元"].contains(where: text.contains), "\(language) disclosure states the paid price after the trial")
        expect(lang.t(.audDLimit, "902").contains("902"), "\(language) limit shows the code")
    }
}

final class LockedSecretStore: SecretStore, @unchecked Sendable {
    func read() -> String? { nil }
    func readKey() -> Result<String, ProviderError> { .failure(.keychainUnavailable) }
    func write(_ value: String) -> Bool { false }
    func delete() -> Bool { false }
}

await test("AudD: an unreadable Keychain item is reported as such, never as 'no token' and never uploads") {
    let d = freshDefaults()
    let audio = SyntheticAudio()
    d.set(MusicRecognitionMode.audd.rawValue, forKey: MusicRecognitionMode.defaultsKey)
    let r = AudDRecognition(secrets: LockedSecretStore(), defaults: d, session: AudDService.makeSession(protocolClasses: [MockAudD.self]),
                            audio: audio, listenDuration: .milliseconds(10))
    await r.refreshTokenState()
    expect(r.tokenState == .unavailable, "unreadable token status is explicit")
    expect(!r.removeToken() && r.tokenState == .unavailable, "a refused deletion is not reported as success")
    r.saveSetup(consent: true, token: "")
    MockAudD.reset()
    r.start(source: .systemAudio); await settle(r)
    expect(r.phase == .keychain && audio.begun.isEmpty && MockAudD.count == 0, "Keychain error shown; no audio, no upload")
}

await test("island: quick actions row, subpages reset on open, toast is a temporary indicator") {
    expect(IslandViewModel.widgetsContentHeight >= 188 + IslandViewModel.quickActionsHeight - 2, "room for the quick-action row")
    let d = freshDefaults()
    let model = IslandViewModel(geometry: NotchGeometry(screenFrame: NSRect(x: 0, y: 0, width: 1512, height: 982), hasNotch: true,
                                                        notchRect: NSRect(x: 662, y: 950, width: 185, height: 32)),
                                timer: CountdownTimer(defaults: d), music: MusicController(defaults: d), stopwatch: Stopwatch(defaults: d))
    model.subpage = .clipboard
    model.setExpanded(true)
    expect(model.subpage == .none && model.page == .widgets, "opening the island starts on the widgets")
    model.startSystemRecognition(feedbackDuration: .zero, run: { .menuBarNotExposed })
    while model.checkingSystemRecognition { await Task.yield() }
    expect(model.subpage == .shazam(.menuBarNotExposed), "AX failure opens the matching guidance")
    model.subpage = .none
    model.startSystemRecognition(feedbackDuration: .zero, run: { .listening })
    while model.checkingSystemRecognition { await Task.yield() }
    expect(model.subpage == .none, "confirmed listening leaves the system UI in control")
    model.setExpanded(false)
    model.showToast(.init(symbol: "checkmark", text: "OK", style: .success), duration: 0.1)
    expect(model.mode == .compact && model.toast != nil, "toast shows in the notch")
    try await Task.sleep(for: .milliseconds(250))
    expect(model.toast == nil && model.mode == .idle, "and disappears")
}

await test("onboarding: shown once, never resets existing settings") {
    let d = freshDefaults()
    d.set("zh-Hant", forKey: "NotchIsland.language")
    d.set(["battery", "weather"], forKey: "NotchIsland.widgets.enabled")
    expect(OnboardingState.shouldShow(d), "existing user sees the guide once")
    let before = d.dictionaryRepresentation().filter { $0.key.hasPrefix("NotchIsland.") }
    OnboardingState.markCompleted(d)
    let after = d.dictionaryRepresentation().filter { $0.key.hasPrefix("NotchIsland.") && $0.key != OnboardingState.key }
    expect(NSDictionary(dictionary: before).isEqual(to: after), "no existing setting changed")
    expect(!OnboardingState.shouldShow(d), "not shown again")
}

// MARK: - 0.1.1

await test("time 0.1.1: rapid skips, stale sources coming back, same length, flicker, late reads, ads") {
    typealias S = BrowserMedia.TimeSample
    let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    func at(_ s: Double) -> Date { t0.addingTimeInterval(s) }
    func both(_ p: Double, _ d: Double) -> BrowserMedia.TimeSamples { .init(ui: S(position: p, duration: d), player: S(position: p + 0.2, duration: d), element: nil) }
    func only(_ p: Double, _ d: Double) -> BrowserMedia.TimeSamples { .init(ui: nil, player: S(position: p, duration: d), element: S(position: p, duration: d)) }

    // A → B → C quickly; B is never shown. The page's player/element still run A's timeline
    // under C's ID. The old resolver forgot A at the second change and stacked A's time on C.
    var rapid = BrowserMedia.TimeResolver()
    _ = rapid.resolve(item: "A", samples: only(150, 240), isPlaying: true, at: at(0))
    expect(rapid.resolve(item: "B", samples: .init(ui: S(position: 151, duration: 240), player: S(position: 1, duration: 200), element: nil), isPlaying: true, at: at(1)) == nil, "B: sources disagree → hidden")
    var leaked: [Double] = []
    for k in 0..<8 {
        if let r = rapid.resolve(item: "C", samples: only(152 + Double(k), 240), isPlaying: true, at: at(2 + Double(k))) { leaked.append(r.0.position) }
    }
    expect(leaked.isEmpty, "C never shows A's continuing time after two quick skips: \(leaked)")
    expect(rapid.rememberedItems.contains("A"), "A's timeline is still remembered")
    expect(rapid.resolve(item: "C", samples: only(2, 190), isPlaying: true, at: at(11))?.0.position == 2, "C's own time appears once the page catches up")

    // Stale source comes back after the new song was already shown (old code dropped A then).
    var back = BrowserMedia.TimeResolver()
    _ = back.resolve(item: "A", samples: only(100, 200), isPlaying: true, at: at(0))
    expect(back.resolve(item: "B", samples: only(1, 180), isPlaying: true, at: at(2))?.0.position == 1, "B shown")
    expect(back.resolve(item: "B", samples: only(104, 200), isPlaying: true, at: at(4)) == nil, "A's timeline reappearing under B is hidden, not stacked")
    expect(back.resolve(item: "B", samples: only(3, 180), isPlaying: true, at: at(4.5))?.0.position == 3, "B's own time right after")

    // Same-length songs: the player bar keeps A's time (same duration) for a moment.
    var same = BrowserMedia.TimeResolver()
    _ = same.resolve(item: "A", samples: both(190, 200), isPlaying: true, at: at(0))
    let stale1 = same.resolve(item: "B", samples: .init(ui: S(position: 191, duration: 200), player: S(position: 191.2, duration: 200), element: nil), isPlaying: true, at: at(1))
    let stale2 = same.resolve(item: "B", samples: .init(ui: S(position: 192, duration: 200), player: S(position: 192.2, duration: 200), element: nil), isPlaying: true, at: at(2))
    expect(stale1 == nil && stale2 == nil, "same length, old position continuing → hidden")
    expect(same.resolve(item: "B", samples: both(1, 200), isPlaying: true, at: at(3))?.0.position == 1.2, "same-length new song from 0:01 shown")

    // Skip only 4 s in: a stale bar with the same length used to pass as a fresh start (≤ 6 s slack).
    var early = BrowserMedia.TimeResolver()
    _ = early.resolve(item: "A", samples: both(4, 210), isPlaying: true, at: at(0))
    expect(early.resolve(item: "B", samples: both(5, 210), isPlaying: true, at: at(1)) == nil, "exact old signature, even near the start → hidden")
    expect(early.resolve(item: "B", samples: both(0.5, 210), isPlaying: true, at: at(1.6))?.0.position == 0.7, "real start of B shown")

    // No title / missing metadata: identity flickers A → A′ → A. A's own time is restored at once.
    var flicker = BrowserMedia.TimeResolver()
    _ = flicker.resolve(item: "Song|Artist|", samples: both(60, 240), isPlaying: true, at: at(0))
    expect(flicker.resolve(item: "Song||", samples: both(61, 240), isPlaying: true, at: at(1)) == nil, "while metadata is missing the old line is not trusted")
    let restored = flicker.resolve(item: "Song|Artist|", samples: .init(ui: S(position: 62, duration: 240), player: nil, element: nil), isPlaying: true, at: at(2))
    expect(restored?.0.position == 62, "back to the same item: its own timeline continues immediately (single source, no wait): \(String(describing: restored))")

    // A read that started earlier but returned later is ignored.
    var late = BrowserMedia.TimeResolver()
    _ = late.resolve(item: "A", samples: both(10, 200), isPlaying: true, at: at(10))
    expect(late.resolve(item: "B", samples: both(1, 180), isPlaying: true, at: at(9)) == nil, "older sample (previous song's scan) dropped")
    expect(late.resolve(item: "A", samples: both(11, 200), isPlaying: true, at: at(11))?.0.position == 11.2, "late sample changed nothing")

    // Ad between songs: nothing during the ad, the ad's own clock never becomes the song's.
    var ad = BrowserMedia.TimeResolver()
    _ = ad.resolve(item: "A", samples: both(230, 235), isPlaying: true, at: at(0))
    for k in 0..<5 {
        expect(ad.resolve(item: "B", samples: .init(ui: S(position: Double(k), duration: 15), player: S(position: Double(k), duration: 15), element: nil, blocked: true), isPlaying: true, at: at(2 + Double(k))) == nil, "ad \(k): hidden")
    }
    expect(ad.resolve(item: "B", samples: both(0.5, 200), isPlaying: true, at: at(8))?.0.position == 0.7, "song after the ad from its own start")
    expect(ad.resolve(item: "B", samples: only(239.5, 600), isPlaying: true, at: at(9)) == nil, "A's continuous element line (230.2 + 9 s) still hidden after the ad")

    // Once B has been shown for a while, earlier timelines are forgotten: a seek in B that
    // happens to land on A's line is shown (never hidden indefinitely).
    var forget = BrowserMedia.TimeResolver()
    _ = forget.resolve(item: "A", samples: both(100, 240), isPlaying: true, at: at(0))
    _ = forget.resolve(item: "B", samples: both(1, 240), isPlaying: true, at: at(2))
    _ = forget.resolve(item: "B", samples: both(19, 240), isPlaying: true, at: at(20))
    expect(forget.resolve(item: "B", samples: both(121, 240), isPlaying: true, at: at(21))?.0.position == 121.2, "after 15 s of B, a seek onto A's old line is shown")
    expect(forget.rememberedItems.isEmpty, "earlier timelines dropped")

    // Same song re-identified (ID or metadata arrives late): the bar keeps advancing on the
    // "previous" line. Hidden briefly, then shown — never hidden for the rest of the song.
    var rekey = BrowserMedia.TimeResolver()
    _ = rekey.resolve(item: "Song|Artist|", samples: both(40, 240), isPlaying: true, at: at(0))
    var shownAfter: Double?
    for k in 1...20 where shownAfter == nil {
        if rekey.resolve(item: "videoID-x", samples: both(40 + Double(k), 240), isPlaying: true, at: at(Double(k))) != nil { shownAfter = Double(k) }
    }
    // The change is first seen at t = 1 s.
    expect(shownAfter != nil && shownAfter! - 1 <= BrowserMedia.TimeResolver.visibleLagLimit + 1, "re-identified song shown ≤ 9 s after the change: \(String(describing: shownAfter))")
    // …but an element-only continuous timeline (no visible bar) still stays hidden.
    var elementOnly = BrowserMedia.TimeResolver()
    _ = elementOnly.resolve(item: "A", samples: only(40, 600), isPlaying: true, at: at(0))
    var leakedLater: [Double] = []
    for k in 1...20 { if let r = elementOnly.resolve(item: "B", samples: only(40 + Double(k), 600), isPlaying: true, at: at(Double(k))) { leakedLater.append(r.0.position) } }
    expect(leakedLater.isEmpty, "continuous element line without a visible bar: hidden for 20 s: \(leakedLater)")
    // Consecutive auto-advance through five songs with lagging player bar: never shows a previous song's time.
    var chain = BrowserMedia.TimeResolver()
    var t = 0.0, stacked: [String] = []
    for song in 0..<5 {
        let length = 180 + Double(song % 2) * 0 // same length every time (hardest case)
        for p in stride(from: 170.0, through: 179, by: 1) { _ = chain.resolve(item: "S\(song)", samples: both(p, length), isPlaying: true, at: at(t)); t += 1 }
        // Next song: bar shows the old time for two reads, then the new one.
        let next = "S\(song + 1)"
        for k in 0..<2 {
            if chain.resolve(item: next, samples: both(180, length), isPlaying: true, at: at(t)) != nil { stacked.append("\(next) stale \(k)") }
            t += 0.55
        }
        let fresh = chain.resolve(item: next, samples: both(0.4, length), isPlaying: true, at: at(t)); t += 1
        if fresh == nil { stacked.append("\(next) not shown") }
    }
    expect(stacked.isEmpty, "five same-length auto-advances: \(stacked)")
}

await test("time 0.1.1: seeded sweep — stale samples never shown, fresh songs always shown within 6 s") {
    typealias S = BrowserMedia.TimeSample
    let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    var seed: UInt64 = 0x5EED_0111
    func rnd(_ range: ClosedRange<Double>) -> Double {
        seed = seed &* 6364136223846793005 &+ 1442695040888963407
        return range.lowerBound + Double(seed >> 11) / Double(1 << 53) * (range.upperBound - range.lowerBound)
    }
    var shownStale: [String] = [], neverShown: [String] = []
    for run in 0..<400 {
        var r = BrowserMedia.TimeResolver()
        let oldLength = rnd(120...420), oldPos = rnd(8...(oldLength - 1))
        let sameLength = run % 3 == 0
        let newLength = sameLength ? oldLength + rnd(-0.8...0.8) : rnd(120...420)
        let shape = run % 4 // 0: ui+player, 1: player+element, 2: ui only, 3: player only
        func samples(_ p: Double, _ d: Double) -> BrowserMedia.TimeSamples {
            switch shape {
            case 0: return .init(ui: S(position: p, duration: d), player: S(position: p + 0.1, duration: d), element: nil)
            case 1: return .init(ui: nil, player: S(position: p, duration: d), element: S(position: p + 0.05, duration: d))
            case 2: return .init(ui: S(position: p, duration: d), player: nil, element: nil)
            default: return .init(ui: nil, player: S(position: p, duration: d), element: nil)
            }
        }
        var t = 0.0
        for k in 0..<3 { _ = r.resolve(item: "A", samples: samples(oldPos + Double(k), oldLength), isPlaying: true, at: t0.addingTimeInterval(t)); t += 1 }
        let change = t
        let lag = rnd(0...2.5)          // new song started before the change was seen
        var firstShown: Double?
        while t < change + 12 {
            let since = t - change
            let stale = since < 2.2 && rnd(0...1) < 0.6
            let p = stale ? oldPos + 2 + (t - (change - 1)) : lag + since
            if let res = r.resolve(item: "B", samples: samples(p, stale ? oldLength : newLength), isPlaying: true, at: t0.addingTimeInterval(t)) {
                if stale { shownStale.append("run \(run) shape \(shape) at +\(String(format: "%.1f", since)) s: \(res.0.position)") }
                else if firstShown == nil { firstShown = since }
            }
            t += 0.55
        }
        if (firstShown ?? .infinity) > 6 { neverShown.append("run \(run) shape \(shape) oldPos \(Int(oldPos)) same \(sameLength): \(String(describing: firstShown))") }
    }
    expect(shownStale.isEmpty, "no stale (previous song's) time shown: \(shownStale.prefix(4))")
    expect(neverShown.isEmpty, "every fresh song shown within 6 s: \(neverShown.prefix(4))")
}

await test("time 0.1.1: MusicController keeps the old timeline across an empty scan; hidden time hides its length too") {
    let music = MusicController(defaults: freshDefaults())
    typealias S = BrowserMedia.TimeSample
    let t0 = Date()
    func snap(_ id: String, _ title: String, _ samples: BrowserMedia.TimeSamples, _ t: Double) -> MusicController.Snapshot {
        MusicController.Snapshot(source: .chrome, track: .init(title: title, artist: "", album: "", duration: samples.player?.duration),
                                 isPlaying: true, position: samples.player?.position, browserTab: (ref: "1/2", site: .youtubeMusic),
                                 browserVideoID: id, timeSamples: samples, sampledAt: t0.addingTimeInterval(t))
    }
    let a = BrowserMedia.TimeSamples(ui: S(position: 200, duration: 230), player: S(position: 200.2, duration: 230), element: nil)
    music.applyForTesting(snap("idA", "A", a, 0))
    expect(music.position == 200.2 && music.track?.duration == 230, "A shown")
    // Song change: metadata briefly missing → the scan returns nothing.
    music.applyForTesting(nil)
    expect(music.track == nil, "nothing shown for a moment")
    // B arrives while player and element still run A's timeline (agreeing with each other).
    let stale = BrowserMedia.TimeSamples(ui: nil, player: S(position: 203, duration: 230), element: S(position: 203, duration: 230))
    music.applyForTesting(snap("idB", "B", stale, 3))
    expect(music.track?.title == "B" && music.position == nil, "B is shown without A's time (old code reset the resolver on the empty scan): \(String(describing: music.position))")
    expect(music.track?.duration == nil, "and without A's length")
    let fresh = BrowserMedia.TimeSamples(ui: S(position: 1, duration: 190), player: S(position: 1.1, duration: 190), element: nil)
    music.applyForTesting(snap("idB", "B", fresh, 4))
    expect(music.position == 1.1 && music.track?.duration == 190, "B's own time")
    expect(MusicController.timelineOwner(source: .chrome, tab: (ref: "1/2", site: .youtubeMusic))
           != MusicController.timelineOwner(source: .chrome, tab: (ref: "1/3", site: .youtubeMusic)), "each tab has its own timelines")
    expect(MusicController.timelineOwner(source: .music, tab: nil) == "music", "native players are separate")
}

await test("permissions: Allow always does something, Open Settings opens the exact pane, status refreshes") {
    expect(PostEventAccess.step(granted: true, alreadyRequestedThisBuild: false) == .nothing, "granted → nothing")
    expect(PostEventAccess.step(granted: false, alreadyRequestedThisBuild: false) == .systemPrompt, "first press asks macOS")
    expect(PostEventAccess.step(granted: false, alreadyRequestedThisBuild: true) == .openSettings, "later presses open Settings (macOS only asks once)")
    var granted = false, prompts = 0, opened = 0
    let defaults = freshDefaults()
    let access = PostEventAccess(defaults: defaults, preflight: { granted }, requestSystem: { prompts += 1 },
                                 openSettings: { opened += 1; return true }, buildID: "build-2")
    access.request()
    expect(prompts == 1 && opened == 0 && access.feedback == .prompted, "first press → system request")
    access.request()
    expect(prompts == 1 && opened == 1 && access.feedback == .openedSettings, "second press → Accessibility pane, no silent no-op")
    access.showSettings()
    expect(opened == 2, "Open Settings button")
    granted = true
    access.refresh()
    expect(access.granted && access.feedback == .none && defaults.string(forKey: PostEventAccess.grantedBuildKey) == "build-2", "grant picked up without reopening Settings")
    // A grant for an earlier ad-hoc build is recognised (rebuild changed the identity).
    let staleDefaults = freshDefaults()
    staleDefaults.set("build-1", forKey: PostEventAccess.grantedBuildKey)
    let stale = PostEventAccess(defaults: staleDefaults, preflight: { false }, requestSystem: {}, openSettings: { false }, buildID: "build-2")
    expect(stale.grantLooksStale, "stale grant explained")
    stale.showSettings()
    expect(stale.feedback == .couldNotOpen, "failure to open is reported, not hidden")
    // URL fallbacks: legacy pane id → new extension id → System Settings itself.
    var tried: [String] = []
    expect(SystemSettingsLink.open(.pasteboard) { tried.append($0.absoluteString); return tried.count == 2 }, "second URL opened")
    expect(tried == ["x-apple.systempreferences:com.apple.preference.security?Privacy_Pasteboard",
                     "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_Pasteboard"], "order: \(tried)")
    tried = []
    _ = SystemSettingsLink.open(.accessibility) { tried.append($0.absoluteString); return false }
    expect(tried.last == SystemSettingsLink.settingsApp.absoluteString && tried.count == 4, "last resort: System Settings app")
    expect(SystemSettingsLink.battery.first?.absoluteString == "x-apple.systempreferences:com.apple.Battery-Settings.extension", "Battery pane")
    // Anchors exist in this Mac's System Settings (read-only check of the installed binary).
    let ext = "/System/Library/ExtensionKit/Extensions/SecurityPrivacyExtension.appex/Contents/MacOS/SecurityPrivacyExtension"
    if let data = FileManager.default.contents(atPath: ext) {
        for pane in PrivacyPane.allCases {
            expect(data.range(of: Data(pane.rawValue.utf8)) != nil, "\(pane.rawValue) is a real anchor on this macOS")
        }
    }
    // Pasteboard privacy (macOS 15.4+): mapping and a read that never prompts.
    expect([0, 1, 2, 3].map(PasteboardAccess.from) == [.notAskedYet, .asks, .allowed, .denied], "access behaviour mapping")
    expect(!PasteboardAccess.denied.historyCanRecord && PasteboardAccess.allowed.historyCanRecord, "denied → history can't record")
    let privateBoard = NSPasteboard(name: .init("NotchIslandTests.\(UUID().uuidString)"))
    if #available(macOS 15.4, *) { expect(PasteboardAccess.current(privateBoard) == .allowed, "non-general pasteboards are always allowed") }
    privateBoard.releaseGlobally()
    let lang = LanguageSettings.shared
    let saved = lang.language
    defer { lang.language = saved }
    for (language, pane) in [(AppLanguage.english, "Paste from Other Apps"), (.traditionalChinese, "從其他App貼上"), (.simplifiedChinese, "从其他App粘贴")] {
        lang.language = language
        expect(lang.t(.pasteboardAsks).contains(pane) && lang.t(.pasteboardDenied).contains(pane), "\(language): System Settings' own pane name")
        expect(!lang.t(.permPromptedHint).isEmpty && lang.t(.pasteNeedsPermission).contains(lang.t(.openSettings)), "\(language): paste hint names the button")
    }
    let settingsSource = try String(contentsOfFile: "Sources/NotchIsland/SettingsWindow.swift", encoding: .utf8)
    expect(!settingsSource.contains("SystemMedia.requestPostEventAccess() }"), "Settings no longer calls the one-shot request directly")
}

await test("shazam 0.1.1: Control Center honesty, shortcut not found / stop / time limit") {
    let notFound = Data("Error: The operation couldn’t be completed. Couldn’t find shortcut\n".utf8)
    expect(ShazamRecognizer.shortcutOutcome(status: 1, reason: .exit, output: Data(), errorOutput: notFound) == .notFound,
           "the literal stderr of /usr/bin/shortcuts on macOS 27 → not found")
    expect(ShazamRecognizer.shortcutOutcome(status: 1, reason: .exit, output: Data(), errorOutput: Data("Error: something else".utf8)) == .failed, "other errors stay generic")
    expect(ShazamRecognizer.shortcutOutcome(status: 0, reason: .exit, output: Data("Song — Artist\n".utf8)) == .result("Song — Artist"), "text result")
    expect(ShazamRecognizer.shortcutOutcome(status: 15, reason: .uncaughtSignal, output: Data(), errorOutput: notFound) == .failed, "killed ≠ not found")
    expect(ShazamRecognizer.shortcutTimeout == 90, "time limit")
    let shazam = ShazamRecognizer()
    shazam.stopShortcut()
    expect(shazam.shortcutPhase == .idle, "stop without a running shortcut does nothing")
    let lang = LanguageSettings.shared
    let saved = lang.language
    defer { lang.language = saved }
    for language in [AppLanguage.english, .traditionalChinese, .simplifiedChinese] {
        lang.language = language
        let text = lang.t(.shazamSystemNotExposed)
        expect(text.contains(language == .english ? "Control Center" : (language == .traditionalChinese ? "控制中心" : "控制中心")), "\(language): says where the result is")
        expect(lang.t(.shazamShortcutNotFound, "X").contains("X"), "\(language): names the shortcut")
        expect(!lang.t(.shazamSystemFallback).isEmpty && !lang.t(.shazamShortcutHelp).contains("Gallery first"), "\(language): updated guidance")
    }
    let page = try String(contentsOfFile: "Sources/NotchIsland/IslandPages.swift", encoding: .utf8)
    expect(page.contains("case .menuBarNotExposed: return lang.t(.shazamSystemNotExposed)"), "page explains the measured macOS 27 limitation")
    let cc = try String(contentsOfFile: "Sources/NotchIsland/ControlCenterMedia.swift", encoding: .utf8)
    expect(cc.contains("if menu.isEmpty { return .menuBarNotExposed }"), "no menu-bar items → honest result, nothing pressed")
}

await test("power: charger and low-battery moments without jitter or repeats") {
    typealias D = PowerEventDetector
    func snap(_ p: Int, ac: Bool, charging: Bool? = nil) -> BatterySnapshot {
        BatterySnapshot(percent: p, isCharging: charging ?? ac, onACPower: ac, isCharged: false, minutesToEmpty: nil, minutesToFull: nil)
    }
    let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    func at(_ s: Double) -> Date { t0.addingTimeInterval(s) }
    var d = D()
    expect(d.observe(snap(60, ac: true), at: at(0)).isEmpty, "launch while plugged in: no fake 'connected'")
    expect(d.observe(snap(60, ac: false), at: at(5)).isEmpty, "unplug: nothing")
    expect(d.observe(snap(60, ac: true), at: at(20)) == [.connected(percent: 60, charging: true)], "plug in → once")
    _ = d.observe(snap(60, ac: false), at: at(22))
    expect(d.observe(snap(60, ac: true), at: at(24)).isEmpty, "loose cable within 10 s: not repeated")
    _ = d.observe(snap(60, ac: false), at: at(40))
    expect(d.observe(snap(61, ac: true, charging: false), at: at(41)) == [.connected(percent: 61, charging: false)], "after the cooldown: again (charge on hold → not 'charging')")
    expect(d.observe(nil, at: at(42)).isEmpty, "no battery → nothing")

    var low = D()
    _ = low.observe(snap(22, ac: false), at: at(0))
    expect(low.observe(snap(21, ac: false), at: at(1)).isEmpty, "21 %: nothing")
    expect(low.observe(snap(20, ac: false), at: at(2)) == [.low(percent: 20, threshold: 20)], "20 % → alert")
    expect(low.observe(snap(21, ac: false), at: at(3)).isEmpty && low.observe(snap(20, ac: false), at: at(4)).isEmpty, "jitter around 20 %: once")
    expect(low.observe(snap(19, ac: true), at: at(5)).first == .connected(percent: 19, charging: true), "plug in at 19 %")
    expect(low.observe(snap(19, ac: false), at: at(6)).isEmpty, "unplug at 19 %: not repeated")
    expect(low.observe(snap(10, ac: false), at: at(7)) == [.low(percent: 10, threshold: 10)], "10 % → second (last) alert")
    expect(low.observe(snap(9, ac: false), at: at(8)).isEmpty, "below 10 %: nothing more")
    _ = low.observe(snap(26, ac: true), at: at(100))
    expect(low.observe(snap(20, ac: false), at: at(200)) == [.low(percent: 20, threshold: 20)], "charged back above 25 % → re-armed")
    var launch = D()
    expect(launch.observe(snap(8, ac: false), at: at(0)) == [.low(percent: 8, threshold: 10)], "launch at 8 %: one alert, not two")
    var onAC = D()
    expect(onAC.observe(snap(5, ac: true), at: at(0)).isEmpty, "low but charging: no alert")

    // Controller → island: toast, banner, expanded, disabled, language.
    let defaults = freshDefaults()
    let model = IslandViewModel(geometry: NotchGeometry(screenFrame: NSRect(x: 0, y: 0, width: 1512, height: 982), hasNotch: true,
                                                        notchRect: NSRect(x: 662, y: 950, width: 185, height: 32)),
                                timer: CountdownTimer(defaults: defaults), music: MusicController(defaults: defaults), stopwatch: Stopwatch(defaults: defaults))
    var clock = t0
    let power = PowerAlertController(model: model, defaults: defaults, now: { clock })
    expect(power.enabled, "on by default (local, no permission)")
    power.handle(.available(snap(50, ac: false)))
    clock = at(30)
    power.handle(.available(snap(50, ac: true)))
    expect(model.toast?.text == "50%" && model.toast?.symbol == "bolt.fill" && model.toast?.accessibilityText?.contains("50") == true, "charging toast with percent")
    clock = at(60)
    power.handle(.available(snap(20, ac: false)))
    expect(model.banner == IslandBanner(kind: .lowBattery(percent: 20)) && model.mode == .compact, "low battery banner below the notch")
    // Hit testing: buttons on the banner are clickable, but it is not a hover-to-expand target.
    let inside = NSPoint(x: 662 + 92, y: 950 - 30)
    expect(model.bannerContains(inside) && model.acceptsMouse(at: inside), "banner takes clicks")
    expect(!model.activationContains(inside), "hovering the banner doesn't expand the island")
    expect(model.activationContains(NSPoint(x: 754, y: 975)), "the notch still expands it")
    clock = at(90)
    power.handle(.available(snap(20, ac: true)))
    expect(model.banner == nil, "plugging in dismisses the low-battery card")
    // Expanded: charging is shown over the panel; a low alert waits until it collapses.
    model.setExpanded(true)
    clock = at(200); power.handle(.available(snap(30, ac: false)))
    clock = at(300); power.handle(.available(snap(30, ac: true)))
    expect(model.toast?.text == "30%" && model.toast?.symbol == "bolt.fill", "charging toast is available while expanded")
    clock = at(400); power.handle(.available(snap(10, ac: false)))
    expect(model.banner == nil, "not shown over the expanded panel")
    model.setExpanded(false)
    expect(model.banner == IslandBanner(kind: .lowBattery(percent: 10)), "shown after collapsing")
    model.dismissBanner()
    power.setEnabled(false)
    clock = at(500); power.handle(.available(snap(5, ac: true)))
    expect(model.banner == nil, "disabled → nothing")
    // Reduce Motion: no springs.
    model.reduceMotion = { true }
    expect(model.modeAnimation(expanding: true) == IslandViewModel.reducedMotionAnimation, "reduce motion → short ease")
    model.reduceMotion = { false }
    expect(model.modeAnimation(expanding: true) == IslandViewModel.expandAnimation, "springs otherwise")
    let lang = LanguageSettings.shared
    let saved = lang.language
    defer { lang.language = saved }
    for (language, word) in [(AppLanguage.english, "Low Power Mode"), (.traditionalChinese, "低耗電模式"), (.simplifiedChinese, "低电量模式")] {
        lang.language = language
        expect(lang.t(.lowBatteryRemaining, "20").contains("20%") && lang.t(.lowPowerModeButton).contains(word) && lang.t(.lowPowerModeHelp).contains(word), "\(language): banner text uses macOS's own name")
    }
    let source = try String(contentsOfFile: "Sources/NotchIsland/PowerAlerts.swift", encoding: .utf8)
    expect(!source.contains("pmset -a") && !source.contains("AuthorizationExecuteWithPrivileges") && !source.contains("sudo"), "never switches Low Power Mode itself")
}

await test("layout 0.1.1: shorter island, same widget cards and notch geometry") {
    expect(IslandViewModel.expandedWidth == 560 && IslandViewModel.expandedWidth < 580, "20 pt shorter than 0.1.0")
    // 0.1.0: floor((580 − 2·20 − 3·10) / 4) = 127 for four cards; one to three cards were height-limited.
    for count in 1...4 {
        let old = floor(min(138, (580 - 40 - 10 * CGFloat(count - 1)) / CGFloat(count)))
        expect(IslandViewModel.widgetCardSide(count: count, rowHeight: 138) >= old, "\(count) cards keep their size (\(old))")
    }
    expect(IslandViewModel.widgetCardSide(count: 4, rowHeight: 138) == 127, "four cards: 127 pt")
    expect(WidgetsPage.spacing == IslandViewModel.widgetCardSpacing, "page uses the same spacing")
    let quick = (IslandViewModel.expandedWidth - 2 * IslandViewModel.widgetsHorizontalPadding - 3 * 8) / 4
    expect(quick >= 125, "quick-action buttons stay wide: \(quick)")
    let defaults = freshDefaults()
    let notch = NSRect(x: 662, y: 950, width: 185, height: 32)
    let model = IslandViewModel(geometry: NotchGeometry(screenFrame: NSRect(x: 0, y: 0, width: 1512, height: 982), hasNotch: true, notchRect: notch),
                                timer: CountdownTimer(defaults: defaults), music: MusicController(defaults: defaults), stopwatch: Stopwatch(defaults: defaults))
    expect(model.neckWidth(for: .idle, hovering: false) == 185 && model.neckWidth(for: .expanded, hovering: false) == 185, "notch geometry unchanged")
    expect(model.windowSize.width == 560 + 2 * IslandViewModel.windowPadding, "window follows the new width")
    model.setExpanded(true)
    expect(model.shapeContains(NSPoint(x: 754 - 270, y: 950 - 100)) && !model.shapeContains(NSPoint(x: 754 - 290, y: 950 - 100)), "expanded body is 560 wide")
}

await test("DMG 0.1.1: no dark header or title, icons and arrow kept, README hint, layout constants agree") {
    let art = try String(contentsOfFile: "scripts/render_artwork.swift", encoding: .utf8)
    expect(!art.contains("0x14223A") && !art.contains("label(\"Notch Island\""), "dark header and title removed")
    expect(art.contains("please read the README") && art.contains("請閱讀 README"), "README hint (EN + 繁中)")
    expect(art.contains("arrow.addLine") && art.contains("drawIcon"), "arrow and icon artwork kept")
    let settings = try String(contentsOfFile: "scripts/dmg_settings.py", encoding: .utf8)
    let make = try String(contentsOfFile: "scripts/make_dmg.sh", encoding: .utf8)
    expect(art.contains("let installerIconRow: CGFloat = 165") && settings.contains("(158, 165)") && settings.contains("(462, 165)")
           && make.contains("app[1] == link[1] == 165"), "icon row 165 everywhere")
    expect(settings.contains("symlinks = {\"Applications\": \"/Applications\"}"), "Applications shortcut kept")
}

await test("packaging & publishing: purpose strings, .gitignore, secret scan never prints values") {
    let plist = try String(contentsOfFile: "Resources/Info.plist", encoding: .utf8)
    expect(plist.contains("NSMicrophoneUsageDescription") && plist.contains("NSAppleEventsUsageDescription"), "microphone and media automation purpose strings")
    expect(plist.contains("CFBundleIconFile") && FileManager.default.fileExists(atPath: "Resources/NotchIsland.icns"), "custom app icon")
    // First public release is v0.1.0. The marketing version restarted from the
    // private 0.3.x builds, so the build number must keep increasing (0.3.2 was 5)
    // and nothing may key migrations on the marketing version.
    let info = try PropertyListSerialization.propertyList(from: Data(contentsOf: URL(fileURLWithPath: "Resources/Info.plist")), format: nil) as? [String: Any]
    expect(info?["CFBundleShortVersionString"] as? String == "0.1.1", "release version is v0.1.1")
    expect(Int(info?["CFBundleVersion"] as? String ?? "") ?? 0 > 6, "build number stays above v0.1.0 (6) and the private 0.3.2 (5) build")
    expect(info?["CFBundleIdentifier"] as? String == "local.notchisland.app", "bundle ID unchanged, so existing settings and Keychain items are kept")
    let providers = try String(contentsOfFile: "Sources/NotchIsland/Providers.swift", encoding: .utf8)
    expect(providers.contains("\"NotchIsland/0.1 (macOS)\""), "User-Agent uses the release series")
    for l in ["en", "zh-Hant", "zh-Hans"] {
        let strings = try String(contentsOfFile: "Resources/\(l).lproj/InfoPlist.strings", encoding: .utf8)
        expect(strings.contains("NSMicrophoneUsageDescription"), "\(l) mic string")
        expect(strings.components(separatedBy: "AudD").count >= 3, "\(l) mic and system-audio purposes disclose the optional AudD upload")
        expect(strings.contains("QuickTime"), "\(l) Apple Events purpose names QuickTime recording")
    }
    let ignore = try String(contentsOfFile: ".gitignore", encoding: .utf8)
    for entry in ["build/", "dist/", "*.dmg", "screenshots/", ".DS_Store", "CLAUDE.md", "*.mov"] {
        expect(ignore.contains(entry), ".gitignore has \(entry)")
    }
    // Secret scan on a temp folder with a fake token: reported, value never printed.
    let dir = tempDirectory(); defer { try? FileManager.default.removeItem(at: dir) }
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let fake = "ghp_" + String(repeating: "A1b2", count: 9)
    try "let token = \"\(fake)\"\n".write(to: dir.appendingPathComponent("leak.swift"), atomically: true, encoding: .utf8)
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    process.arguments = ["python3", "-I", "scripts/secret_scan.py", dir.path]
    let pipe = Pipe(); process.standardOutput = pipe; process.standardError = Pipe()
    try process.run(); process.waitUntilExit()
    let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    expect(output.contains("github-token") && output.contains("leak.swift") && !output.contains(fake) && !output.contains("A1b2A1b2"),
           "finding reported, value redacted")
    expect(process.terminationStatus == 1, "non-zero exit when something needs review")
}

// MARK: - Click activation

await test("activation: click/hover target is the notch plus a strip below it, never the menu bar beside it") {
    let frame = NSRect(x: 0, y: 0, width: 1512, height: 982)
    let geometry = NotchGeometry(screenFrame: frame, hasNotch: true, notchRect: NSRect(x: 662, y: 950, width: 185, height: 32))
    let d = freshDefaults()
    let sw = Stopwatch(defaults: d)
    let model = IslandViewModel(geometry: geometry, timer: CountdownTimer(defaults: d), music: MusicController(defaults: d), stopwatch: sw)
    let mid = 754.5
    expect(model.mode == .idle, "idle")
    expect(model.activationContains(NSPoint(x: mid, y: 970)), "physical notch")
    expect(model.activationContains(NSPoint(x: mid, y: 982)), "top pixel row")
    expect(model.activationContains(NSPoint(x: mid, y: 950 - 4)), "strip just below the notch (hardware notch may not be clickable)")
    expect(model.activationContains(NSPoint(x: 663, y: 943)), "strip spans the notch width")
    expect(!model.activationContains(NSPoint(x: mid, y: 950 - 12)), "nothing further down")
    expect(!model.activationContains(NSPoint(x: 662 - 5, y: 970)), "menu bar left of the notch is free")
    expect(!model.activationContains(NSPoint(x: 847 + 5, y: 970)), "menu bar right of the notch is free")
    expect(!model.activationContains(NSPoint(x: 662 - 5, y: 946)), "nor below the menu bar beside the notch")
    expect(model.acceptsMouse(at: NSPoint(x: mid, y: 946)) && !model.acceptsMouse(at: NSPoint(x: 600, y: 970)), "panel takes clicks only there")
    // Hover feedback grows the drawn island over the strip, so the target is visible.
    let hovered = model.shapeParams(for: .idle, hovering: true)
    expect(hovered.neckHeight == 32 + IslandViewModel.hoverGrowth && IslandViewModel.hoverGrowth <= IslandViewModel.activationStripHeight, "hover shows the strip")
    // Compact (live activity): indicators + strip; still nothing beyond them.
    sw.start()
    for _ in 0..<5 { await Task.yield(); try await Task.sleep(for: .milliseconds(20)) }
    expect(model.mode == .compact, "compact")
    expect(model.activationContains(NSPoint(x: 662 - 20, y: 970)), "compact indicator is clickable")
    expect(model.activationContains(NSPoint(x: mid, y: 946)), "strip in compact")
    expect(!model.activationContains(NSPoint(x: 662 - IslandViewModel.compactSideWidth - 20, y: 970)), "beyond indicators is free")
    model.setExpanded(true)
    expect(!model.activationContains(NSPoint(x: mid, y: 970)), "no activation while expanded")
    expect(model.acceptsMouse(at: NSPoint(x: mid, y: 900)) == model.shapeContains(NSPoint(x: mid, y: 900)), "expanded uses the drawn shape")
    sw.reset()

    let ext = NotchGeometry.compute(frame: NSRect(x: 0, y: 0, width: 2560, height: 1440), visibleFrame: NSRect(x: 0, y: 0, width: 2560, height: 1415),
                                    safeAreaTop: 0, leftArea: nil, rightArea: nil, fallbackMenuBarHeight: 24)
    let m2 = IslandViewModel(geometry: ext, timer: CountdownTimer(defaults: d), music: MusicController(defaults: d), stopwatch: Stopwatch(defaults: freshDefaults()))
    expect(m2.activationContains(NSPoint(x: 1280, y: 1430)) && m2.activationContains(NSPoint(x: 1280, y: 1412)), "no-notch: centre zone + strip")
    expect(!m2.activationContains(NSPoint(x: 1280 - 80, y: 1430)), "no-notch: rest of the menu bar is free")
}

// MARK: - Location (weather)

await test("location: coarse rounding, authorization mapping, nothing created at launch, legacy places") {
    let c = LocationProvider.coarse(CLLocationCoordinate2D(latitude: 25.04776, longitude: 121.53185))
    expect(c.latitude == 25.0 && c.longitude == 121.5, "rounded to 0.1° (~11 km): \(c.latitude), \(c.longitude)")
    let s = LocationProvider.coarse(CLLocationCoordinate2D(latitude: -33.86882, longitude: 151.20929))
    expect(s.latitude == -33.9 && s.longitude == 151.2, "southern/eastern: \(s.latitude), \(s.longitude)")
    expect(LocationProvider.isAuthorized(.authorizedAlways) && !LocationProvider.isAuthorized(.notDetermined)
           && !LocationProvider.isAuthorized(.denied) && !LocationProvider.isAuthorized(.restricted), "authorization")
    expect(LocationProvider.failure(for: .denied) == .denied && LocationProvider.failure(for: .restricted) == .restricted
           && LocationProvider.failure(for: .notDetermined) == nil, "status → failure")
    expect(LocationProvider.failure(for: CLError(.network)) == .network && LocationProvider.failure(for: CLError(.denied)) == .denied
           && LocationProvider.failure(for: CLError(.locationUnknown)) == .unavailable, "CLError mapping")
    let provider = LocationProvider()
    expect(!provider.hasLocationManager && !provider.isLocating, "no CLLocationManager (no prompt) until the user asks")
    let lang = LanguageSettings.shared
    let saved = lang.language; defer { lang.language = saved }
    let here = Place.currentLocation(c)
    lang.language = .traditionalChinese
    expect(here.fromLocationServices && here.displayName(lang) == "目前位置", "localized name")
    lang.language = .english
    expect(here.displayName(lang) == "Current Location", "en name")
    let legacy = try JSONDecoder().decode(Place.self, from: Data(#"{"name":"Taipei","latitude":25.05,"longitude":121.53}"#.utf8))
    expect(!legacy.fromLocationServices && legacy.displayName(lang) == "Taipei", "older saved cities still load")
    // Weather requests for a current-location place only carry the rounded coordinates.
    let settings = WidgetSettings(defaults: freshDefaults(), secrets: MemorySecretStore())
    settings.setEnabled(.timer, false) // keep room for the widgets under test
    settings.setEnabled(.weather, true)
    settings.place = here
    let http = MockHTTP { _ in (forecastJSON, 200) }
    let center = WidgetDataCenter(settings: settings, client: http)
    center.configurationChanged()
    await center.waitForIdle()
    let query = http.urls.first?.query ?? ""
    expect(query.contains("latitude=25.0000") && query.contains("longitude=121.5000"), "only coarse coordinates sent: \(query)")
}

// MARK: - Calendar & clock

await test("calendar: filtering, ordering, permission states and local-time labels (no prompts)") {
    let cal = Calendar.current
    let now = cal.date(bySettingHour: 10, minute: 0, second: 0, of: Date(timeIntervalSince1970: 1_793_000_000))!
    func item(_ id: String, _ startH: Double, _ endH: Double, allDay: Bool = false) -> CalendarStore.Item {
        CalendarStore.Item(id: id, title: id, start: now.addingTimeInterval(startH * 3600), end: now.addingTimeInterval(endH * 3600),
                           isAllDay: allDay, color: [1, 0, 0])
    }
    let all = [item("done", -3, -1), item("later", 4, 5), item("soon", 1, 2), item("now", -0.5, 0.5),
               item("holiday", -10, 14, allDay: true)]
    expect(CalendarStore.items(from: all, now: now, includeAllDay: true).map(\.id) == ["now", "soon", "later", "holiday"], "finished dropped, timed first")
    expect(CalendarStore.items(from: all, now: now, includeAllDay: false).map(\.id) == ["now", "soon", "later"], "all-day hidden on request")
    expect(CalendarStore.items(from: (0..<10).map { item("e\($0)", Double($0) + 1, Double($0) + 2) }, now: now, includeAllDay: true).count == CalendarStore.maxItems, "capped")
    expect(CalendarStore.items(from: [], now: now, includeAllDay: true).isEmpty, "empty stays empty (no invented events)")
    expect(CalendarStore.Access(.fullAccess) == .granted && CalendarStore.Access(.writeOnly) == .writeOnly
           && CalendarStore.Access(.denied) == .denied && CalendarStore.Access(.notDetermined) == .notDetermined, "access mapping")
    let denied = CalendarStore(statusProvider: { .denied })
    denied.setActive(true, days: 1, includeAllDay: true)
    denied.requestAccess() // must not prompt when already denied
    expect(denied.access == .denied && denied.items.isEmpty && !denied.isRequesting, "denied: no events, no request")
    var status = EKAuthorizationStatus.denied
    let changing = CalendarStore(statusProvider: { status })
    changing.setActive(true, days: 1, includeAllDay: true)
    status = .fullAccess // user allowed it in System Settings
    changing.reloadAccess()
    expect(changing.access == .granted, "permission change picked up without prompting")
    status = .denied
    changing.reloadAccess()
    expect(changing.access == .denied && changing.items.isEmpty, "revocation clears events")
    let lang = LanguageSettings.shared
    let saved = lang.language; defer { lang.language = saved }
    lang.language = .english
    let tomorrow9 = CalendarStore.Item(id: "t", title: "t", start: cal.date(byAdding: .day, value: 1, to: cal.date(bySettingHour: 9, minute: 0, second: 0, of: now)!)!,
                                       end: cal.date(byAdding: .day, value: 1, to: cal.date(bySettingHour: 10, minute: 0, second: 0, of: now)!)!, isAllDay: false, color: [])
    let label = EventRow.timeText(tomorrow9, now: now, lang: lang)
    expect(label.hasPrefix("Tomorrow ") && label.contains("9:00"), "tomorrow label: \(label)")
    expect(EventRow.timeText(item("now", -0.5, 0.5), now: now, lang: lang).hasPrefix("Now until"), "in progress")
    expect(EventRow.timeText(item("h", -10, 14, allDay: true), now: now, lang: lang) == "All day", "all day")
    lang.language = .traditionalChinese
    expect(EventRow.timeText(tomorrow9, now: now, lang: lang).hasPrefix("明天"), "zh-Hant tomorrow")
}

await test("clock: offsets, day changes, hand angles, time-zone settings") {
    let date = ISO8601DateFormatter().date(from: "2026-11-07T02:00:00Z")!
    let taipei = TimeZone(identifier: "Asia/Taipei")!
    expect(ClockText.offset(TimeZone(identifier: "America/New_York")!, at: date, local: taipei) == "-13", "NY vs Taipei (EST)")
    expect(ClockText.offset(TimeZone(identifier: "Asia/Kolkata")!, at: date, local: taipei) == "-2.5", "half-hour zone")
    expect(ClockText.offset(taipei, at: date, local: taipei) == nil, "same zone")
    expect(ClockText.dayDelta(TimeZone(identifier: "America/New_York")!, at: date, local: taipei) == -1, "NY is still yesterday")
    expect(ClockText.dayDelta(TimeZone(identifier: "Pacific/Kiritimati")!, at: date, local: taipei) == 0, "Kiritimati same day at 16:00")
    expect(ClockText.city(TimeZone(identifier: "America/New_York")!) == "New York", "city")
    let a = AnalogClock.angles(ISO8601DateFormatter().date(from: "2026-11-07T15:30:15Z")!, timeZone: .gmt)
    expect(a.hour == 105 && a.minute == 181.5 && a.second == 90, "hands \(a)")
    let s = WidgetSettings(defaults: freshDefaults(), secrets: MemorySecretStore())
    expect(s.addTimeZone("Mars/Base") == .failure(.invalid), "invalid zone")
    expect(s.addTimeZone("Europe/London") == .success("Europe/London") && s.addTimeZone("Europe/London") == .failure(.duplicate), "dup")
    expect(s.addTimeZone("Asia/Tokyo") == .success("Asia/Tokyo") && s.addTimeZone("Asia/Dubai") == .failure(.limit), "limit 2")
    let q = SettingsView.matchingZones("new y", excluding: [])
    expect(q.contains("America/New_York"), "search finds New York: \(q)")
}

await test("widgets: at most four enabled, legacy overflow trimmed, new kinds persisted") {
    let d = freshDefaults()
    let s = WidgetSettings(defaults: d, secrets: MemorySecretStore())
    expect(s.order.contains(.calendar) && s.order.contains(.clock), "new kinds in the order list")
    expect(s.enabledInOrder.count == 3 && s.setEnabled(.weather, true), "defaults (3) + one = four")
    expect(!s.setEnabled(.clock, true) && !s.isEnabled(.clock) && !s.canEnableMore, "fifth refused")
    expect(s.setEnabled(.battery, false) && s.setEnabled(.calendar, true), "swap works")
    let r = WidgetSettings(defaults: d, secrets: MemorySecretStore())
    expect(Set(r.enabledInOrder) == [.weather, .timer, .calendar, .stopwatch], "persisted: \(r.enabledInOrder)")
    let legacy = freshDefaults()
    legacy.set(WidgetKind.allCases.map(\.rawValue), forKey: "NotchIsland.widgets.enabled")
    expect(WidgetSettings(defaults: legacy, secrets: MemorySecretStore()).enabledInOrder.count == WidgetSettings.maxEnabled, "trimmed to four")
    // An existing Alpha Vantage user keeps that provider; new users get Yahoo.
    let av = freshDefaults(); av.set(true, forKey: "NotchIsland.widgets.hasStockKey")
    expect(WidgetSettings(defaults: av, secrets: MemorySecretStore("k")).stockProvider == .alphaVantage, "existing AV user")
    expect(WidgetSettings(defaults: freshDefaults(), secrets: MemorySecretStore()).stockProvider == .yahoo, "new user → Yahoo")
}

await test("Yahoo: realistic intraday + daily series, nulls, symbol encoding, provider switch") {
    // Shape of a real 2330.TW response: daily bars at exchange open, last bar = today's (partial) bar.
    let json = """
    {"chart":{"result":[{"meta":{"currency":"TWD","symbol":"2330.TW","regularMarketPrice":2135.0,"regularMarketTime":1793943005,
    "gmtoffset":28800,"exchangeTimezoneName":"Asia/Taipei"},"timestamp":[1793667600,1793754000,1793840400,1793926800],
    "indicators":{"quote":[{"close":[2250.0,null,2240.0,2135.0]}]}}],"error":null}}
    """
    let q = try YahooFinanceProvider.parse(Data(json.utf8), symbol: "2330.TW")
    expect(q.price == 2135 && abs(q.change + 105) < 1e-9 && abs(q.changePercent + 4.6875) < 1e-3, "vs previous real close: \(q.change) \(q.changePercent)")
    expect(q.closes == [2250, 2240, 2135] && q.latestTradingDay == "2026-11-06", "nulls skipped, day in exchange time: \(q.latestTradingDay)")
    expect(q.asOf == Date(timeIntervalSince1970: 1793943005), "exact as-of time")
    // Market time after the last daily bar (e.g. pre-market): previous = last bar.
    let after = json.replacingOccurrences(of: "1793943005", with: "1794020000")
    let afterQuote = try YahooFinanceProvider.parse(Data(after.utf8), symbol: "2330.TW")
    expect(abs(afterQuote.change) < 1e-9, "previous = last bar when price is newer")
    let notFound = #"{"chart":{"result":null,"error":{"code":"Not Found","description":"No data found, symbol may be delisted"}}}"#
    do { _ = try YahooFinanceProvider.parse(Data(notFound.utf8), symbol: "X"); expect(false, "not found") }
    catch { expect(ProviderError(error) == .notFound, "error payload → not found") }
    for bad in ["{}", #"{"chart":{"result":[{"meta":{}}]}}"#, "<html>Too Many Requests</html>",
                #"{"chart":{"result":[{"meta":{"regularMarketPrice":10,"regularMarketTime":100},"timestamp":[],"indicators":{"quote":[{"close":[]}]}}]}}"#] {
        do { _ = try YahooFinanceProvider.parse(Data(bad.utf8), symbol: "X"); expect(false, "should fail: \(bad)") }
        catch { expect([.invalidResponse, .notFound].contains(ProviderError(error)), "\(bad) → \(error)") }
    }
    expect(YahooFinanceProvider.url(for: "EURUSD=X")?.path == "/v8/finance/chart/EURUSD=X"
           && YahooFinanceProvider.url(for: "EURUSD=X")?.absoluteString.contains("EURUSD%3DX") == true, "'=' encoded")
    expect(YahooFinanceProvider.url(for: "2330.TW")?.absoluteString == "https://query1.finance.yahoo.com/v8/finance/chart/2330.TW?range=3mo&interval=1d", "plain symbol")
    expect(WidgetSettings.normalizeSymbol("2330.tw") == "2330.TW" && WidgetSettings.normalizeSymbol("../etc") == nil
           && WidgetSettings.normalizeSymbol("AAPL?x=1") == nil && WidgetSettings.normalizeSymbol("A/B") == nil, "validation blocks path/query injection")
    // Data center: Yahoo needs no key; switching provider refetches from the other source.
    let settings = WidgetSettings(defaults: freshDefaults(), secrets: MemorySecretStore())
    settings.setEnabled(.timer, false) // keep room for the widgets under test
    settings.setEnabled(.stocks, true)
    _ = settings.addSymbol("2330.TW")
    let http = MockHTTP { url in url.host == "query1.finance.yahoo.com" ? (Data(json.utf8), 200) : (quoteJSON, 200) }
    let center = WidgetDataCenter(settings: settings, client: http)
    center.yahooRequestSpacing = .zero
    center.configurationChanged()
    await center.waitForIdle()
    expect(settings.stockProvider == .yahoo && center.stocks.value?.first?.quote?.provider == .yahoo, "Yahoo without key")
    settings.stockProvider = .alphaVantage
    center.configurationChanged()
    await center.waitForIdle()
    expect(center.stocks == .empty && http.urls.filter { $0.host == "www.alphavantage.co" }.isEmpty, "AV without key: cleared, no request")
}

// MARK: - Live network (opt-in)

if CommandLine.arguments.contains("--live") {
    await test("LIVE Open-Meteo geocoding + forecast") {
        let provider = OpenMeteoProvider(client: URLSessionHTTPClient())
        let places = try await provider.searchPlaces("Taipei", language: "zh")
        expect(!places.isEmpty, "geocoded")
        let wx = try await provider.current(for: places[0], unit: .celsius)
        print("    \(places[0].name): \(wx.temperature)°C code \(wx.code) observed \(wx.observedLocal ?? "-")")
        expect(wx.temperature > -60 && wx.temperature < 60, "plausible temperature")
    }
    await test("LIVE Yahoo Finance (unofficial chart endpoint): 2330.TW and AAPL") {
        let provider = YahooFinanceProvider(client: URLSessionHTTPClient())
        for symbol in ["2330.TW", "AAPL"] {
            do {
                let q = try await provider.quote(symbol: symbol)
                print("    \(q.symbol) \(q.price) \(q.currency ?? "") \(String(format: "%+.2f%%", q.changePercent)) as of \(q.asOf.map { "\($0)" } ?? "-"), \(q.closes.count) closes")
                expect(q.price > 0 && q.closes.count >= 2 && q.asOf != nil, "\(symbol) real quote")
            } catch {
                // Unofficial endpoint: report honestly instead of failing on rate limits.
                print("    \(symbol) unavailable: \(ProviderError(error))")
                expect(ProviderError(error) == .rateLimited, "only rate limiting is tolerated: \(error)")
            }
            try await Task.sleep(for: .milliseconds(600))
        }
        do { _ = try await provider.quote(symbol: "ZZZZQQX9"); expect(false, "unknown symbol") }
        catch { expect([.notFound, .rateLimited].contains(ProviderError(error)), "unknown → \(error)") }
    }
    await test("LIVE Alpha Vantage (documented demo key, IBM only)") {
        let q = try await AlphaVantageProvider(client: URLSessionHTTPClient()).quote(symbol: "IBM", apiKey: "demo")
        print("    IBM \(q.price) \(q.changePercent)% as of \(q.latestTradingDay), \(q.closes.count) real closes for chart")
        expect(q.closes.count >= 2 && q.closes.last == q.price, "chart ends at the latest close")
        expect(q.price > 0, "price")
        do { _ = try await AlphaVantageProvider(client: URLSessionHTTPClient()).quote(symbol: "AAPL", apiKey: "demo"); expect(false, "demo key should be rejected for AAPL") }
        catch { expect(ProviderError(error) == .invalidAPIKey || ProviderError(error) == .rateLimited, "demo rejection mapped: \(error)") }
    }
}

print(failures == 0 ? "\nAll \(checks) checks passed." : "\n\(failures) of \(checks) checks FAILED.")
exit(failures == 0 ? 0 : 1)
