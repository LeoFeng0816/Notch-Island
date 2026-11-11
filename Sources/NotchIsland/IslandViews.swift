import SwiftUI
import AppKit

struct IslandShapeParams: Equatable {
    /// Part inside the menu bar: the physical notch, or notch + side indicators.
    var neckWidth: CGFloat
    var neckHeight: CGFloat
    var neckRadius: CGFloat
    /// Outward curve at the top edge that blends the neck into the bezel.
    var flare: CGFloat
    /// Part hanging below the menu bar. `bodyTop` is never above the menu bar
    /// line, so the body can never cover menu bar items, even mid-animation.
    var bodyWidth: CGFloat
    var bodyTop: CGFloat
    var height: CGFloat
    var bodyRadius: CGFloat
}

/// Union of a neck (confined to the notch / active indicators) and a body that
/// only exists below the menu bar. Idle/compact have a zero-height body, so all
/// states morph through one animatable shape. Drawn centred on `rect.midX`
/// from `rect.minY`; the same path is used for mouse hit testing.
struct IslandShape: Shape {
    var p: IslandShapeParams

    static let bodyTopRadius: CGFloat = 18

    typealias Pair = AnimatablePair
    var animatableData: Pair<Pair<Pair<CGFloat, CGFloat>, Pair<CGFloat, CGFloat>>,
                             Pair<Pair<CGFloat, CGFloat>, Pair<CGFloat, CGFloat>>> {
        get {
            Pair(Pair(Pair(p.neckWidth, p.neckHeight), Pair(p.neckRadius, p.flare)),
                 Pair(Pair(p.bodyWidth, p.bodyTop), Pair(p.height, p.bodyRadius)))
        }
        set {
            p.neckWidth = newValue.first.first.first
            p.neckHeight = newValue.first.first.second
            p.neckRadius = newValue.first.second.first
            p.flare = newValue.first.second.second
            p.bodyWidth = newValue.second.first.first
            p.bodyTop = newValue.second.first.second
            p.height = newValue.second.second.first
            p.bodyRadius = newValue.second.second.second
        }
    }

    func path(in rect: CGRect) -> Path {
        let cx = rect.midX, top = rect.minY
        func pt(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: x, y: top + y) }
        var path = Path()

        // Neck: flared top, straight sides, rounded bottom.
        let nw = max(0, p.neckWidth) / 2
        let nh = max(0, p.neckHeight)
        if nw > 0.5, nh > 0.5 {
            let f = min(max(0, p.flare), nh / 2)
            let r = max(0, min(p.neckRadius, nw, nh - f))
            path.move(to: pt(cx - nw - f, 0))
            path.addQuadCurve(to: pt(cx - nw, f), control: pt(cx - nw, 0))
            path.addLine(to: pt(cx - nw, nh - r))
            path.addQuadCurve(to: pt(cx - nw + r, nh), control: pt(cx - nw, nh))
            path.addLine(to: pt(cx + nw - r, nh))
            path.addQuadCurve(to: pt(cx + nw, nh - r), control: pt(cx + nw, nh))
            path.addLine(to: pt(cx + nw, f))
            path.addQuadCurve(to: pt(cx + nw + f, 0), control: pt(cx + nw, 0))
            path.closeSubpath()
        }

        // Body: rounded rectangle below the menu bar (same winding → union).
        let bw = max(0, p.bodyWidth) / 2
        let y0 = max(0, p.bodyTop)
        let depth = p.height - y0
        if bw > 0.5, depth > 0.5 {
            let r = max(0, min(p.bodyRadius, bw, depth / 2))
            let c = max(0, min(Self.bodyTopRadius, bw, depth - r))
            let y1 = p.height
            path.move(to: pt(cx - bw + c, y0))
            path.addQuadCurve(to: pt(cx - bw, y0 + c), control: pt(cx - bw, y0))
            path.addLine(to: pt(cx - bw, y1 - r))
            path.addQuadCurve(to: pt(cx - bw + r, y1), control: pt(cx - bw, y1))
            path.addLine(to: pt(cx + bw - r, y1))
            path.addQuadCurve(to: pt(cx + bw, y1 - r), control: pt(cx + bw, y1))
            path.addLine(to: pt(cx + bw, y0 + c))
            path.addQuadCurve(to: pt(cx + bw - c, y0), control: pt(cx + bw, y0))
            path.closeSubpath()
        }
        return path
    }
}

struct IslandRootView: View {
    @ObservedObject var model: IslandViewModel
    @ObservedObject var timer: CountdownTimer
    @ObservedObject var music: MusicController
    @ObservedObject var lang: LanguageSettings
    let stopwatch: Stopwatch
    let battery: BatteryMonitor
    let data: WidgetDataCenter
    let settings: WidgetSettings
    let calendar: CalendarStore
    let location: LocationProvider
    let audioMonitor: AudioLevelMonitor
    let clipboard: ClipboardStore
    let shazam: ShazamRecognizer
    let audd: AudDRecognition
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let mode = model.mode
        let shape = IslandShape(p: model.currentParams)
        let window = model.windowSize

        ZStack(alignment: .top) {
            // Shadow layer, masked so it never darkens the menu bar.
            shape
                .fill(Color.black)
                .shadow(color: .black.opacity(mode == .expanded ? 0.45 : 0), radius: 16, y: 6)
                .mask(alignment: .top) {
                    VStack(spacing: 0) {
                        Color.clear.frame(height: model.menuBarHeight)
                        Color.black
                    }
                }
            shape.fill(Color.black)

            VStack(spacing: 0) {
                // Menu-bar row: only the notch and, while active, its side indicators.
                ZStack {
                    if model.isActive {
                        CompactContent(model: model, timer: timer, music: music, lang: lang)
                            .frame(width: model.compactWidth)
                            .transition(.opacity.animation(.easeOut(duration: 0.18)))
                    }
                }
                .frame(height: model.menuBarHeight)

                // Everything else emerges downward, below the menu bar.
                if mode == .expanded {
                    ExpandedContent(model: model, timer: timer, music: music, lang: lang)
                        .frame(width: IslandViewModel.expandedWidth, height: model.contentHeight)
                        .overlay(alignment: .bottom) {
                            if let toast = model.toast {
                                HStack(spacing: 7) {
                                    ToastLeading(toast: toast)
                                    ToastTrailing(toast: toast)
                                }
                                .padding(.horizontal, 12)
                                .padding(.vertical, 7)
                                .background(.regularMaterial, in: Capsule())
                                .padding(.bottom, 10)
                                .allowsHitTesting(false)
                                .transition(.opacity)
                            }
                        }
                        .padding(.top, model.bodyTop - model.menuBarHeight)
                        .transition(.asymmetric(
                            insertion: reduceMotion ? .opacity.animation(.easeOut(duration: 0.16))
                                : .opacity.combined(with: .offset(y: -14)).combined(with: .scale(scale: 0.96, anchor: .top))
                                .animation(.easeOut(duration: 0.26).delay(0.08)),
                            // The shape still contracts. Remove the expanded widgets immediately
                            // so their idle timer cannot show through the shrinking panel.
                            removal: .identity))
                } else if let banner = model.banner, mode == .compact {
                    PowerBannerView(banner: banner, model: model, lang: lang)
                        .frame(width: IslandViewModel.bannerWidth, height: IslandViewModel.bannerHeight)
                        .padding(.top, model.bodyTop - model.menuBarHeight)
                        .transition(reduceMotion ? .opacity : .opacity.combined(with: .offset(y: -8)))
                }
            }
            .frame(width: window.width, height: window.height, alignment: .top)
            .clipShape(shape)
        }
        .frame(width: window.width, height: window.height, alignment: .top)
        .animation(reduceMotion ? .easeOut(duration: 0.12) : .spring(response: 0.3, dampingFraction: 0.7), value: model.isHovering)
        .environment(\.colorScheme, .dark)
        .environmentObject(model)
        .environmentObject(timer)
        .environmentObject(stopwatch)
        .environmentObject(battery)
        .environmentObject(data)
        .environmentObject(settings)
        .environmentObject(calendar)
        .environmentObject(location)
        .environmentObject(audioMonitor)
        .environmentObject(clipboard)
        .environmentObject(shazam)
        .environmentObject(audd)
    }
}

// MARK: - Compact (sides of the notch only)

struct CompactContent: View {
    @ObservedObject var model: IslandViewModel
    @ObservedObject var timer: CountdownTimer
    @ObservedObject var music: MusicController
    @ObservedObject var lang: LanguageSettings

    var body: some View {
        let notch = model.geometry.notchSize
        HStack(spacing: 0) {
            leading
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.leading, 10)
            Color.clear.frame(width: notch.width)
            trailing
                .frame(maxWidth: .infinity, alignment: .trailing)
                .padding(.trailing, 10)
        }
        .frame(height: notch.height)
        .contentShape(Rectangle())
        .onTapGesture { model.setExpanded(true) }
    }

    @EnvironmentObject var stopwatch: Stopwatch
    @EnvironmentObject var audioMonitor: AudioLevelMonitor

    @ViewBuilder private var leading: some View {
        if let toast = model.toast {
            ToastLeading(toast: toast)
        } else if music.isPlaying {
            ArtworkView(image: music.artwork, size: max(16, model.geometry.notchSize.height - 12), corner: 5)
        } else if timer.isActive {
            Image(systemName: timer.phase == .finished ? "bell.fill" : "timer")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.orange)
                .symbolEffect(.pulse, options: .repeating, isActive: timer.phase == .finished)
        } else if stopwatch.isActive {
            Image(systemName: "stopwatch")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.cyan)
        }
    }

    @ViewBuilder private var trailing: some View {
        if let toast = model.toast {
            ToastTrailing(toast: toast)
        } else if timer.isActive {
            Text(timer.phase == .finished ? lang.t(.done) : CountdownTimer.format(timer.remaining))
                .font(.system(size: 12.5, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(timer.phase == .paused ? Color.orange.opacity(0.55) : .orange)
                .contentTransition(.numericText(countsDown: true))
                .animation(.snappy(duration: 0.25), value: Int(timer.remaining.rounded(.up)))
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        } else if stopwatch.isActive {
            TimelineView(.periodic(from: .now, by: 0.5)) { context in
                Text(Stopwatch.format(stopwatch.elapsed(at: context.date), fraction: false))
                    .font(.system(size: 12.5, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(stopwatch.phase == .paused ? Color.cyan.opacity(0.55) : .cyan)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
        } else if music.isPlaying {
            MusicBars(isPlaying: music.isPlaying, palette: music.palette, realLevels: audioMonitor.levels)
        }
    }
}

// MARK: - Expanded

struct ExpandedContent: View {
    @ObservedObject var model: IslandViewModel
    @ObservedObject var timer: CountdownTimer
    @ObservedObject var music: MusicController
    @ObservedObject var lang: LanguageSettings
    @EnvironmentObject var stopwatch: Stopwatch
    @EnvironmentObject private var audd: AudDRecognition
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: 0) {
            // Header sits below the menu bar, inside the body.
            ZStack {
                HStack(spacing: 6) {
                    Text(lang.t(.appName))
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.55))
                        .lineLimit(1)
                    Spacer(minLength: 12)
                    Button { model.onOpenSettings?() } label: {
                        Image(systemName: "gearshape.fill")
                            .font(.system(size: 10.5, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.55))
                            .frame(width: 20, height: 17)
                    }
                    .buttonStyle(PressableStyle())
                    .help(lang.t(.settingsMenu))
                    .accessibilityLabel(lang.t(.settingsMenu))
                }
                PageSwitcher(model: model, lang: lang)
            }
            .padding(.horizontal, model.page == .widgets ? 15 : 22)
            .padding(.top, 10)
            .frame(height: 32)

            ZStack {
                switch model.page {
                case .activities:
                    // Only tools that are actually running appear here; an idle
                    // timer/stopwatch lives in its widget.
                    let tools = IslandViewModel.visibleTools(timerActive: timer.isActive, stopwatchActive: stopwatch.isActive)
                    HStack(alignment: .top, spacing: 16) {
                        MusicPanel(music: music, lang: lang)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        if let tool = IslandViewModel.resolvedTool(model.activityTool, in: tools) {
                            Rectangle()
                                .fill(.white.opacity(0.1))
                                .frame(width: 1)
                                .padding(.vertical, 4)
                            Group {
                                switch tool {
                                case .timer: TimerPanel(timer: timer, lang: lang, tool: $model.activityTool, options: tools)
                                case .stopwatch: StopwatchPanel(stopwatch: stopwatch, lang: lang, tool: $model.activityTool, options: tools)
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .transition(.opacity)
                        }
                    }
                    .animation(.smooth(duration: 0.3), value: tools)
                    .transition(.opacity.combined(with: .offset(x: -12)))
                case .widgets:
                    Group {
                        switch model.subpage {
                        case .none:
                            VStack(spacing: 6) {
                                WidgetsPage(model: model, lang: lang)
                                QuickActionsBar(model: model, lang: lang)
                            }
                        case .clipboard:
                            ClipboardPage(model: model, lang: lang)
                                .transition(reduceMotion ? .opacity : .opacity.combined(with: .offset(y: 8)))
                        case .shazam(let status):
                            ShazamPage(model: model, lang: lang, systemStatus: status, audd: audd)
                                .transition(.opacity)
                        case .audd:
                            ShazamPage(model: model, lang: lang, startWithAudD: true, audd: audd)
                                .transition(reduceMotion ? .opacity : .opacity.combined(with: .offset(y: 8)))
                        }
                    }
                    .transition(.opacity.combined(with: .offset(x: 12)))
                }
            }
            .padding(.horizontal, model.page == .widgets ? IslandViewModel.widgetsHorizontalPadding : 20)
            .padding(.top, model.page == .widgets ? 6 : 8)
            .padding(.bottom, model.page == .widgets ? 14 : 16)
            .frame(maxHeight: .infinity, alignment: .top)
        }
        .foregroundStyle(.white)
    }
}

struct MusicPanel: View {
    @ObservedObject var music: MusicController
    @ObservedObject var lang: LanguageSettings
    @EnvironmentObject var model: IslandViewModel
    @EnvironmentObject var audioMonitor: AudioLevelMonitor

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            ArtworkView(image: music.artwork, size: 72, corner: 14)
                .shadow(color: (music.palette?.primary.color ?? .clear).opacity(0.45), radius: 10)
                .scaleEffect(music.isPlaying || music.track == nil ? 1 : 0.92)
                .animation(.spring(response: 0.35, dampingFraction: 0.75), value: music.isPlaying)

            VStack(alignment: .leading, spacing: 3) {
                if let track = music.track {
                    HStack(spacing: 6) {
                        Text(sourceName)
                            .font(.system(size: 9.5, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.45))
                            .textCase(.uppercase)
                        MusicBars(isPlaying: music.isPlaying, palette: music.palette, realLevels: audioMonitor.levels)
                    }
                    Text(track.title)
                        .font(.system(size: 13, weight: .semibold))
                        .lineLimit(1)
                    Text(track.artist.isEmpty ? track.album : track.artist)
                        .font(.system(size: 11))
                        .foregroundStyle(.white.opacity(0.6))
                        .lineLimit(1)
                    ProgressLine(music: music, lang: lang, trackIdentity: music.trackIdentity)
                        .id(music.trackIdentity)
                        .padding(.top, 3)
                    controls.padding(.top, 2)
                    if music.source == .chrome, music.browserIssues[.chrome] == .youtubeMusicAppNotVisible {
                        // We may be showing a YouTube video while the PWA plays something we can't see.
                        Text(lang.t(.ytmAppNotVisibleShort))
                            .font(.system(size: 9.5))
                            .foregroundStyle(.yellow.opacity(0.85))
                            .lineLimit(2)
                            .minimumScaleFactor(0.8)
                            .help(lang.t(.ytmAppNotVisible))
                    }
                    if !music.routesThroughControlCenter && music.controlOutcome == .noEffect && !music.lastControlFailed {
                        Text(lang.t(.controlNoEffect))
                            .font(.system(size: 9.5))
                            .foregroundStyle(.yellow.opacity(0.85))
                            .lineLimit(2)
                            .minimumScaleFactor(0.8)
                    }
                    if !music.routesThroughControlCenter && music.lastControlFailed {
                        Text(lang.t(.controlFailed))
                            .font(.system(size: 9.5))
                            .foregroundStyle(.yellow.opacity(0.85))
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                    }
                    if music.seekFailed {
                        Text(lang.t(.seekFailed))
                            .font(.system(size: 9.5))
                            .foregroundStyle(.yellow.opacity(0.85))
                            .lineLimit(1)
                    }
                } else {
                    Text(lang.t(.nothingPlaying))
                        .font(.system(size: 13, weight: .semibold))
                    Text(emptyHint)
                        .font(.system(size: 11))
                        .foregroundStyle(.white.opacity(0.55))
                        .fixedSize(horizontal: false, vertical: true)
                        .lineLimit(3)
                    if music.showsSystemControls {
                        controls.padding(.top, 2)
                    }
                    if music.permissionDenied || music.browserIssues.values.contains(.automationDenied) {
                        Button(lang.t(.openSettings)) { music.openAutomationSettings() }
                            .buttonStyle(PillStyle())
                            .padding(.top, 4)
                    } else if !music.browserIssues.isEmpty {
                        // Automation not yet allowed, or JavaScript from Apple Events off.
                        Button(lang.t(.setUp)) { model.onOpenSettings?() }
                            .buttonStyle(PillStyle())
                            .padding(.top, 4)
                    }
                }
                if let message = music.controlCenterFeedback {
                    Text(lang.t(message))
                        .font(.system(size: 9.5))
                        .foregroundStyle(.yellow.opacity(0.85))
                        .lineLimit(2)
                        .help(lang.t(message))
                }
            }
        }
        .frame(maxHeight: .infinity)
        .padding(8)
        // Gradient from the album cover's own colours (no colours when there's no artwork).
        .background {
            if let palette = music.palette {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(LinearGradient(colors: [palette.primary.color.opacity(0.42), palette.secondary.color.opacity(0.18)],
                                         startPoint: .topLeading, endPoint: .bottomTrailing))
                    .transition(.opacity)
            }
        }
        .padding(-8)
        .animation(.easeInOut(duration: 0.6), value: music.palette)
    }

    private var sourceName: String {
        switch music.source {
        case .spotify: return "Spotify"
        case .chrome: return (music.browserSite?.displayName ?? "YouTube") + " · Chrome"
        case .safari: return (music.browserSite?.displayName ?? "YouTube") + " · Safari"
        case .system: return music.systemAppName ?? lang.t(.nowPlaying)
        default: return lang.t(.musicApp)
        }
    }

    /// Honest empty state: says why browser playback can't be shown instead of guessing.
    private var emptyHint: String {
        if music.permissionDenied { return lang.t(.permissionNeeded) }
        if let (browser, issue) = music.browserIssues.sorted(by: { $0.key.rawValue < $1.key.rawValue }).first {
            switch issue {
            case .javascriptDisabled: return lang.t(.browserJSHint, browser.displayName)
            case .needsAutomation: return lang.t(.browserNeedsAutomation, browser.displayName)
            case .automationDenied: return lang.t(.browserAutomationHint, browser.displayName)
            case .youtubeMusicAppNotVisible: return lang.t(.ytmAppNotVisible)
            }
        }
        return lang.t(.playHint)
    }

    private var controls: some View {
        // Generous hit areas (the glyphs alone are ~13 pt and easy to miss).
        HStack(spacing: 8) {
            Button { music.previousTrack() } label: {
                Image(systemName: "backward.fill").frame(width: 30, height: 26).contentShape(Rectangle())
            }
            .accessibilityLabel(lang.t(.previousTrack))
            Button { music.playPause() } label: {
                // Unknown state (controlling via media keys with nothing readable): neutral icon.
                // Reacts immediately to the press; dimmed until the player confirms.
                Image(systemName: music.routesThroughControlCenter || music.track == nil
                      ? "playpause.fill" : (music.displayedIsPlaying ? "pause.fill" : "play.fill"))
                    .font(.system(size: 18))
                    .frame(width: 34, height: 26)
                    .contentShape(Rectangle())
                    .contentTransition(.symbolEffect(.replace))
                    .opacity(music.controlPending ? 0.55 : 1)
                    .animation(.easeOut(duration: 0.15), value: music.controlPending)
            }
            .accessibilityLabel(lang.t(.playPause))
            .accessibilityValue(music.controlPending ? lang.t(.controlSending) : "")
            .help(music.controlPending ? lang.t(.controlSending) : lang.t(.playPause))
            Button { music.nextTrack() } label: {
                Image(systemName: "forward.fill").frame(width: 30, height: 26).contentShape(Rectangle())
            }
            .accessibilityLabel(lang.t(.nextTrack))
        }
        .font(.system(size: 13))
        .buttonStyle(PressableStyle())
        .disabled(music.controlCenterBusy)
        .opacity(music.controlCenterBusy ? 0.55 : 1)
    }
}

struct ProgressLine: View {
    @ObservedObject var music: MusicController
    @ObservedObject var lang: LanguageSettings
    let trackIdentity: String
    @State private var isDragging = false
    @State private var preview: TimeInterval?

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            if let duration = music.track?.duration, duration.isFinite, duration > 0,
               let base = music.position {
                let running = music.isPlaying && music.pendingPlaying != false
                let elapsed = running ? max(0, context.date.timeIntervalSince(music.positionDate)) : 0
                let current = min(duration, max(0, preview ?? (base + elapsed)))
                HStack(spacing: 6) {
                    Text(CountdownTimer.formatElapsed(current))
                    if music.canSeek {
                        Slider(value: Binding(get: { current }, set: { value in
                            if isDragging { preview = value }
                            else { music.seek(to: value, trackIdentity: trackIdentity) }
                        }), in: 0...duration, onEditingChanged: { editing in
                            isDragging = editing
                            if !editing, let preview {
                                self.preview = nil
                                music.seek(to: preview, trackIdentity: trackIdentity)
                            }
                        })
                        .labelsHidden()
                        .controlSize(.small)
                        .tint(.white.opacity(0.85))
                        .accessibilityLabel(lang.t(.playbackPosition))
                        .accessibilityValue(CountdownTimer.formatElapsed(current))
                    } else {
                        ProgressView(value: current, total: duration)
                            .tint(.white.opacity(0.85))
                    }
                    Text(CountdownTimer.formatElapsed(duration))
                }
                .font(.system(size: 9, weight: .medium).monospacedDigit())
                .foregroundStyle(.white.opacity(0.5))
            }
        }
    }
}

struct TimerPanel: View {
    @ObservedObject var timer: CountdownTimer
    @ObservedObject var lang: LanguageSettings
    @Binding var tool: ActivityTool
    var options: [ActivityTool] = ActivityTool.allCases

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 5) {
                ToolSwitcher(tool: $tool, lang: lang, options: options)
                Spacer()
                Text(statusText)
                    .foregroundStyle(timer.phase == .finished ? .orange : .white.opacity(0.45))
            }
            .font(.system(size: 10.5, weight: .semibold))
            .foregroundStyle(.white.opacity(0.6))

            HStack(alignment: .center) {
                Text(CountdownTimer.format(timer.remaining))
                    .font(.system(size: 32, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(timer.phase == .idle ? .white : .orange)
                    .contentTransition(.numericText(countsDown: true))
                    .animation(.snappy(duration: 0.25), value: Int(timer.remaining.rounded(.up)))
                Spacer()
                Button { timer.reset() } label: {
                    Image(systemName: "arrow.counterclockwise")
                        .font(.system(size: 12, weight: .semibold))
                        .frame(width: 28, height: 28)
                        .background(Circle().fill(.white.opacity(0.12)))
                }
                .buttonStyle(PressableStyle())
                .help(lang.t(.reset))
                .disabled(timer.phase == .idle)
                .opacity(timer.phase == .idle ? 0.35 : 1)
                Button { timer.toggle() } label: {
                    Image(systemName: timer.phase == .running ? "pause.fill" : "play.fill")
                        .font(.system(size: 13, weight: .bold))
                        .frame(width: 34, height: 34)
                        .background(Circle().fill(Color.orange))
                        .foregroundStyle(.black)
                        .contentTransition(.symbolEffect(.replace))
                }
                .buttonStyle(PressableStyle())
                .help(primaryHelp)
            }

            Capsule().fill(.white.opacity(0.12))
                .overlay(alignment: .leading) {
                    GeometryReader { geo in
                        Capsule().fill(Color.orange)
                            .frame(width: geo.size.width * timer.progress)
                            .animation(.linear(duration: 0.2), value: timer.progress)
                    }
                }
                .frame(height: 3)

            HStack(spacing: 5) {
                Button { timer.adjust(minutes: -1) } label: { Image(systemName: "minus") }
                    .buttonStyle(PillStyle())
                ForEach(CountdownTimer.presets, id: \.self) { minutes in
                    Button("\(minutes)\(lang.t(.minuteShort))") { timer.start(minutes: minutes) }
                        .buttonStyle(PillStyle(highlighted: timer.phase == .idle && Int(timer.selectedDuration) == minutes * 60))
                }
                Button { timer.adjust(minutes: 1) } label: { Image(systemName: "plus") }
                    .buttonStyle(PillStyle())
            }
            .padding(.top, 2)
        }
    }

    private var statusText: String {
        switch timer.phase {
        case .idle: return lang.t(.ready)
        case .running: return lang.t(.running)
        case .paused: return lang.t(.paused)
        case .finished: return lang.t(.timesUp)
        }
    }

    private var primaryHelp: String {
        switch timer.phase {
        case .running: return lang.t(.pause)
        case .paused: return lang.t(.resume)
        case .idle, .finished: return lang.t(.start)
        }
    }
}

// MARK: - Small components

struct ArtworkView: View {
    var image: NSImage?
    var size: CGFloat
    var corner: CGFloat

    var body: some View {
        ZStack {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .transition(.opacity)
            } else {
                LinearGradient(colors: [Color(white: 0.28), Color(white: 0.16)], startPoint: .top, endPoint: .bottom)
                Image(systemName: "music.note")
                    .font(.system(size: size * 0.42, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.6))
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: corner, style: .continuous))
        .animation(.easeOut(duration: 0.2), value: image != nil)
    }
}

struct PressableStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .contentShape(Rectangle())
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.88 : 1)
            .opacity(configuration.isPressed ? 0.75 : 1)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

struct PillStyle: ButtonStyle {
    var highlighted = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 10.5, weight: .semibold))
            .padding(.horizontal, 8)
            .frame(height: 20)
            .background(Capsule().fill(highlighted ? Color.orange.opacity(0.35) : .white.opacity(configuration.isPressed ? 0.24 : 0.12)))
            .foregroundStyle(.white.opacity(0.9))
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.94 : 1)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

extension CountdownTimer {
    nonisolated static func formatElapsed(_ interval: TimeInterval) -> String {
        let seconds = max(0, Int(interval))
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
}
