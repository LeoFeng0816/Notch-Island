import Foundation
import Combine
import Security
import LocalAuthentication
import CoreLocation

enum WidgetKind: String, CaseIterable, Identifiable, Codable {
    case battery, weather, stocks, timer, stopwatch, calendar, clock

    var id: String { rawValue }

    var symbol: String {
        switch self {
        case .battery: return "battery.75percent"
        case .weather: return "cloud.sun.fill"
        case .stocks: return "chart.line.uptrend.xyaxis"
        case .stopwatch: return "stopwatch"
        case .timer: return "timer"
        case .calendar: return "calendar"
        case .clock: return "clock.fill"
        }
    }

    var titleKey: L10nKey {
        switch self {
        case .battery: return .battery
        case .weather: return .weather
        case .stocks: return .stocks
        case .stopwatch: return .stopwatch
        case .timer: return .timer
        case .calendar: return .calendarWidget
        case .clock: return .clockWidget
        }
    }

    /// Widgets that contact a network provider when enabled.
    var usesNetwork: Bool { self == .weather || self == .stocks }
    /// Widgets that need a macOS privacy permission (requested only on user action).
    var needsPermission: Bool { self == .calendar }
}

/// A geocoded city chosen by the user, or a coarse "current location" the
/// user explicitly asked for (coordinates rounded, see `LocationProvider`).
struct Place: Codable, Equatable, Identifiable {
    var name: String
    var admin: String?
    var country: String?
    var latitude: Double
    var longitude: Double
    var timezone: String?
    /// True when it came from Location Services (optional for older saved data).
    var isCurrentLocation: Bool? = nil

    var fromLocationServices: Bool { isCurrentLocation == true }

    @MainActor func displayName(_ lang: LanguageSettings) -> String {
        fromLocationServices || name.isEmpty ? lang.t(.currentLocation) : name
    }

    /// Coarse coordinate from `LocationProvider`; the name is localized at display time.
    static func currentLocation(_ coordinate: CLLocationCoordinate2D) -> Place {
        Place(name: "", admin: nil, country: nil, latitude: coordinate.latitude, longitude: coordinate.longitude,
              timezone: nil, isCurrentLocation: true)
    }

    var id: String { "\(latitude),\(longitude)" }

    var subtitle: String {
        [admin, country].compactMap { $0 }.filter { !$0.isEmpty && $0 != name }.joined(separator: ", ")
    }
}

enum TemperatureUnit: String, CaseIterable, Codable, Identifiable {
    case celsius, fahrenheit
    var id: String { rawValue }
    var symbol: String { self == .celsius ? "°C" : "°F" }
}

/// User widget configuration, persisted locally in UserDefaults. The stock API
/// key lives in the Keychain (`SecretStore`), never in preferences.
@MainActor
final class WidgetSettings: ObservableObject {
    static let maxSymbols = 3
    /// Cards are iOS-style squares; four fit side by side in the island.
    static let maxEnabled = 4
    static let maxExtraTimeZones = 2

    /// All kinds in display order (enabled or not), so re-enabling keeps the position.
    @Published private(set) var order: [WidgetKind]
    @Published private(set) var enabled: Set<WidgetKind>
    @Published var place: Place? { didSet { persist() } }
    @Published var unit: TemperatureUnit { didSet { persist() } }
    @Published private(set) var symbols: [String]
    @Published private(set) var hasStockAPIKey: Bool
    @Published var stockProvider: StockProviderKind { didSet { persist() } }
    /// Calendar widget look-ahead in days (1 = rest of today).
    @Published var calendarDays: Int { didSet { persist() } }
    @Published var calendarShowsAllDay: Bool { didSet { persist() } }
    /// Extra time-zone identifiers for the clock widget (local time is always shown).
    @Published private(set) var timeZones: [String]

    private let defaults: UserDefaults
    private let secrets: SecretStore
    private var loading = true

    private enum Key {
        static let order = "NotchIsland.widgets.order"
        static let enabled = "NotchIsland.widgets.enabled"
        static let place = "NotchIsland.widgets.place"
        static let unit = "NotchIsland.widgets.unit"
        static let symbols = "NotchIsland.widgets.symbols"
        static let hasKey = "NotchIsland.widgets.hasStockKey"
        static let provider = "NotchIsland.widgets.stockProvider"
        static let calendarDays = "NotchIsland.widgets.calendarDays"
        static let calendarAllDay = "NotchIsland.widgets.calendarAllDay"
        static let timeZones = "NotchIsland.widgets.timeZones"
        static let timerMigrated = "NotchIsland.widgets.timerMigrated"
    }

    static let calendarDayOptions = [1, 3, 7]

    static let defaultEnabled: Set<WidgetKind> = [.battery, .timer, .stopwatch] // offline widgets only

    init(defaults: UserDefaults = .standard, secrets: SecretStore = KeychainSecretStore()) {
        self.defaults = defaults
        self.secrets = secrets
        let storedOrder = (defaults.stringArray(forKey: Key.order) ?? []).compactMap(WidgetKind.init(rawValue:))
        var order: [WidgetKind] = []
        for kind in storedOrder + WidgetKind.allCases where !order.contains(kind) { order.append(kind) }
        self.order = order
        if let stored = defaults.stringArray(forKey: Key.enabled) {
            enabled = Set(stored.compactMap(WidgetKind.init(rawValue:)))
        } else {
            enabled = Self.defaultEnabled
        }
        place = defaults.data(forKey: Key.place).flatMap { try? JSONDecoder().decode(Place.self, from: $0) }
        unit = defaults.string(forKey: Key.unit).flatMap(TemperatureUnit.init(rawValue:))
            ?? (Locale.current.measurementSystem == .us ? .fahrenheit : .celsius)
        symbols = defaults.stringArray(forKey: Key.symbols) ?? []
        // Cached flag, so the UI never needs to touch the Keychain just to render.
        let cachedStockKey = defaults.bool(forKey: Key.hasKey)
        hasStockAPIKey = cachedStockKey
        // Users who already set up Alpha Vantage keep it; everyone else starts on Yahoo.
        stockProvider = defaults.string(forKey: Key.provider).flatMap(StockProviderKind.init(rawValue:))
            ?? (cachedStockKey ? .alphaVantage : .yahoo)
        let days = defaults.integer(forKey: Key.calendarDays)
        calendarDays = Self.calendarDayOptions.contains(days) ? days : 1
        calendarShowsAllDay = defaults.object(forKey: Key.calendarAllDay) as? Bool ?? true
        timeZones = (defaults.stringArray(forKey: Key.timeZones) ?? []).filter { TimeZone(identifier: $0) != nil }
        // The timer moved from the Live Activities page to the widgets (it is a
        // live activity only while running): add it once for existing users if
        // there is room; never push out a widget they chose.
        if !defaults.bool(forKey: Key.timerMigrated) {
            if defaults.stringArray(forKey: Key.enabled) != nil, enabled.count < Self.maxEnabled { enabled.insert(.timer) }
            defaults.set(true, forKey: Key.timerMigrated)
            if defaults.stringArray(forKey: Key.enabled) != nil {
                defaults.set(WidgetKind.allCases.filter(enabled.contains).map(\.rawValue), forKey: Key.enabled)
            }
        }
        if enabled.count > Self.maxEnabled {
            enabled = Set(order.filter(enabled.contains).prefix(Self.maxEnabled))
        }
        loading = false
    }

    var enabledInOrder: [WidgetKind] { order.filter(enabled.contains) }

    func isEnabled(_ kind: WidgetKind) -> Bool { enabled.contains(kind) }

    var canEnableMore: Bool { enabled.count < Self.maxEnabled }

    /// Localized explanation shown when a fifth widget is turned on.
    static func limitMessage(trying kind: WidgetKind?, enabled: [WidgetKind], lang: LanguageSettings) -> String {
        let names = enabled.map { lang.t($0.titleKey) }.joined(separator: lang.t(.listSeparator))
        return lang.t(.widgetLimitMessage, kind.map { lang.t($0.titleKey) } ?? "", "\(maxEnabled)", names)
    }

    /// Returns false when turning on would exceed `maxEnabled`.
    @discardableResult
    func setEnabled(_ kind: WidgetKind, _ on: Bool) -> Bool {
        if on {
            guard enabled.contains(kind) || canEnableMore else { return false }
            enabled.insert(kind)
        } else {
            enabled.remove(kind)
        }
        persist()
        return true
    }

    // MARK: Clock

    enum TimeZoneError: Error, Equatable { case invalid, duplicate, limit }

    @discardableResult
    func addTimeZone(_ identifier: String) -> Result<String, TimeZoneError> {
        guard TimeZone(identifier: identifier) != nil else { return .failure(.invalid) }
        guard !timeZones.contains(identifier) else { return .failure(.duplicate) }
        guard timeZones.count < Self.maxExtraTimeZones else { return .failure(.limit) }
        timeZones.append(identifier)
        persist()
        return .success(identifier)
    }

    func removeTimeZone(_ identifier: String) {
        timeZones.removeAll { $0 == identifier }
        persist()
    }

    /// Moves a widget up (negative) or down (positive) in the display order.
    func move(_ kind: WidgetKind, by offset: Int) {
        guard let index = order.firstIndex(of: kind) else { return }
        let target = index + offset
        guard order.indices.contains(target) else { return }
        order.insert(order.remove(at: index), at: target)
        persist()
    }

    func move(fromOffsets source: IndexSet, toOffset destination: Int) {
        order.move(fromOffsets: source, toOffset: destination)
        persist()
    }

    // MARK: Stocks

    enum SymbolError: Error, Equatable { case invalid, duplicate, limit }

    /// Uppercased ticker such as "AAPL", "BRK.B" or "TSCO.LON".
    nonisolated static func normalizeSymbol(_ raw: String) -> String? {
        let symbol = raw.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard (1...15).contains(symbol.count),
              symbol.unicodeScalars.allSatisfy({ CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.-^=").contains($0) })
        else { return nil }
        return symbol
    }

    @discardableResult
    func addSymbol(_ raw: String) -> Result<String, SymbolError> {
        guard let symbol = Self.normalizeSymbol(raw) else { return .failure(.invalid) }
        guard !symbols.contains(symbol) else { return .failure(.duplicate) }
        guard symbols.count < Self.maxSymbols else { return .failure(.limit) }
        symbols.append(symbol)
        persist()
        return .success(symbol)
    }

    func removeSymbol(_ symbol: String) {
        symbols.removeAll { $0 == symbol }
        persist()
    }

    func stockAPIKey() -> String? {
        guard hasStockAPIKey else { return nil }
        return secrets.read()
    }

    /// Reads the key off the main thread without any Keychain UI, so a locked
    /// Keychain (e.g. at the lock screen) can never freeze the island.
    /// If the Keychain still blocks (e.g. an access prompt waiting behind the
    /// lock screen after a re-signed build), give up after `keyReadTimeout`.
    func loadStockAPIKey(timeout: Duration = WidgetSettings.keyReadTimeout) async -> Result<String, ProviderError> {
        guard hasStockAPIKey else { return .failure(.missingAPIKey) }
        let store = secrets
        let gate = keyReadGate
        // A previous read is still stuck: don't pile up blocked threads.
        guard gate.begin() else { return .failure(.keychainUnavailable) }
        return await withCheckedContinuation { continuation in
            let once = OnceFlag()
            Task.detached(priority: .utility) {
                let result = store.readKey()
                gate.end()
                if once.claim() { continuation.resume(returning: result) }
            }
            Task.detached {
                try? await Task.sleep(for: timeout)
                if once.claim() { continuation.resume(returning: .failure(.keychainUnavailable)) }
            }
        }
    }

    nonisolated static let keyReadTimeout: Duration = .seconds(5)
    private let keyReadGate = KeyReadGate()

    func setStockAPIKey(_ key: String?) {
        let trimmed = key?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if trimmed.isEmpty {
            secrets.delete()
            hasStockAPIKey = false
        } else {
            hasStockAPIKey = secrets.write(trimmed)
        }
        defaults.set(hasStockAPIKey, forKey: Key.hasKey)
    }

    // MARK: Network gating

    /// Weather is fetched only when the widget is on and the user picked a city.
    var weatherFetchAllowed: Bool { isEnabled(.weather) && place != nil }
    /// Quotes are fetched only when the widget is on and tickers exist (plus a
    /// saved key when Alpha Vantage is the provider).
    var stocksFetchAllowed: Bool {
        isEnabled(.stocks) && !symbols.isEmpty && (stockProvider == .yahoo || hasStockAPIKey)
    }

    private func persist() {
        guard !loading else { return }
        defaults.set(order.map(\.rawValue), forKey: Key.order)
        defaults.set(WidgetKind.allCases.filter(enabled.contains).map(\.rawValue), forKey: Key.enabled)
        if let place, let data = try? JSONEncoder().encode(place) {
            defaults.set(data, forKey: Key.place)
        } else {
            defaults.removeObject(forKey: Key.place)
        }
        defaults.set(unit.rawValue, forKey: Key.unit)
        defaults.set(stockProvider.rawValue, forKey: Key.provider)
        defaults.set(calendarDays, forKey: Key.calendarDays)
        defaults.set(calendarShowsAllDay, forKey: Key.calendarAllDay)
        defaults.set(timeZones, forKey: Key.timeZones)
        defaults.set(symbols, forKey: Key.symbols)
    }
}

// MARK: - Secret storage

/// Resumes a continuation at most once.
final class OnceFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false
    func claim() -> Bool { lock.withLock { defer { done = true }; return !done } }
}

/// Allows one outstanding Keychain read at a time.
final class KeyReadGate: @unchecked Sendable {
    private let lock = NSLock()
    private var busy = false
    func begin() -> Bool { lock.withLock { guard !busy else { return false }; busy = true; return true } }
    func end() { lock.withLock { busy = false } }
}

protocol SecretStore: Sendable {
    func read() -> String?
    /// Like `read()`, but tells "not stored" apart from "stored but unreadable".
    func readKey() -> Result<String, ProviderError>
    @discardableResult func write(_ value: String) -> Bool
    func delete()
}

extension SecretStore {
    func readKey() -> Result<String, ProviderError> {
        read().map { .success($0) } ?? .failure(.missingAPIKey)
    }
}

/// Generic-password item in the login Keychain.
struct KeychainSecretStore: SecretStore {
    var service = KeychainSecretStore.defaultService

    /// The shipping app keeps its original item name; other bundle IDs (e.g.
    /// isolated preview copies) get their own item and never touch it.
    static var defaultService: String {
        guard let id = Bundle.main.bundleIdentifier, id != "local.notchisland.app" else {
            return "local.notchisland.alphavantage"
        }
        return id + ".alphavantage"
    }
    var account = "api-key"

    private var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }

    func read() -> String? { try? readKey().get() }

    func readKey() -> Result<String, ProviderError> {
        var q = query
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        // Fail instead of showing an unlock/permission prompt.
        let context = LAContext()
        context.interactionNotAllowed = true
        q[kSecUseAuthenticationContext as String] = context
        var item: CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary, &item)
        switch status {
        case errSecSuccess:
            guard let data = item as? Data, let key = String(data: data, encoding: .utf8), !key.isEmpty else {
                return .failure(.keychainUnavailable)
            }
            return .success(key)
        case errSecItemNotFound:
            return .failure(.missingAPIKey)
        default:
            return .failure(.keychainUnavailable)
        }
    }

    func write(_ value: String) -> Bool {
        let data = Data(value.utf8)
        let status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var q = query
            q[kSecValueData as String] = data
            return SecItemAdd(q as CFDictionary, nil) == errSecSuccess
        }
        return status == errSecSuccess
    }

    func delete() { SecItemDelete(query as CFDictionary) }
}

/// In-memory store used by tests.
final class MemorySecretStore: SecretStore, @unchecked Sendable {
    var value: String?
    init(_ value: String? = nil) { self.value = value }
    func read() -> String? { value }
    func write(_ value: String) -> Bool { self.value = value; return true }
    func delete() { value = nil }
}
