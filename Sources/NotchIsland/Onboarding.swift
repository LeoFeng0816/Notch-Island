import AppKit
import SwiftUI
import AVFoundation
import UserNotifications
import Combine

/// First-run guide. Shown once (also to existing users after updating),
/// never resets or rewrites existing settings: it only changes what the user
/// changes here. Every permission is explained and requested only when the
/// user presses its button.
enum OnboardingState {
    static let key = "NotchIsland.onboarding.completedVersion"
    static let currentVersion = 1

    static func shouldShow(_ defaults: UserDefaults = .standard) -> Bool {
        defaults.integer(forKey: key) < currentVersion
    }

    static func markCompleted(_ defaults: UserDefaults = .standard) {
        defaults.set(currentVersion, forKey: key)
    }
}

/// Live permission status for the guide (read-only checks; no prompts).
@MainActor
final class PermissionStatus: ObservableObject {
    enum State: Equatable { case granted, notAsked, denied, unknown }

    @Published private(set) var keystrokes: State = .unknown
    @Published private(set) var screenRecording: State = .unknown
    @Published private(set) var microphone: State = .unknown
    @Published private(set) var notifications: State = .unknown

    func refresh() {
        keystrokes = CGPreflightPostEventAccess() ? .granted : .notAsked
        screenRecording = CGPreflightScreenCaptureAccess() ? .granted : .notAsked
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: microphone = .granted
        case .notDetermined: microphone = .notAsked
        default: microphone = .denied
        }
        IslandNotifier.authorizationStatus { [weak self] status in
            switch status {
            case .authorized, .provisional: self?.notifications = .granted
            case .notDetermined: self?.notifications = .notAsked
            default: self?.notifications = .denied
            }
        }
    }

    private let keystrokeAccess = PostEventAccess()
    static let screenRequestedKey = "NotchIsland.screenCapture.requestedBuild"

    // Each request is triggered by a button press only. macOS shows its own
    // request once per app identity; later presses open the pane instead of
    // silently doing nothing.
    func requestKeystrokes() { keystrokeAccess.request(); refresh() }
    func requestScreenRecording() {
        if !CGPreflightScreenCaptureAccess() {
            let build = SystemMedia.currentBuildID() ?? "unknown"
            if UserDefaults.standard.string(forKey: Self.screenRequestedKey) == build {
                SystemSettingsLink.open(.screenCapture)
            } else {
                UserDefaults.standard.set(build, forKey: Self.screenRequestedKey)
                CGRequestScreenCaptureAccess()
            }
        }
        refresh()
    }
    func requestMicrophone() {
        AVCaptureDevice.requestAccess(for: .audio) { _ in
            DispatchQueue.main.async { MainActor.assumeIsolated { self.refresh() } }
        }
    }
    func requestNotifications() { IslandNotifier.requestAuthorization { [weak self] _ in self?.refresh() } }
}

@MainActor
final class OnboardingWindowController: NSObject, NSWindowDelegate {
    private var window: NSWindow?
    private let makeView: (@escaping () -> Void) -> AnyView
    private let lang: LanguageSettings
    private var cancellable: AnyCancellable?

    init(lang: LanguageSettings, makeView: @escaping (@escaping () -> Void) -> AnyView) {
        self.lang = lang
        self.makeView = makeView
    }

    func show() {
        if window == nil {
            let hosting = NSHostingController(rootView: makeView { [weak self] in self?.window?.close() })
            let window = NSWindow(contentViewController: hosting)
            window.styleMask = [.titled, .closable]
            window.setContentSize(NSSize(width: 520, height: 640))
            window.isReleasedWhenClosed = false
            window.delegate = self
            window.center()
            self.window = window
            cancellable = lang.$language.sink { [weak self] _ in
                DispatchQueue.main.async { MainActor.assumeIsolated { self?.window?.title = self?.lang.t(.onboardingTitle) ?? "" } }
            }
        }
        window?.title = lang.t(.onboardingTitle)
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}

struct OnboardingView: View {
    @ObservedObject var lang: LanguageSettings
    @ObservedObject var clipboard: ClipboardStore
    @StateObject private var status = PermissionStatus()
    var openSettings: () -> Void
    var done: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Form {
                Section {
                    Text(lang.t(.onboardingIntro)).font(.callout).fixedSize(horizontal: false, vertical: true)
                    Picker(lang.t(.language), selection: $lang.language) {
                        ForEach(AppLanguage.allCases) { Text(lang.displayName($0)).tag($0) }
                    }
                }
                Section {
                    row("keyboard", .permKeystrokes, .permKeystrokesWhy, status.keystrokes, request: status.requestKeystrokes,
                        settings: PrivacyPane.accessibility.urls)
                    row("camera.viewfinder", .permScreen, .permScreenWhy, status.screenRecording, request: status.requestScreenRecording,
                        settings: PrivacyPane.screenCapture.urls)
                    row("mic.fill", .permMicrophone, .permMicrophoneWhy, status.microphone, request: status.requestMicrophone,
                        settings: PrivacyPane.microphone.urls)
                    row("bell.badge.fill", .permNotifications, .permNotificationsWhy, status.notifications, request: status.requestNotifications,
                        settings: ["x-apple.systempreferences:com.apple.Notifications-Settings.extension"].compactMap(URL.init(string:)))
                    info("gearshape.2.fill", .permAutomation, .permAutomationWhy)
                    info("waveform", .permSystemAudio, .permSystemAudioWhy)
                    info("location.fill", .permLocationCalendar, .permLocationCalendarWhy)
                } header: { Text(lang.t(.onboardingPermissions)) } footer: {
                    Text(lang.t(.onboardingPermissionsFooter)).font(.caption).foregroundStyle(.secondary)
                }
                Section {
                    Toggle(lang.t(.clipboardHistoryToggle), isOn: Binding(get: { clipboard.enabled }, set: { clipboard.setEnabled($0) }))
                    Picker(lang.t(.clipboardRetention), selection: Binding(get: { clipboard.retention }, set: { clipboard.setRetention($0) })) {
                        Text(lang.t(.retention1)).tag(ClipboardRetention.oneDay)
                        Text(lang.t(.retention3)).tag(ClipboardRetention.threeDays)
                        Text(lang.t(.retention7)).tag(ClipboardRetention.sevenDays)
                        Text(lang.t(.retention30)).tag(ClipboardRetention.thirtyDays)
                    }
                } header: { Text(lang.t(.qaClipboard)) } footer: {
                    Text(lang.t(.clipboardPrivacy)).font(.caption).foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)
            HStack {
                Button(lang.t(.settingsMenu), action: openSettings)
                Spacer()
                Button(lang.t(.onboardingDone)) { OnboardingState.markCompleted(); done() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(16)
        }
        .frame(minWidth: 480, minHeight: 560)
        .onAppear { status.refresh() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in status.refresh() }
        .onReceive(Timer.publish(every: 2, on: .main, in: .common).autoconnect()) { _ in status.refresh() }
    }

    private func statusText(_ state: PermissionStatus.State) -> String {
        switch state {
        case .granted: return lang.t(.permGranted)
        case .notAsked: return lang.t(.permNotGranted)
        case .denied: return lang.t(.permDenied)
        case .unknown: return "—"
        }
    }

    private func row(_ symbol: String, _ title: L10nKey, _ why: L10nKey, _ state: PermissionStatus.State,
                     request: @escaping () -> Void, settings: [URL]) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: symbol).frame(width: 20).foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text(lang.t(title)).font(.body.weight(.semibold))
                    Spacer()
                    Text(statusText(state)).font(.caption).foregroundStyle(state == .granted ? Color.green : .secondary)
                }
                Text(lang.t(why)).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                if state != .granted {
                    HStack {
                        if state != .denied { Button(lang.t(.permAllow), action: request) }
                        Button(lang.t(.openSettings)) { SystemSettingsLink.open(settings) }
                    }
                    .controlSize(.small)
                }
            }
        }
    }

    private func info(_ symbol: String, _ title: L10nKey, _ why: L10nKey) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: symbol).frame(width: 20).foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(lang.t(title)).font(.body.weight(.semibold))
                Text(lang.t(why)).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
