import SwiftUI
import AppKit
import ShazamKit

// MARK: - Quick actions under the widgets

struct QuickActionsBar: View {
    @ObservedObject var model: IslandViewModel
    @ObservedObject var lang: LanguageSettings

    var body: some View {
        HStack(spacing: 8) {
            action("doc.on.clipboard", .qaClipboard) { withAnimation(.spring(response: 0.32, dampingFraction: 0.86)) { model.subpage = .clipboard } }
            action("camera.viewfinder", .qaScreenshot) { model.onScreenshot?() }
            action("record.circle", .qaScreenRecord, help: .recordToolbarHelp) { model.onScreenRecording?() }
            action("shazam.logo.fill", .qaShazam) {
                withAnimation(.spring(response: 0.32, dampingFraction: 0.86)) { model.subpage = .shazam }
            }
        }
        .frame(height: IslandViewModel.quickActionsHeight - 6)
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
        withAnimation(.spring(response: 0.32, dampingFraction: 0.86)) { model.subpage = .none }
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
            Text(lang.t(.clipboardEmpty)).font(.system(size: 11)).foregroundStyle(.white.opacity(0.55))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
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
    @AppStorage("NotchIsland.musicShortcutName") private var shortcutName = ""
    @State private var systemPanelStatus: ControlCenterMedia.MusicRecognitionResult?
    @State private var openingSystemPanel = false
    @State private var showingAudD = false

    init(model: IslandViewModel, lang: LanguageSettings, systemStatus: ControlCenterMedia.MusicRecognitionResult? = nil) {
        self.model = model
        self.lang = lang
        _systemPanelStatus = State(initialValue: systemStatus)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            SubpageHeader(title: "Shazam", closeLabel: lang.t(.close), close: {
                shazam.reset()
                withAnimation(.spring(response: 0.32, dampingFraction: 0.86)) { model.subpage = .none }
            }) { EmptyView() }
            if showingAudD {
                AudDPage(lang: lang) { showingAudD = false }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                content.frame(maxWidth: .infinity, maxHeight: .infinity)
                Text(lang.t(.shazamPrivacy)).font(.system(size: 8.5)).foregroundStyle(.white.opacity(0.45)).lineLimit(2)
            }
        }
        .foregroundStyle(.white)
    }

    @ViewBuilder private var content: some View {
        switch shazam.phase {
        case .idle, .cancelled:
            VStack(spacing: 6) {
                if shazam.phase == .cancelled { Text(lang.t(.shazamCancelled)).font(.system(size: 11)).foregroundStyle(.white.opacity(0.6)) }
                Text(lang.t(.shazamStart)).font(.system(size: 12, weight: .semibold))
                sourceButtons
                systemRecognition
            }
        case .preparing, .listening:
            HStack(spacing: 14) {
                TimelineView(.animation(minimumInterval: 1 / 30)) { context in
                    let t = context.date.timeIntervalSinceReferenceDate
                    Image(systemName: "shazam.logo.fill").font(.system(size: 34))
                        .foregroundStyle(Color(hex: 0x0A84FF))
                        .scaleEffect(1 + 0.06 * sin(t * 4))
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
                            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") { NSWorkspace.shared.open(url) }
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
                .multilineTextAlignment(.center).lineLimit(3).fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 6) {
                Button(lang.t(.shazamSystemOpen), action: openSystemPanel).buttonStyle(PillStyle())
                    .disabled(openingSystemPanel || shazam.shortcutPhase == .running)
                    .help(lang.t(.shazamSystemFallback))
                Button(lang.t(.shazamShortcut), action: chooseShortcut).buttonStyle(PillStyle())
                    .disabled(shazam.shortcutPhase == .running || openingSystemPanel)
                Button(lang.t(.audDTitle)) { showingAudD = true }.buttonStyle(PillStyle())
                    .disabled(shazam.shortcutPhase == .running)
                if systemPanelStatus == .permissionNeeded {
                    // Opens System Settings; the user decides. Never granted automatically.
                    Button(lang.t(.openSettings)) {
                        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") { NSWorkspace.shared.open(url) }
                    }.buttonStyle(PillStyle())
                } else {
                    guideButton
                }
            }
        }
    }

    private var systemRecognitionStatus: String {
        switch shazam.shortcutPhase {
        case .running: return lang.t(.shazamShortcutRunning)
        case .finished: return lang.t(.shazamShortcutFinished)
        case .failed: return lang.t(.shazamShortcutFailed)
        case .result(let text): return text
        case .idle: break
        }
        switch systemPanelStatus {
        case .listening: return lang.t(.shazamSystemListening)
        case .uncertain: return lang.t(.shazamSystemUncertain)
        case .permissionNeeded: return lang.t(.shazamSystemNeedsAX)
        case .notInControlCenter: return lang.t(.shazamSystemMissing)
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
        alert.addButton(withTitle: lang.t(.shazamShortcutGallery))
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
            NSWorkspace.shared.open(URL(string: "shortcuts://gallery")!)
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
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.white)
            .lineLimit(1)
            .minimumScaleFactor(0.6)
            .transition(.opacity)
    }
}
