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

@MainActor func render<V: View>(_ view: V, _ name: String, out: URL) {
    let framed = view.frame(width: 540, height: 210).padding(20).background(Color.black).environment(\.colorScheme, .dark)
    let renderer = ImageRenderer(content: framed)
    renderer.scale = 2
    guard let image = renderer.nsImage, let tiff = image.tiffRepresentation,
          let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) else { print("✗ \(name)"); return }
    try? png.write(to: out.appendingPathComponent("\(name).png"))
    print("• \(name).png")
}

@MainActor func run() async {
    let out = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? "build/qa/pages", isDirectory: true)
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
    for (language, code) in [(AppLanguage.english, "en"), (.traditionalChinese, "zh-Hant"), (.simplifiedChinese, "zh-Hans")] {
        lang.language = language
        render(QuickActionsBar(model: model, lang: lang), "\(code)-quick-actions", out: out)
        let statuses: [(ControlCenterMedia.MusicRecognitionResult?, String)] = [(nil, "idle"), (.listening, "listening"), (.uncertain, "uncertain"),
                                                                              (.permissionNeeded, "needs-ax"), (.notInControlCenter, "missing")]
        for (status, name) in statuses {
            render(ShazamPage(model: model, lang: lang, systemStatus: status).environmentObject(shazam), "\(code)-shazam-\(name)", out: out)
        }
        // AudD: no consent → ready → listening → matched (synthetic tone, mocked AudD).
        let store = MemorySecretStore()
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

@main
struct RenderPages {
    static func main() async { await run() }
}
