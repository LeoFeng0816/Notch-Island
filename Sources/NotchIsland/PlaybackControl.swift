import Foundation

/// Tracks playback commands from press to confirmation, so the island reacts
/// immediately without pretending: the button shows the *requested* state as
/// "pending" until the player is observed in that state; failures, timeouts
/// and outside changes always fall back to what the player actually reports.
///
/// Pure value type (no I/O) so every race can be unit-tested.
struct PlaybackCommandTracker: Equatable {
    enum Kind: Equatable { case playPause, next, previous }

    struct Pending: Equatable {
        var id: Int
        var kind: Kind
        /// For play/pause: the state we asked for. nil for next/previous.
        var expectedPlaying: Bool?
        /// Track identity when the command was issued (next/previous confirm on change).
        var trackKey: String
        var position: TimeInterval?
        var issuedAt: Date
        var deliveredAt: Date?
    }

    enum Outcome: Equatable {
        case none
        /// Command reached the player and the new state was observed.
        case confirmed
        /// Older command result arrived after a newer one: ignored.
        case stale
        /// Couldn't be sent (no permission, tab closed, script error, no response).
        case failed
        /// Sent, but the player wasn't seen changing within the window.
        case noEffect
    }

    /// How long after delivery we wait to see the player change.
    static let confirmWindow: TimeInterval = 2.5
    /// If the command itself never comes back (hung app), give up after this.
    static let deliveryTimeout: TimeInterval = 4

    private(set) var pending: Pending?
    private(set) var lastOutcome: Outcome = .none
    private var nextID = 1

    var isPending: Bool { pending != nil }

    /// Play state to *show* on the button: the request while pending, else what the player reports.
    func displayedPlaying(observed: Bool) -> Bool {
        pending?.expectedPlaying ?? observed
    }

    /// Registers a press. Play/pause targets the opposite of what is currently
    /// shown (including a pending request), so rapid taps alternate predictably.
    mutating func issue(_ kind: Kind, observedPlaying: Bool, trackKey: String, now: Date, position: TimeInterval? = nil) -> Pending {
        let expected: Bool? = kind == .playPause ? !displayedPlaying(observed: observedPlaying) : nil
        let command = Pending(id: nextID, kind: kind, expectedPlaying: expected, trackKey: trackKey, position: position,
                              issuedAt: now, deliveredAt: nil)
        nextID += 1
        pending = command
        lastOutcome = .none
        return command
    }

    /// Whether a queued command is still the latest (older queued ones are skipped, i.e. coalesced).
    func isCurrent(_ id: Int) -> Bool { pending?.id == id }

    /// Result of actually sending command `id`.
    mutating func delivered(_ id: Int, success: Bool, now: Date) -> Outcome {
        guard pending?.id == id else { return finish(.stale, clear: false) }
        guard success else { return finish(.failed, clear: true) }
        pending?.deliveredAt = now
        return .none
    }

    /// A newer observation of the player (from the control's read-back, a
    /// targeted read or the regular scan).
    mutating func observe(isPlaying: Bool, trackKey: String, sampledAt: Date, now: Date, position: TimeInterval? = nil) -> Outcome {
        guard let command = pending else { return .none }
        // Sampled before the press: says nothing about the command.
        guard sampledAt >= command.issuedAt else { return expireIfNeeded(now: now) }
        if let expected = command.expectedPlaying {
            if isPlaying == expected { return finish(.confirmed, clear: true) }
            if trackKey != command.trackKey { return finish(.noEffect, clear: true) } // something else changed underneath
        } else if trackKey != command.trackKey {
            return finish(.confirmed, clear: true) // next/previous moved to another item
        } else if command.kind == .previous, let before = command.position, let position,
                  before > 4, (0...2).contains(position), command.deliveredAt != nil {
            // YouTube Music restarts the current item when Previous is
            // pressed after its opening seconds. This is a successful press.
            return finish(.confirmed, clear: true)
        }
        return expireIfNeeded(now: now)
    }

    /// Time-based expiry without a new observation.
    mutating func expireIfNeeded(now: Date) -> Outcome {
        guard let command = pending else { return .none }
        if let delivered = command.deliveredAt {
            if now.timeIntervalSince(delivered) >= Self.confirmWindow { return finish(.noEffect, clear: true) }
        } else if now.timeIntervalSince(command.issuedAt) >= Self.deliveryTimeout {
            return finish(.failed, clear: true)
        }
        return .none
    }

    /// The displayed source/track went away or changed by other means.
    mutating func cancel() { pending = nil }

    private mutating func finish(_ outcome: Outcome, clear: Bool) -> Outcome {
        if clear { pending = nil }
        if outcome != .stale { lastOutcome = outcome }
        return outcome
    }
}

/// Cache of compiled scripts (compiling the scan script each time costs
/// tens of milliseconds). Only used on the serial script queue.
final class CompiledScriptCache: @unchecked Sendable {
    private var scripts: [String: NSAppleScript] = [:]
    private var order: [String] = []
    let capacity: Int

    init(capacity: Int = 24) { self.capacity = capacity }

    private let lock = NSLock()

    func script(for source: String) -> NSAppleScript? {
        lock.lock(); defer { lock.unlock() }
        if let cached = scripts[source] { return cached }
        guard let script = NSAppleScript(source: source) else { return nil }
        var error: NSDictionary?
        guard script.compileAndReturnError(&error) else { return script } // let execution report the error
        scripts[source] = script
        order.append(source)
        if order.count > capacity { scripts[order.removeFirst()] = nil }
        return script
    }

    var count: Int { lock.withLock { scripts.count } }
}
