import Foundation
import Combine
import IOKit.ps

// MARK: - Battery (IOKit power sources, public API, no network)

struct BatterySnapshot: Equatable {
    var percent: Int
    var isCharging: Bool
    var onACPower: Bool
    var isCharged: Bool
    /// Minutes; nil while macOS is still estimating or when not applicable.
    var minutesToEmpty: Int?
    var minutesToFull: Int?
}

enum BatteryStatus: Equatable {
    case unknown
    /// Desktop Macs (or a missing/unreadable internal battery).
    case noBattery
    case available(BatterySnapshot)
}

@MainActor
final class BatteryMonitor: ObservableObject {
    @Published private(set) var status: BatteryStatus = .unknown
    @Published private(set) var lowPowerMode = ProcessInfo.processInfo.isLowPowerModeEnabled

    private var runLoopSource: CFRunLoopSource?
    private var observers: [NSObjectProtocol] = []
    private var pollTask: Task<Void, Never>?

    var isRunning: Bool { runLoopSource != nil }

    func start() {
        guard runLoopSource == nil else { return }
        refresh()
        let context = Unmanaged.passUnretained(self).toOpaque()
        if let source = IOPSNotificationCreateRunLoopSource({ context in
            guard let context else { return }
            let monitor = Unmanaged<BatteryMonitor>.fromOpaque(context).takeUnretainedValue()
            MainActor.assumeIsolated { monitor.refresh() }
        }, context)?.takeRetainedValue() {
            CFRunLoopAddSource(CFRunLoopGetMain(), source, .defaultMode)
            runLoopSource = source
        }
        observers.append(NotificationCenter.default.addObserver(
            forName: .NSProcessInfoPowerStateDidChange, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.refresh() }
            })
        // Time estimates change without a power-source event; refresh occasionally.
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(60))
                self?.refresh()
            }
        }
    }

    func stop() {
        if let source = runLoopSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .defaultMode) }
        runLoopSource = nil
        observers.forEach(NotificationCenter.default.removeObserver)
        observers = []
        pollTask?.cancel()
        pollTask = nil
    }

    func refresh() {
        let newStatus = Self.read()
        if newStatus != status { status = newStatus }
        let low = ProcessInfo.processInfo.isLowPowerModeEnabled
        if low != lowPowerMode { lowPowerMode = low }
    }

    static func read() -> BatteryStatus {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef]
        else { return .noBattery }
        for source in list {
            guard let description = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue() as? [String: Any],
                  let snapshot = parse(description) else { continue }
            return .available(snapshot)
        }
        return .noBattery
    }

    /// Parses one IOPowerSources description dictionary (keys from IOPSKeys.h).
    nonisolated static func parse(_ d: [String: Any]) -> BatterySnapshot? {
        guard (d["Type"] as? String) == "InternalBattery",
              (d["Is Present"] as? Bool) ?? true,
              let current = d["Current Capacity"] as? Int,
              let max = d["Max Capacity"] as? Int, max > 0
        else { return nil }
        func minutes(_ key: String) -> Int? {
            guard let value = d[key] as? Int, value > 0 else { return nil } // -1 = still calculating
            return value
        }
        let onAC = (d["Power Source State"] as? String) == "AC Power"
        let charging = (d["Is Charging"] as? Bool) ?? false
        return BatterySnapshot(percent: Swift.max(0, Swift.min(100, Int((Double(current) / Double(max) * 100).rounded()))),
                               isCharging: charging,
                               onACPower: onAC,
                               isCharged: (d["Is Charged"] as? Bool) ?? false,
                               minutesToEmpty: onAC ? nil : minutes("Time to Empty"),
                               minutesToFull: charging ? minutes("Time to Full Charge") : nil)
    }
}

// MARK: - Network feeds

/// Loading/error/freshness state of one provider feed. A failed refresh keeps
/// the last good value, but the UI marks it unavailable with its timestamp.
struct FeedState<Value: Equatable>: Equatable {
    var value: Value?
    var fetchedAt: Date?
    var isLoading = false
    var error: ProviderError?

    static var empty: FeedState { FeedState() }
}

struct QuoteRow: Equatable, Identifiable {
    var symbol: String
    var quote: StockQuote?
    var error: ProviderError?
    var id: String { symbol }
}

/// Owns weather/stock fetching. Nothing touches the network unless the widget
/// is enabled and configured (see `WidgetSettings.*FetchAllowed`).
@MainActor
final class WidgetDataCenter: ObservableObject {
    @Published private(set) var weather = FeedState<WeatherSnapshot>.empty
    @Published private(set) var stocks = FeedState<[QuoteRow]>.empty

    static let weatherInterval: TimeInterval = 30 * 60
    /// Free Alpha Vantage keys allow 25 requests/day: 3 tickers × 8 refreshes.
    static let stocksInterval: TimeInterval = 3 * 60 * 60
    static let manualRefreshCooldown: TimeInterval = 60
    static let stocksManualCooldown: TimeInterval = 5 * 60

    let settings: WidgetSettings
    private let weatherProvider: OpenMeteoProvider
    private let stockProvider: AlphaVantageProvider
    private let yahooProvider: YahooFinanceProvider
    private let now: () -> Date
    /// Pause between quote requests (free tier allows ~1 request/second).
    var stockRequestSpacing: Duration = .milliseconds(1200)

    private var weatherTask: Task<Void, Never>?
    private var stocksTask: Task<Void, Never>?
    private var scheduler: Task<Void, Never>?
    private var cancellables: Set<AnyCancellable> = []
    private var weatherKey: String?
    private var stocksKey: String?

    /// Number of network requests started (used by tests to prove gating).
    private(set) var requestCount = 0

    init(settings: WidgetSettings, client: HTTPClient = URLSessionHTTPClient(), now: @escaping () -> Date = Date.init) {
        self.settings = settings
        weatherProvider = OpenMeteoProvider(client: client)
        stockProvider = AlphaVantageProvider(client: client)
        yahooProvider = YahooFinanceProvider(client: client)
        self.now = now
    }

    func start() {
        // Any configuration change re-evaluates what may be fetched.
        settings.objectWillChange
            .sink { [weak self] _ in
                DispatchQueue.main.async { MainActor.assumeIsolated { self?.configurationChanged() } }
            }
            .store(in: &cancellables)
        configurationChanged()
        scheduler = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(60))
                self?.refreshDue()
            }
        }
    }

    /// Called on settings changes; clears feeds that are no longer allowed and
    /// refetches when the city/unit/tickers changed.
    func configurationChanged() {
        if settings.weatherFetchAllowed, let place = settings.place {
            let key = "\(place.id)|\(settings.unit.rawValue)"
            if key != weatherKey {
                weatherKey = key
                weather = .empty
                refreshWeather(force: true)
            }
        } else {
            weatherKey = nil
            weatherTask?.cancel(); weatherTask = nil
            if weather != .empty { weather = .empty }
        }

        if settings.stocksFetchAllowed {
            let key = settings.stockProvider.rawValue + "|" + settings.symbols.joined(separator: ",")
            if key != stocksKey {
                stocksKey = key
                stocks = .empty
                refreshStocks(force: true)
            }
        } else {
            stocksKey = nil
            stocksTask?.cancel(); stocksTask = nil
            if stocks != .empty { stocks = .empty }
        }
    }

    /// Refreshes feeds whose data is older than their interval (e.g. after wake).
    func refreshDue() {
        refreshWeather(force: false)
        refreshStocks(force: false)
    }

    /// Manual refresh from the UI; rate-limited to protect free provider quotas.
    func manualRefresh(_ kind: WidgetKind) {
        switch kind {
        case .weather:
            if isOlder(weather.fetchedAt, than: Self.manualRefreshCooldown) || weather.error != nil { refreshWeather(force: true) }
        case .stocks:
            if isOlder(stocks.fetchedAt, than: stocksManualCooldown) || stocks.error != nil { refreshStocks(force: true) }
        default: break
        }
    }

    func canManuallyRefresh(_ kind: WidgetKind) -> Bool {
        switch kind {
        case .weather: return !weather.isLoading && (weather.error != nil || isOlder(weather.fetchedAt, than: Self.manualRefreshCooldown))
        case .stocks: return !stocks.isLoading && (stocks.error != nil || isOlder(stocks.fetchedAt, than: stocksManualCooldown))
        default: return false
        }
    }

    private func isOlder(_ date: Date?, than interval: TimeInterval) -> Bool {
        guard let date else { return true }
        return now().timeIntervalSince(date) >= interval
    }

    func refreshWeather(force: Bool) {
        guard settings.weatherFetchAllowed, let place = settings.place, weatherTask == nil else { return }
        guard force || isOlder(weather.fetchedAt, than: Self.weatherInterval) else { return }
        // Don't hammer a failing provider from the periodic scheduler.
        if !force, weather.error != nil, !isOlder(weather.fetchedAt ?? lastWeatherAttempt, than: 5 * 60) { return }
        let unit = settings.unit
        weather.isLoading = true
        lastWeatherAttempt = now()
        requestCount += 1
        weatherTask = Task { [weak self, weatherProvider] in
            let result: Result<WeatherSnapshot, ProviderError>
            do { result = .success(try await weatherProvider.current(for: place, unit: unit)) }
            catch { result = .failure(ProviderError(error)) }
            guard let self else { return }
            self.weatherTask = nil
            if case .failure(.cancelled) = result { self.weather.isLoading = false; return }
            // Ignore results for a configuration that changed meanwhile.
            guard self.settings.weatherFetchAllowed, self.settings.place == place, self.settings.unit == unit else {
                self.weather.isLoading = false
                return
            }
            switch result {
            case .success(let snapshot):
                self.weather = FeedState(value: snapshot, fetchedAt: self.now(), isLoading: false, error: nil)
            case .failure(let error):
                self.weather.isLoading = false
                self.weather.error = error
            }
        }
    }
    private var lastWeatherAttempt: Date?
    private var lastStocksAttempt: Date?

    /// Yahoo (unofficial) is refreshed more often than the 25-request/day Alpha Vantage free tier.
    static let yahooInterval: TimeInterval = 15 * 60
    static let yahooManualCooldown: TimeInterval = 60
    var stocksInterval: TimeInterval { settings.stockProvider == .yahoo ? Self.yahooInterval : Self.stocksInterval }
    var stocksManualCooldown: TimeInterval { settings.stockProvider == .yahoo ? Self.yahooManualCooldown : Self.stocksManualCooldown }
    /// Pause between Yahoo requests, to stay well clear of its rate limiting.
    var yahooRequestSpacing: Duration = .milliseconds(400)

    func refreshStocks(force: Bool) {
        guard settings.stocksFetchAllowed, stocksTask == nil else { return }
        guard force || isOlder(stocks.fetchedAt, than: stocksInterval) else { return }
        if !force, stocks.error != nil, !isOlder(stocks.fetchedAt ?? lastStocksAttempt, than: 30 * 60) { return }
        let symbols = settings.symbols
        let provider = settings.stockProvider
        stocks.isLoading = true
        lastStocksAttempt = now()
        stocksTask = Task { [weak self, settings, stockProvider, yahooProvider, stockRequestSpacing, yahooRequestSpacing] in
            var key = ""
            if provider == .alphaVantage {
                switch await settings.loadStockAPIKey() {
                case .success(let value): key = value
                case .failure(let error):
                    // No request is made without a readable key.
                    guard let self else { return }
                    self.stocksTask = nil
                    self.stocks.isLoading = false
                    self.stocks.error = error
                    return
                }
            }
            var rows: [QuoteRow] = []
            for (index, symbol) in symbols.enumerated() {
                if Task.isCancelled { break }
                if index > 0 { try? await Task.sleep(for: provider == .yahoo ? yahooRequestSpacing : stockRequestSpacing) }
                self?.requestCount += 1
                do {
                    let quote = provider == .yahoo
                        ? try await yahooProvider.quote(symbol: symbol)
                        : try await stockProvider.quote(symbol: symbol, apiKey: key)
                    rows.append(QuoteRow(symbol: symbol, quote: quote))
                } catch {
                    let error = ProviderError(error)
                    rows.append(QuoteRow(symbol: symbol, error: error))
                    // Key/quota problems affect every ticker: stop spending requests.
                    if error == .invalidAPIKey || error == .rateLimited || error == .offline {
                        for rest in symbols.dropFirst(index + 1) { rows.append(QuoteRow(symbol: rest, error: error)) }
                        break
                    }
                }
            }
            guard let self else { return }
            self.stocksTask = nil
            guard !Task.isCancelled, self.settings.stocksFetchAllowed, self.settings.symbols == symbols,
                  self.settings.stockProvider == provider else {
                self.stocks.isLoading = false
                return
            }
            let successes = rows.filter { $0.quote != nil }.count
            if successes > 0 {
                // Rows that failed this time stay marked as unavailable.
                self.stocks = FeedState(value: rows, fetchedAt: self.now(), isLoading: false,
                                        error: successes < rows.count ? rows.first(where: { $0.error != nil })?.error : nil)
            } else {
                self.stocks.isLoading = false
                self.stocks.error = rows.first?.error ?? .invalidResponse
                self.stocks.value = rows
                self.stocks.fetchedAt = nil
            }
        }
    }

    /// Lets tests await completion of in-flight requests.
    func waitForIdle() async {
        await weatherTask?.value
        await stocksTask?.value
    }
}
