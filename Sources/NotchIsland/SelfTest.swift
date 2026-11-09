import AppKit

/// `NotchIsland --self-test`: verifies the installed bundle without showing any
/// UI or touching user data/permissions, then exits (used by the DMG checks).
@MainActor
enum SelfTest {
    static func run() -> Int32 {
        var failures: [String] = []
        func check(_ ok: Bool, _ name: String) { if !ok { failures.append(name) } }
        let bundle = Bundle.main
        let expectedID = ProcessInfo.processInfo.environment["NOTCHISLAND_BUNDLE_ID"].flatMap { $0.isEmpty ? nil : $0 }
        check(bundle.bundleIdentifier == (expectedID ?? "local.notchisland.app"), "bundle identifier")
        check(bundle.url(forResource: "NotchIsland", withExtension: "icns") != nil, "app icon")
        for key in ["NSAppleEventsUsageDescription", "NSLocationWhenInUseUsageDescription", "NSCalendarsFullAccessUsageDescription",
                    "NSAudioCaptureUsageDescription", "NSMicrophoneUsageDescription"] {
            check((bundle.object(forInfoDictionaryKey: key) as? String)?.isEmpty == false, "Info.plist \(key)")
        }
        for lproj in ["en", "zh-Hant", "zh-Hans"] {
            check(bundle.path(forResource: "InfoPlist", ofType: "strings", inDirectory: nil, forLocalization: lproj) != nil, "\(lproj).lproj")
        }
        check(LanguageSettings.missingKeys.isEmpty, "localization keys")
        check(LevelAnalyzer(sampleRate: 48_000) != nil, "audio analyser")
        check(ClipboardPolicy.shouldIgnore(types: ["org.nspasteboard.ConcealedType"], frontmostBundleID: nil), "clipboard policy")
        check(FileManager.default.isExecutableFile(atPath: CaptureTool.tool.path), "screencapture tool")
        #if arch(arm64)
        let arch = "arm64"
        #else
        let arch = "x86_64"
        #endif
        let version = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        print(failures.isEmpty ? "SELF-TEST OK (\(arch), version \(version))" : "SELF-TEST FAILED (\(arch)): \(failures.joined(separator: ", "))")
        return failures.isEmpty ? 0 : 1
    }
}
