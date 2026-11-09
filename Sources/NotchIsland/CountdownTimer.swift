import AppKit
import Combine

/// Wall-clock based countdown, so it stays accurate across sleep and UI stalls.
@MainActor
final class CountdownTimer: ObservableObject {
    enum Phase: Equatable { case idle, running, paused, finished }

    static let presets: [Int] = [1, 5, 10, 25]
    private static let durationKey = "NotchIsland.timerDuration"

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var remaining: TimeInterval
    @Published private(set) var total: TimeInterval
    /// Duration used by the next start; persisted between launches.
    @Published private(set) var selectedDuration: TimeInterval

    private var endDate: Date?
    private var tickTask: Task<Void, Never>?
    private var finishedResetTask: Task<Void, Never>?

    var isActive: Bool { phase != .idle }

    var progress: Double {
        guard total > 0 else { return 0 }
        return max(0, min(1, 1 - remaining / total))
    }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let stored = defaults.double(forKey: Self.durationKey)
        let duration = stored >= 60 ? stored : 5 * 60
        selectedDuration = duration
        remaining = duration
        total = duration
    }

    /// Chooses the next duration without starting (idle / finished only).
    func select(minutes: Int) {
        guard phase == .idle || phase == .finished else { return }
        if phase == .finished { reset() }
        setDuration(TimeInterval(minutes * 60))
    }

    func start(minutes: Int) {
        setDuration(TimeInterval(minutes * 60))
        start()
    }

    func start() {
        finishedResetTask?.cancel()
        if phase == .paused {
            endDate = Date().addingTimeInterval(remaining)
        } else {
            total = selectedDuration
            remaining = selectedDuration
            endDate = Date().addingTimeInterval(selectedDuration)
        }
        phase = .running
        startTicking()
    }

    func pause() {
        guard phase == .running else { return }
        tick()
        tickTask?.cancel()
        endDate = nil
        phase = .paused
    }

    func toggle() {
        switch phase {
        case .running: pause()
        case .idle, .paused: start()
        case .finished: reset()
        }
    }

    func reset() {
        tickTask?.cancel()
        finishedResetTask?.cancel()
        endDate = nil
        phase = .idle
        total = selectedDuration
        remaining = selectedDuration
    }

    /// Adjusts the running/paused countdown, or the next duration when idle.
    func adjust(minutes: Int) {
        let delta = TimeInterval(minutes * 60)
        switch phase {
        case .running:
            guard let end = endDate else { return }
            let newRemaining = max(1, remaining + delta)
            endDate = end.addingTimeInterval(newRemaining - remaining)
            total = max(total + delta, newRemaining)
            remaining = newRemaining
        case .paused:
            remaining = max(1, remaining + delta)
            total = max(total + delta, remaining)
        case .idle, .finished:
            setDuration(selectedDuration + delta)
            reset()
        }
    }

    private func setDuration(_ duration: TimeInterval) {
        selectedDuration = min(max(duration, 60), 180 * 60)
        defaults.set(selectedDuration, forKey: Self.durationKey)
        if phase == .idle {
            total = selectedDuration
            remaining = selectedDuration
        }
    }

    private func startTicking() {
        tickTask?.cancel()
        tickTask = Task { [weak self] in
            while !Task.isCancelled {
                self?.tick()
                try? await Task.sleep(for: .milliseconds(200))
            }
        }
    }

    private func tick() {
        guard phase == .running, let end = endDate else { return }
        let left = end.timeIntervalSinceNow
        if left <= 0 {
            finish()
        } else if left.rounded(.up) != remaining.rounded(.up) || remaining - left > 0.5 {
            remaining = left
        }
    }

    private func finish() {
        tickTask?.cancel()
        endDate = nil
        remaining = 0
        phase = .finished
        NSSound(named: "Glass")?.play()
        // Keep "time's up" visible for a while, then return the notch to idle.
        finishedResetTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(12))
            guard !Task.isCancelled, self?.phase == .finished else { return }
            self?.reset()
        }
    }

    static func format(_ interval: TimeInterval) -> String {
        let seconds = Int(interval.rounded(.up))
        let h = seconds / 3600, m = (seconds % 3600) / 60, s = seconds % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }
}
