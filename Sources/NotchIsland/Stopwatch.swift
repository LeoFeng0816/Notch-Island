import Foundation
import Combine

/// Wall-clock stopwatch. State is persisted, so a running stopwatch keeps
/// counting across relaunches (like the iOS Clock app). Views read the live
/// value with `elapsed(at:)` inside a `TimelineView`, so the model never ticks.
@MainActor
final class Stopwatch: ObservableObject {
    enum Phase: String, Equatable { case idle, running, paused }

    static let maxLaps = 50
    private static let stateKey = "NotchIsland.stopwatch"

    @Published private(set) var phase: Phase = .idle
    /// Lap split times (cumulative elapsed when the lap was recorded), newest last.
    @Published private(set) var laps: [TimeInterval] = []

    private var accumulated: TimeInterval = 0
    private var startDate: Date?
    private let defaults: UserDefaults
    private let now: () -> Date

    var isActive: Bool { phase != .idle }

    init(defaults: UserDefaults = .standard, now: @escaping () -> Date = Date.init) {
        self.defaults = defaults
        self.now = now
        restore()
    }

    func elapsed(at date: Date? = nil) -> TimeInterval {
        guard let startDate else { return accumulated }
        return accumulated + max(0, (date ?? now()).timeIntervalSince(startDate))
    }

    func start() {
        guard phase != .running else { return }
        startDate = now()
        phase = .running
        persist()
    }

    func pause() {
        guard phase == .running else { return }
        accumulated = elapsed()
        startDate = nil
        phase = .paused
        persist()
    }

    func toggle() { phase == .running ? pause() : start() }

    func reset() {
        accumulated = 0
        startDate = nil
        laps = []
        phase = .idle
        persist()
    }

    func lap() {
        guard phase == .running else { return }
        laps.append(elapsed())
        if laps.count > Self.maxLaps { laps.removeFirst(laps.count - Self.maxLaps) }
        persist()
    }

    /// Duration of lap `index` (difference to the previous split).
    func lapDuration(_ index: Int) -> TimeInterval {
        guard laps.indices.contains(index) else { return 0 }
        return laps[index] - (index > 0 ? laps[index - 1] : 0)
    }

    // MARK: Persistence

    private func persist() {
        var state: [String: Any] = ["phase": phase.rawValue, "accumulated": accumulated, "laps": laps]
        if let startDate { state["start"] = startDate.timeIntervalSince1970 }
        defaults.set(state, forKey: Self.stateKey)
    }

    private func restore() {
        guard let state = defaults.dictionary(forKey: Self.stateKey),
              let raw = state["phase"] as? String, let phase = Phase(rawValue: raw) else { return }
        accumulated = max(0, state["accumulated"] as? Double ?? 0)
        laps = (state["laps"] as? [Double]) ?? []
        if phase == .running, let start = state["start"] as? Double {
            // A start date in the future means the clock went backwards; resume from now.
            startDate = min(Date(timeIntervalSince1970: start), now())
        }
        self.phase = (phase == .running && startDate == nil) ? .paused : phase
    }

    // MARK: Formatting

    /// "1:02.34" / "1:02:03.4" style, with hundredths when `fraction` is true.
    nonisolated static func format(_ interval: TimeInterval, fraction: Bool) -> String {
        let total = max(0, interval)
        let seconds = Int(total)
        let h = seconds / 3600, m = (seconds % 3600) / 60, s = seconds % 60
        let base = h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
        guard fraction else { return base }
        let hundredths = min(99, Int((total - Double(seconds)) * 100))
        return h > 0 ? base + String(format: ".%d", hundredths / 10) : base + String(format: ".%02d", hundredths)
    }
}
