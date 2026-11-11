import AppKit
import Combine

/// System Settings panes Notch Island points to. Nothing here changes a
/// setting: it only opens the pane, and the user decides there.
enum PrivacyPane: String, CaseIterable {
    case accessibility = "Privacy_Accessibility"
    case screenCapture = "Privacy_ScreenCapture"
    case microphone = "Privacy_Microphone"
    case automation = "Privacy_Automation"
    /// "Paste from Other Apps" (macOS 15.4+ pasteboard privacy).
    case pasteboard = "Privacy_Pasteboard"
    case audioCapture = "Privacy_AudioCapture"

    /// The legacy pane id is still mapped by System Settings on macOS 27
    /// (`legacyBundleIdentifier` of the Privacy & Security extension, anchors
    /// checked against its binary). The extension id and the plain pane are
    /// fallbacks, so the button always opens *something*.
    var urls: [URL] {
        ["x-apple.systempreferences:com.apple.preference.security?\(rawValue)",
         "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?\(rawValue)",
         "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension"].compactMap(URL.init(string:))
    }
}

enum SystemSettingsLink {
    /// Battery (Low Power Mode lives there). New extension id first, then the legacy pane.
    static let battery: [URL] = ["x-apple.systempreferences:com.apple.Battery-Settings.extension",
                                 "x-apple.systempreferences:com.apple.preference.battery"].compactMap(URL.init(string:))
    static let settingsApp = URL(fileURLWithPath: "/System/Applications/System Settings.app")

    /// Tries each URL in order, then System Settings itself. Returns whether anything opened.
    @discardableResult
    static func open(_ urls: [URL], opener: (URL) -> Bool = { NSWorkspace.shared.open($0) }) -> Bool {
        for url in urls where opener(url) { return true }
        return opener(settingsApp)
    }

    @discardableResult
    static func open(_ pane: PrivacyPane, opener: (URL) -> Bool = { NSWorkspace.shared.open($0) }) -> Bool {
        open(pane.urls, opener: opener)
    }
}

/// The "post events" permission used to send ⌘V (paste) and media keys.
///
/// Why the old "Allow…" button seemed dead: `CGRequestPostEventAccess()` shows
/// macOS's request only the first time for an app identity and returns
/// silently afterwards (also after a rebuild with a new ad-hoc signature,
/// whose old entry still sits in the list), and the Settings row read the
/// status once and never refreshed. Now the first press asks macOS, every
/// later press opens Privacy & Security › Accessibility, and the status is
/// re-checked while the user is in System Settings.
@MainActor
final class PostEventAccess: ObservableObject {
    enum Step: Equatable { case nothing, systemPrompt, openSettings }
    enum Feedback: Equatable { case none, prompted, openedSettings, couldNotOpen }

    @Published private(set) var granted: Bool
    @Published private(set) var feedback: Feedback = .none
    /// Granted to an earlier (ad-hoc) build but not to this one.
    @Published private(set) var grantLooksStale = false

    private let defaults: UserDefaults
    private let preflight: () -> Bool
    private let requestSystem: () -> Void
    private let openSettings: () -> Bool
    private let buildID: String?
    private var pollTask: Task<Void, Never>?
    private var activation: NSObjectProtocol?

    /// Same key the media-key setting uses, so both know which build was granted.
    static let grantedBuildKey = "NotchIsland.media.mediaKeysGrantedBuild"
    static let requestedBuildKey = "NotchIsland.postEvents.requestedBuild"

    init(defaults: UserDefaults = .standard,
         preflight: @escaping () -> Bool = { CGPreflightPostEventAccess() },
         requestSystem: @escaping () -> Void = { _ = CGRequestPostEventAccess() },
         openSettings: @escaping () -> Bool = { SystemSettingsLink.open(.accessibility) },
         buildID: String? = SystemMedia.currentBuildID()) {
        self.defaults = defaults
        self.preflight = preflight
        self.requestSystem = requestSystem
        self.openSettings = openSettings
        self.buildID = buildID
        granted = preflight()
        updateStale()
        activation = NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification,
                                                            object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
    }

    deinit {
        pollTask?.cancel()
        if let activation { NotificationCenter.default.removeObserver(activation) }
    }

    /// Pure decision (tests).
    nonisolated static func step(granted: Bool, alreadyRequestedThisBuild: Bool) -> Step {
        if granted { return .nothing }
        return alreadyRequestedThisBuild ? .openSettings : .systemPrompt
    }

    private var requestedThisBuild: Bool {
        guard let buildID else { return defaults.string(forKey: Self.requestedBuildKey) != nil }
        return defaults.string(forKey: Self.requestedBuildKey) == buildID
    }

    /// The user's "Allow…" press. Always has a visible effect.
    func request() {
        refresh()
        switch Self.step(granted: granted, alreadyRequestedThisBuild: requestedThisBuild) {
        case .nothing:
            feedback = .none
        case .systemPrompt:
            defaults.set(buildID ?? "unknown", forKey: Self.requestedBuildKey)
            requestSystem()
            feedback = .prompted
            watch()
        case .openSettings:
            feedback = openSettings() ? .openedSettings : .couldNotOpen
            watch()
        }
    }

    /// The user's "Open Settings" press.
    func showSettings() {
        feedback = openSettings() ? .openedSettings : .couldNotOpen
        watch()
    }

    func refresh() {
        let now = preflight()
        if now != granted { granted = now }
        if now {
            if let buildID { defaults.set(buildID, forKey: Self.grantedBuildKey) }
            feedback = .none
            pollTask?.cancel(); pollTask = nil
        }
        updateStale()
    }

    private func updateStale() {
        let stale = SystemMedia.grantLooksStale(hasAccess: granted, grantedBuild: defaults.string(forKey: Self.grantedBuildKey),
                                                currentBuild: buildID)
        if stale != grantLooksStale { grantLooksStale = stale }
    }

    /// Re-checks once a second for a minute while the user is in System Settings.
    private func watch() {
        pollTask?.cancel()
        pollTask = Task { [weak self] in
            for _ in 0..<60 {
                try? await Task.sleep(for: .seconds(1))
                guard let self, !Task.isCancelled else { return }
                self.refresh()
                if self.granted { return }
            }
        }
    }
}

/// macOS 15.4+ asks before an app reads what *other* apps copied
/// ("Paste from Other Apps"). Clipboard history reads new clipboard contents
/// programmatically, so this setting decides whether it works silently, asks
/// each time, or gets nothing. Reading `accessBehavior` never prompts.
enum PasteboardAccess: Equatable {
    /// Older macOS without pasteboard privacy.
    case unrestricted
    /// macOS will ask the first time (the app isn't listed yet).
    case notAskedYet
    case asks
    case allowed
    case denied

    static func current(_ pasteboard: NSPasteboard = .general) -> PasteboardAccess {
        if #available(macOS 15.4, *) { return from(pasteboard.accessBehavior.rawValue) }
        return .unrestricted
    }

    /// Maps `NSPasteboard.AccessBehavior` raw values (pure, for tests).
    static func from(_ raw: Int) -> PasteboardAccess {
        switch raw {
        case 0: return .notAskedYet
        case 1: return .asks
        case 2: return .allowed
        case 3: return .denied
        default: return .asks
        }
    }

    /// Whether reading other apps' copies can produce anything at all.
    var historyCanRecord: Bool { self != .denied }
    var needsAttention: Bool { self == .notAskedYet || self == .asks || self == .denied }
}
