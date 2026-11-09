import Foundation
import EventKit
import AppKit
import Combine

/// Upcoming events for the calendar widget.
///
/// - Access is requested only from an explicit user action (Settings button or
///   tapping the widget's "Allow Access" prompt), with the macOS 14
///   `requestFullAccessToEvents()` API.
/// - Events live in memory only; nothing is written to disk or sent anywhere.
@MainActor
final class CalendarStore: ObservableObject {
    enum Access: Equatable {
        case notDetermined, denied, restricted, writeOnly, granted
        init(_ status: EKAuthorizationStatus) {
            switch status {
            case .fullAccess: self = .granted
            case .writeOnly: self = .writeOnly
            case .denied: self = .denied
            case .restricted: self = .restricted
            case .notDetermined: self = .notDetermined
            @unknown default: self = .denied
            }
        }
    }

    struct Item: Equatable, Identifiable {
        var id: String
        var title: String
        var start: Date
        var end: Date
        var isAllDay: Bool
        /// sRGB components of the calendar colour.
        var color: [Double]
    }

    @Published private(set) var access: Access
    @Published private(set) var items: [Item] = []
    @Published private(set) var lastRefresh: Date?
    @Published private(set) var isRequesting = false

    private var store: EKEventStore?
    private var observer: NSObjectProtocol?
    private var timer: Task<Void, Never>?
    private let statusProvider: () -> EKAuthorizationStatus
    private let now: () -> Date
    private var days = 1
    private var includeAllDay = true
    private(set) var isActive = false

    nonisolated static let maxItems = 6

    init(statusProvider: @escaping () -> EKAuthorizationStatus = { EKEventStore.authorizationStatus(for: .event) },
         now: @escaping () -> Date = Date.init) {
        self.statusProvider = statusProvider
        self.now = now
        access = Access(statusProvider())
    }

    /// Starts/stops observing according to whether the widget is enabled.
    func setActive(_ active: Bool, days: Int, includeAllDay: Bool) {
        self.days = days
        self.includeAllDay = includeAllDay
        isActive = active
        access = Access(statusProvider())
        if active && access == .granted {
            startObserving()
            refresh()
        } else {
            stopObserving()
            if !active { items = [] }
        }
    }

    /// Re-reads the authorization status (never prompts), e.g. after the user
    /// changed it in System Settings.
    func reloadAccess() {
        let current = Access(statusProvider())
        guard current != access else { return }
        access = current
        if isActive && current == .granted {
            startObserving()
            refresh()
        } else if current != .granted {
            stopObserving()
            items = []
        }
    }

    /// Explicit user action only.
    func requestAccess() {
        guard access == .notDetermined, !isRequesting else { return }
        isRequesting = true
        let store = self.store ?? EKEventStore()
        self.store = store
        Task {
            _ = try? await store.requestFullAccessToEvents()
            isRequesting = false
            access = Access(statusProvider())
            if isActive && access == .granted {
                startObserving()
                refresh()
            }
        }
    }

    func openPrivacySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars") {
            NSWorkspace.shared.open(url)
        }
    }

    func refresh() {
        guard access == .granted else { items = []; return }
        let store = self.store ?? EKEventStore()
        self.store = store
        let start = now()
        let calendar = Calendar.current
        let end = calendar.date(byAdding: .day, value: days, to: calendar.startOfDay(for: start)) ?? start.addingTimeInterval(86400)
        let predicate = store.predicateForEvents(withStart: start, end: end, calendars: nil)
        let events = store.events(matching: predicate)
        items = Self.items(from: events.map(Self.snapshot), now: start, includeAllDay: includeAllDay)
        lastRefresh = start
    }

    /// EKEvent → plain value (only fields the widget shows).
    nonisolated static func snapshot(_ event: EKEvent) -> Item {
        let color = event.calendar?.color?.usingColorSpace(.sRGB)
        return Item(id: (event.eventIdentifier ?? UUID().uuidString) + "|\(event.startDate.timeIntervalSince1970)",
                    title: event.title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "",
                    start: event.startDate, end: event.endDate, isAllDay: event.isAllDay,
                    color: color.map { [Double($0.redComponent), Double($0.greenComponent), Double($0.blueComponent)] } ?? [1, 0.23, 0.19])
    }

    /// Filtering/sorting, separated for tests: drop finished and (optionally)
    /// all-day events, timed events first by start, then all-day ones.
    nonisolated static func items(from all: [Item], now: Date, includeAllDay: Bool) -> [Item] {
        let upcoming = all.filter { $0.end > now && (includeAllDay || !$0.isAllDay) }
        let sorted = upcoming.sorted {
            if $0.isAllDay != $1.isAllDay { return !$0.isAllDay }
            return $0.start == $1.start ? $0.title < $1.title : $0.start < $1.start
        }
        return Array(sorted.prefix(maxItems))
    }

    private func startObserving() {
        let store = self.store ?? EKEventStore()
        self.store = store
        if observer == nil {
            observer = NotificationCenter.default.addObserver(forName: .EKEventStoreChanged, object: store, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.refresh() }
            }
        }
        if timer == nil {
            // Drop finished events as time passes.
            timer = Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(60))
                    self?.refresh()
                }
            }
        }
    }

    private func stopObserving() {
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil
        timer?.cancel()
        timer = nil
    }
}
