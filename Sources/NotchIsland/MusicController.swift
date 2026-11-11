import AppKit
import Combine

/// Reads and controls Apple Music / Spotify through Apple Events, plus (opt-in)
/// YouTube / YouTube Music tabs in Chrome or Safari via `BrowserMedia`.
///
/// Public macOS APIs do not expose the system-wide "Now Playing" session, so
/// this intentionally supports only these sources. Apps are never launched:
/// scripts run only while they are open, and nothing is played or changed
/// unless the user presses a control.
@MainActor
final class MusicController: ObservableObject {
    enum Source: String {
        case music, spotify, chrome, safari
        /// System Now Playing via MediaRemote (only where macOS provides it).
        case system

        var bundleID: String {
            switch self {
            case .system: return ""
            case .music: return "com.apple.Music"
            case .spotify: return "com.spotify.client"
            case .chrome: return BrowserMedia.Browser.chrome.bundleID
            case .safari: return BrowserMedia.Browser.safari.bundleID
            }
        }

        var browser: BrowserMedia.Browser? {
            switch self {
            case .chrome: return .chrome
            case .safari: return .safari
            default: return nil
            }
        }

        init(_ browser: BrowserMedia.Browser) { self = browser == .chrome ? .chrome : .safari }
    }

    struct Track: Equatable {
        var title: String
        var artist: String
        var album: String
        var duration: TimeInterval?
    }

    @Published private(set) var source: Source?
    @Published private(set) var track: Track?
    @Published private(set) var isPlaying = false
    @Published private(set) var artwork: NSImage? {
        // Album-cover colours for the music gradient and level bars (local, 24×24 sample).
        didSet { if artwork !== oldValue { palette = artwork.flatMap(ArtworkPalette.extract(from:)) } }
    }
    @Published private(set) var palette: ArtworkPalette?
    @Published private(set) var permissionDenied = false
    /// Player position at `positionDate`; the UI extrapolates while playing.
    @Published private(set) var position: TimeInterval?
    @Published private(set) var positionDate = Date()
    @Published private(set) var trackIdentity = ""
    @Published private(set) var seekFailed = false
    private var browserVideoID: String?
    private var trackTransition = BrowserMedia.TrackTransition()
    private var timeResolver = BrowserMedia.TimeResolver()
    /// Whose timelines `timeResolver` remembers ("chrome|<window>/<tab>|youtubeMusic").
    private var resolverOwner: String?

    /// One time resolver per playing tab; any other source starts fresh.
    nonisolated static func timelineOwner(source: Source, tab: (ref: String, site: BrowserMedia.Site)?) -> String {
        guard source.browser != nil, let tab else { return source.rawValue }
        return "\(source.rawValue)|\(tab.ref)|\(tab.site.rawValue)"
    }
    /// Site of the current browser source (nil for Music/Spotify).
    @Published private(set) var browserSite: BrowserMedia.Site?
    /// Per-browser problems found during the last scan (shown as onboarding hints).
    @Published private(set) var browserIssues: [BrowserMedia.Browser: BrowserMedia.Issue] = [:]
    /// Browsers the user opted into (off by default; persisted).
    @Published private(set) var enabledBrowsers: Set<BrowserMedia.Browser>
    /// Whether a control could not be delivered (e.g. tab closed); cleared on next refresh.
    @Published private(set) var lastControlFailed = false
    /// Last scan per browser: counts only (no URLs/titles), shown in Settings.
    @Published private(set) var browserDiagnostics: [BrowserMedia.Browser: BrowserMedia.Diagnostics] = [:]

    /// Progress samples between scans; only touched on `scriptQueue`.
    private final class HistoryBox: @unchecked Sendable { var value = BrowserMedia.History() }
    private let history = HistoryBox()

    /// Read system Now Playing (MediaRemote) when macOS provides it. Default on.
    @Published private(set) var useSystemNowPlaying: Bool
    /// Send playback controls as system media keys (needs the post-events permission). Default off.
    @Published private(set) var useMediaKeys: Bool
    @Published private(set) var useControlCenter: Bool
    @Published private(set) var controlCenterAccess = false
    @Published private(set) var controlCenterBusy = false
    @Published private(set) var controlCenterResult: ControlCenterMedia.Result?
    /// Whether the last MediaRemote query returned data.
    @Published private(set) var systemNowPlayingWorks = false
    /// Name of the app that owns the system Now Playing session (when known).
    @Published private(set) var systemAppName: String?
    /// Cached `CGPreflightPostEventAccess()` (re-checked on refresh).
    @Published private(set) var mediaKeyAccess = false

    private let defaults: UserDefaults
    private static let browsersKey = "NotchIsland.media.browsers"
    private static let systemKey = "NotchIsland.media.systemNowPlaying"
    private static let mediaKeysKey = "NotchIsland.media.mediaKeys"
    private static let controlCenterKey = "NotchIsland.media.controlCenter"
    private let controlCenterQueue = DispatchQueue(label: "NotchIsland.ControlCenter", qos: .userInitiated)
    private var browserTab: (BrowserMedia.Browser, String, BrowserMedia.Site)?
    private var artworkURL: URL?
    private var systemArtwork: Data?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        enabledBrowsers = Set((defaults.stringArray(forKey: Self.browsersKey) ?? []).compactMap(BrowserMedia.Browser.init(rawValue:)))
        useSystemNowPlaying = defaults.object(forKey: Self.systemKey) as? Bool ?? true
        useMediaKeys = defaults.bool(forKey: Self.mediaKeysKey)
        useControlCenter = defaults.bool(forKey: Self.controlCenterKey)
        mediaKeyAccess = SystemMedia.canPostEvents
        controlCenterAccess = ControlCenterMedia.hasAccess
    }

    func setUseControlCenter(_ on: Bool) {
        useControlCenter = on
        defaults.set(on, forKey: Self.controlCenterKey)
        controlCenterResult = nil
        if on && !ControlCenterMedia.hasAccess { ControlCenterMedia.requestAccess() }
        recheckControlCenterAccess()
    }

    func recheckControlCenterAccess() {
        let access = ControlCenterMedia.hasAccess
        if controlCenterAccess != access { controlCenterAccess = access }
    }

    var showsSystemControls: Bool { useControlCenter || (useMediaKeys && mediaKeyAccess) }

    private var currentControlRoute: ControlRoute {
        let tab = browserTab.flatMap { enabledBrowsers.contains($0.0) ? $0 : nil }
        return Self.controlRoute(source: source, useMediaKeys: useMediaKeys, hasMediaKeyAccess: mediaKeyAccess,
                                 hasBrowserTab: tab != nil, useControlCenter: useControlCenter, browserSite: tab?.2)
    }

    var routesThroughControlCenter: Bool { currentControlRoute == .controlCenter }

    var controlCenterFeedback: L10nKey? {
        switch controlCenterResult {
        case .permissionNeeded: return .controlCenterPermission
        case .unavailable: return .controlCenterUnavailable
        case .playerUnavailable: return .skipUnavailable
        case .uncertain: return .controlCenterUncertain
        case .sent, nil: return nil
        }
    }

    func setUseSystemNowPlaying(_ on: Bool) {
        useSystemNowPlaying = on
        defaults.set(on, forKey: Self.systemKey)
        refresh()
    }

    /// Turning media keys on is the explicit action that shows the permission request.
    func setUseMediaKeys(_ on: Bool) {
        useMediaKeys = on
        defaults.set(on, forKey: Self.mediaKeysKey)
        if on && !SystemMedia.canPostEvents { SystemMedia.requestPostEventAccess() }
        updateMediaKeyAccess()
    }

    func recheckMediaKeyAccess() { updateMediaKeyAccess() }

    /// True when the post-events permission was granted to an earlier build
    /// (ad-hoc signature changed on rebuild) — explains a "lost" permission.
    @Published private(set) var mediaKeyGrantStale = false
    private static let grantedBuildKey = "NotchIsland.media.mediaKeysGrantedBuild"
    private let currentBuild = SystemMedia.currentBuildID()

    private func updateMediaKeyAccess() {
        let access = SystemMedia.canPostEvents
        if mediaKeyAccess != access { mediaKeyAccess = access }
        if access, let currentBuild { defaults.set(currentBuild, forKey: Self.grantedBuildKey) }
        let stale = SystemMedia.grantLooksStale(hasAccess: access, grantedBuild: defaults.string(forKey: Self.grantedBuildKey),
                                                currentBuild: currentBuild)
        if mediaKeyGrantStale != stale { mediaKeyGrantStale = stale }
    }

    /// Which path a control takes (pure, for tests and the Settings explanation).
    enum ControlRoute: Equatable { case controlCenter, mediaKey, mediaRemote, appleScript, browserScript, unavailable }

    nonisolated static func controlRoute(source: Source?, useMediaKeys: Bool, hasMediaKeyAccess: Bool,
                                         hasBrowserTab: Bool, useControlCenter: Bool = false,
                                         browserSite: BrowserMedia.Site? = nil) -> ControlRoute {
        if source?.browser != nil && hasBrowserTab && browserSite == .youtubeMusic { return .browserScript }
        if useControlCenter { return .controlCenter }
        // Media keys go to whatever macOS considers "Now Playing", like the keyboard keys.
        if useMediaKeys && hasMediaKeyAccess { return .mediaKey }
        switch source {
        case .system: return .mediaRemote
        case .music, .spotify: return .appleScript
        case .chrome, .safari: return hasBrowserTab ? .browserScript : .unavailable
        case nil: return .unavailable
        }
    }

    func setBrowser(_ browser: BrowserMedia.Browser, enabled: Bool) {
        if enabled { enabledBrowsers.insert(browser) } else { enabledBrowsers.remove(browser); browserIssues[browser] = nil }
        defaults.set(BrowserMedia.Browser.allCases.filter(enabledBrowsers.contains).map(\.rawValue), forKey: Self.browsersKey)
        // Turning it on is the user action that may show the Automation prompt (once).
        if enabled && browser.isRunning {
            requestAutomation(for: browser) { [weak self] _ in self?.refresh() }
        } else {
            refresh()
        }
    }

    /// Asks macOS for Automation permission (shows the system prompt once).
    /// Only called from an explicit user action in Settings.
    func requestAutomation(for browser: BrowserMedia.Browser, completion: @escaping (BrowserMedia.Permission) -> Void) {
        scriptQueue.async {
            let result = BrowserMedia.automationPermission(for: browser, askIfNeeded: true)
            DispatchQueue.main.async { completion(result) }
        }
    }

    /// Non-prompting check for the Settings status line.
    func checkAutomation(for browser: BrowserMedia.Browser, completion: @escaping (BrowserMedia.Permission) -> Void) {
        scriptQueue.async {
            let result = BrowserMedia.automationPermission(for: browser, askIfNeeded: false)
            DispatchQueue.main.async { completion(result) }
        }
    }

    private let scriptQueue = DispatchQueue(label: "NotchIsland.AppleScript", qos: .userInitiated)
    private var pollTask: Task<Void, Never>?
    private var artworkKey: String?
    private var observers: [NSObjectProtocol] = []
    private var refreshInFlight = false
    private var tabReadInFlight = false
    private var lastDiscoveryRequest = -Double.infinity
    /// A refresh was requested while one was running: run again right after
    /// (previously such requests — e.g. the one after a control — were dropped).
    private var refreshQueued = false

    // Control pipeline
    private(set) var tracker = PlaybackCommandTracker()
    /// Requested play state while a command is unconfirmed (button shows it as pending).
    @Published private(set) var pendingPlaying: Bool?
    @Published private(set) var controlPending = false
    /// Outcome of the last finished command (failed / no visible effect), for a hint.
    @Published private(set) var controlOutcome: PlaybackCommandTracker.Outcome = .none
    private var confirmTask: Task<Void, Never>?
    /// Latest issued command id, readable from the script queue (coalescing).
    private let latestCommand = LatestCommandID()
    /// Newest sample applied, so an older scan result can't overwrite a newer read-back.
    private var lastSampledAt = Date.distantPast
    nonisolated static let scriptCache = CompiledScriptCache()

    /// What the play button shows: the request while pending, else the player's state.
    var displayedIsPlaying: Bool { tracker.displayedPlaying(observed: isPlaying) }

    func start() {
        let distributed = DistributedNotificationCenter.default()
        for name in ["com.apple.Music.playerInfo", "com.spotify.client.PlaybackStateChanged"] {
            observers.append(distributed.addObserver(forName: Notification.Name(name), object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.refresh() }
            })
        }
        let workspace = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification] {
            observers.append(workspace.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.refresh() }
            })
        }
        // Native players send notifications. Browsers don't: sample the known
        // tab between discovery scans, including when that tab is paused.
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                self?.pollPlayback()
                try? await Task.sleep(for: .milliseconds(550))
            }
        }
    }

    private func pollPlayback() {
        guard !refreshInFlight, !tabReadInFlight else { return }
        let uptime = ProcessInfo.processInfo.systemUptime
        let discoveryInterval = enabledBrowsers.isEmpty ? 3.0 : (browserTab != nil && isPlaying ? 2.75 : 1.1)
        if uptime - lastDiscoveryRequest >= discoveryInterval {
            refresh()
        } else if let (browser, ref, site) = browserTab {
            readTab(browser, ref: ref, site: site)
        }
    }

    // MARK: Controls

    func playPause() { control(.playPause) }
    func nextTrack() { control(.next) }
    func previousTrack() { control(.previous) }

    func openAutomationSettings() {
        SystemSettingsLink.open(.automation)
    }

    var canSeek: Bool {
        guard let duration = track?.duration, duration.isFinite, duration > 0, position != nil else { return false }
        return browserTab != nil || source == .music || source == .spotify
    }

    func seek(to seconds: TimeInterval, trackIdentity: String) {
        guard trackIdentity == self.trackIdentity, canSeek, let track, let duration = track.duration,
              let source, seconds.isFinite else { return }
        seekFailed = false
        let target = min(max(seconds, 0), duration)
        let tab = browserTab
        let script: String
        if let (browser, ref, site) = tab {
            guard let js = BrowserMedia.seekJS(seconds: target, duration: duration, videoID: browserVideoID, title: track.title),
                  let command = BrowserMedia.controlScript(for: browser, ref: ref, js: js, readBack: true, site: site)
            else { return }
            script = command
        } else {
            let title = BrowserMedia.appleScriptString(track.title)
            let artist = BrowserMedia.appleScriptString(track.artist)
            let album = BrowserMedia.appleScriptString(track.album)
            script = """
            tell application id "\(source.bundleID)"
                with timeout of \(BrowserMedia.controlTimeout) seconds
                    if player state is stopped then return "none"
                    set t to current track
                    if (name of t as text) is not \(title) or (artist of t as text) is not \(artist) then return "none"
                    if (album of t as text) is not \(album) then return "none"
                    set player position to \(target)
                    return "ok"
                end timeout
            end tell
            """
        }
        scriptQueue.async { [weak self] in
            let permitted = tab.map { BrowserMedia.automationPermission(for: $0.0, askIfNeeded: false) == .granted }
                ?? Self.isRunning(source)
            let output = permitted ? (try? Self.run(script).get().stringValue) ?? nil : nil
            let result = BrowserMedia.parseControlResult(output ?? "")
            let sampledAt = Date()
            let tabState = tab.flatMap { browser, ref, site in
                result.stateJSON.flatMap { BrowserMedia.parseState($0, browser: browser, ref: ref, site: site, tabTitle: track.title) }
            }
            DispatchQueue.main.async { [weak self] in
                guard let self, self.trackIdentity == trackIdentity else { return }
                self.controlCenterResult = nil
                self.seekFailed = !BrowserMedia.controlSucceeded(result.result)
                if let tabState { self.applyTabObservation(tabState, sampledAt: sampledAt) }
                if let (browser, ref, site) = tab { self.readTab(browser, ref: ref, site: site) }
                else { self.refresh() }
            }
        }
    }

    /// Press → command. The button reacts at once (pending state), the command
    /// is sent on the fastest available path, and the result is confirmed from
    /// real observations; nothing is shown as done before the player reports it.
    private func control(_ kind: PlaybackCommandTracker.Kind) {
        guard !controlCenterBusy else { return }
        updateMediaKeyAccess()
        // The known YouTube Music tab is the exact playback target, even when
        // the system panel does not expose controls for its web app.
        let route = currentControlRoute
        if route == .controlCenter {
            sendToControlCenter(kind)
            return
        }
        controlCenterResult = nil
        guard route != .unavailable else {
            lastControlFailed = source != nil
            controlOutcome = source != nil ? .failed : .none
            return
        }
        let now = Date()
        let estimatedPosition = position.map { $0 + (isPlaying ? max(0, now.timeIntervalSince(positionDate)) : 0) }
        let command = tracker.issue(kind, observedPlaying: isPlaying, trackKey: trackIdentity, now: now,
                                    position: browserSite == .youtubeMusic ? estimatedPosition : nil)
        latestCommand.set(command.id)
        lastControlFailed = false
        publishTracker()
        let intent = Self.intent(for: kind, expectedPlaying: command.expectedPlaying, route: route)

        switch route {
        case .mediaKey:
            // Posting the key is synchronous and immediate (main thread).
            let key: SystemMedia.MediaKey = kind == .playPause ? .playPause : (kind == .next ? .next : .previous)
            finishDelivery(command.id, success: SystemMedia.press(key))
            // Without a readable source the result can't be confirmed: don't show a guessed state.
            if source == nil { tracker.cancel(); publishTracker() }
            startConfirmation(target: nil)
        case .mediaRemote:
            finishDelivery(command.id, success: SystemMedia.sendCommand(intent))
            startConfirmation(target: nil)
        case .appleScript:
            guard let source else { return }
            let verb: String
            switch intent {
            case .play: verb = "play"
            case .pause: verb = "pause"
            case .next: verb = "next track"
            case .previous: verb = "previous track"
            case .playPause: verb = "playpause"
            }
            let script = "tell application id \"\(source.bundleID)\"\nwith timeout of \(BrowserMedia.controlTimeout) seconds\n\(verb)\nend timeout\nend tell"
            let latest = latestCommand
            scriptQueue.async { [weak self] in
                // Coalesce: a newer play/pause press replaces one that hasn't been sent yet.
                if kind == .playPause, latest.value != command.id {
                    DispatchQueue.main.async { MainActor.assumeIsolated { _ = self?.tracker.delivered(command.id, success: true, now: Date()) } }
                    return
                }
                let ok: Bool
                if case .success = Self.run(script) { ok = true } else { ok = false }
                // Read back right away in the same queue turn (no waiting for the poll).
                let readBack = ok ? (try? Self.fetch(source).get()) ?? nil : nil
                DispatchQueue.main.async { [weak self] in
                    MainActor.assumeIsolated {
                        guard let self else { return }
                        self.finishDelivery(command.id, success: ok)
                        if let readBack { self.applyObservation(readBack) }
                        self.startConfirmation(target: nil)
                    }
                }
            }
        case .browserScript:
            guard let (browser, ref, site) = browserTab,
                  let script = BrowserMedia.controlScript(for: browser, ref: ref, js: BrowserMedia.controlJS(intent, site: site),
                                                          readBack: true, site: site)
            else { return }
            let pwaTitle = useControlCenter && browser == .chrome && site == .youtubeMusic && kind != .playPause ? track?.title : nil
            let latest = latestCommand
            scriptQueue.async { [weak self] in
                if kind == .playPause, latest.value != command.id {
                    DispatchQueue.main.async { MainActor.assumeIsolated { _ = self?.tracker.delivered(command.id, success: true, now: Date()) } }
                    return
                }
                let output: String?
                if BrowserMedia.automationPermission(for: browser, askIfNeeded: false) == .granted,
                   case .success(let descriptor) = Self.run(script) { output = descriptor.stringValue } else { output = nil }
                let sampled = Date()
                let parsed = output.map(BrowserMedia.parseControlResult)
                // A fallback is safe only if the script found the tab in an
                // installed web app and explicitly took no action.
                let fallback = if parsed?.result == "none-standalone", let pwaTitle {
                    YouTubeMusicTransport.send(kind == .next ? .next : .previous, expectedTitle: pwaTitle)
                } else {
                    YouTubeMusicTransport.Result.unavailable
                }
                let ok = parsed.map { BrowserMedia.controlSucceeded($0.result) } == true || fallback == .sent
                let state = parsed?.stateJSON.flatMap {
                    BrowserMedia.parseState($0, browser: browser, ref: ref, site: site, tabTitle: "")
                }
                DispatchQueue.main.async { [weak self] in
                    MainActor.assumeIsolated {
                        guard let self else { return }
                        self.finishDelivery(command.id, success: ok)
                        if parsed?.result == "ok", let state { self.applyTabObservation(state, sampledAt: sampled) }
                        if fallback == .uncertain { self.controlCenterResult = .uncertain }
                        self.startConfirmation(target: ok ? (browser, ref, site) : nil)
                    }
                }
            }
        case .controlCenter, .unavailable:
            break
        }
    }

    private func sendToControlCenter(_ kind: PlaybackCommandTracker.Kind) {
        recheckControlCenterAccess()
        confirmTask?.cancel()
        tracker.cancel()
        publishTracker()
        lastControlFailed = false
        controlCenterResult = nil
        controlCenterBusy = true
        let command: ControlCenterMedia.Command = kind == .playPause ? .playPause : (kind == .next ? .next : .previous)
        let key: SystemMedia.MediaKey = kind == .playPause ? .playPause : (kind == .next ? .next : .previous)
        let findYouTubeMusic = kind != .playPause && !isPlaying && enabledBrowsers.contains(.chrome)
        controlCenterQueue.async { [weak self] in
            let pwa = findYouTubeMusic ? YouTubeMusicTransport.send(kind == .next ? .next : .previous) : .unavailable
            let result: ControlCenterMedia.Result = switch pwa {
            case .sent: .sent
            case .uncertain: .uncertain
            case .blocked: .playerUnavailable
            case .unavailable: ControlCenterMedia.send(command)
            }
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.controlCenterBusy = false
                guard self.useControlCenter else { return }
                // Fall back only if AX definitely didn't press a transport
                // button. Retrying an uncertain toggle could undo the first.
                let canFallback = pwa == .unavailable && (result == .unavailable || result == .permissionNeeded)
                let sentKey = canFallback && self.useMediaKeys && SystemMedia.press(key)
                self.controlCenterResult = sentKey ? .sent : result
                self.recheckControlCenterAccess()
                self.refresh()
            }
        }
    }

    /// Explicit play/pause where the path supports it (idempotent); media keys only toggle.
    nonisolated static func intent(for kind: PlaybackCommandTracker.Kind, expectedPlaying: Bool?,
                                   route: ControlRoute) -> BrowserMedia.Command {
        switch kind {
        case .next: return .next
        case .previous: return .previous
        case .playPause:
            guard route != .mediaKey, let expected = expectedPlaying else { return .playPause }
            return expected ? .play : .pause
        }
    }

    private func finishDelivery(_ id: Int, success: Bool) {
        let outcome = tracker.delivered(id, success: success, now: Date())
        if outcome == .failed { lastControlFailed = true }
        publishTracker()
    }

    private func publishTracker() {
        let pending = tracker.pending?.expectedPlaying
        if pendingPlaying != pending { pendingPlaying = pending }
        if controlPending != tracker.isPending { controlPending = tracker.isPending }
        if controlOutcome != tracker.lastOutcome { controlOutcome = tracker.lastOutcome }
        if tracker.lastOutcome == .failed { lastControlFailed = true }
    }

    /// Quick follow-up reads until the player is seen in the requested state
    /// (or the window expires). A browser command re-reads only its own tab,
    /// which is much cheaper than a full scan.
    static let confirmationDelays: [Double] = [0.15, 0.35, 0.7, 1.2, 1.9, 2.7]

    private func startConfirmation(target: (BrowserMedia.Browser, String, BrowserMedia.Site)?) {
        confirmTask?.cancel()
        guard tracker.isPending else {
            // Nothing to confirm (e.g. media key with no readable source): one refresh soon.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in MainActor.assumeIsolated { self?.refresh() } }
            return
        }
        confirmTask = Task { [weak self] in
            var elapsed = 0.0
            for delay in Self.confirmationDelays {
                try? await Task.sleep(for: .milliseconds(Int((delay - elapsed) * 1000)))
                elapsed = delay
                guard let self, !Task.isCancelled else { return }
                _ = self.tracker.expireIfNeeded(now: Date())
                self.publishTracker()
                guard self.tracker.isPending else { return }
                if let (browser, ref, site) = target { self.readTab(browser, ref: ref, site: site) } else { self.refresh() }
            }
            try? await Task.sleep(for: .milliseconds(Int((PlaybackCommandTracker.confirmWindow + 0.3) * 1000)))
            guard let self, !Task.isCancelled else { return }
            _ = self.tracker.expireIfNeeded(now: Date())
            self.publishTracker()
        }
    }

    private func readTab(_ browser: BrowserMedia.Browser, ref: String, site: BrowserMedia.Site) {
        guard !refreshInFlight, !tabReadInFlight, enabledBrowsers.contains(browser), browser.isRunning,
              let script = BrowserMedia.readTabScript(for: browser, ref: ref) else { return }
        tabReadInFlight = true
        let historyBox = history
        scriptQueue.async { [weak self] in
            let output: String?
            if BrowserMedia.automationPermission(for: browser, askIfNeeded: false) == .granted,
               case .success(let descriptor) = Self.run(script) { output = descriptor.stringValue }
            else { output = nil }
            let sampled = Date()
            let parsed = BrowserMedia.parseControlResult(output ?? "")
            let state = parsed.stateJSON.flatMap { BrowserMedia.parseState($0, browser: browser, ref: ref, site: site, tabTitle: "") }
            let playing = state.map {
                let progress = BrowserMedia.progress(of: $0, history: &historyBox.value, now: sampled)
                return BrowserMedia.isEffectivelyPlaying($0, progress: progress)
            }
            DispatchQueue.main.async { [weak self] in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.tabReadInFlight = false
                    guard self.enabledBrowsers.contains(browser),
                          let current = self.browserTab, current.0 == browser, current.1 == ref else { return }
                    if let state { self.applyTabObservation(state, sampledAt: sampled, effectivePlaying: playing) }
                    else if parsed.result == "gone" || parsed.result == "blocked" {
                        self.tracker.cancel()
                        self.publishTracker()
                        self.refresh()
                    }
                }
            }
        }
    }

    /// A read of the currently shown browser tab (read-back or targeted read).
    private func applyTabObservation(_ tab: BrowserMedia.TabState, sampledAt: Date, effectivePlaying: Bool? = nil) {
        guard let current = browserTab, current.0 == tab.browser, current.1 == tab.ref else { return }
        applyObservation(Snapshot(source: Source(tab.browser),
                                  track: Track(title: tab.title, artist: tab.artist, album: tab.album, duration: tab.duration),
                                  isPlaying: effectivePlaying ?? tab.isPlaying, position: tab.position,
                                  browserTab: (tab.ref, tab.site), artworkURL: tab.artworkURL,
                                  browserVideoID: tab.videoID, timeSamples: tab.timeSamples,
                                  sampledAt: sampledAt))
    }

    private func applyObservation(_ snapshot: Snapshot) {
        apply(snapshot)
    }

    // MARK: State

    private nonisolated static func isRunning(_ source: Source) -> Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: source.bundleID).isEmpty
    }

    func refresh() {
        if useControlCenter { recheckControlCenterAccess() }
        guard !refreshInFlight else { refreshQueued = true; return }
        lastDiscoveryRequest = ProcessInfo.processInfo.systemUptime
        let running = [Source.spotify, .music].filter(Self.isRunning)
        let browsers = BrowserMedia.Browser.allCases.filter { enabledBrowsers.contains($0) && $0.isRunning }
        let trySystem = useSystemNowPlaying && SystemMedia.isFrameworkPresent && !SystemMedia.isRestrictedOS()
        if !trySystem {
            if systemNowPlayingWorks { systemNowPlayingWorks = false }
            if systemAppName != nil { systemAppName = nil }
        }
        guard trySystem || !running.isEmpty || !browsers.isEmpty else {
            if !browserIssues.isEmpty { browserIssues = [:] }
            apply(nil)
            return
        }
        refreshInFlight = true
        let preferred = source
        let previousTab = browserTab.map { ($0.0, $0.1) }
        let historyBox = history
        scriptQueue.async { [weak self] in
            // 1) System Now Playing, like Control Center — only if macOS hands it out.
            if trySystem, let (info, pid) = SystemMedia.readNowPlaying() {
                let now = Date()
                let appName = pid > 0 ? NSRunningApplication(processIdentifier: pid)?.localizedName : nil
                let snapshot = Snapshot(source: .system,
                                        track: Track(title: info.title, artist: info.artist, album: info.album, duration: info.duration),
                                        isPlaying: info.isPlaying, position: info.position(at: now),
                                        sampledAt: now, artworkData: info.artwork)
                DispatchQueue.main.async { [weak self] in
                    MainActor.assumeIsolated {
                        guard let self else { return }
                        self.finishRefresh()
                        self.systemNowPlayingWorks = true
                        if self.systemAppName != appName { self.systemAppName = appName }
                        self.permissionDenied = false
                        self.apply(snapshot)
                    }
                }
                return
            }
            DispatchQueue.main.async { [weak self] in
                MainActor.assumeIsolated {
                    if self?.systemNowPlayingWorks == true { self?.systemNowPlayingWorks = false }
                    if self?.systemAppName != nil { self?.systemAppName = nil }
                }
            }
            // 2) Apps and browser tabs we can read directly.
            var snapshots: [Snapshot] = []
            var denied = false
            for candidate in running {
                switch Self.fetch(candidate) {
                case .success(let snapshot?): snapshots.append(snapshot)
                case .success(nil): break
                case .failure(let error): denied = denied || error.isPermissionDenied
                }
            }
            // Browser tabs (only supported YouTube / YouTube Music URLs ever come back).
            var tabs: [BrowserMedia.TabState] = []
            var issues: [BrowserMedia.Browser: BrowserMedia.Issue] = [:]
            var diagnostics: [BrowserMedia.Browser: BrowserMedia.Diagnostics] = [:]
            var chromeMusicTabs = 0
            var chromeScanned = false
            let now = Date()
            for browser in browsers {
                // Non-prompting check first: background polling must never pop up a dialog.
                switch BrowserMedia.automationPermission(for: browser, askIfNeeded: false) {
                case .granted: break
                case .denied: issues[browser] = .automationDenied; continue
                case .notDetermined: issues[browser] = .needsAutomation; continue
                case .browserNotRunning, .unknown: continue
                }
                switch Self.run(BrowserMedia.listScript(for: browser)) {
                case .success(let descriptor):
                    let scan = BrowserMedia.parse(descriptor.stringValue ?? "", browser: browser)
                    tabs += scan.tabs
                    if let issue = scan.issue { issues[browser] = issue }
                    if browser == .chrome { chromeMusicTabs = scan.musicTabCount; chromeScanned = true }
                    var d = BrowserMedia.Diagnostics(date: now)
                    d.musicTabs = scan.musicTabCount
                    d.videoTabs = scan.supportedTabCount - scan.musicTabCount
                    d.unreadable = scan.unreadableCount
                    diagnostics[browser] = d
                case .failure(let error):
                    if error.isPermissionDenied { issues[browser] = .automationDenied }
                }
            }
            // The YT Music PWA's window belongs to Chrome; if Chrome's scripting
            // didn't report any music.youtube.com tab while the PWA runs, say so.
            let appRunning = browsers.contains(.chrome) && BrowserMedia.youtubeMusicAppIsRunning()
            let appUnseen = appRunning && chromeScanned && chromeMusicTabs == 0
            if appUnseen && issues[.chrome] == nil { issues[.chrome] = .youtubeMusicAppNotVisible }
            let sampledAt = Date()
            let selection = BrowserMedia.select(tabs, previous: previousTab, history: &historyBox.value,
                                                now: sampledAt, youtubeMusicAppUnseen: appUnseen)
            for tab in tabs where tab.isPlaying {
                if tab.site == .youtubeMusic { diagnostics[tab.browser]?.musicPlaying += 1 } else { diagnostics[tab.browser]?.videoPlaying += 1 }
            }
            diagnostics[.chrome]?.youtubeMusicAppRunning = appRunning
            if let tab = selection.tab {
                diagnostics[tab.browser]?.shownSite = tab.site
                diagnostics[tab.browser]?.shownIsPlaying = selection.isPlaying
                diagnostics[tab.browser]?.shownTimeSource = tab.timeSource
                diagnostics[tab.browser]?.shownMediaElements = tab.mediaElementCount
                snapshots.append(Snapshot(source: Source(tab.browser),
                                          track: Track(title: tab.title, artist: tab.artist, album: tab.album, duration: tab.duration),
                                          isPlaying: selection.isPlaying, position: tab.position,
                                          browserTab: (tab.ref, tab.site), artworkURL: tab.artworkURL,
                                          browserVideoID: tab.videoID, timeSamples: tab.timeSamples,
                                          sampledAt: sampledAt))
            }
            // A playing source wins; otherwise keep showing the last paused one.
            let chosen = snapshots.first(where: \.isPlaying)
                ?? snapshots.first(where: { $0.source == preferred })
                ?? snapshots.first
            DispatchQueue.main.async { [weak self] in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.finishRefresh()
                    self.permissionDenied = denied && chosen == nil
                    if self.browserIssues != issues { self.browserIssues = issues }
                    if self.browserDiagnostics != diagnostics { self.browserDiagnostics = diagnostics }
                    self.apply(chosen)
                }
            }
        }
    }

    private func finishRefresh() {
        refreshInFlight = false
        guard refreshQueued else { return }
        refreshQueued = false
        DispatchQueue.main.async { [weak self] in MainActor.assumeIsolated { self?.refresh() } }
    }

    /// Offline tests feed synthetic observations through the real state path.
    func applyForTesting(_ snapshot: Snapshot?) { apply(snapshot) }

    private func apply(_ snapshot: Snapshot?) {
        guard let snapshot else {
            tracker.cancel()
            publishTracker()
            lastSampledAt = .distantPast
            if source != nil { source = nil }
            if track != nil { track = nil }
            if isPlaying { isPlaying = false }
            if artwork != nil { artwork = nil }
            position = nil
            if !trackIdentity.isEmpty { trackIdentity = "" }
            browserVideoID = nil
            // Keep the time resolver's memory: during a song change the page can
            // briefly report no metadata, so a scan finds nothing. Forgetting the
            // previous song's timeline here let its time be shown on the next song.
            // It is reset when a different tab (or a non-browser source) shows up.
            artworkKey = nil
            browserTab = nil
            artworkURL = nil
            if browserSite != nil { browserSite = nil }
            return
        }
        // An older result (e.g. a scan that started before a control's read-back) must not
        // overwrite newer state for the same source.
        if snapshot.source == source, snapshot.sampledAt < lastSampledAt { return }
        lastSampledAt = snapshot.sampledAt
        let item = snapshot.browserVideoID ?? "\(snapshot.track.title)|\(snapshot.track.artist)|\(snapshot.track.album)"
        let trackKey = "\(snapshot.source.rawValue)|\(snapshot.browserTab?.ref ?? "")|\(item)"
        _ = tracker.observe(isPlaying: snapshot.isPlaying, trackKey: trackKey, sampledAt: snapshot.sampledAt, now: Date(),
                            position: snapshot.position)
        publishTracker()
        let timelineOwner = Self.timelineOwner(source: snapshot.source, tab: snapshot.browserTab)
        if timelineOwner != resolverOwner {
            resolverOwner = timelineOwner
            trackTransition = .init()
            timeResolver = .init()
        }
        if let browser = snapshot.source.browser, let tab = snapshot.browserTab {
            browserTab = (browser, tab.ref, tab.site)
            if browserSite != tab.site { browserSite = tab.site }
        } else {
            browserTab = nil
            if browserSite != nil { browserSite = nil }
        }
        let changedTrack = trackIdentity != trackKey
        if changedTrack {
            trackIdentity = trackKey
            seekFailed = false
        }
        browserVideoID = snapshot.browserVideoID
        artworkURL = snapshot.artworkURL ?? (changedTrack ? nil : artworkURL)
        if source != snapshot.source { source = snapshot.source }
        var newTrack = snapshot.track
        var newPosition = snapshot.position
        if snapshot.browserTab != nil, let samples = snapshot.timeSamples {
            // Several page time sources: show a time only when it clearly belongs to this item.
            let resolved = timeResolver.resolve(item: trackKey, samples: samples, isPlaying: snapshot.isPlaying, at: snapshot.sampledAt)
            newPosition = resolved?.0.position
            // While hidden, don't keep a length that may be the previous song's.
            newTrack.duration = resolved?.0.duration
        } else if snapshot.browserTab != nil {
            newPosition = trackTransition.position(item: trackKey, value: snapshot.position,
                                                   duration: snapshot.track.duration, at: snapshot.sampledAt)
        }
        if track != newTrack { track = newTrack }
        if isPlaying != snapshot.isPlaying { isPlaying = snapshot.isPlaying }
        position = newPosition
        positionDate = snapshot.sampledAt

        systemArtwork = snapshot.artworkData
        let key = "\(trackKey)|\(artworkURL?.absoluteString ?? "")"
        if key != artworkKey {
            artworkKey = key
            artwork = nil
            loadArtwork(for: snapshot.source, key: key)
        }
    }

    private func loadArtwork(for source: Source, key: String) {
        switch source {
        case .system:
            artwork = systemArtwork.flatMap(NSImage.init(data:))
        case .music:
            let script = "tell application id \"com.apple.Music\" to get raw data of artwork 1 of current track"
            scriptQueue.async { [weak self] in
                guard case .success(let descriptor) = Self.run(script) else { return }
                let image = NSImage(data: descriptor.data)
                DispatchQueue.main.async { [weak self] in
                    MainActor.assumeIsolated {
                        guard let self, self.artworkKey == key else { return }
                        self.artwork = image
                    }
                }
            }
        case .chrome, .safari:
            guard let url = artworkURL, BrowserMedia.isAllowedArtwork(url) else { return }
            Self.artworkSession.dataTask(with: url) { [weak self] data, response, _ in
                guard let data, data.count < 4_000_000,
                      (response as? HTTPURLResponse)?.statusCode == 200,
                      let image = NSImage(data: data) else { return }
                DispatchQueue.main.async { [weak self] in
                    MainActor.assumeIsolated {
                        guard let self, self.artworkKey == key else { return }
                        self.artwork = image
                    }
                }
            }.resume()
        case .spotify:
            let script = "tell application id \"com.spotify.client\" to get artwork url of current track"
            scriptQueue.async { [weak self] in
                guard case .success(let descriptor) = Self.run(script),
                      let string = descriptor.stringValue,
                      let url = URL(string: string), url.scheme == "https" else { return }
                URLSession.shared.dataTask(with: url) { [weak self] data, _, _ in
                    guard let data, let image = NSImage(data: data) else { return }
                    DispatchQueue.main.async { [weak self] in
                        MainActor.assumeIsolated {
                            guard let self, self.artworkKey == key else { return }
                            self.artwork = image
                        }
                    }
                }.resume()
            }
        }
    }

    // MARK: AppleScript (runs on scriptQueue only)

    struct Snapshot {
        var source: Source
        var track: Track
        var isPlaying: Bool
        var position: TimeInterval?
        var browserTab: (ref: String, site: BrowserMedia.Site)? = nil
        var artworkURL: URL? = nil
        var browserVideoID: String? = nil
        var timeSamples: BrowserMedia.TimeSamples? = nil
        /// When `position` was read (the UI extrapolates from this, not from
        /// when the main thread got the result).
        var sampledAt = Date()
        /// Artwork delivered with the info (MediaRemote).
        var artworkData: Data? = nil
    }

    /// No cookies or cache for artwork downloads.
    private static let artworkSession: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 10
        config.httpCookieStorage = nil
        config.urlCache = nil
        return URLSession(configuration: config)
    }()

    struct ScriptError: Error {
        var code: Int
        /// errAEEventNotPermitted: the user denied (or has not yet granted) Automation.
        var isPermissionDenied: Bool { code == -1743 }
    }

    private nonisolated static let separator = "\u{1F}"

    private nonisolated static func fetch(_ source: Source) -> Result<Snapshot?, ScriptError> {
        let script = """
        tell application id "\(source.bundleID)"
            with timeout of 1 second
            if player state is stopped then return "stopped"
            set sep to (ASCII character 31)
            set t to current track
            return (player state as text) & sep & (name of t) & sep & (artist of t) & sep & (album of t) & sep & ((duration of t) as text) & sep & ((player position) as text)
            end timeout
        end tell
        """
        switch run(script) {
        case .failure(let error):
            return .failure(error)
        case .success(let descriptor):
            guard let text = descriptor.stringValue, text != "stopped" else { return .success(nil) }
            let parts = text.components(separatedBy: separator)
            guard parts.count >= 6, !parts[1].isEmpty else { return .success(nil) }
            var duration = number(parts[4])
            // Spotify reports duration in milliseconds, Music in seconds.
            if source == .spotify, let ms = duration { duration = ms / 1000 }
            let track = Track(title: parts[1], artist: parts[2], album: parts[3], duration: duration)
            return .success(Snapshot(source: source, track: track,
                                     isPlaying: parts[0] == "playing", position: number(parts[5])))
        }
    }

    /// AppleScript coerces reals using the user's locale ("12,5" in many regions).
    private nonisolated static func number(_ text: String) -> Double? {
        Double(text.replacingOccurrences(of: ",", with: ".").trimmingCharacters(in: .whitespaces))
    }

    private nonisolated static func run(_ source: String) -> Result<NSAppleEventDescriptor, ScriptError> {
        // Compiled once and reused (only ever called on the serial script queue).
        guard let script = scriptCache.script(for: source) else { return .failure(ScriptError(code: -1)) }
        var errorInfo: NSDictionary?
        let result = script.executeAndReturnError(&errorInfo)
        if let errorInfo {
            let code = (errorInfo[NSAppleScript.errorNumber] as? NSNumber)?.intValue ?? -1
            return .failure(ScriptError(code: code))
        }
        return .success(result)
    }
}

/// Latest issued command id, shared with the script queue.
final class LatestCommandID: @unchecked Sendable {
    private let lock = NSLock()
    private var id = 0
    var value: Int { lock.withLock { id } }
    func set(_ value: Int) { lock.withLock { id = value } }
}
