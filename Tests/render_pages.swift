import AppKit
import SwiftUI

// Off-screen layout check: renders island subpages at their real size
// (540 × 210 pt) in all three languages with ImageRenderer. Uses only
// synthetic data and a mocked network; never reads the screen.

final class RenderMock: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let json = #"{"status":"success","result":{"artist":"Synthetic Artist With A Long Name","title":"A Deliberately Long Synthetic Test Tone Title","song_link":"https://lis.tn/test"}}"#
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(json.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@MainActor final class ToneSource: AudDAudioSource {
    func begin(_ source: ShazamRecognizer.Source, into clip: AudDClip) -> Bool {
        clip.append((0..<160_000).map { 0.3 * sin(Float($0) * 0.17) }, rate: 16_000); return true
    }
    func end() {}
}

/// Song Finder answers from `SongFinderRender.reply` (synthetic JSON; nothing leaves the Mac).
final class SongFinderRender: URLProtocol {
    nonisolated(unsafe) static var reply: (Int, String) = (200, "{}")
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let (status, json) = Self.reply
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(json.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@MainActor final class TwoTones: AudDAudioSource {
    var silentMac = false
    func begin(_ source: ShazamRecognizer.Source, into clip: AudDClip) -> Bool {
        let amplitude: Float = source == .systemAudio && silentMac ? 0 : 0.3
        clip.append((0..<(13 * 16_000)).map { amplitude * sin(Float($0) * 0.17) }, rate: 16_000); return true
    }
    func end() {}
}

/// Answers every request with an error: the widget renders its offline state.
final class OfflineHTTP: HTTPClient, @unchecked Sendable {
    func get(_ url: URL) async throws -> (Data, Int) { throw URLError(.notConnectedToInternet) }
}

@MainActor func render<V: View>(_ view: V, _ name: String, out: URL, size: CGSize = CGSize(width: 540, height: 210)) {
    let framed = view.frame(width: size.width, height: size.height).padding(20).background(Color.black).environment(\.colorScheme, .dark)
    let renderer = ImageRenderer(content: framed)
    renderer.scale = 2
    guard let image = renderer.nsImage, let tiff = image.tiffRepresentation,
          let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) else { print("✗ \(name)"); return }
    try? png.write(to: out.appendingPathComponent("\(name).png"))
    print("• \(name).png")
}

@MainActor func run() async {
    let out = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first(where: { !$0.hasPrefix("--") }) ?? "build/qa/pages", isDirectory: true)
    try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
    let lang = LanguageSettings.shared
    let savedLanguage = lang.language
    defer { lang.language = savedLanguage }
    let suite = "NotchIslandRender.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    let model = IslandViewModel(geometry: NotchGeometry(screenFrame: NSRect(x: 0, y: 0, width: 1512, height: 982), hasNotch: true,
                                                        notchRect: NSRect(x: 662, y: 950, width: 185, height: 32)),
                                timer: CountdownTimer(defaults: defaults), music: MusicController(defaults: defaults), stopwatch: Stopwatch(defaults: defaults))
    let shazam = ShazamRecognizer()
    let session = AudDService.makeSession(protocolClasses: [RenderMock.self])
    // 0.1.1 layout: four widget cards + quick actions in the 560 pt island (synthetic data,
    // memory-only secrets, calendar "not asked" — nothing real is read).
    let widgetSettings = WidgetSettings(defaults: defaults, secrets: MemorySecretStore())
    for kind in widgetSettings.order where widgetSettings.enabled.count < 4 { _ = widgetSettings.setEnabled(kind, true) }
    let battery = BatteryMonitor()
    let songFinderSession = SongFinderService.makeSession(protocolClasses: [SongFinderRender.self])
    let idleSongFinder = SongFinderRecognition(defaults: defaults, session: songFinderSession, audio: TwoTones())
    func widgetsPage() -> some View {
        VStack(spacing: 6) {
            WidgetsPage(model: model, lang: lang)
            QuickActionsBar(model: model, lang: lang)
        }
        .padding(.horizontal, IslandViewModel.widgetsHorizontalPadding)
        .padding(.top, 6).padding(.bottom, 14)
        .frame(width: IslandViewModel.expandedWidth, height: IslandViewModel.widgetsContentHeight - 32)
        .environmentObject(model).environmentObject(widgetSettings).environmentObject(battery)
        .environmentObject(WidgetDataCenter(settings: widgetSettings, client: OfflineHTTP()))
        .environmentObject(CalendarStore(statusProvider: { .notDetermined })).environmentObject(LocationProvider())
        .environmentObject(model.stopwatch).environmentObject(model.timer).environmentObject(idleSongFinder)
    }
    for (language, code) in [(AppLanguage.english, "en"), (.traditionalChinese, "zh-Hant"), (.simplifiedChinese, "zh-Hans")] {
        lang.language = language
        render(widgetsPage(), "\(code)-widgets-560", out: out, size: CGSize(width: IslandViewModel.expandedWidth, height: IslandViewModel.widgetsContentHeight - 32))
        for percent in [20, 10] {
            let banner = PowerBannerView(banner: IslandBanner(kind: .lowBattery(percent: percent)), model: model, lang: lang)
                .frame(width: IslandViewModel.bannerWidth, height: IslandViewModel.bannerHeight)
                .background(RoundedRectangle(cornerRadius: 22, style: .continuous).fill(Color.black))
                .environmentObject(battery)
            render(banner, "\(code)-low-battery-\(percent)", out: out, size: CGSize(width: IslandViewModel.bannerWidth, height: IslandViewModel.bannerHeight))
        }
        let toast = HStack { ToastLeading(toast: .init(symbol: "bolt.fill", text: "82%", style: .success)); Spacer(); ToastTrailing(toast: .init(symbol: "bolt.fill", text: "82%", style: .success)) }
            .padding(.horizontal, 10).frame(width: 185 + 2 * IslandViewModel.compactSideWidth, height: 32)
        render(toast, "\(code)-charging-toast", out: out, size: CGSize(width: 185 + 2 * IslandViewModel.compactSideWidth, height: 32))
        render(QuickActionsBar(model: model, lang: lang).environmentObject(idleSongFinder), "\(code)-quick-actions", out: out)
        // Song Finder: disclosure → recording → result / honest failures (synthetic tones, mocked answers).
        func songFinderPage(_ r: SongFinderRecognition) -> some View {
            SongFinderPage(model: model, lang: lang, recognition: r)
                .frame(width: IslandViewModel.expandedWidth - 2 * IslandViewModel.widgetsHorizontalPadding, height: IslandViewModel.widgetsContentHeight - 52)
        }
        let size = CGSize(width: IslandViewModel.expandedWidth - 2 * IslandViewModel.widgetsHorizontalPadding, height: IslandViewModel.widgetsContentHeight - 52)
        defaults.removeObject(forKey: MusicRecognitionMode.defaultsKey) // Song Finder is the default
        defaults.removeObject(forKey: SongFinderService.consentKey)
        let consent = SongFinderRecognition(defaults: defaults, session: songFinderSession, audio: TwoTones())
        consent.start()
        render(songFinderPage(consent), "\(code)-songfinder-consent", out: out, size: size)
        defaults.set(SongFinderService.consentVersion, forKey: SongFinderService.consentKey)
        let recording = SongFinderRecognition(defaults: defaults, session: songFinderSession, audio: TwoTones(), listenDuration: .seconds(30),
                                              microphoneAccess: { true })
        recording.start()
        for _ in 0..<200 where recording.phase != .listening { try? await Task.sleep(for: .milliseconds(10)) }
        render(songFinderPage(recording), "\(code)-songfinder-listening", out: out, size: size)
        recording.cancel()
        let results: [(String, (Int, String), Bool, Bool)] = [
            ("matched", (200, #"{"code":0,"message":"ok","data":{"matched":true,"title":"A Deliberately Long Synthetic Test Tone Title That Keeps Going","artist":"Synthetic Artist With A Long Name","album":"Synthetic Album"}}"#), true, false),
            ("no-match", (200, #"{"code":0,"message":"ok","data":{"matched":false}}"#), true, false),
            ("rate-limited", (429, "{}"), true, false),
            ("refused", (403, "{}"), true, false),
            ("mic-denied-mac-silent", (200, #"{"code":0,"message":"ok","data":{"matched":false}}"#), false, true),
        ]
        for (name, reply, micAllowed, silentMac) in results {
            SongFinderRender.reply = reply
            let tones = TwoTones(); tones.silentMac = silentMac
            let r = SongFinderRecognition(defaults: defaults, session: songFinderSession, audio: tones, listenDuration: .milliseconds(10),
                                          microphoneAccess: { micAllowed })
            r.start()
            for _ in 0..<500 where r.phase.busy || r.phase == .idle { try? await Task.sleep(for: .milliseconds(10)) }
            render(songFinderPage(r), "\(code)-songfinder-\(name)", out: out, size: size)
        }
        defaults.removeObject(forKey: SongFinderService.consentKey)
        let statuses: [(ControlCenterMedia.MusicRecognitionResult?, String)] = [(nil, "idle"), (.listening, "listening"), (.uncertain, "uncertain"),
                                                                              (.permissionNeeded, "needs-ax"), (.notInControlCenter, "missing"),
                                                                              (.menuBarNotExposed, "not-exposed"), (.unavailable, "unavailable")]
        for (status, name) in statuses {
            render(ShazamPage(model: model, lang: lang, systemStatus: status).environmentObject(shazam), "\(code)-shazam-\(name)", out: out)
        }
        // AudD: no consent → ready → listening → matched (synthetic tone, mocked AudD).
        let store = MemorySecretStore()
        defaults.removeObject(forKey: MusicRecognitionMode.defaultsKey)
        let notChosen = AudDRecognition(secrets: store, defaults: defaults, session: session, audio: ToneSource())
        notChosen.start(source: .systemAudio) // macOS is the chosen method → refused before anything
        render(AudDPage(lang: lang, close: {}, recognition: notChosen), "\(code)-audd-not-selected", out: out)
        defaults.set(MusicRecognitionMode.audd.rawValue, forKey: MusicRecognitionMode.defaultsKey)
        let noConsent = AudDRecognition(secrets: store, defaults: defaults, session: session, audio: ToneSource())
        render(AudDPage(lang: lang, close: {}, recognition: noConsent), "\(code)-audd-consent", out: out)
        noConsent.saveSetup(consent: true, token: ["render", "placeholder"].joined(separator: "-"))
        render(AudDPage(lang: lang, close: {}, recognition: noConsent), "\(code)-audd-ready", out: out)
        let listening = AudDRecognition(secrets: store, defaults: defaults, session: session, audio: ToneSource(), listenDuration: .seconds(30))
        listening.start(source: .systemAudio)
        for _ in 0..<100 where listening.phase != .listening { try? await Task.sleep(for: .milliseconds(10)) }
        render(AudDPage(lang: lang, close: {}, recognition: listening), "\(code)-audd-listening", out: out)
        listening.cancel()
        let matched = AudDRecognition(secrets: store, defaults: defaults, session: session, audio: ToneSource(), listenDuration: .milliseconds(10))
        matched.start(source: .systemAudio)
        for _ in 0..<300 where matched.phase.busy || matched.phase == .idle { try? await Task.sleep(for: .milliseconds(10)) }
        render(AudDPage(lang: lang, close: {}, recognition: matched), "\(code)-audd-matched", out: out)
        defaults.removeObject(forKey: AudDService.consentKey)
    }
}

// MARK: - 0.1.3: Pomodoro (offline renders; synthetic data, fake clock, no capture)

final class RenderClock { var t: TimeInterval = 50_000 }

/// Synthetic album cover (gradient), so "music playing" needs no player or network.
@MainActor func syntheticArtwork() -> Data {
    let image = NSImage(size: NSSize(width: 64, height: 64), flipped: false) { rect in
        NSGradient(colors: [NSColor(srgbRed: 0.35, green: 0.45, blue: 0.95, alpha: 1), NSColor(srgbRed: 0.9, green: 0.4, blue: 0.6, alpha: 1)])?
            .draw(in: rect, angle: 45)
        return true
    }
    return NSBitmapImageRep(data: image.tiffRepresentation!)!.representation(using: .png, properties: [:])!
}

@MainActor func renderPomodoro(out: URL) async {
    let lang = LanguageSettings.shared
    let suite = "NotchIslandRender.pomodoro.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    let geometry = NotchGeometry(screenFrame: NSRect(x: 0, y: 0, width: 1512, height: 982), hasNotch: true,
                                 notchRect: NSRect(x: 662, y: 950, width: 185, height: 32))
    let clock = RenderClock()
    let pomodoro = PomodoroTimer(defaults: defaults, now: { clock.t }, autoTick: false)
    let timer = CountdownTimer(defaults: defaults)
    let stopwatch = Stopwatch(defaults: defaults)
    let music = MusicController(defaults: defaults)
    let model = IslandViewModel(geometry: geometry, timer: timer, music: music, stopwatch: stopwatch, pomodoro: pomodoro)
    model.reduceMotion = { true } // no springs mid-render
    let widgetSettings = WidgetSettings(defaults: defaults, secrets: MemorySecretStore())
    for kind in WidgetKind.allCases { widgetSettings.setEnabled(kind, false) }
    // No battery/clock/weather: their real readings would be device data or "Loading…".
    for kind in [WidgetKind.timer, .stopwatch, .pomodoro] { widgetSettings.setEnabled(kind, true) }
    let tempClipboard = FileManager.default.temporaryDirectory.appendingPathComponent("ni-render-clip-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: tempClipboard) }
    let clipboard = ClipboardStore(defaults: defaults, pasteboard: NSPasteboard(name: NSPasteboard.Name("NotchIslandRender.\(UUID().uuidString)")),
                                   directory: tempClipboard)
    let audd = AudDRecognition(secrets: MemorySecretStore(), defaults: defaults, session: AudDService.makeSession(protocolClasses: [RenderMock.self]),
                               audio: ToneSource())
    let songFinder = SongFinderRecognition(defaults: defaults, session: SongFinderService.makeSession(protocolClasses: [SongFinderRender.self]),
                                           audio: TwoTones())
    let battery = BatteryMonitor()
    let data = WidgetDataCenter(settings: widgetSettings, client: OfflineHTTP())
    let root = IslandRootView(model: model, timer: timer, music: music, lang: lang, stopwatch: stopwatch, battery: battery, data: data,
                              settings: widgetSettings, calendar: CalendarStore(statusProvider: { .notDetermined }), location: LocationProvider(),
                              audioMonitor: AudioLevelMonitor(defaults: defaults), clipboard: clipboard, shazam: ShazamRecognizer(),
                              audd: audd, songFinder: songFinder)
    let artwork = syntheticArtwork()
    func setMusic(playing: Bool?) {
        guard let playing else { music.applyForTesting(nil); return }
        music.applyForTesting(.init(source: .system, track: .init(title: "Sample Song", artist: "Sample Artist", album: "Sample Album", duration: nil),
                                    isPlaying: playing, position: 63, sampledAt: Date(), artworkData: artwork))
    }
    func settle() async { for _ in 0..<12 { await Task.yield(); try? await Task.sleep(for: .milliseconds(15)) } }
    /// Menu bar (light, with a few fake status items) + the compact island.
    func compact(_ name: String) {
        let window = model.windowSize
        let scene = ZStack(alignment: .top) {
            Rectangle().fill(Color(white: 0.9)).frame(height: model.menuBarHeight)
            HStack {
                Text("Finder  File  Edit  View").font(.system(size: 13, weight: .medium)).foregroundStyle(.black.opacity(0.8))
                Spacer()
                Text("Wi-Fi  100%  Mon 9:41").font(.system(size: 13, weight: .medium)).foregroundStyle(.black.opacity(0.8))
            }
            .padding(.horizontal, 12).frame(height: model.menuBarHeight)
            root
        }
        .frame(width: window.width, height: model.menuBarHeight + 16, alignment: .top)
        .clipped()
        render(scene, name, out: out, size: CGSize(width: window.width, height: model.menuBarHeight + 16))
    }
    func expanded(_ name: String) {
        let window = model.windowSize
        render(root.frame(width: window.width, height: window.height, alignment: .top).background(Color(white: 0.85)), name, out: out,
               size: CGSize(width: window.width, height: model.menuBarHeight + IslandViewModel.maxContentHeight + 10))
    }
    func reset() async {
        model.setExpanded(false)
        pomodoro.reset(); pomodoro.reset()
        timer.reset(); stopwatch.reset(); setMusic(playing: nil)
        await settle()
    }
    /// Two completed sessions, then 6:18 into the third focus (18:42 left).
    func focusState() {
        for _ in 0..<2 { pomodoro.start(); clock.t += 1500; pomodoro.refresh(); pomodoro.skipBreak() }
        pomodoro.start(); clock.t += 378; pomodoro.refresh()
    }

    for (language, code) in [(AppLanguage.english, "en"), (.traditionalChinese, "zh-Hant"), (.simplifiedChinese, "zh-Hans")] {
        lang.language = language
        let p = "\(code)-pomodoro"

        await reset(); focusState(); await settle()
        compact("\(p)-compact-alone-focus")
        pomodoro.pause(); await settle()
        compact("\(p)-compact-alone-paused")
        pomodoro.resume(); clock.t += 1122; pomodoro.refresh(); clock.t += 110; pomodoro.refresh(); await settle()
        compact("\(p)-compact-alone-short-break")
        clock.t += 190; pomodoro.refresh(); await settle()
        compact("\(p)-compact-break-over")

        await reset(); focusState(); setMusic(playing: true); await settle()
        compact("\(p)-compact-with-music")
        setMusic(playing: false); await settle()
        compact("\(p)-compact-music-paused")
        setMusic(playing: true); timer.start(minutes: 5); await settle()
        compact("\(p)-compact-music-and-timer")
        setMusic(playing: nil); await settle()
        compact("\(p)-compact-with-timer")

        // Expanded: Live Activities with music + Pomodoro, and with three tools.
        setMusic(playing: true); timer.reset(); await settle()
        model.setExpanded(true); await settle()
        expanded("\(p)-expanded-with-music")
        model.setExpanded(false)
        timer.start(minutes: 5); stopwatch.start(); await settle()
        model.setExpanded(true); model.activityTool = .pomodoro; await settle()
        expanded("\(p)-expanded-three-tools")

        // Widgets page with the Pomodoro card: ready, focus, paused, short and long break.
        await reset()
        func widgets(_ state: String) async {
            model.setExpanded(true); model.page = .widgets; await settle()
            expanded("\(p)-widgets-\(state)")
            model.setExpanded(false)
        }
        await widgets("ready")
        focusState(); await widgets("focus")
        pomodoro.pause(); await widgets("paused")
        pomodoro.resume(); clock.t += 1122; pomodoro.refresh(); await widgets("short-break")
        pomodoro.skipBreak()
        pomodoro.start(); clock.t += 1500; pomodoro.refresh(); clock.t += 240; pomodoro.refresh() // 4th → long break
        await widgets("long-break")
    }
    await reset()
}

/// Menu-bar icon on simulated light and dark menu bars, 1x and 2x (template tinting simulated).
@MainActor func renderStatusIcon(out: URL) {
    for dark in [false, true] {
        for scale in [1, 2] {
            let width = 160, height = 24
            let ctx = CGContext(data: nil, width: width * scale, height: height * scale, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            ctx.scaleBy(x: CGFloat(scale), y: CGFloat(scale))
            ctx.setFillColor(dark ? CGColor(srgbRed: 0.13, green: 0.13, blue: 0.15, alpha: 1) : CGColor(srgbRed: 0.94, green: 0.94, blue: 0.95, alpha: 1))
            ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
            let ink = dark ? NSColor.white : NSColor.black.withAlphaComponent(0.85)
            for (index, image) in [StatusBarIcon.image(), NSImage(systemSymbolName: "wifi", accessibilityDescription: nil)!,
                                   NSImage(systemSymbolName: "battery.75percent", accessibilityDescription: nil)!].enumerated() {
                let tinted = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { rect in
                    image.draw(in: rect.insetBy(dx: index == 0 ? 0 : 1, dy: index == 0 ? 0 : 3))
                    ink.set()
                    rect.fill(using: .sourceAtop)
                    return true
                }
                tinted.draw(in: NSRect(x: 12 + index * 32, y: 3, width: 18, height: 18))
            }
            NSGraphicsContext.restoreGraphicsState()
            let png = NSBitmapImageRep(cgImage: ctx.makeImage()!).representation(using: .png, properties: [:])!
            let name = "status-icon-\(dark ? "dark" : "light")-\(scale)x"
            try? png.write(to: out.appendingPathComponent("\(name).png"))
            print("• \(name).png")
        }
    }
}

@main
struct RenderPages {
    static func main() async {
        // `--pomodoro-only` skips the older pages (quick QA of the 0.1.3 additions).
        if !CommandLine.arguments.contains("--pomodoro-only") { await run() }
        let out = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first(where: { !$0.hasPrefix("--") }) ?? "build/qa/pages", isDirectory: true)
        try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let lang = LanguageSettings.shared
        let saved = lang.language
        await renderPomodoro(out: out)
        renderStatusIcon(out: out)
        lang.language = saved
    }
}
