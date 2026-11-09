import Foundation

// MARK: - HTTP

protocol HTTPClient: Sendable {
    /// Returns the body and HTTP status code. Throws `ProviderError`.
    func get(_ url: URL) async throws -> (Data, Int)
}

/// Ephemeral session: no cookies, no disk cache, short timeouts.
struct URLSessionHTTPClient: HTTPClient {
    private static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 12
        config.timeoutIntervalForResource = 20
        config.httpCookieStorage = nil
        config.urlCache = nil
        config.httpAdditionalHeaders = ["User-Agent": "NotchIsland/0.3 (macOS)"]
        return URLSession(configuration: config)
    }()

    func get(_ url: URL) async throws -> (Data, Int) {
        do {
            let (data, response) = try await Self.session.data(from: url)
            return (data, (response as? HTTPURLResponse)?.statusCode ?? 0)
        } catch {
            // Never surface the URL (it may contain the API key).
            throw ProviderError(error)
        }
    }
}

enum ProviderError: Error, Equatable {
    case offline, timeout, network
    case http(Int)
    case rateLimited
    case invalidResponse
    case notFound
    case missingAPIKey
    /// Key is saved but the Keychain refused to hand it out (e.g. locked).
    case keychainUnavailable
    /// Search text the provider can't handle (e.g. non-Latin company names on Yahoo).
    case unsupportedQuery
    case invalidAPIKey
    case cancelled

    init(_ error: Error) {
        if let error = error as? ProviderError { self = error; return }
        if error is CancellationError { self = .cancelled; return }
        guard let urlError = error as? URLError else { self = .network; return }
        switch urlError.code {
        case .notConnectedToInternet, .networkConnectionLost, .dataNotAllowed, .internationalRoamingOff:
            self = .offline
        case .timedOut: self = .timeout
        case .cancelled: self = .cancelled
        default: self = .network
        }
    }

    var messageKey: L10nKey {
        switch self {
        case .offline: return .errOffline
        case .timeout: return .errTimeout
        case .network, .cancelled: return .errNetwork
        case .http: return .errServer
        case .rateLimited: return .errRateLimited
        case .invalidResponse: return .errInvalidResponse
        case .notFound: return .errNotFound
        case .missingAPIKey: return .errMissingKey
        case .invalidAPIKey: return .errInvalidKey
        case .keychainUnavailable: return .errKeychain
        case .unsupportedQuery: return .errUnsupportedQuery
        }
    }
}

// MARK: - Weather (Open-Meteo, no API key)

struct WeatherSnapshot: Equatable {
    var temperature: Double
    var apparent: Double?
    var high: Double?
    var low: Double?
    var code: Int
    var isDay: Bool
    /// Observation time reported by the provider (local to the place).
    var observedLocal: String?
}

/// https://open-meteo.com/en/docs — free for non-commercial use, CC BY 4.0
/// attribution required ("Weather data by Open-Meteo.com").
struct OpenMeteoProvider {
    var client: HTTPClient

    func searchPlaces(_ query: String, language: String) async throws -> [Place] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        var components = URLComponents(string: "https://geocoding-api.open-meteo.com/v1/search")!
        components.queryItems = [
            URLQueryItem(name: "name", value: trimmed),
            URLQueryItem(name: "count", value: "8"),
            URLQueryItem(name: "language", value: language),
            URLQueryItem(name: "format", value: "json"),
        ]
        let data = try await fetch(components.url!)
        struct Response: Decodable {
            struct Result: Decodable {
                var name: String
                var latitude: Double
                var longitude: Double
                var country: String?
                var admin1: String?
                var timezone: String?
            }
            var results: [Result]?
        }
        guard let response = try? JSONDecoder().decode(Response.self, from: data) else { throw ProviderError.invalidResponse }
        let places = (response.results ?? []).map {
            Place(name: $0.name, admin: $0.admin1, country: $0.country,
                  latitude: $0.latitude, longitude: $0.longitude, timezone: $0.timezone)
        }
        if places.isEmpty { throw ProviderError.notFound }
        return places
    }

    func current(for place: Place, unit: TemperatureUnit) async throws -> WeatherSnapshot {
        var components = URLComponents(string: "https://api.open-meteo.com/v1/forecast")!
        components.queryItems = [
            URLQueryItem(name: "latitude", value: String(format: "%.4f", place.latitude)),
            URLQueryItem(name: "longitude", value: String(format: "%.4f", place.longitude)),
            URLQueryItem(name: "current", value: "temperature_2m,apparent_temperature,weather_code,is_day"),
            URLQueryItem(name: "daily", value: "temperature_2m_max,temperature_2m_min"),
            URLQueryItem(name: "timezone", value: "auto"),
            URLQueryItem(name: "forecast_days", value: "1"),
            URLQueryItem(name: "temperature_unit", value: unit.rawValue),
        ]
        return try Self.parseForecast(try await fetch(components.url!))
    }

    static func parseForecast(_ data: Data) throws -> WeatherSnapshot {
        struct Response: Decodable {
            struct Current: Decodable {
                var time: String?
                var temperature_2m: Double?
                var apparent_temperature: Double?
                var weather_code: Int?
                var is_day: Int?
            }
            struct Daily: Decodable {
                var temperature_2m_max: [Double?]?
                var temperature_2m_min: [Double?]?
            }
            var current: Current?
            var daily: Daily?
        }
        guard let response = try? JSONDecoder().decode(Response.self, from: data),
              let current = response.current,
              let temperature = current.temperature_2m,
              let code = current.weather_code
        else { throw ProviderError.invalidResponse }
        return WeatherSnapshot(temperature: temperature,
                               apparent: current.apparent_temperature,
                               high: response.daily?.temperature_2m_max?.first ?? nil,
                               low: response.daily?.temperature_2m_min?.first ?? nil,
                               code: code,
                               isDay: (current.is_day ?? 1) == 1,
                               observedLocal: current.time)
    }

    private func fetch(_ url: URL) async throws -> Data {
        let (data, status) = try await client.get(url)
        switch status {
        case 200: return data
        case 429: throw ProviderError.rateLimited
        default: throw ProviderError.http(status)
        }
    }

    /// WMO weather interpretation codes → SF Symbol + localized description key.
    static func describe(code: Int, isDay: Bool) -> (symbol: String, key: L10nKey) {
        switch code {
        case 0: return (isDay ? "sun.max.fill" : "moon.stars.fill", .wxClear)
        case 1, 2: return (isDay ? "cloud.sun.fill" : "cloud.moon.fill", .wxPartlyCloudy)
        case 3: return ("cloud.fill", .wxCloudy)
        case 45, 48: return ("cloud.fog.fill", .wxFog)
        case 51, 53, 55, 56, 57: return ("cloud.drizzle.fill", .wxDrizzle)
        case 61, 63, 65, 66, 67, 80, 81, 82: return ("cloud.rain.fill", .wxRain)
        case 71, 73, 75, 77, 85, 86: return ("cloud.snow.fill", .wxSnow)
        case 95, 96, 99: return ("cloud.bolt.rain.fill", .wxThunder)
        default: return ("cloud.fill", .wxUnknown)
        }
    }
}

// MARK: - Stocks (Alpha Vantage, free API key)

struct StockQuote: Equatable {
    var symbol: String
    /// Latest daily close.
    var price: Double
    /// Versus the previous daily close.
    var change: Double
    var changePercent: Double
    /// "YYYY-MM-DD" as reported by the provider; free data is not real-time.
    var latestTradingDay: String
    /// Real daily closes, oldest first (up to `AlphaVantageProvider.chartDays`), for the sparkline.
    var closes: [Double] = []
    /// Exact time of `price` when the provider reports one (Yahoo `regularMarketTime`).
    var asOf: Date? = nil
    var currency: String? = nil
    var provider: StockProviderKind = .alphaVantage
}

enum StockProviderKind: String, CaseIterable, Codable, Identifiable {
    /// Unofficial, undocumented Yahoo Finance chart endpoint; no key.
    case yahoo
    /// Documented Alpha Vantage API; needs a free key.
    case alphaVantage
    var id: String { rawValue }
    var displayName: String { self == .yahoo ? "Yahoo Finance" : "Alpha Vantage" }
}

/// Yahoo Finance's public chart endpoint (`/v8/finance/chart/{symbol}`), the
/// same data source many quote apps use. It is **unofficial and undocumented**:
/// Yahoo can rate-limit (HTTP 429), change or block it at any time, and prices
/// are delayed (exchange-dependent, typically 15–20 min) or end-of-day. One
/// request per ticker returns the price, its timestamp and the daily closes.
/// One search hit: a ticker on a specific exchange.
struct SymbolMatch: Equatable, Identifiable {
    var symbol: String
    var name: String
    var exchangeCode: String
    var exchangeName: String
    var type: String
    var id: String { symbol }
}

struct YahooFinanceProvider {
    var client: HTTPClient
    static let chartDays = 30

    /// Yahoo's (unofficial) search answers HTTP 400 for non-ASCII text such as
    /// 「台積電」, so those queries are explained locally instead of sent.
    static func isSearchable(_ query: String) -> Bool {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return (1...40).contains(q.count) && q.unicodeScalars.allSatisfy { $0.isASCII && $0.value >= 0x20 }
    }

    static func searchURL(_ query: String) -> URL? {
        guard isSearchable(query) else { return nil }
        var components = URLComponents(string: "https://query1.finance.yahoo.com/v1/finance/search")!
        components.queryItems = [URLQueryItem(name: "q", value: query.trimmingCharacters(in: .whitespacesAndNewlines)),
                                 URLQueryItem(name: "quotesCount", value: "12"), URLQueryItem(name: "newsCount", value: "0"),
                                 URLQueryItem(name: "listsCount", value: "0")]
        return components.url
    }

    func search(_ query: String) async throws -> [SymbolMatch] {
        guard let url = Self.searchURL(query) else { throw ProviderError.unsupportedQuery }
        let (data, status) = try await client.get(url)
        switch status {
        case 200: return try Self.parseSearch(data)
        case 400: throw ProviderError.unsupportedQuery
        case 429: throw ProviderError.rateLimited
        default: throw ProviderError.http(status)
        }
    }

    /// Keeps only results whose symbol passes the app's ticker validation.
    static func parseSearch(_ data: Data) throws -> [SymbolMatch] {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let quotes = object["quotes"] as? [[String: Any]] else { throw ProviderError.invalidResponse }
        var seen = Set<String>()
        return quotes.compactMap { q -> SymbolMatch? in
            guard let raw = q["symbol"] as? String, let symbol = WidgetSettings.normalizeSymbol(raw), seen.insert(symbol).inserted
            else { return nil }
            let name = (q["longname"] as? String) ?? (q["shortname"] as? String) ?? symbol
            return SymbolMatch(symbol: symbol, name: name,
                               exchangeCode: (q["exchange"] as? String) ?? "",
                               exchangeName: (q["exchDisp"] as? String) ?? (q["exchange"] as? String) ?? "",
                               type: (q["typeDisp"] as? String) ?? (q["quoteType"] as? String) ?? "")
        }
    }

    /// Path-safe encoding: only letters, digits, "." and "-" stay literal
    /// ("^GSPC" → "%5EGSPC", "EURUSD=X" → "EURUSD%3DX").
    static func url(for symbol: String) -> URL? {
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789.-")
        guard let encoded = symbol.addingPercentEncoding(withAllowedCharacters: allowed), !encoded.isEmpty else { return nil }
        var components = URLComponents(string: "https://query1.finance.yahoo.com")!
        components.percentEncodedPath = "/v8/finance/chart/" + encoded
        components.queryItems = [URLQueryItem(name: "range", value: "3mo"), URLQueryItem(name: "interval", value: "1d")]
        return components.url
    }

    func quote(symbol: String) async throws -> StockQuote {
        guard let url = Self.url(for: symbol) else { throw ProviderError.notFound }
        let (data, status) = try await client.get(url)
        switch status {
        case 200: return try Self.parse(data, symbol: symbol)
        case 404: throw ProviderError.notFound
        case 429: throw ProviderError.rateLimited
        default:
            // 4xx with a payload such as "No data found" is still "not found".
            if (try? Self.parse(data, symbol: symbol)) == nil, Self.errorCode(data) == "Not Found" { throw ProviderError.notFound }
            throw ProviderError.http(status)
        }
    }

    static func errorCode(_ data: Data) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let chart = object["chart"] as? [String: Any],
              let error = chart["error"] as? [String: Any] else { return nil }
        return error["code"] as? String
    }

    static func parse(_ data: Data, symbol: String) throws -> StockQuote {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let chart = object["chart"] as? [String: Any] else { throw ProviderError.invalidResponse }
        if let error = chart["error"] as? [String: Any], !(error.isEmpty) {
            throw (error["code"] as? String) == "Not Found" ? ProviderError.notFound : ProviderError.invalidResponse
        }
        guard let result = (chart["result"] as? [[String: Any]])?.first,
              let meta = result["meta"] as? [String: Any] else { throw ProviderError.notFound }
        func double(_ value: Any?) -> Double? { (value as? NSNumber)?.doubleValue }
        guard let price = double(meta["regularMarketPrice"]), price > 0,
              let marketTime = double(meta["regularMarketTime"]) else { throw ProviderError.invalidResponse }
        let offset = double(meta["gmtoffset"]) ?? 0
        let timestamps = (result["timestamp"] as? [NSNumber])?.map(\.doubleValue) ?? []
        let rawCloses = ((result["indicators"] as? [String: Any])?["quote"] as? [[String: Any]])?.first?["close"] as? [Any] ?? []
        // Keep only real (non-null) daily closes, paired with their day in exchange time.
        var daily: [(day: Int, close: Double)] = []
        for (index, time) in timestamps.enumerated() where index < rawCloses.count {
            if let close = double(rawCloses[index]), close > 0 {
                daily.append((Int(((time + offset) / 86400).rounded(.down)), close))
            }
        }
        let marketDay = Int(((marketTime + offset) / 86400).rounded(.down))
        // Previous close = last real close from a trading day before the price's day.
        guard let previous = daily.last(where: { $0.day < marketDay })?.close else { throw ProviderError.invalidResponse }
        let change = price - previous
        let asOf = Date(timeIntervalSince1970: marketTime)
        let dayFormatter = DateFormatter()
        dayFormatter.locale = Locale(identifier: "en_US_POSIX")
        dayFormatter.timeZone = TimeZone(secondsFromGMT: Int(offset)) ?? .gmt
        dayFormatter.dateFormat = "yyyy-MM-dd"
        return StockQuote(symbol: (meta["symbol"] as? String)?.uppercased() ?? symbol,
                          price: price,
                          change: change,
                          changePercent: change / previous * 100,
                          latestTradingDay: dayFormatter.string(from: asOf),
                          closes: daily.suffix(chartDays).map(\.close),
                          asOf: asOf,
                          currency: meta["currency"] as? String,
                          provider: .yahoo)
    }
}

/// https://www.alphavantage.co/documentation/#daily — documented REST API.
/// One TIME_SERIES_DAILY request gives the latest close, the previous close
/// (for the change) and the recent history drawn as the chart, so the chart
/// costs no extra quota. Free keys are limited (currently 25 requests/day,
/// ~1 request/second).
struct AlphaVantageProvider {
    var client: HTTPClient
    static let chartDays = 30

    func quote(symbol: String, apiKey: String) async throws -> StockQuote {
        var components = URLComponents(string: "https://www.alphavantage.co/query")!
        components.queryItems = [
            URLQueryItem(name: "function", value: "TIME_SERIES_DAILY"),
            URLQueryItem(name: "symbol", value: symbol),
            // outputsize defaults to "compact" (latest 100 days).
            URLQueryItem(name: "apikey", value: apiKey),
        ]
        let (data, status) = try await client.get(components.url!)
        guard status == 200 else { throw status == 429 ? ProviderError.rateLimited : ProviderError.http(status) }
        return try Self.parse(data, symbol: symbol)
    }

    /// Documented SYMBOL_SEARCH endpoint (uses the same key and quota).
    func search(_ query: String, apiKey: String) async throws -> [SymbolMatch] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (1...40).contains(q.count) else { throw ProviderError.unsupportedQuery }
        var components = URLComponents(string: "https://www.alphavantage.co/query")!
        components.queryItems = [URLQueryItem(name: "function", value: "SYMBOL_SEARCH"),
                                 URLQueryItem(name: "keywords", value: q), URLQueryItem(name: "apikey", value: apiKey)]
        let (data, status) = try await client.get(components.url!)
        guard status == 200 else { throw status == 429 ? ProviderError.rateLimited : ProviderError.http(status) }
        return try Self.parseSearch(data)
    }

    static func parseSearch(_ data: Data) throws -> [SymbolMatch] {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw ProviderError.invalidResponse }
        for field in ["Note", "Information", "Error Message"] {
            guard let message = (object[field] as? String)?.lowercased() else { continue }
            if message.contains("apikey") || message.contains("api key") {
                if message.contains("rate limit") || message.contains("requests per") { throw ProviderError.rateLimited }
                throw ProviderError.invalidAPIKey
            }
            throw field == "Error Message" ? ProviderError.unsupportedQuery : ProviderError.rateLimited
        }
        guard let matches = object["bestMatches"] as? [[String: String]] else { throw ProviderError.invalidResponse }
        var seen = Set<String>()
        return matches.compactMap { m in
            guard let raw = m["1. symbol"], let symbol = WidgetSettings.normalizeSymbol(raw), seen.insert(symbol).inserted else { return nil }
            let region = m["4. region"] ?? ""
            return SymbolMatch(symbol: symbol, name: m["2. name"] ?? symbol, exchangeCode: region,
                               exchangeName: region, type: m["3. type"] ?? "")
        }
    }

    static func parse(_ data: Data, symbol: String) throws -> StockQuote {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ProviderError.invalidResponse
        }
        // Errors arrive as HTTP 200 with a message field.
        for field in ["Note", "Information", "Error Message"] {
            guard let message = (object[field] as? String)?.lowercased() else { continue }
            if message.contains("apikey") || message.contains("api key") {
                if message.contains("rate limit") || message.contains("requests per") || message.contains("frequency") {
                    throw ProviderError.rateLimited
                }
                throw ProviderError.invalidAPIKey
            }
            // "Invalid API call" is what an unknown ticker returns.
            if field == "Error Message" { throw ProviderError.notFound }
            throw ProviderError.rateLimited
        }
        guard let series = object["Time Series (Daily)"] as? [String: [String: String]] else {
            throw ProviderError.invalidResponse
        }
        if series.isEmpty { throw ProviderError.notFound }
        // ISO dates sort chronologically as strings.
        let days = series.keys.sorted()
        var closes: [(day: String, close: Double)] = []
        for day in days {
            guard let raw = series[day]?["4. close"], let close = Double(raw), close > 0 else {
                throw ProviderError.invalidResponse
            }
            closes.append((day, close))
        }
        guard closes.count >= 2, let last = closes.last else { throw ProviderError.invalidResponse }
        let previous = closes[closes.count - 2].close
        let change = last.close - previous
        let meta = object["Meta Data"] as? [String: String]
        return StockQuote(symbol: meta?["2. Symbol"]?.uppercased() ?? symbol,
                          price: last.close,
                          change: change,
                          changePercent: change / previous * 100,
                          latestTradingDay: last.day,
                          closes: closes.suffix(chartDays).map(\.close))
    }
}
