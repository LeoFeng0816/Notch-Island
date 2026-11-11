import SwiftUI
import AppKit
import ShazamKit

// MARK: - Quick actions under the widgets

enum MusicRecognitionMode: String, CaseIterable {
    /// Song Finder (songfinder.dev): free, no key; asks for consent before the first upload.
    case songFinder
    /// macOS Control Center "Recognize Music" (results stay in Control Center).
    case system
    /// AudD with the user's own API token.
    case audd
    static let defaultsKey = "NotchIsland.musicRecognitionMode"
    /// Song Finder is the default, also for a missing or unknown value. An explicit,
    /// stored choice (macOS or AudD) is kept. AudD is never chosen implicitly.
    static func resolve(_ value: String) -> Self { Self(rawValue: value) ?? .songFinder }
}

struct QuickActionsBar: View {
    @ObservedObject var model: IslandViewModel
    @ObservedObject var lang: LanguageSettings
    @EnvironmentObject private var songFinder: SongFinderRecognition
    @AppStorage(MusicRecognitionMode.defaultsKey) private var recognitionMode = MusicRecognitionMode.songFinder.rawValue
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var recognitionFlash = false

    /// Shazam-blue fill on the Music Recognition button while macOS is being tried.
    /// Only opacity changes (no movement), so Reduce Motion keeps a short dissolve
    /// instead of snapping the color on and off.
    static let recognitionBlue: UInt32 = 0x0058BD
    static func flashFade(fadingIn: Bool, reduceMotion: Bool) -> TimeInterval {
        reduceMotion ? 0.12 : (fadingIn ? 0.18 : 0.5)
    }
    /// Minimum time the blue stays up, so a fast failure is still visible.
    static func feedbackDuration(reduceMotion: Bool) -> Duration {
        reduceMotion ? .milliseconds(350) : .milliseconds(850)
    }

    var body: some View {
        HStack(spacing: 8) {
            action("doc.on.clipboard", .qaClipboard) {
                withAnimation(reduceMotion ? .easeOut(duration: 0.15) : .spring(response: 0.32, dampingFraction: 0.86)) { model.subpage = .clipboard }
            }
            action("camera.viewfinder", .qaScreenshot) { model.onScreenshot?() }
            action("record.circle", .qaScreenRecord, help: .recordToolbarHelp) { model.onScreenRecording?() }
            recognitionButton
        }
        .frame(height: IslandViewModel.quickActionsHeight - 6)
        .onChange(of: model.checkingSystemRecognition) { _, checking in
            guard !checking, recognitionFlash else { return }
            withAnimation(.easeOut(duration: Self.flashFade(fadingIn: false, reduceMotion: reduceMotion))) { recognitionFlash = false }
        }
    }

    private var recognitionButton: some View {
        Button(action: recognizeMusic) {
            HStack(spacing: 5) {
                Image(systemName: "waveform.and.magnifyingglass").font(.system(size: 11, weight: .semibold))
                Text(lang.t(.qaShazam)).font(.system(size: 10.5, weight: .semibold)).lineLimit(1).minimumScaleFactor(0.7)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background {
                Capsule().fill(.white.opacity(0.1))
                    .overlay(Capsule().fill(Color(hex: Self.recognitionBlue)).opacity(recognitionFlash ? 1 : 0))
            }
            .foregroundStyle(.white.opacity(0.95))
            .contentShape(Capsule())
        }
        .buttonStyle(PressableStyle())
        .disabled(model.checkingSystemRecognition)
        .help(lang.t(.qaShazam))
        .accessibilityLabel(lang.t(.qaShazam))
    }

    private func recognizeMusic() {
        switch MusicRecognitionMode.resolve(recognitionMode) {
        case .songFinder:
            // The press is the user's action: the first time this shows the disclosure
            // (nothing is recorded until "Agree and Start"); afterwards it records ~12 s.
            withAnimation(reduceMotion ? nil : .easeOut(duration: 0.2)) { model.subpage = .songFinder }
            songFinder.start()
            return
        case .audd:
            withAnimation(reduceMotion ? nil : .easeOut(duration: 0.2)) { model.subpage = .audd }
            return
        case .system:
            break
        }
        guard !model.checkingSystemRecognition else { return }
        // Blue while macOS is being tried; it fades out when the attempt ends
        // (onChange above), never as a claim that a song was recognized.
        withAnimation(.easeOut(duration: Self.flashFade(fadingIn: true, reduceMotion: reduceMotion))) { recognitionFlash = true }
        model.startSystemRecognition(feedbackDuration: Self.feedbackDuration(reduceMotion: reduceMotion))
    }

    private func action(_ symbol: String, _ key: L10nKey, help: L10nKey? = nil, perform: @escaping () -> Void) -> some View {
        Button(action: perform) {
            HStack(spacing: 5) {
                Image(systemName: symbol).font(.system(size: 11, weight: .semibold))
                Text(lang.t(key)).font(.system(size: 10.5, weight: .semibold)).lineLimit(1).minimumScaleFactor(0.75)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Capsule().fill(.white.opacity(0.1)))
            .foregroundStyle(.white.opacity(0.9))
            .contentShape(Capsule())
        }
        .buttonStyle(PressableStyle())
        .help(lang.t(help ?? key))
        .accessibilityLabel(lang.t(key))
    }
}

/// Header used by the full-area pages: close on the left, optional action on the right.
struct SubpageHeader<Trailing: View>: View {
    var title: String
    var closeLabel: String
    var close: () -> Void
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(spacing: 8) {
            Button(action: close) {
                Image(systemName: "xmark").font(.system(size: 10, weight: .bold))
                    .frame(width: 22, height: 22)
                    .background(Circle().fill(.white.opacity(0.12)))
            }
            .buttonStyle(PressableStyle())
            .help(closeLabel)
            .accessibilityLabel(closeLabel)
            Text(title).font(.system(size: 12, weight: .semibold))
            Spacer()
            trailing
        }
        .frame(height: 24)
    }
}

// MARK: - Clipboard page

struct ClipboardPage: View {
    @ObservedObject var model: IslandViewModel
    @ObservedObject var lang: LanguageSettings
    @EnvironmentObject var store: ClipboardStore
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var confirmClear = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            SubpageHeader(title: lang.t(.qaClipboard), closeLabel: lang.t(.close), close: closePage) {
                if store.enabled && !store.items.isEmpty {
                    Button {
                        if confirmClear { store.clear(); confirmClear = false } else {
                            confirmClear = true
                            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { confirmClear = false }
                        }
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "trash.fill").font(.system(size: 11, weight: .semibold))
                            if confirmClear { Text(lang.t(.clipboardClearConfirm)).font(.system(size: 10, weight: .semibold)) }
                        }
                        .foregroundStyle(.white)
                        .padding(.horizontal, confirmClear ? 9 : 0)
                        .frame(minWidth: 22, minHeight: 22)
                        .background(Capsule().fill(Color(hex: 0xFF453A)))
                    }
                    .buttonStyle(PressableStyle())
                    .help(lang.t(.clipboardClear))
                    .accessibilityLabel(lang.t(.clipboardClear))
                    .animation(.snappy(duration: 0.2), value: confirmClear)
                }
            }
            content
        }
        .foregroundStyle(.white)
    }

    private func closePage() {
        withAnimation(reduceMotion ? .easeOut(duration: 0.15) : .spring(response: 0.32, dampingFraction: 0.86)) { model.subpage = .none }
    }

    @ViewBuilder private var content: some View {
        if !store.enabled {
            VStack(spacing: 6) {
                Image(systemName: "lock.doc").font(.system(size: 20)).foregroundStyle(.white.opacity(0.5))
                Text(lang.t(.clipboardOff)).font(.system(size: 12, weight: .semibold))
                Text(lang.t(.clipboardOffHint, lang.t(retentionKey(store.retention))))
                    .font(.system(size: 10.5)).foregroundStyle(.white.opacity(0.6))
                    .multilineTextAlignment(.center).lineLimit(3)
                Button(lang.t(.clipboardTurnOn)) { store.setEnabled(true) }.buttonStyle(PillStyle())
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if store.items.isEmpty {
            VStack(spacing: 6) {
                Text(lang.t(.clipboardEmpty)).font(.system(size: 11)).foregroundStyle(.white.opacity(0.55))
                pasteboardHint
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            pasteboardHint
            ScrollView(.vertical, showsIndicators: false) {
                LazyVStack(spacing: 4) {
                    ForEach(store.items) { item in
                        ClipboardRow(item: item, lang: lang, image: item.kind == .image ? store.image(for: item) : nil) {
                            model.onPasteClipboardItem?(item)
                        }
                    }
                }
            }
            Text(lang.t(.clipboardFooter, lang.t(retentionKey(store.retention))))
                .font(.system(size: 9)).foregroundStyle(.white.opacity(0.45)).lineLimit(1)
        }
    }

    /// macOS 15.4+ "Paste from Other Apps": only shown when it blocks or interrupts history.
    @ViewBuilder private var pasteboardHint: some View {
        let access = PasteboardAccess.current()
        if access == .denied || access == .asks || access == .notAskedYet {
            HStack(spacing: 6) {
                Image(systemName: access == .denied ? "exclamationmark.triangle.fill" : "info.circle")
                    .font(.system(size: 10)).foregroundStyle(access == .denied ? .yellow : .white.opacity(0.6))
                Text(lang.t(access == .denied ? .pasteboardDeniedShort : .pasteboardAsksShort))
                    .font(.system(size: 9.5)).foregroundStyle(.white.opacity(0.7)).lineLimit(2)
                Spacer(minLength: 4)
                Button(lang.t(.openSettings)) { SystemSettingsLink.open(.pasteboard) }.buttonStyle(PillStyle())
            }
        }
    }

    private func retentionKey(_ r: ClipboardRetention) -> L10nKey {
        switch r {
        case .oneDay: return .retention1
        case .threeDays: return .retention3
        case .sevenDays: return .retention7
        case .thirtyDays: return .retention30
        }
    }
}

struct ClipboardRow: View {
    var item: ClipboardItem
    @ObservedObject var lang: LanguageSettings
    var image: NSImage?
    var paste: () -> Void

    var body: some View {
        Button(action: paste) {
            HStack(spacing: 8) {
                if let image {
                    Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
                        .frame(width: 26, height: 20).clipShape(RoundedRectangle(cornerRadius: 4))
                } else {
                    Image(systemName: item.kind == .files ? "doc.fill" : "text.alignleft")
                        .font(.system(size: 10)).frame(width: 26, height: 20)
                        .foregroundStyle(.white.opacity(0.7))
                }
                Text(item.preview.isEmpty ? lang.t(.clipboardImage) : item.preview)
                    .font(.system(size: 11)).lineLimit(1)
                Spacer(minLength: 4)
                Text(item.date.formatted(.relative(presentation: .named).locale(lang.locale)))
                    .font(.system(size: 9)).foregroundStyle(.white.opacity(0.45)).lineLimit(1)
            }
            .padding(.horizontal, 8).padding(.vertical, 4)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(.white.opacity(0.07)))
            .contentShape(Rectangle())
        }
        .buttonStyle(PressableStyle())
        .help(lang.t(.clipboardPasteHint))
        .accessibilityLabel(item.kind == .text ? lang.t(.clipboardText) : (item.kind == .image ? lang.t(.clipboardImage) : lang.t(.clipboardFiles)))
        .accessibilityHint(lang.t(.clipboardPasteHint))
    }
}

// MARK: - Shazam page

struct ShazamPage: View {
    @ObservedObject var model: IslandViewModel
    @ObservedObject var lang: LanguageSettings
    @EnvironmentObject var shazam: ShazamRecognizer
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AppStorage("NotchIsland.musicShortcutName") private var shortcutName = ""
    @State private var systemPanelStatus: ControlCenterMedia.MusicRecognitionResult?
    @State private var openingSystemPanel = false
    @State private var showingAudD = false
    private let audd: AudDRecognition?
    private let guidanceOnly: Bool

    init(model: IslandViewModel, lang: LanguageSettings, systemStatus: ControlCenterMedia.MusicRecognitionResult? = nil,
         startWithAudD: Bool = false, audd: AudDRecognition? = nil) {
        self.model = model
        self.lang = lang
        self.audd = audd
        guidanceOnly = systemStatus != nil
        _systemPanelStatus = State(initialValue: systemStatus)
        _showingAudD = State(initialValue: startWithAudD)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            SubpageHeader(title: lang.t(.qaShazam), closeLabel: lang.t(.close), close: {
                if showingAudD { audd?.cancel() }
                shazam.reset()
                withAnimation(reduceMotion ? nil : .easeOut(duration: 0.2)) { model.subpage = .none }
            }) { EmptyView() }
            if showingAudD {
                AudDPage(lang: lang, close: {
                    if guidanceOnly { showingAudD = false }
                    else { model.subpage = .none }
                }, recognition: audd)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                content.frame(maxWidth: .infinity, maxHeight: .infinity)
                if !guidanceOnly {
                    Text(lang.t(.shazamPrivacy)).font(.system(size: 8.5)).foregroundStyle(.white.opacity(0.45)).lineLimit(2)
                }
            }
        }
        .foregroundStyle(.white)
    }

    @ViewBuilder private var content: some View {
        switch shazam.phase {
        case .idle, .cancelled:
            VStack(spacing: 6) {
                if shazam.phase == .cancelled { Text(lang.t(.shazamCancelled)).font(.system(size: 11)).foregroundStyle(.white.opacity(0.6)) }
                if !guidanceOnly {
                    Text(lang.t(.shazamStart)).font(.system(size: 12, weight: .semibold))
                    sourceButtons
                }
                systemRecognition
            }
        case .preparing, .listening:
            HStack(spacing: 14) {
                TimelineView(.animation(minimumInterval: 1 / 30)) { context in
                    let t = context.date.timeIntervalSinceReferenceDate
                    Image(systemName: "shazam.logo.fill").font(.system(size: 34))
                        .foregroundStyle(Color(hex: 0x0A84FF))
                        .scaleEffect(reduceMotion ? 1 : 1 + 0.06 * sin(t * 4))
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text(lang.t(.shazamListening)).font(.system(size: 13, weight: .semibold))
                    Text(sourcesText).font(.system(size: 10)).foregroundStyle(.white.opacity(0.6))
                    if shazam.catalogErrorWhileListening {
                        Text(lang.t(.shazamRetrying)).font(.system(size: 10, weight: .semibold)).foregroundStyle(.yellow).lineLimit(1)
                    }
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        let elapsed = shazam.startedAt.map { context.date.timeIntervalSince($0) } ?? 0
                        ProgressView(value: min(elapsed, ShazamRecognizer.timeout), total: ShazamRecognizer.timeout)
                            .tint(Color(hex: 0x0A84FF)).frame(width: 160)
                    }
                    HStack(spacing: 6) {
                        Button(lang.t(.cancel)) { shazam.cancel() }.buttonStyle(PillStyle())
                        if shazam.catalogErrorWhileListening { guideButton }
                    }
                }
            }
        case .matched(let song):
            HStack(spacing: 12) {
                AsyncImage(url: song.artworkURL) { image in image.resizable().aspectRatio(contentMode: .fill) } placeholder: {
                    Color.white.opacity(0.1)
                }
                .frame(width: 72, height: 72).clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                VStack(alignment: .leading, spacing: 3) {
                    Text(song.title).font(.system(size: 14, weight: .semibold)).lineLimit(1)
                    Text(song.artist).font(.system(size: 11)).foregroundStyle(.white.opacity(0.65)).lineLimit(1)
                    HStack(spacing: 6) {
                        if let url = song.appleMusicURL ?? song.webURL {
                            Button(lang.t(.shazamOpen)) { NSWorkspace.shared.open(url) }.buttonStyle(PillStyle())
                        }
                        Button(lang.t(.shazamCopy)) {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString("\(song.title) — \(song.artist)", forType: .string)
                        }.buttonStyle(PillStyle())
                        retryButton
                    }
                    .padding(.top, 2)
                }
            }
        case .noMatch:
            VStack(spacing: 6) {
                Text(lang.t(.shazamNoMatch)).font(.system(size: 12, weight: .semibold))
                systemRecognition
                HStack(spacing: 6) {
                    retryButton
                }
            }
        case .failed(let failure):
            VStack(spacing: 6) {
                Label(failureText(failure), systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 11, weight: .semibold)).foregroundStyle(.yellow)
                    .multilineTextAlignment(.center).lineLimit(3)
                if case .service = failure { systemRecognition }
                HStack(spacing: 6) {
                    if failure == .microphoneDenied {
                        Button(lang.t(.openSettings)) {
                            SystemSettingsLink.open(.microphone)
                        }.buttonStyle(PillStyle())
                    }
                    retryButton
                }
            }
        }
    }

    private var sourcesText: String {
        guard case .listening(let source) = shazam.phase else { return "" }
        return lang.t(source == .microphone ? .shazamMic : .shazamSystemAudio)
    }

    private var sourceButtons: some View {
        HStack(spacing: 6) {
            if ShazamRecognizer.supportsSystemAudio {
                Button(lang.t(.shazamSystemAudio)) { shazam.start(source: .systemAudio) }.buttonStyle(PillStyle())
            }
            Button(lang.t(.shazamMic)) { shazam.start(source: .microphone) }.buttonStyle(PillStyle())
        }
        .disabled(shazam.shortcutPhase == .running)
    }

    private var retryButton: some View {
        Button(lang.t(.shazamAgain)) { shazam.reset() }.buttonStyle(PillStyle())
    }

    private func failureText(_ failure: ShazamRecognizer.Failure) -> String {
        switch failure {
        case .microphoneDenied: return lang.t(.shazamMicDenied)
        case .noAudioSource: return lang.t(.shazamNoSource)
        case .network: return lang.t(.shazamNetwork)
        case .service(let code) where code == SHError.Code.matchAttemptFailed.rawValue: return lang.t(.shazamCatalogFailed)
        case .service(let code): return lang.t(.shazamService, String(code))
        }
    }

    private var systemRecognition: some View {
        VStack(spacing: 5) {
            Text(systemRecognitionStatus).font(.system(size: 10)).foregroundStyle(.white.opacity(0.75))
                .multilineTextAlignment(.center).lineLimit(4).fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 6) {
                Button(lang.t(.shazamSystemOpen), action: openSystemPanel).buttonStyle(PillStyle())
                    .disabled(openingSystemPanel || shazam.shortcutPhase == .running)
                    .help(lang.t(.shazamSystemFallback))
                if shazam.shortcutPhase == .running {
                    // The shortcut runs in Shortcuts; stopping it is the user's choice.
                    Button(lang.t(.shazamShortcutStop)) { shazam.stopShortcut() }.buttonStyle(PillStyle())
                } else {
                    Button(lang.t(.shazamShortcut), action: chooseShortcut).buttonStyle(PillStyle())
                        .disabled(openingSystemPanel)
                        .help(lang.t(.shazamShortcutHelp))
                }
                // No AudD shortcut here: the third-party service is only reachable after the
                // user picks it in Settings › Music Recognition (and consents there).
                if systemPanelStatus == .permissionNeeded {
                    // Opens Privacy & Security › Accessibility; the user decides there.
                    Button(lang.t(.openSettings)) { SystemSettingsLink.open(.accessibility) }.buttonStyle(PillStyle())
                }
                guideButton
            }
        }
    }

    private var systemRecognitionStatus: String {
        switch shazam.shortcutPhase {
        case .running: return lang.t(.shazamShortcutRunning)
        case .finished: return lang.t(.shazamShortcutFinished)
        case .failed: return lang.t(.shazamShortcutFailed)
        case .notFound: return lang.t(.shazamShortcutNotFound, shortcutName)
        case .stopped: return lang.t(.shazamShortcutStopped)
        case .timedOut: return lang.t(.shazamShortcutTimedOut)
        // Whatever the user's shortcut printed, labelled as such (not as our own match).
        case .result(let text): return lang.t(.shazamShortcutResult, text)
        case .idle: break
        }
        switch systemPanelStatus {
        case .listening: return lang.t(.shazamSystemListening)
        case .uncertain: return lang.t(.shazamSystemUncertain)
        case .permissionNeeded: return lang.t(.shazamSystemNeedsAX)
        case .notInControlCenter: return lang.t(.shazamSystemMissing)
        case .menuBarNotExposed: return lang.t(.shazamSystemNotExposed)
        case .unavailable: return lang.t(.shazamSystemUnavailable)
        case nil: return lang.t(.shazamSystemFallback)
        }
    }

    private func openSystemPanel() {
        shazam.clearShortcutResult()
        openingSystemPanel = true
        DispatchQueue.global(qos: .userInitiated).async {
            let result = ControlCenterMedia.startMusicRecognition()
            DispatchQueue.main.async {
                systemPanelStatus = result
                openingSystemPanel = false
            }
        }
    }

    private func chooseShortcut() {
        let alert = NSAlert()
        alert.messageText = lang.t(.shazamShortcut)
        alert.informativeText = lang.t(.shazamShortcutHelp)
        alert.addButton(withTitle: lang.t(.shazamShortcutRun))
        alert.addButton(withTitle: lang.t(.cancel))
        alert.addButton(withTitle: lang.t(.shazamShortcutOpen))
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 280, height: 24))
        field.placeholderString = lang.t(.shazamShortcutName)
        field.stringValue = shortcutName
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        NSApp.activate()
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            shortcutName = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            shazam.runShortcut(named: shortcutName)
        case .alertThirdButtonReturn:
            if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.shortcuts") {
                NSWorkspace.shared.open(url)
            }
        default: break
        }
    }

    /// Opens Apple's support article for Recognize Music in the browser.
    private var guideButton: some View {
        Button {
            NSWorkspace.shared.open(ShazamRecognizer.recognizeMusicGuideURL(lang.language))
        } label: {
            Label(lang.t(.shazamSystemGuide), systemImage: "safari")
        }
        .buttonStyle(PillStyle())
        .help(lang.t(.shazamSystemFallback))
    }
}

// MARK: - Toast in the notch

struct ToastLeading: View {
    var toast: IslandToast
    var body: some View {
        Image(systemName: toast.symbol)
            .font(.system(size: 12, weight: .bold))
            .foregroundStyle(toast.style == .failure ? Color(hex: 0xFF453A) : (toast.style == .success ? Color(hex: 0x30D158) : .white))
            .transition(.scale.combined(with: .opacity))
    }
}

struct ToastTrailing: View {
    var toast: IslandToast
    var body: some View {
        Text(toast.text)
            .accessibilityLabel(toast.accessibilityText ?? toast.text)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.white)
            .lineLimit(1)
            .minimumScaleFactor(0.6)
            .transition(.opacity)
    }
}
