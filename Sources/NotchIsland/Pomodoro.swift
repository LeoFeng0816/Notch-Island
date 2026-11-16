import AppKit
import Combine

/// Pomodoro cycle: 25-minute focus → 5-minute short break; the break after every
/// fourth *completed* focus session is a long one (15–30 minutes, default 20).
///
/// Definitions (shown in Settings and the README):
/// - **Completed**: a focus session whose full 25 minutes ran out while it was
///   running. Only this adds to the count. Pausing, resuming, resetting and
///   skipping never count as completing a session.
/// - **Paused / Resumed**: Pause freezes the time left; Resume continues from
///   there. Paused time is not counted.
/// - **Skipped**: only breaks can be skipped. Skipping ends the break at once and
///   waits for the next focus. Skipping a long break still starts a new set of four.
/// - **Reset**: during a session, stops it without counting it (completed
///   sessions are kept) and waits for the next focus. When nothing is running,
///   Reset clears the completed count.
/// - A break starts by itself when a focus session completes (so it can't be
///   "missed"), and the next focus always waits for the user: nothing is ever
///   counted while the user is away.
///
/// Timekeeping uses a monotonic clock that keeps counting while the Mac sleeps
/// (`ContinuousClock`, i.e. mach_continuous_time), never the wall clock: changing
/// the date, time or time zone, or an NTP correction, doesn't shorten or extend a
/// session. If a session ends while the Mac sleeps, the cycle is caught up on wake
/// from the moment it actually ended (at most focus → break → ready, because a
/// focus never starts by itself) and the catch-up is applied silently.
///
/// Independent of the countdown timer and the stopwatch: none of them stops,
/// pauses or resets another. Nothing is persisted except the long-break length;
/// quitting the app ends the current session.
@MainActor
final class PomodoroTimer: ObservableObject {
    enum Phase: String, Equatable, CaseIterable {
        case focus, shortBreak, longBreak
        var isBreak: Bool { self != .focus }
    }

    enum RunState: Equatable { case ready, running, paused }

    /// Short-lived "break over" state shown in the notch (like the timer's "Time's up").
    struct Notice: Equatable {
        var endedBreak: Phase
        /// Monotonic time when the notice disappears.
        var until: TimeInterval
    }

    /// Emitted exactly once per automatic transition (never for user actions).
    enum Event: Equatable {
        case focusCompleted(total: Int, next: Phase, late: Bool)
        case breakEnded(Phase, late: Bool)

        /// Late events were caught up after sleep: applied silently (no sound, no toast).
        var late: Bool {
            switch self {
            case .focusCompleted(_, _, let late), .breakEnded(_, let late): return late
            }
        }
    }

    nonisolated static let focusMinutes = 25
    nonisolated static let shortBreakMinutes = 5
    nonisolated static let sessionsPerLongBreak = 4
    nonisolated static let longBreakRange = 15...30
    nonisolated static let defaultLongBreakMinutes = 20
    nonisolated static let longBreakPresets = [15, 20, 25, 30]
    nonisolated static let noticeDuration: TimeInterval = 12
    /// A transition noticed later than this (e.g. after waking from sleep) is late.
    nonisolated static let lateThreshold: TimeInterval = 5
    nonisolated static let longBreakKey = "NotchIsland.pomodoro.longBreakMinutes"

    @Published private(set) var phase: Phase = .focus
    @Published private(set) var runState: RunState = .ready
    @Published private(set) var remaining: TimeInterval
    @Published private(set) var total: TimeInterval
    /// Completed focus sessions in the current set of four (0…3; the set restarts
    /// when its long break begins).
    @Published private(set) var completedInSet = 0
    /// Completed focus sessions since launch or the last count reset.
    @Published private(set) var completedTotal = 0
    @Published private(set) var notice: Notice?
    @Published private(set) var longBreakMinutes: Int

    let events = PassthroughSubject<Event, Never>()

    private let defaults: UserDefaults
    private let now: () -> TimeInterval
    private let autoTick: Bool
    /// Monotonic end of the running session.
    private var endTime: TimeInterval?
    private var tickTask: Task<Void, Never>?
    private var noticeTask: Task<Void, Never>?

    /// - Parameters:
    ///   - now: monotonic seconds (tests inject a fake clock).
    ///   - autoTick: off in tests, which call `refresh()` themselves.
    init(defaults: UserDefaults = .standard, now: @escaping () -> TimeInterval = PomodoroTimer.monotonicNow,
         autoTick: Bool = true) {
        self.defaults = defaults
        self.now = now
        self.autoTick = autoTick
        let stored = defaults.integer(forKey: Self.longBreakKey)
        longBreakMinutes = Self.longBreakRange.contains(stored) ? stored : Self.defaultLongBreakMinutes
        let focus = Self.duration(of: .focus, longBreakMinutes: Self.defaultLongBreakMinutes)
        remaining = focus
        total = focus
    }

    nonisolated private static let origin = ContinuousClock.now
    /// Seconds on a clock that keeps counting during sleep and ignores wall-clock changes.
    nonisolated static func monotonicNow() -> TimeInterval {
        let elapsed = ContinuousClock.now - origin
        return Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
    }

    nonisolated static func duration(of phase: Phase, longBreakMinutes: Int) -> TimeInterval {
        switch phase {
        case .focus: return TimeInterval(focusMinutes * 60)
        case .shortBreak: return TimeInterval(shortBreakMinutes * 60)
        case .longBreak: return TimeInterval(longBreakMinutes * 60)
        }
    }

    func duration(of phase: Phase) -> TimeInterval { Self.duration(of: phase, longBreakMinutes: longBreakMinutes) }

    /// Running, paused, or showing "break over" for a moment: shown as a live activity.
    var isLive: Bool { runState != .ready || notice != nil }
    var isSessionActive: Bool { runState != .ready }

    var livePublisher: AnyPublisher<Bool, Never> {
        Publishers.CombineLatest($runState, $notice)
            .map { state, notice in state != .ready || notice != nil }
            .removeDuplicates()
            .eraseToAnyPublisher()
    }

    /// Dots filled toward the long break; the whole set (4) during the long break.
    var setProgress: Int {
        phase == .longBreak && runState != .ready ? Self.sessionsPerLongBreak : completedInSet
    }

    /// Whether the focus that would complete next earns the long break.
    var nextBreakIsLong: Bool { completedInSet + 1 >= Self.sessionsPerLongBreak }

    var progress: Double {
        guard total > 0 else { return 0 }
        return max(0, min(1, 1 - remaining / total))
    }

    /// What Reset does right now (nil: nothing to reset).
    enum ResetAction: Equatable { case session, count }
    var resetAction: ResetAction? {
        if runState != .ready { return .session }
        return completedTotal > 0 || completedInSet > 0 || notice != nil ? .count : nil
    }

    var canSkip: Bool { phase.isBreak && runState != .ready }

    // MARK: User actions

    /// Starts the next focus session (only from ready).
    func start() {
        refresh()
        guard runState == .ready else { return }
        clearNotice()
        begin(.focus, at: now())
    }

    func pause() {
        refresh()
        guard runState == .running, let end = endTime else { return }
        remaining = max(0, end - now())
        endTime = nil
        runState = .paused
        stopTicking()
    }

    func resume() {
        guard runState == .paused else { return }
        endTime = now() + remaining
        runState = .running
        startTicking()
    }

    /// Start / Pause / Resume.
    func toggle() {
        switch runState {
        case .ready: start()
        case .running: pause()
        case .paused: resume()
        }
    }

    /// See the type's documentation: stops the session (not counted), or clears the count.
    func reset() {
        refresh()
        switch runState {
        case .running, .paused:
            enterReady()
        case .ready:
            completedInSet = 0
            completedTotal = 0
        }
        clearNotice()
    }

    /// Ends the current break now; the next focus waits for the user.
    func skipBreak() {
        refresh()
        guard canSkip else { return }
        enterReady()
        clearNotice()
    }

    /// Long-break length (clamped to 15–30 minutes, saved). During a long break the
    /// break itself follows the new length; if that's already used up, it ends now.
    func setLongBreakMinutes(_ minutes: Int) {
        let clamped = min(max(minutes, Self.longBreakRange.lowerBound), Self.longBreakRange.upperBound)
        guard clamped != longBreakMinutes else { return }
        refresh()
        let oldTotal = total
        longBreakMinutes = clamped
        defaults.set(clamped, forKey: Self.longBreakKey)
        guard phase == .longBreak else { return }
        let newTotal = duration(of: .longBreak)
        switch runState {
        case .running:
            guard let end = endTime else { return }
            let newEnd = end + (newTotal - oldTotal)
            total = newTotal
            let t = now()
            if newEnd <= t {
                // Already rested longer than the new length: the break ends now (on time).
                finishBreak(at: t, now: t)
            } else {
                endTime = newEnd
                refresh()
            }
        case .paused:
            let elapsed = oldTotal - remaining
            total = newTotal
            remaining = newTotal - elapsed
            if remaining <= 0 { let t = now(); finishBreak(at: t, now: t) }
        case .ready:
            break
        }
    }

    func adjustLongBreak(by minutes: Int) { setLongBreakMinutes(longBreakMinutes + minutes) }

    // MARK: Time

    /// Applies every transition that is due and updates the time left. Called by
    /// the tick loop, on wake, and before every user action.
    func refresh() {
        let t = now()
        // Bounded: a focus never starts by itself, so this runs at most twice.
        while runState == .running, let end = endTime, t >= end {
            complete(at: end, now: t)
        }
        if runState == .running, let end = endTime { updateRemaining(end - t) }
        if let notice, t >= notice.until { self.notice = nil }
    }

    private func complete(at boundary: TimeInterval, now t: TimeInterval) {
        let late = t - boundary > Self.lateThreshold
        switch phase {
        case .focus:
            completedTotal += 1
            completedInSet += 1
            let next: Phase
            if completedInSet >= Self.sessionsPerLongBreak {
                next = .longBreak
                completedInSet = 0
            } else {
                next = .shortBreak
            }
            // The break is timed from the moment the focus ended (also after sleep).
            begin(next, at: boundary)
            events.send(.focusCompleted(total: completedTotal, next: next, late: late))
        case .shortBreak, .longBreak:
            finishBreak(at: boundary, now: t)
        }
    }

    private func finishBreak(at boundary: TimeInterval, now t: TimeInterval) {
        let ended = phase
        let late = t - boundary > Self.lateThreshold
        enterReady()
        let until = boundary + Self.noticeDuration
        // A break that ended while the Mac slept is applied quietly: no "break over" moment.
        if !late, until > t {
            notice = Notice(endedBreak: ended, until: until)
            scheduleNoticeExpiry(after: until - t)
        }
        events.send(.breakEnded(ended, late: late))
    }

    private func begin(_ next: Phase, at start: TimeInterval) {
        phase = next
        let length = duration(of: next)
        total = length
        let end = start + length
        endTime = end
        runState = .running
        updateRemaining(max(0, end - now()), force: true)
        startTicking()
    }

    private func enterReady() {
        stopTicking()
        endTime = nil
        phase = .focus
        runState = .ready
        total = duration(of: .focus)
        remaining = total
    }

    private func updateRemaining(_ left: TimeInterval, force: Bool = false) {
        if force || left.rounded(.up) != remaining.rounded(.up) || remaining - left > 0.5 {
            remaining = left
        }
    }

    private func clearNotice() {
        noticeTask?.cancel()
        noticeTask = nil
        notice = nil
    }

    private func startTicking() {
        guard autoTick else { return }
        tickTask?.cancel()
        tickTask = Task { [weak self] in
            while !Task.isCancelled {
                self?.refresh()
                try? await Task.sleep(for: .milliseconds(250))
            }
        }
    }

    private func stopTicking() {
        tickTask?.cancel()
        tickTask = nil
    }

    private func scheduleNoticeExpiry(after delay: TimeInterval) {
        noticeTask?.cancel()
        guard autoTick else { return }
        noticeTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay + 0.05))
            guard !Task.isCancelled else { return }
            self?.refresh()
        }
    }

    static func format(_ interval: TimeInterval) -> String { CountdownTimer.format(max(0, interval)) }
}

// MARK: - Compact island layout

/// What each side of the notch shows while the island is compact. One pure
/// function decides it so every combination of activities can be tested.
///
/// Rules (Pomodoro additions; without a Pomodoro the layout is unchanged):
/// - Music that is really playing (not paused, not stale) keeps the left side.
/// - A live Pomodoro takes the right side, except for the 12 s "Time's up" of
///   the countdown timer, which is an alert and wins the right side briefly.
/// - Without playing music, the left side shows a running timer (or stopwatch)
///   in a small icon + time form, otherwise the Pomodoro's own badge (phase +
///   progress toward the long break). Nothing is stopped: activities that don't
///   fit stay visible on the Live Activities page.
enum CompactSlot: Equatable {
    case none, toast, artwork, musicBars
    case timerIcon, timerTime, timerCompact
    case stopwatchIcon, stopwatchTime, stopwatchCompact
    case pomodoroBadge
    /// `glyph`: show the phase glyph before the time (when the badge isn't on the left).
    case pomodoroTime(glyph: Bool)
}

struct CompactLayout: Equatable {
    var leading: CompactSlot
    var trailing: CompactSlot

    nonisolated static func resolve(toast: Bool, musicPlaying: Bool, timer: CountdownTimer.Phase,
                                    stopwatchActive: Bool, pomodoroLive: Bool) -> CompactLayout {
        if toast { return CompactLayout(leading: .toast, trailing: .toast) }
        let timerActive = timer != .idle
        let pomodoroRight = pomodoroLive && timer != .finished

        let trailing: CompactSlot
        if pomodoroRight {
            trailing = .pomodoroTime(glyph: musicPlaying || timerActive || stopwatchActive)
        } else if timerActive {
            trailing = .timerTime
        } else if stopwatchActive {
            trailing = .stopwatchTime
        } else if musicPlaying {
            trailing = .musicBars
        } else {
            trailing = .none
        }

        let leading: CompactSlot
        if musicPlaying {
            leading = .artwork
        } else if pomodoroRight {
            leading = timerActive ? .timerCompact : (stopwatchActive ? .stopwatchCompact : .pomodoroBadge)
        } else if trailing == .timerTime {
            leading = pomodoroLive ? .pomodoroBadge : .timerIcon
        } else if trailing == .stopwatchTime {
            leading = .stopwatchIcon
        } else {
            leading = .none
        }
        return CompactLayout(leading: leading, trailing: trailing)
    }
}
