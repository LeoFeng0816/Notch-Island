import SwiftUI
import AppKit

// Pomodoro UI: widget card, Live Activities panel, compact notch pieces and the
// Settings section. Behaviour and definitions live in `PomodoroTimer`.

enum PomodoroStyle {
    /// Light, clear tomato red (≈7.5:1 contrast on the black island).
    static let tomato = Color(hex: 0xFF6B57)
    /// The Pomodoro's one icon everywhere (widget, compact island, Live Activities,
    /// Settings): Apple's built-in `timer` SF Symbol in tomato red. The countdown
    /// timer uses the same symbol in orange; colour, dots and labels tell them apart.
    static let symbol = "timer"
    /// Dark tomato fill behind the primary button (like the iOS Clock buttons).
    static let buttonFill = Color(hex: 0x3D1A14)
    /// Paused stays a light tomato (just softer); a pause glyph marks the state.
    static let pausedOpacity = 0.78
}

/// The Pomodoro icon (SF Symbol `timer`), decorative for VoiceOver (labels carry the meaning).
struct PomodoroIcon: View {
    var size: CGFloat
    var color: Color = PomodoroStyle.tomato

    var body: some View {
        Image(systemName: PomodoroStyle.symbol)
            .font(.system(size: size, weight: .semibold))
            .foregroundStyle(color)
            .accessibilityHidden(true)
    }
}

/// Four dots: focus sessions completed toward the long break.
struct PomodoroDots: View {
    var filled: Int
    var dot: CGFloat
    var color: Color = PomodoroStyle.tomato

    var body: some View {
        HStack(spacing: dot * 0.55) {
            ForEach(0..<PomodoroTimer.sessionsPerLongBreak, id: \.self) { index in
                Circle()
                    .fill(index < filled ? color : Color.white.opacity(0.22))
                    .frame(width: dot, height: dot)
            }
        }
        .accessibilityHidden(true)
    }
}

// MARK: - Text

@MainActor
enum PomodoroText {
    static func phaseName(_ phase: PomodoroTimer.Phase, _ lang: LanguageSettings) -> String {
        switch phase {
        case .focus: return lang.t(.pomoFocus)
        case .shortBreak: return lang.t(.pomoShortBreak)
        case .longBreak: return lang.t(.pomoLongBreak)
        }
    }

    /// "Focus", "Paused · Short break", "Ready to focus", "Break over".
    static func status(_ p: PomodoroTimer, _ lang: LanguageSettings) -> String {
        switch p.runState {
        case .running: return phaseName(p.phase, lang)
        case .paused: return lang.t(.paused) + " · " + phaseName(p.phase, lang)
        case .ready: return p.notice != nil ? lang.t(.pomoBreakOver) : lang.t(.pomoReady)
        }
    }

    /// "24 minutes, 13 seconds" in the app language (VoiceOver).
    static func spoken(_ seconds: TimeInterval, _ lang: LanguageSettings) -> String {
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = [.minute, .second]
        formatter.unitsStyle = .full
        var calendar = Calendar.current
        calendar.locale = lang.locale
        formatter.calendar = calendar
        return formatter.string(from: max(0, seconds.rounded(.up))) ?? PomodoroTimer.format(seconds)
    }

    /// Full spoken state, e.g. "Pomodoro. Focus. 24 minutes, 13 seconds left. 2 of 4 … 6 completed."
    static func summary(_ p: PomodoroTimer, _ lang: LanguageSettings) -> String {
        var parts = [lang.t(.pomodoro), status(p, lang)]
        if p.runState != .ready { parts.append(lang.t(.pomoA11yRemaining, spoken(p.remaining, lang))) }
        parts.append(lang.t(.pomoSetA11y, "\(p.setProgress)", "\(PomodoroTimer.sessionsPerLongBreak)"))
        parts.append(lang.t(.pomoCompleted, "\(p.completedTotal)"))
        return parts.joined(separator: lang.t(.pomoA11ySeparator))
    }

    static func primaryLabel(_ p: PomodoroTimer, _ lang: LanguageSettings) -> String {
        switch p.runState {
        case .ready: return lang.t(.pomoStartFocus)
        case .running: return lang.t(.pause)
        case .paused: return lang.t(.resume)
        }
    }

    static func resetLabel(_ p: PomodoroTimer, _ lang: LanguageSettings) -> (label: String, help: String) {
        p.resetAction == .count ? (lang.t(.pomoResetCount), lang.t(.pomoResetCountHelp))
            : (lang.t(.pomoResetSession), lang.t(.pomoResetSessionHelp))
    }
}

/// Island message for an automatic transition; nil when it must stay silent
/// (caught up after sleep). One event → at most one message and one sound.
@MainActor
enum PomodoroAnnouncement {
    static func toast(for event: PomodoroTimer.Event, lang: LanguageSettings, longBreakMinutes: Int) -> IslandToast? {
        guard !event.late else { return nil }
        switch event {
        case .focusCompleted(_, let next, _):
            let minutes = Int(PomodoroTimer.duration(of: next, longBreakMinutes: longBreakMinutes) / 60)
            return IslandToast(symbol: "checkmark.circle.fill", text: PomodoroText.phaseName(next, lang), style: .success,
                               accessibilityText: lang.t(.pomoA11yFocusDone, PomodoroText.phaseName(next, lang), "\(minutes)"))
        case .breakEnded:
            return IslandToast(symbol: "bell.fill", text: lang.t(.pomoBreakOver), style: .info,
                               accessibilityText: lang.t(.pomoA11yBreakOver))
        }
    }
}

// MARK: - Shared controls

struct PomodoroControls: View {
    @ObservedObject var pomodoro: PomodoroTimer
    @ObservedObject var lang: LanguageSettings
    /// Diameter of the secondary buttons; the primary one is a little larger.
    var side: CGFloat
    var spacer = true

    var body: some View {
        let reset = PomodoroText.resetLabel(pomodoro, lang)
        HStack(spacing: 6) {
            circle(symbol: pomodoro.resetAction == .count ? "arrow.counterclockwise" : "xmark",
                   fill: Color(white: 0.3), tint: .white, size: side, label: reset.label, help: reset.help) { pomodoro.reset() }
                .disabled(pomodoro.resetAction == nil)
                .opacity(pomodoro.resetAction == nil ? 0.4 : 1)
            if pomodoro.canSkip {
                circle(symbol: "forward.end.fill", fill: Color(white: 0.3), tint: .white, size: side,
                       label: lang.t(.pomoSkipBreak), help: lang.t(.pomoSkipBreakHelp)) { pomodoro.skipBreak() }
                    .transition(.opacity)
            }
            if spacer { Spacer(minLength: 0) }
            circle(symbol: pomodoro.runState == .running ? "pause.fill" : "play.fill",
                   fill: PomodoroStyle.buttonFill, tint: PomodoroStyle.tomato, size: side + 4,
                   label: PomodoroText.primaryLabel(pomodoro, lang), help: PomodoroText.primaryLabel(pomodoro, lang)) {
                pomodoro.toggle()
            }
        }
        .animation(.snappy(duration: 0.2), value: pomodoro.canSkip)
    }

    private func circle(symbol: String, fill: Color, tint: Color, size: CGFloat, label: String, help: String,
                        action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: size * 0.4, weight: .bold))
                .foregroundStyle(tint)
                .frame(width: size, height: size)
                .background(Circle().fill(fill))
                .contentTransition(.symbolEffect(.replace))
        }
        .buttonStyle(PressableStyle())
        .help(help)
        .accessibilityLabel(label)
        .accessibilityHint(help == label ? "" : help)
    }
}

// MARK: - Widget card

/// Widget: phase, time left, progress toward the long break, completed count, and
/// Start / Pause / Resume, Reset and (during breaks) Skip. While a session runs it
/// is also a live activity (compact island + Live Activities page).
struct PomodoroCard: View {
    @ObservedObject var lang: LanguageSettings
    @EnvironmentObject var pomodoro: PomodoroTimer
    @Environment(\.widgetSide) private var side
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let active = pomodoro.runState != .ready
        let tint = pomodoro.runState == .paused ? PomodoroStyle.tomato.opacity(PomodoroStyle.pausedOpacity) : PomodoroStyle.tomato
        WidgetCard {
            DarkCardBackground()
        } content: {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 4) {
                    PomodoroIcon(size: 10.5)
                    Text(lang.t(.pomodoro)).lineLimit(1).minimumScaleFactor(0.7)
                }
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(.white.opacity(0.65))
                Spacer(minLength: 0)
                Text(PomodoroText.status(pomodoro, lang))
                    .font(.system(size: 9.5, weight: .semibold))
                    .foregroundStyle(active || pomodoro.notice != nil ? tint : .white.opacity(0.55))
                    .lineLimit(1).minimumScaleFactor(0.7)
                Text(PomodoroTimer.format(pomodoro.remaining))
                    .font(.system(size: side * 0.2, weight: .light))
                    .monospacedDigit()
                    .foregroundStyle(active ? tint : .white)
                    .contentTransition(.numericText(countsDown: true))
                    .animation(reduceMotion ? nil : .snappy(duration: 0.25), value: Int(pomodoro.remaining.rounded(.up)))
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                HStack(spacing: 4) {
                    PomodoroDots(filled: pomodoro.setProgress, dot: max(4, side * 0.045))
                    Spacer(minLength: 2)
                    Text(lang.t(.pomoCompleted, "\(pomodoro.completedTotal)"))
                        .font(.system(size: 9, weight: .medium).monospacedDigit())
                        .foregroundStyle(.white.opacity(0.55))
                        .lineLimit(1).minimumScaleFactor(0.7)
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(PomodoroText.summary(pomodoro, lang))
                Spacer(minLength: 0)
                PomodoroControls(pomodoro: pomodoro, lang: lang, side: side * 0.21)
            }
            .foregroundStyle(.white)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(lang.t(.pomodoro))
    }
}

// MARK: - Live Activities panel

struct PomodoroPanel: View {
    @ObservedObject var pomodoro: PomodoroTimer
    @ObservedObject var lang: LanguageSettings
    @Binding var tool: ActivityTool
    var options: [ActivityTool] = ActivityTool.allCases
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let tint = pomodoro.runState == .paused ? PomodoroStyle.tomato.opacity(PomodoroStyle.pausedOpacity) : PomodoroStyle.tomato
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 5) {
                ToolSwitcher(tool: $tool, lang: lang, options: options)
                Spacer(minLength: 4)
                Text(PomodoroText.status(pomodoro, lang))
                    .foregroundStyle(pomodoro.runState == .ready ? .white.opacity(0.45) : tint)
                    .lineLimit(1).minimumScaleFactor(0.7)
            }
            .font(.system(size: 10.5, weight: .semibold))
            .foregroundStyle(.white.opacity(0.6))

            HStack(alignment: .center) {
                Text(PomodoroTimer.format(pomodoro.remaining))
                    .font(.system(size: 32, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(pomodoro.runState == .ready ? .white : tint)
                    .contentTransition(.numericText(countsDown: true))
                    .animation(reduceMotion ? nil : .snappy(duration: 0.25), value: Int(pomodoro.remaining.rounded(.up)))
                    .accessibilityLabel(PomodoroText.summary(pomodoro, lang))
                Spacer(minLength: 4)
                PomodoroControls(pomodoro: pomodoro, lang: lang, side: 28, spacer: false)
                    .fixedSize()
            }

            Capsule().fill(.white.opacity(0.12))
                .overlay(alignment: .leading) {
                    GeometryReader { geo in
                        Capsule().fill(PomodoroStyle.tomato)
                            .frame(width: geo.size.width * pomodoro.progress)
                            .animation(reduceMotion ? nil : .linear(duration: 0.2), value: pomodoro.progress)
                    }
                }
                .frame(height: 3)
                .accessibilityHidden(true)

            HStack(spacing: 5) {
                PomodoroDots(filled: pomodoro.setProgress, dot: 5)
                Text(lang.t(.pomoCompleted, "\(pomodoro.completedTotal)"))
                    .font(.system(size: 10, weight: .medium).monospacedDigit())
                    .foregroundStyle(.white.opacity(0.55))
                    .lineLimit(1).minimumScaleFactor(0.7)
                Spacer(minLength: 4)
                Text(lang.t(.pomoLongBreakLength, "\(pomodoro.longBreakMinutes)"))
                    .font(.system(size: 10, weight: .medium).monospacedDigit())
                    .foregroundStyle(.white.opacity(0.6))
                    .lineLimit(1).minimumScaleFactor(0.7)
                    .help(lang.t(.pomoLongBreakHelp))
                Button { pomodoro.adjustLongBreak(by: -1) } label: { Image(systemName: "minus") }
                    .buttonStyle(PillStyle())
                    .disabled(pomodoro.longBreakMinutes <= PomodoroTimer.longBreakRange.lowerBound)
                    .accessibilityLabel(lang.t(.pomoLongBreakShorter))
                    .help(lang.t(.pomoLongBreakShorter))
                Button { pomodoro.adjustLongBreak(by: 1) } label: { Image(systemName: "plus") }
                    .buttonStyle(PillStyle())
                    .disabled(pomodoro.longBreakMinutes >= PomodoroTimer.longBreakRange.upperBound)
                    .accessibilityLabel(lang.t(.pomoLongBreakLonger))
                    .help(lang.t(.pomoLongBreakLonger))
            }
            .padding(.top, 2)
        }
    }
}

// MARK: - Compact island pieces

/// Left of the notch when nothing else needs it: phase glyph + progress dots.
struct PomodoroCompactBadge: View {
    @ObservedObject var pomodoro: PomodoroTimer
    @ObservedObject var lang: LanguageSettings
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let ended = pomodoro.notice?.endedBreak
        HStack(spacing: 4) {
            PomodoroIcon(size: 13)
                .symbolEffect(.pulse, options: .repeating, isActive: ended != nil && !reduceMotion)
            PomodoroDots(filled: pomodoro.setProgress, dot: 4.5)
        }
        .opacity(pomodoro.runState == .paused ? PomodoroStyle.pausedOpacity : 1)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(lang.t(.pomoSetA11y, "\(pomodoro.setProgress)", "\(PomodoroTimer.sessionsPerLongBreak)"))
    }
}

/// Right of the notch: time left (or "Done" while the break-over notice shows).
struct PomodoroCompactTime: View {
    @ObservedObject var pomodoro: PomodoroTimer
    @ObservedObject var lang: LanguageSettings
    var glyph: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let paused = pomodoro.runState == .paused
        HStack(spacing: 3) {
            if paused {
                Image(systemName: "pause.fill")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(PomodoroStyle.tomato)
            } else if glyph {
                PomodoroIcon(size: 9.5)
            }
            Text(pomodoro.runState == .ready ? lang.t(.done) : PomodoroTimer.format(pomodoro.remaining))
                .font(.system(size: 12.5, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(PomodoroStyle.tomato)
                .contentTransition(.numericText(countsDown: true))
                .animation(reduceMotion ? nil : .snappy(duration: 0.25), value: Int(pomodoro.remaining.rounded(.up)))
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .opacity(paused ? PomodoroStyle.pausedOpacity : 1)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(PomodoroText.summary(pomodoro, lang))
    }
}

// MARK: - Settings

struct PomodoroSettingsSection: View {
    @ObservedObject var lang: LanguageSettings
    @ObservedObject var pomodoro: PomodoroTimer

    var body: some View {
        Section {
            Stepper(value: Binding(get: { pomodoro.longBreakMinutes }, set: { pomodoro.setLongBreakMinutes($0) }),
                    in: PomodoroTimer.longBreakRange) {
                Text(lang.t(.pomoLongBreakLength, "\(pomodoro.longBreakMinutes)"))
            }
            .accessibilityValue(lang.t(.timerMinutes, "\(pomodoro.longBreakMinutes)"))
            HStack(spacing: 6) {
                ForEach(PomodoroTimer.longBreakPresets, id: \.self) { minutes in
                    Button(lang.t(.timerMinutes, "\(minutes)")) { pomodoro.setLongBreakMinutes(minutes) }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .tint(pomodoro.longBreakMinutes == minutes ? .accentColor : nil)
                }
            }
        } header: {
            Text(lang.t(.pomodoro))
        } footer: {
            Text(lang.t(.pomoRules))
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
