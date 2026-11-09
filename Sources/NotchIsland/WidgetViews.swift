import SwiftUI
import AppKit

// MARK: - Activities page helpers (stopwatch panel, switchers)

struct StopwatchReadout: View {
    @ObservedObject var stopwatch: Stopwatch
    var size: CGFloat
    var weight: Font.Weight = .semibold
    var design: Font.Design = .rounded
    var activeTint: Color = .cyan

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 20, paused: stopwatch.phase != .running)) { context in
            Text(Stopwatch.format(stopwatch.elapsed(at: context.date), fraction: true))
                .font(.system(size: size, weight: weight, design: design))
                .monospacedDigit()
                .foregroundStyle(stopwatch.phase == .idle ? .white : activeTint)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
        }
    }
}

struct StopwatchControls: View {
    @ObservedObject var stopwatch: Stopwatch
    @ObservedObject var lang: LanguageSettings
    var compact: Bool

    var body: some View {
        let side: CGFloat = compact ? 24 : 28
        HStack(spacing: 8) {
            Button {
                stopwatch.phase == .running ? stopwatch.lap() : stopwatch.reset()
            } label: {
                Image(systemName: stopwatch.phase == .running ? "flag.fill" : "arrow.counterclockwise")
                    .font(.system(size: compact ? 10 : 12, weight: .semibold))
                    .frame(width: side, height: side)
                    .background(Circle().fill(.white.opacity(0.12)))
                    .contentTransition(.symbolEffect(.replace))
            }
            .buttonStyle(PressableStyle())
            .disabled(stopwatch.phase == .idle)
            .opacity(stopwatch.phase == .idle ? 0.35 : 1)
            .help(stopwatch.phase == .running ? lang.t(.lap) : lang.t(.reset))
            if !compact { Spacer() }
            Button { stopwatch.toggle() } label: {
                Image(systemName: stopwatch.phase == .running ? "pause.fill" : "play.fill")
                    .font(.system(size: compact ? 11 : 13, weight: .bold))
                    .frame(width: side + 6, height: side + 6)
                    .background(Circle().fill(Color.cyan))
                    .foregroundStyle(.black)
                    .contentTransition(.symbolEffect(.replace))
            }
            .buttonStyle(PressableStyle())
            .help(stopwatch.phase == .running ? lang.t(.pause) : (stopwatch.phase == .paused ? lang.t(.resume) : lang.t(.start)))
        }
    }
}

/// Activities page right column for the stopwatch (mirrors `TimerPanel`).
struct StopwatchPanel: View {
    @ObservedObject var stopwatch: Stopwatch
    @ObservedObject var lang: LanguageSettings
    @Binding var tool: ActivityTool
    var options: [ActivityTool] = ActivityTool.allCases

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 5) {
                ToolSwitcher(tool: $tool, lang: lang, options: options)
                Spacer()
                Text(statusText).foregroundStyle(.white.opacity(0.45))
            }
            .font(.system(size: 10.5, weight: .semibold))
            .foregroundStyle(.white.opacity(0.6))

            HStack(alignment: .center) {
                StopwatchReadout(stopwatch: stopwatch, size: 30)
                Spacer()
                StopwatchControls(stopwatch: stopwatch, lang: lang, compact: false)
                    .fixedSize()
            }

            // Two most recent laps.
            VStack(alignment: .leading, spacing: 2) {
                ForEach(Array(stopwatch.laps.indices.suffix(2).reversed()), id: \.self) { index in
                    HStack {
                        Text("\(lang.t(.lap)) \(index + 1)")
                        Spacer()
                        Text(Stopwatch.format(stopwatch.lapDuration(index), fraction: true)).monospacedDigit()
                    }
                }
            }
            .font(.system(size: 10))
            .foregroundStyle(.white.opacity(0.55))
        }
    }

    private var statusText: String {
        switch stopwatch.phase {
        case .idle: return lang.t(.ready)
        case .running: return lang.t(.running)
        case .paused: return lang.t(.paused)
        }
    }
}

struct ToolSwitcher: View {
    @Binding var tool: ActivityTool
    @ObservedObject var lang: LanguageSettings
    /// Only running tools; with one, it's a plain label.
    var options: [ActivityTool] = ActivityTool.allCases

    var body: some View {
        HStack(spacing: 2) {
            ForEach(options) { option in
                let selected = tool == option
                Button {
                    withAnimation(.snappy(duration: 0.2)) { tool = option }
                } label: {
                    HStack(spacing: 3) {
                        Image(systemName: option == .timer ? "timer" : "stopwatch")
                        Text(lang.t(option == .timer ? .timer : .stopwatch))
                    }
                    .padding(.horizontal, 6)
                    .frame(height: 17)
                    .background(Capsule().fill(.white.opacity(selected && options.count > 1 ? 0.18 : 0)))
                    .foregroundStyle(.white.opacity(selected || options.count == 1 ? 0.95 : 0.5))
                }
                .buttonStyle(PressableStyle())
                .disabled(options.count == 1)
            }
        }
    }
}

/// Activities / Widgets switch in the expanded header.
struct PageSwitcher: View {
    @ObservedObject var model: IslandViewModel
    @ObservedObject var lang: LanguageSettings

    var body: some View {
        HStack(spacing: 2) {
            ForEach(ExpandedPage.allCases) { page in
                let selected = model.page == page
                Button {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) { model.page = page }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: page == .activities ? "dot.radiowaves.left.and.right" : "square.grid.2x2.fill")
                        Text(lang.t(page == .activities ? .activities : .widgets))
                        if page == .activities && model.isActive {
                            Circle().fill(Color.orange).frame(width: 5, height: 5)
                        }
                    }
                    .font(.system(size: 10, weight: .semibold))
                    .padding(.horizontal, 8)
                    .frame(height: 19)
                    .background(Capsule().fill(.white.opacity(selected ? 0.2 : 0)))
                    .foregroundStyle(.white.opacity(selected ? 1 : 0.5))
                }
                .buttonStyle(PressableStyle())
            }
        }
        .padding(2)
        .background(Capsule().fill(.white.opacity(0.07)))
    }
}
