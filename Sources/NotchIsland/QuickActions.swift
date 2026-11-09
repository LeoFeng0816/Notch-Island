import AppKit
import Security
import UserNotifications

// MARK: - Code identity (why a macOS privacy grant may not apply to this copy)

/// How macOS identifies this copy of the app. Privacy grants (TCC) are stored
/// against the app's designated requirement. An ad-hoc signature's requirement
/// is its exact code hash, so every rebuild or newly installed ad-hoc DMG is a
/// different app to TCC, even though System Settings still shows the old
/// "Notch Island" switch turned on.
struct CodeIdentity: Equatable {
    enum Kind: Equatable { case adHoc, developerID, appleDevelopment, otherCertificate, unsigned, unknown }

    var kind: Kind
    /// Hex code-directory hash (for diagnostics only).
    var cdhash: String?
    var designatedRequirement: String?

    /// TCC grants are pinned to this exact build (cdhash requirement).
    var grantsPinnedToBuild: Bool {
        kind == .adHoc || kind == .unsigned || (designatedRequirement?.hasPrefix("cdhash ") ?? false)
    }

    /// `kSecCodeSignatureAdhoc` = 0x0002 (from <Security/CSCommon.h>).
    static func kind(flags: UInt32?, leafSummary: String?) -> Kind {
        guard let flags else { return .unsigned }
        if flags & 0x0002 != 0 { return .adHoc }
        guard let leaf = leafSummary else { return .unknown }
        if leaf.hasPrefix("Developer ID Application") { return .developerID }
        if leaf.hasPrefix("Apple Development") || leaf.hasPrefix("Mac Developer") { return .appleDevelopment }
        return .otherCertificate
    }

    static func current() -> CodeIdentity {
        var code: SecCode?
        var staticCode: SecStaticCode?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code,
              SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode else {
            return CodeIdentity(kind: .unknown)
        }
        var info: CFDictionary?
        let flags = SecCSFlags(rawValue: kSecCSSigningInformation)
        guard SecCodeCopySigningInformation(staticCode, flags, &info) == errSecSuccess,
              let dict = info as? [String: Any] else { return CodeIdentity(kind: .unknown) }
        let signatureFlags = (dict[kSecCodeInfoFlags as String] as? NSNumber)?.uint32Value
        let leaf = (dict[kSecCodeInfoCertificates as String] as? [SecCertificate])?.first
            .flatMap { SecCertificateCopySubjectSummary($0) as String? }
        let unique = (dict[kSecCodeInfoUnique as String] as? Data)?.map { String(format: "%02x", $0) }.joined()
        var requirement: SecRequirement?
        var text: CFString?
        if SecCodeCopyDesignatedRequirement(staticCode, [], &requirement) == errSecSuccess, let requirement {
            SecRequirementCopyString(requirement, [], &text)
        }
        let isSigned = dict[kSecCodeInfoIdentifier as String] != nil
        return CodeIdentity(kind: isSigned ? kind(flags: signatureFlags ?? 0, leafSummary: leaf) : .unsigned,
                            cdhash: unique, designatedRequirement: text as String?)
    }

    init(kind: Kind, cdhash: String? = nil, designatedRequirement: String? = nil) {
        self.kind = kind
        self.cdhash = cdhash
        self.designatedRequirement = designatedRequirement
    }
}

// MARK: - /usr/sbin/screencapture

/// `/usr/sbin/screencapture` carries `com.apple.private.tcc.check-allow-on-responsible-process`
/// for kTCCServiceScreenCapture: when Notch Island launches it, macOS checks
/// *Notch Island's* screen-recording grant, not the tool's.
enum CaptureTool {
    static let tool = URL(fileURLWithPath: "/usr/sbin/screencapture")
    @MainActor private static var activeProcess: Process?

    enum Exit: Equatable {
        /// Normal exit without a diagnostic. Says nothing about whether an image was taken.
        case finished
        /// The tool itself said the selection was cancelled.
        case cancelled
        /// The tool said captures are not allowed (a privacy or managed-device refusal).
        case refused
        /// The tool couldn't read the screen ("could not create image from …").
        case noImage
        case busy
        /// Exit with a diagnostic we don't recognise, or killed by a signal.
        case failed(Int32)
    }

    /// Every diagnostic below is a literal string inside macOS 27's
    /// /usr/sbin/screencapture or screencaptureui (checked with `strings`).
    static func classify(status: Int32, reason: Process.TerminationReason, diagnostic: String) -> Exit {
        guard reason == .exit else { return .failed(status) }
        let message = diagnostic.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if message.contains("cannot run two interactive screen captures") ||
            message.contains("screen recording is already running") ||
            message.contains("two interactive screen recordings requested") { return .busy }
        if message.contains("screencapture not allowed") || message.contains("screenshots are not allowed") { return .refused }
        if message.contains("could not create image from") { return .noImage }
        if message.contains("no selection to capture") || message == "canceled" || message == "cancelled" { return .cancelled }
        if message.isEmpty {
            // Esc ends interactive mode without an image; callers check the result itself.
            return status == 0 || status == 1 ? .finished : .failed(status)
        }
        return .failed(status)
    }

    @MainActor
    static func run(_ arguments: [String], completion: @escaping @MainActor (Exit) -> Void) {
        guard activeProcess == nil else { completion(.busy); return }
        let process = Process()
        let diagnostics = Pipe()
        process.executableURL = tool
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = diagnostics
        process.standardError = diagnostics
        process.terminationHandler = { finished in
            // Diagnostics are short status lines; never read more than 4 KB.
            let data = (try? diagnostics.fileHandleForReading.read(upToCount: 4096)) ?? Data()
            let result = classify(status: finished.terminationStatus, reason: finished.terminationReason,
                                  diagnostic: String(decoding: data, as: UTF8.self))
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    activeProcess = nil
                    completion(result)
                }
            }
        }
        do {
            try process.run()
            activeProcess = process
        } catch {
            completion(.failed(-1))
        }
    }
}

/// What a refused/failed capture most likely means, from facts we can read
/// without prompting: the TCC preflight for this copy and its signature.
enum CaptureAdvice: Equatable {
    /// Not granted to this copy, and it is ad-hoc signed: a grant given to an
    /// earlier build/DMG does not apply. (Likely, not certain.)
    case grantProbablyForAnotherBuild
    /// Not granted to this copy.
    case notGranted
    /// macOS reports the grant is present, yet the tool failed: cause unknown.
    case grantedButFailed

    static func from(screenCaptureAllowed: Bool, identity: CodeIdentity) -> CaptureAdvice {
        if screenCaptureAllowed { return .grantedButFailed }
        return identity.grantsPinnedToBuild ? .grantProbablyForAnotherBuild : .notGranted
    }
}

enum ScreenshotAction {
    enum Outcome: Equatable {
        case copied, cancelled, busy
        /// Only for an explicit refusal or an unreadable screen; never for Esc.
        case refused(CaptureAdvice)
        case noImage(CaptureAdvice)
        case failed(Int32)
    }

    static let arguments = ["-i", "-J", "selection", "-c"]

    /// `screenCaptureAllowed` is only used to *explain* a failure the tool
    /// reported; it never turns a cancel or a success into a permission error.
    static func classify(_ exit: CaptureTool.Exit, changeCountBefore: Int, changeCountAfter: Int,
                         clipboardHasImage: Bool, screenCaptureAllowed: Bool, identity: CodeIdentity) -> Outcome {
        let advice = { CaptureAdvice.from(screenCaptureAllowed: screenCaptureAllowed, identity: identity) }
        switch exit {
        case .finished, .cancelled:
            return changeCountAfter != changeCountBefore && clipboardHasImage ? .copied : .cancelled
        case .refused: return .refused(advice())
        case .noImage: return .noImage(advice())
        case .busy: return .busy
        case .failed(let status): return .failed(status)
        }
    }

    @MainActor
    static func run(pasteboard: NSPasteboard = .general, completion: @escaping @MainActor (Outcome) -> Void) {
        let before = pasteboard.changeCount
        CaptureTool.run(arguments) { exit in
            let after = pasteboard.changeCount
            // Only the pasteboard's types are inspected, never its contents.
            let hasImage = after != before && pasteboard.canReadItem(withDataConformingToTypes: ["public.png", "public.tiff"])
            completion(classify(exit, changeCountBefore: before, changeCountAfter: after, clipboardHasImage: hasImage,
                                screenCaptureAllowed: CGPreflightScreenCaptureAccess(), identity: .current()))
        }
    }
}

// MARK: - Screen recording entry points

enum ScreenRecordingAction {
    static let screenshotApp = URL(fileURLWithPath: "/System/Applications/Utilities/Screenshot.app", isDirectory: true)
    static let quickTimeID = "com.apple.QuickTimePlayerX"
    /// Toolbar starts in video mode (`-J video`); the user still clicks Record.
    /// The recording runs inside screencapture under Notch Island's grant.
    static let recordingArguments = ["-i", "-U", "-J", "video", "-p"]
    /// QuickTime Player has its own screen-capture entitlement and opens the
    /// system recording toolbar; this needs only Automation consent for QuickTime.
    static let quickTimeScript = "tell application id \"\(quickTimeID)\" to new screen recording"

    enum Route: Equatable {
        /// screencapture's toolbar in video mode (needs this copy's screen-recording grant).
        case captureToolbar
        /// Ask first: explains the missing grant and offers QuickTime / Screenshot / Settings.
        case askForFallback
    }

    /// Without this copy's grant, a direct recording could fail or record only
    /// the desktop, so the toolbar is only used when macOS reports the grant.
    static func route(screenCaptureAllowed: Bool) -> Route {
        screenCaptureAllowed ? .captureToolbar : .askForFallback
    }

    enum QuickTimeResult: Equatable { case requested, automationDenied, notInstalled, failed }

    /// osascript reports Apple Event errors on stderr, e.g. "… (-1743)".
    static func classifyQuickTime(status: Int32, diagnostic: String) -> QuickTimeResult {
        if status == 0 { return .requested }
        if diagnostic.contains("(-1743)") || diagnostic.contains("(-1744)") { return .automationDenied }
        if diagnostic.contains("(-10814)") || (diagnostic.contains("(-2700)") && diagnostic.contains("find application")) { return .notInstalled }
        return .failed
    }

    static var quickTimeInstalled: Bool {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: quickTimeID) != nil
    }

    /// Asks QuickTime to open its recording toolbar. macOS shows its own
    /// Automation prompt the first time; the user decides.
    @MainActor
    static func openQuickTimeRecording(completion: @escaping @MainActor (QuickTimeResult) -> Void) {
        guard quickTimeInstalled else { completion(.notInstalled); return }
        let process = Process()
        let errors = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", quickTimeScript]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = errors
        process.terminationHandler = { finished in
            let data = (try? errors.fileHandleForReading.read(upToCount: 2048)) ?? Data()
            let result = classifyQuickTime(status: finished.terminationStatus, diagnostic: String(decoding: data, as: UTF8.self))
            DispatchQueue.main.async { MainActor.assumeIsolated { completion(result) } }
        }
        do { try process.run() } catch { completion(.failed) }
    }

    @MainActor
    static func openSystemToolbar() async throws {
        _ = try await NSWorkspace.shared.openApplication(at: screenshotApp, configuration: .init())
    }

    static let screenRecordingSettings = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!
}

// MARK: - Diagnostics (`--capture-diagnostics`)

/// Prints facts only (no prompts, no capture): signature, TCC preflights.
/// Launch through LaunchServices so macOS attributes the checks to this app:
/// `open -W build/NotchIsland.app --args --capture-diagnostics --diagnostics-output /tmp/x.txt`
@MainActor
enum CaptureDiagnostics {
    static func report() -> String {
        let identity = CodeIdentity.current()
        let bundle = Bundle.main
        var lines = [
            "bundle=\(bundle.bundleIdentifier ?? "?") version=\(bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?")",
            "path=\(bundle.bundlePath)",
            "signature=\(identity.kind) cdhash=\(identity.cdhash ?? "-")",
            "designatedRequirement=\(identity.designatedRequirement ?? "-")",
            "grantsPinnedToBuild=\(identity.grantsPinnedToBuild)",
            "screenCapturePreflight=\(CGPreflightScreenCaptureAccess())",
            "postEventPreflight=\(CGPreflightPostEventAccess())",
            "accessibilityTrusted=\(AXIsProcessTrusted())",
        ]
        lines.append("advice=\(CaptureAdvice.from(screenCaptureAllowed: CGPreflightScreenCaptureAccess(), identity: identity))")
        return lines.joined(separator: "\n")
    }

    static func run(arguments: [String]) -> Int32 {
        let text = report() + "\n"
        if let index = arguments.firstIndex(of: "--diagnostics-output"), arguments.indices.contains(index + 1) {
            let url = URL(fileURLWithPath: arguments[index + 1])
            do { try text.write(to: url, atomically: true, encoding: .utf8) } catch { return 1 }
        } else {
            print(text, terminator: "")
        }
        return 0
    }
}

/// Optional system notifications (only if the user allowed them in onboarding/settings).
enum IslandNotifier {
    static func requestAuthorization(completion: @escaping (Bool) -> Void) {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { granted, _ in
            DispatchQueue.main.async { completion(granted) }
        }
    }

    static func authorizationStatus(completion: @escaping (UNAuthorizationStatus) -> Void) {
        UNUserNotificationCenter.current().getNotificationSettings { settings in
            DispatchQueue.main.async { completion(settings.authorizationStatus) }
        }
    }

    /// Posts only when already authorized; never prompts.
    static func post(title: String, body: String) {
        let center = UNUserNotificationCenter.current()
        center.getNotificationSettings { settings in
            guard settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional else { return }
            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            center.add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
        }
    }
}
