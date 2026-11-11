import AppKit
import CoreGraphics

/// System-wide "Now Playing" (what Control Center shows) and media-key control.
///
/// **Reading.** macOS has no public API for other apps' Now Playing info.
/// Control Center uses the private MediaRemote framework. It is loaded here
/// dynamically, read-only, and only used when it actually returns data. Since
/// macOS 15.4 MediaRemote returns nothing to third-party (non-Apple) apps; on
/// this project's test Mac (macOS 27.0.1) it returned no info while audio was
/// playing. Known workarounds run a helper inside an Apple-signed binary to pass
/// that check; that would circumvent an OS access control, so it isn't done.
///
/// **Control.** Pressing a hardware media key is routed by macOS to the current
/// Now Playing app (Music, Spotify, Chrome/YouTube Music, Safari…). Synthesizing
/// that key needs the public "post events" permission
/// (`CGRequestPostEventAccess`, listed under Privacy & Security ›
/// Accessibility). It is opt-in and requested only when the user turns it on.
enum SystemMedia {
    // MARK: MediaRemote (private, optional)

    struct NowPlaying: Equatable {
        var title: String
        var artist: String
        var album: String
        var duration: TimeInterval?
        /// Elapsed time at `timestamp` (MediaRemote reports both).
        var elapsed: TimeInterval?
        var timestamp: Date?
        var isPlaying: Bool
        var artwork: Data?

        /// Position extrapolated to `now` while playing.
        func position(at now: Date) -> TimeInterval? {
            guard let elapsed else { return nil }
            guard isPlaying, let timestamp else { return elapsed }
            let value = elapsed + max(0, now.timeIntervalSince(timestamp))
            return duration.map { min($0, value) } ?? value
        }
    }

    /// Parses a MediaRemote info dictionary (keys `kMRMediaRemoteNowPlayingInfo…`).
    static func parse(_ info: [String: Any], isPlaying: Bool?) -> NowPlaying? {
        func string(_ key: String) -> String {
            (info["kMRMediaRemoteNowPlayingInfo" + key] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        }
        func number(_ key: String) -> Double? {
            guard let value = (info["kMRMediaRemoteNowPlayingInfo" + key] as? NSNumber)?.doubleValue,
                  value.isFinite, value >= 0 else { return nil }
            return value
        }
        let title = string("Title")
        guard !title.isEmpty else { return nil }
        let rate = number("PlaybackRate")
        let duration = number("Duration").flatMap { $0 > 0 ? $0 : nil }
        var elapsed = number("ElapsedTime")
        if let e = elapsed, let d = duration, e > d + 2 { elapsed = nil }
        return NowPlaying(title: title, artist: string("Artist"), album: string("Album"),
                          duration: duration, elapsed: elapsed,
                          timestamp: info["kMRMediaRemoteNowPlayingInfoTimestamp"] as? Date,
                          isPlaying: isPlaying ?? ((rate ?? 0) > 0),
                          artwork: info["kMRMediaRemoteNowPlayingInfoArtworkData"] as? Data)
    }

    private typealias InfoFn = @convention(c) (DispatchQueue, @escaping @convention(block) (CFDictionary?) -> Void) -> Void
    private typealias BoolFn = @convention(c) (DispatchQueue, @escaping @convention(block) (Bool) -> Void) -> Void
    private typealias PIDFn = @convention(c) (DispatchQueue, @escaping @convention(block) (Int32) -> Void) -> Void

    private static let framework: UnsafeMutableRawPointer? =
        dlopen("/System/Library/PrivateFrameworks/MediaRemote.framework/MediaRemote", RTLD_LAZY)

    static var isFrameworkPresent: Bool { framework != nil }

    /// Read-only query; blocks up to `timeout` (call off the main thread).
    /// Returns nil when nothing is playing *or* macOS withholds the data.
    static func readNowPlaying(timeout: TimeInterval = 1) -> (info: NowPlaying, pid: Int32)? {
        guard let framework,
              let infoSym = dlsym(framework, "MRMediaRemoteGetNowPlayingInfo") else { return nil }
        let queue = DispatchQueue(label: "NotchIsland.MediaRemote")
        let group = DispatchGroup()
        var dict: [String: Any]?
        var playing: Bool?
        var pid: Int32 = 0
        group.enter()
        unsafeBitCast(infoSym, to: InfoFn.self)(queue) { value in
            dict = value as? [String: Any]
            group.leave()
        }
        if let sym = dlsym(framework, "MRMediaRemoteGetNowPlayingApplicationIsPlaying") {
            group.enter()
            unsafeBitCast(sym, to: BoolFn.self)(queue) { value in playing = value; group.leave() }
        }
        if let sym = dlsym(framework, "MRMediaRemoteGetNowPlayingApplicationPID") {
            group.enter()
            unsafeBitCast(sym, to: PIDFn.self)(queue) { value in pid = value; group.leave() }
        }
        guard group.wait(timeout: .now() + timeout) == .success else { return nil }
        return queue.sync {
            guard let dict, let info = parse(dict, isPlaying: playing) else { return nil }
            return (info, pid)
        }
    }

    private typealias CommandFn = @convention(c) (Int32, CFDictionary?) -> Bool

    /// MRCommand values: 2 toggle play/pause, 4 next track, 5 previous track.
    static func mediaRemoteCommand(_ command: BrowserMedia.Command) -> Int32 {
        switch command {
        case .play: return 0
        case .pause: return 1
        case .playPause: return 2
        case .next: return 4
        case .previous: return 5
        }
    }

    /// Only used for the `.system` source, i.e. where MediaRemote actually works.
    static func sendCommand(_ command: BrowserMedia.Command) -> Bool {
        guard let framework, let sym = dlsym(framework, "MRMediaRemoteSendCommand") else { return false }
        return unsafeBitCast(sym, to: CommandFn.self)(mediaRemoteCommand(command), nil)
    }

    /// macOS versions where MediaRemote is known to withhold Now Playing data
    /// from third-party apps.
    static func isRestrictedOS(_ version: OperatingSystemVersion = ProcessInfo.processInfo.operatingSystemVersion) -> Bool {
        version.majorVersion > 15 || (version.majorVersion == 15 && version.minorVersion >= 4)
    }

    // MARK: Build identity (why a granted permission can "disappear")

    /// cdhash of the running app (public Security API). With ad-hoc signing
    /// the designated requirement *is* this hash, so macOS privacy grants
    /// (Accessibility / post events, Automation) don't carry over to a rebuilt app.
    static func currentBuildID() -> String? {
        var code: SecCode?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code else { return nil }
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode else { return nil }
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
              let dict = info as? [String: Any], let hash = dict[kSecCodeInfoUnique as String] as? Data else { return nil }
        return hash.map { String(format: "%02x", $0) }.joined()
    }

    /// Whether the build is ad-hoc signed (grants are tied to the exact binary).
    static func isAdHocSigned() -> Bool {
        var code: SecCode?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code else { return true }
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode else { return true }
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
              let dict = info as? [String: Any] else { return true }
        // No certificate chain → ad-hoc.
        return (dict[kSecCodeInfoCertificates as String] as? [Any])?.isEmpty ?? true
    }

    /// Permission was granted to an earlier build but doesn't apply to this one.
    static func grantLooksStale(hasAccess: Bool, grantedBuild: String?, currentBuild: String?) -> Bool {
        guard !hasAccess, let grantedBuild, let currentBuild else { return false }
        return grantedBuild != currentBuild
    }

    // MARK: Media keys (public, opt-in permission)

    enum MediaKey: Int32 {
        // NX_KEYTYPE_* from IOKit/hidsystem/ev_keymap.h. Apple keyboards send
        // PLAY (16) for F8 and FAST (19) / REWIND (20) for F9 / F7; that is what
        // macOS routes to the Now Playing app as next / previous track.
        // NX_KEYTYPE_NEXT (17) / PREVIOUS (18) are not what those keys send.
        case playPause = 16, next = 19, previous = 20
    }

    /// `NSEvent.otherEvent` data1 for a media key press/release.
    static func data1(for key: MediaKey, down: Bool) -> Int {
        Int((key.rawValue << 16) | ((down ? 0xA : 0xB) << 8))
    }

    /// Whether this app may post events (no prompt).
    static var canPostEvents: Bool { CGPreflightPostEventAccess() }

    /// Shows the system permission request (explicit user action only).
    @discardableResult
    static func requestPostEventAccess() -> Bool { CGRequestPostEventAccess() }

    static func openAccessibilitySettings() {
        SystemSettingsLink.open(.accessibility)
    }

    /// Builds the key-down/key-up pair (separate for tests; nothing is posted).
    static func events(for key: MediaKey) -> [NSEvent] {
        [true, false].compactMap { down in
            NSEvent.otherEvent(with: .systemDefined, location: .zero,
                               modifierFlags: NSEvent.ModifierFlags(rawValue: down ? 0xA00 : 0xB00),
                               timestamp: 0, windowNumber: 0, context: nil,
                               subtype: 8, data1: data1(for: key, down: down), data2: -1)
        }
    }

    /// Posts the key like the keyboard's media keys. Returns false without permission.
    @discardableResult
    static func press(_ key: MediaKey) -> Bool {
        guard canPostEvents else { return false }
        for event in events(for: key) { event.cgEvent?.post(tap: .cghidEventTap) }
        return true
    }
}
