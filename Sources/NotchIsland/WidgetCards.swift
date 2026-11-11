import SwiftUI
import AppKit

// iOS-inspired small widget cards shown inside the expanded island. These are
// Notch Island's own widgets (drawn with SwiftUI); they are not iOS/WidgetKit
// widgets and other apps' widgets cannot be hosted here.

// MARK: - Page

struct WidgetsPage: View {
    @ObservedObject var model: IslandViewModel
    @ObservedObject var lang: LanguageSettings
    @EnvironmentObject var settings: WidgetSettings

    static let spacing: CGFloat = IslandViewModel.widgetCardSpacing

    var body: some View {
        let kinds = settings.enabledInOrder
        if kinds.isEmpty {
            emptyState
        } else {
            GeometryReader { geo in
                let count = CGFloat(kinds.count)
                // Square cards like iOS small widgets, as large as the row allows.
                let side = floor(min(geo.size.height, (geo.size.width - Self.spacing * (count - 1)) / count))
                HStack(spacing: Self.spacing) {
                    ForEach(kinds) { kind in
                        card(kind)
                            .frame(width: side, height: side)
                            .transition(.scale(scale: 0.88).combined(with: .opacity))
                    }
                }
                .frame(width: geo.size.width, height: geo.size.height)
                .environment(\.widgetSide, side)
            }
            .animation(.spring(response: 0.38, dampingFraction: 0.86), value: kinds)
        }
    }

    @ViewBuilder private func card(_ kind: WidgetKind) -> some View {
        switch kind {
        case .battery: BatteryCard(lang: lang)
        case .weather: WeatherCard(lang: lang)
        case .stocks: StocksCard(lang: lang)
        case .stopwatch: StopwatchCard(lang: lang)
        case .timer: TimerCard(lang: lang)
        case .calendar: CalendarCard(lang: lang)
        case .clock: ClockCard(lang: lang)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 6) {
            Image(systemName: "square.grid.2x2")
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(.white.opacity(0.5))
            Text(lang.t(.noWidgets)).font(.system(size: 13, weight: .semibold))
            Text(lang.t(.noWidgetsHint))
                .font(.system(size: 11))
                .foregroundStyle(.white.opacity(0.6))
                .multilineTextAlignment(.center)
            Button(lang.t(.customize)) { model.onOpenSettings?() }
                .buttonStyle(PillStyle())
                .padding(.top, 2)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct WidgetSideKey: EnvironmentKey { static let defaultValue: CGFloat = 128 }

extension EnvironmentValues {
    /// Card edge length; content scales from it (iOS small widgets are 158 pt).
    var widgetSide: CGFloat {
        get { self[WidgetSideKey.self] }
        set { self[WidgetSideKey.self] = newValue }
    }
}

// MARK: - Card chrome

/// Continuous-corner card with optional press feedback, like a home-screen widget.
struct WidgetCard<Background: View, Content: View>: View {
    var action: (() -> Void)?
    var help: String = ""
    @ViewBuilder var background: Background
    @ViewBuilder var content: Content
    @Environment(\.widgetSide) private var side

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: side * 0.17, style: .continuous)
        let card = content
            .padding(side * 0.095)
            .frame(width: side, height: side, alignment: .topLeading)
            .background(background)
            .clipShape(shape)
            .overlay(shape.strokeBorder(.white.opacity(0.08), lineWidth: 0.5))
            .contentShape(shape)
        if let action {
            Button(action: action) { card }
                .buttonStyle(WidgetPressStyle())
                .help(help)
                .accessibilityHint(help)
        } else {
            card
        }
    }
}

struct WidgetPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.95 : 1)
            .brightness(configuration.isPressed ? -0.04 : 0)
            .animation(.spring(response: 0.25, dampingFraction: 0.7), value: configuration.isPressed)
    }
}

/// Dark card fill used by iOS's Batteries / Stocks / Clock widgets.
struct DarkCardBackground: View {
    var body: some View {
        LinearGradient(colors: [Color(hex: 0x2C2C2E), Color(hex: 0x1C1C1E)], startPoint: .top, endPoint: .bottom)
    }
}

/// Short "unavailable" block; never shows a placeholder number.
struct CardUnavailable: View {
    var error: ProviderError
    var detail: String?
    @ObservedObject var lang: LanguageSettings

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Label(lang.t(.unavailable), systemImage: "exclamationmark.triangle.fill")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.yellow)
                .labelStyle(.titleAndIcon)
            Text(lang.t(error.messageKey))
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(.white.opacity(0.8))
                .lineLimit(2)
                .minimumScaleFactor(0.8)
            if let detail {
                Text(detail)
                    .font(.system(size: 9))
                    .foregroundStyle(.white.opacity(0.55))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
        }
    }
}

/// Setup prompt (city, ticker or key missing); the whole card opens Settings.
struct CardPrompt: View {
    var symbol: String
    var tint: Color
    var text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Image(systemName: symbol)
                .symbolRenderingMode(.multicolor)
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(tint)
            Spacer(minLength: 0)
            Text(text)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.white.opacity(0.92))
                .lineLimit(4)
                .minimumScaleFactor(0.75)
            Image(systemName: "plus.circle.fill")
                .font(.system(size: 13))
                .foregroundStyle(.white.opacity(0.75))
        }
    }
}

/// Tiny bottom line (source attribution, freshness).
struct CardFootnote: View {
    var text: String

    var body: some View {
        Text(text)
            .font(.system(size: 8.5, weight: .medium))
            .foregroundStyle(.white.opacity(0.6))
            .lineLimit(1)
            .minimumScaleFactor(0.7)
    }
}

// MARK: - Weather

struct WeatherCard: View {
    @ObservedObject var lang: LanguageSettings
    @EnvironmentObject var settings: WidgetSettings
    @EnvironmentObject var data: WidgetDataCenter
    @EnvironmentObject var model: IslandViewModel
    @EnvironmentObject var location: LocationProvider
    @Environment(\.widgetSide) private var side

    var body: some View {
        let feed = data.weather
        WidgetCard(action: action(feed), help: help(feed)) {
            WeatherBackground(style: style(feed))
        } content: {
            content(feed)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityText(feed))
    }

    @ViewBuilder private func content(_ feed: FeedState<WeatherSnapshot>) -> some View {
        if let place = settings.place {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 3) {
                    Text(place.displayName(lang))
                        .font(.system(size: 13, weight: .semibold))
                        .lineLimit(1)
                        .minimumScaleFactor(0.75)
                    Image(systemName: "location.fill").font(.system(size: 7.5, weight: .bold))
                    Spacer(minLength: 0)
                    if feed.isLoading && feed.value != nil {
                        ProgressView().controlSize(.mini).scaleEffect(0.6).frame(width: 10, height: 10)
                    }
                }
                if let error = feed.error {
                    Spacer(minLength: 4)
                    CardUnavailable(error: error, detail: lastData(feed), lang: lang)
                    Spacer(minLength: 2)
                    CardFootnote(text: lang.t(.clickToRefresh) + " · Open-Meteo")
                } else if let wx = feed.value {
                    let info = OpenMeteoProvider.describe(code: wx.code, isDay: wx.isDay)
                    Text(temp(wx.temperature))
                        .font(.system(size: side * 0.30, weight: .regular))
                        .tracking(-1)
                        .monospacedDigit()
                        .contentTransition(.numericText())
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                    Spacer(minLength: 0)
                    Image(systemName: info.symbol)
                        .symbolRenderingMode(.multicolor)
                        .font(.system(size: 13))
                        .padding(.bottom, 1)
                    Text(lang.t(info.key))
                        .font(.system(size: 11, weight: .semibold))
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                    if let high = wx.high, let low = wx.low {
                        Text(lang.t(.highLow, temp(high), temp(low)))
                            .font(.system(size: 11, weight: .medium))
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                    }
                    CardFootnote(text: ([feed.fetchedAt.map { lang.time($0) }].compactMap { $0 } + ["Open-Meteo.com"]).joined(separator: " · "))
                        .padding(.top, 2)
                } else {
                    // Loading: iOS-style redacted placeholders, no numbers.
                    Text(verbatim: "00°")
                        .font(.system(size: side * 0.30, weight: .regular))
                        .redacted(reason: .placeholder)
                    Spacer(minLength: 0)
                    Text(lang.t(.loading)).font(.system(size: 11, weight: .semibold))
                    Text(verbatim: "H:00° L:00°").font(.system(size: 11)).redacted(reason: .placeholder)
                    CardFootnote(text: "Open-Meteo.com").padding(.top, 2)
                }
            }
            .foregroundStyle(.white)
            .animation(.smooth(duration: 0.35), value: feed)
        } else if location.isLocating {
            VStack(alignment: .leading, spacing: 6) {
                ProgressView().controlSize(.small)
                Spacer(minLength: 0)
                Text(lang.t(.locating)).font(.system(size: 11, weight: .semibold))
                CardFootnote(text: "Open-Meteo.com")
            }
            .foregroundStyle(.white)
        } else if let failure = location.lastFailure {
            VStack(alignment: .leading, spacing: 2) {
                Label(lang.t(failure.messageKey), systemImage: "location.slash.fill")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.yellow)
                    .lineLimit(2)
                    .minimumScaleFactor(0.8)
                Spacer(minLength: 0)
                Text(lang.t(.chooseCityInstead))
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.white.opacity(0.85))
                    .lineLimit(3)
                    .minimumScaleFactor(0.8)
            }
        } else {
            CardPrompt(symbol: "location.circle.fill", tint: .white, text: lang.t(.weatherUseLocation))
        }
    }

    private func style(_ feed: FeedState<WeatherSnapshot>) -> WeatherBackground.Style {
        guard settings.place != nil else { return .neutral }
        if feed.error != nil { return .unavailable }
        guard let wx = feed.value else { return .neutral }
        return WeatherBackground.Style(code: wx.code, isDay: wx.isDay)
    }

    private func action(_ feed: FeedState<WeatherSnapshot>) -> (() -> Void)? {
        if settings.place == nil {
            // Denied / Location Services off: send the user to the fix (or the city field).
            if let failure = location.lastFailure {
                return failure.opensSettings ? { location.openLocationSettings() } : { model.onOpenSettings?() }
            }
            return { model.onUseCurrentLocation?() }
        }
        return data.canManuallyRefresh(.weather) ? { data.manualRefresh(.weather) } : nil
    }

    private func help(_ feed: FeedState<WeatherSnapshot>) -> String {
        settings.place == nil ? lang.t(.weatherUseLocation) : lang.t(.clickToRefresh) + " — " + lang.t(.weatherAttribution)
    }

    private func lastData(_ feed: FeedState<WeatherSnapshot>) -> String? {
        guard let value = feed.value, let date = feed.fetchedAt else { return nil }
        return lang.t(.lastData, "\(temp(value.temperature)) · \(lang.time(date))")
    }

    private func accessibilityText(_ feed: FeedState<WeatherSnapshot>) -> String {
        guard let place = settings.place else {
            return [lang.t(.weather), location.lastFailure.map { lang.t($0.messageKey) } ?? lang.t(.weatherUseLocation)].joined(separator: ", ")
        }
        var parts = [lang.t(.weather), place.displayName(lang)]
        if let error = feed.error {
            parts += [lang.t(.unavailable), lang.t(error.messageKey)]
        } else if let wx = feed.value {
            parts.append(lang.t(.degrees, "\(Int(wx.temperature.rounded()))"))
            parts.append(lang.t(OpenMeteoProvider.describe(code: wx.code, isDay: wx.isDay).key))
            if let high = wx.high, let low = wx.low { parts.append(lang.t(.highLow, temp(high), temp(low))) }
            if let date = feed.fetchedAt { parts.append(lang.t(.updatedAt, lang.time(date))) }
        } else {
            parts.append(lang.t(.loading))
        }
        parts.append(lang.t(.weatherAttribution))
        return parts.joined(separator: ", ")
    }

    private func temp(_ value: Double) -> String { "\(Int(value.rounded()))°" }
}

/// Sky gradients modelled on the iOS Weather widget, chosen from the real
/// WMO condition code and day/night flag.
struct WeatherBackground: View {
    enum Style: Equatable {
        case clearDay, clearNight, partlyDay, partlyNight, cloudyDay, cloudyNight
        case fog, rainDay, rainNight, snow, thunder, neutral, unavailable

        init(code: Int, isDay: Bool) {
            switch code {
            case 0: self = isDay ? .clearDay : .clearNight
            case 1, 2: self = isDay ? .partlyDay : .partlyNight
            case 3: self = isDay ? .cloudyDay : .cloudyNight
            case 45, 48: self = .fog
            case 51...67, 80...82: self = isDay ? .rainDay : .rainNight
            case 71...77, 85, 86: self = .snow
            case 95...99: self = .thunder
            default: self = isDay ? .cloudyDay : .cloudyNight
            }
        }

        var colors: [Color] {
            switch self {
            case .clearDay: return [Color(hex: 0x2F7FD8), Color(hex: 0x68B3F0)]
            case .clearNight: return [Color(hex: 0x0B1633), Color(hex: 0x2A3A6B)]
            case .partlyDay: return [Color(hex: 0x3F7DC0), Color(hex: 0x88B2DA)]
            case .partlyNight: return [Color(hex: 0x141D38), Color(hex: 0x3A4A74)]
            case .cloudyDay: return [Color(hex: 0x5F7389), Color(hex: 0x95A6B8)]
            case .cloudyNight: return [Color(hex: 0x262E3B), Color(hex: 0x485364)]
            case .fog: return [Color(hex: 0x6F7A84), Color(hex: 0xA3ABB2)]
            case .rainDay: return [Color(hex: 0x45566A), Color(hex: 0x748395)]
            case .rainNight: return [Color(hex: 0x1A2230), Color(hex: 0x364357)]
            case .snow: return [Color(hex: 0x6E87A3), Color(hex: 0xAABDD1)]
            case .thunder: return [Color(hex: 0x272842), Color(hex: 0x4D4E73)]
            case .neutral: return [Color(hex: 0x2F6FB8), Color(hex: 0x5C97D2)]
            case .unavailable: return [Color(hex: 0x3A4250), Color(hex: 0x575F6D)]
            }
        }
    }

    var style: Style

    var body: some View {
        ZStack {
            LinearGradient(colors: style.colors, startPoint: .top, endPoint: .bottom)
                .id(style)
                .transition(.opacity)
        }
        .animation(.easeInOut(duration: 0.6), value: style)
    }
}

// MARK: - Battery

struct BatteryCard: View {
    @ObservedObject var lang: LanguageSettings
    @EnvironmentObject var battery: BatteryMonitor
    @Environment(\.widgetSide) private var side

    var body: some View {
        WidgetCard {
            DarkCardBackground()
        } content: {
            VStack(alignment: .leading, spacing: 0) {
                BatteryRing(status: battery.status, lowPower: battery.lowPowerMode, diameter: side * 0.36)
                Spacer(minLength: 0)
                switch battery.status {
                case .available(let b):
                    HStack(alignment: .firstTextBaseline, spacing: 1) {
                        Text("\(b.percent)")
                            .font(.system(size: side * 0.2, weight: .semibold, design: .rounded))
                            .monospacedDigit()
                            .contentTransition(.numericText())
                        Text(verbatim: "%")
                            .font(.system(size: side * 0.12, weight: .semibold, design: .rounded))
                    }
                    .animation(.snappy, value: b.percent)
                    Text(statusLine(b))
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.white.opacity(0.6))
                        .lineLimit(2)
                        .minimumScaleFactor(0.75)
                case .noBattery:
                    Text(lang.t(.noBattery))
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.75))
                case .unknown:
                    Text(lang.t(.loading))
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.white.opacity(0.6))
                }
            }
            .foregroundStyle(.white)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityText)
    }

    private func statusLine(_ b: BatterySnapshot) -> String {
        var line: String
        if b.isCharging {
            line = lang.t(.charging)
            if let minutes = b.minutesToFull { line += " · " + lang.t(.timeToFull, lang.duration(minutes: minutes)) }
        } else if b.onACPower {
            line = b.isCharged || b.percent >= 100 ? lang.t(.charged) : lang.t(.pluggedIn)
        } else if let minutes = b.minutesToEmpty {
            line = lang.t(.timeLeft, lang.duration(minutes: minutes))
        } else {
            line = lang.t(.onBattery) + " · " + lang.t(.calculating)
        }
        if battery.lowPowerMode { line += " · " + lang.t(.lowPowerMode) }
        return line
    }

    private var accessibilityText: String {
        switch battery.status {
        case .available(let b): return [lang.t(.battery), lang.t(.percentCharged, "\(b.percent)"), statusLine(b)].joined(separator: ", ")
        case .noBattery: return lang.t(.battery) + ", " + lang.t(.noBattery)
        case .unknown: return lang.t(.battery) + ", " + lang.t(.loading)
        }
    }
}

/// Ring with the device glyph in the middle, like the iOS Batteries widget.
struct BatteryRing: View {
    var status: BatteryStatus
    var lowPower: Bool
    var diameter: CGFloat
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var appeared = false

    var body: some View {
        let line = max(3.5, diameter * 0.1)
        let fraction: CGFloat
        let charging: Bool
        let tint: Color
        switch status {
        case .available(let b):
            fraction = CGFloat(b.percent) / 100
            charging = b.isCharging
            tint = lowPower ? .yellow : (b.percent <= 20 && !b.onACPower ? .red : .green)
        default:
            fraction = 0; charging = false; tint = .green
        }
        return ZStack {
            Circle().stroke(.white.opacity(0.14), lineWidth: line)
            Circle()
                .trim(from: 0, to: appeared || reduceMotion ? fraction : 0)
                .stroke(tint, style: StrokeStyle(lineWidth: line, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(.spring(response: 0.9, dampingFraction: 0.9), value: fraction)
            Image(systemName: status == .noBattery ? "desktopcomputer" : "laptopcomputer")
                .font(.system(size: diameter * 0.36, weight: .medium))
                .foregroundStyle(.white.opacity(0.9))
            if charging {
                Image(systemName: "bolt.fill")
                    .font(.system(size: line * 1.5, weight: .black))
                    .foregroundStyle(.white)
                    .padding(2)
                    .background(Circle().fill(Color(hex: 0x1C1C1E)))
                    .offset(y: -diameter / 2)
                    .transition(.scale.combined(with: .opacity))
            }
        }
        .frame(width: diameter, height: diameter)
        .padding(line / 2)
        .onAppear {
            guard !reduceMotion else { return }
            withAnimation(.easeOut(duration: 0.8).delay(0.12)) { appeared = true }
        }
        .accessibilityHidden(true)
    }
}

// MARK: - Stocks

struct StocksCard: View {
    @ObservedObject var lang: LanguageSettings
    @EnvironmentObject var settings: WidgetSettings
    @EnvironmentObject var data: WidgetDataCenter
    @EnvironmentObject var model: IslandViewModel

    var body: some View {
        let feed = data.stocks
        WidgetCard(action: action, help: help) {
            DarkCardBackground()
        } content: {
            Group {
                if settings.symbols.isEmpty {
                    CardPrompt(symbol: "chart.line.uptrend.xyaxis", tint: .green, text: lang.t(.addTickers))
                } else if settings.stockProvider == .alphaVantage && !settings.hasStockAPIKey {
                    CardPrompt(symbol: "key.fill", tint: .yellow, text: lang.t(.addAPIKey))
                } else if let rows = feed.value, rows.contains(where: { $0.quote != nil }) {
                    if rows.count == 1, let quote = rows[0].quote {
                        SingleQuoteView(quote: quote, feed: feed, lang: lang)
                    } else {
                        QuoteListView(rows: rows, feed: feed, lang: lang)
                    }
                } else if let error = feed.error {
                    VStack(alignment: .leading, spacing: 0) {
                        Text(settings.symbols.joined(separator: " · "))
                            .font(.system(size: 12, weight: .bold))
                            .lineLimit(1)
                            .minimumScaleFactor(0.7)
                        Spacer(minLength: 4)
                        CardUnavailable(error: error, detail: nil, lang: lang)
                        Spacer(minLength: 2)
                        CardFootnote(text: lang.t(.clickToRefresh) + " · " + settings.stockProvider.displayName)
                    }
                } else {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(settings.symbols, id: \.self) { symbol in
                            HStack {
                                Text(symbol).font(.system(size: 11, weight: .bold))
                                Spacer()
                                Text(verbatim: "000.00").font(.system(size: 10)).redacted(reason: .placeholder)
                            }
                        }
                        Spacer(minLength: 0)
                        CardFootnote(text: lang.t(.loading) + " · " + settings.stockProvider.displayName)
                    }
                }
            }
            .foregroundStyle(.white)
            .animation(.smooth(duration: 0.35), value: feed)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityText(feed))
    }

    private var action: (() -> Void)? {
        if settings.symbols.isEmpty || needsKey { return { model.onOpenSettings?() } }
        return data.canManuallyRefresh(.stocks) ? { data.manualRefresh(.stocks) } : nil
    }

    private var help: String {
        settings.symbols.isEmpty || needsKey ? lang.t(.customize) : lang.t(.clickToRefresh) + " — " + attribution
    }

    private var needsKey: Bool { settings.stockProvider == .alphaVantage && !settings.hasStockAPIKey }

    private var attribution: String {
        lang.t(settings.stockProvider == .yahoo ? .yahooAttribution : .stocksAttribution)
    }

    private func accessibilityText(_ feed: FeedState<[QuoteRow]>) -> String {
        var parts = [lang.t(.stocks)]
        if settings.symbols.isEmpty { parts.append(lang.t(.addTickers)) }
        else if needsKey { parts.append(lang.t(.addAPIKey)) }
        else if let rows = feed.value {
            for row in rows {
                if let q = row.quote {
                    parts.append("\(q.symbol) \(QuoteFormat.price(q.price)) \(QuoteFormat.percent(q.changePercent))")
                } else {
                    parts.append("\(row.symbol) \(lang.t(.unavailable))")
                }
            }
            if let stamp = QuoteFormat.asOf(rows.compactMap(\.quote), lang: lang) { parts.append(lang.t(.asOf, stamp)) }
        } else if let error = feed.error {
            parts += [lang.t(.unavailable), lang.t(error.messageKey)]
        } else {
            parts.append(lang.t(.loading))
        }
        parts.append(attribution)
        return parts.joined(separator: ", ")
    }
}

enum QuoteFormat {
    /// Oldest price time among `quotes` (so the label never overstates freshness):
    /// exact local time when the provider reports one, else the trading day.
    @MainActor static func asOf(_ quotes: [StockQuote], lang: LanguageSettings, now: Date = Date()) -> String? {
        if let oldest = quotes.compactMap(\.asOf).min() {
            let sameDay = Calendar.current.isDate(oldest, inSameDayAs: now)
            let style = sameDay
                ? Date.FormatStyle(date: .omitted, time: .shortened).locale(lang.locale)
                : Date.FormatStyle().month(.abbreviated).day().hour().minute().locale(lang.locale)
            return oldest.formatted(style)
        }
        return quotes.map(\.latestTradingDay).filter { !$0.isEmpty }.min().map { day($0, locale: lang.locale) }
    }

    static func shortProvider(_ provider: StockProviderKind) -> String { provider == .yahoo ? "Yahoo" : "Alpha Vantage" }

    /// "2026-11-06" → "Nov 6" / "11月6日" in the UI language (falls back to the raw string).
    static func day(_ iso: String, locale: Locale) -> String {
        let parser = DateFormatter()
        parser.locale = Locale(identifier: "en_US_POSIX")
        parser.timeZone = TimeZone(identifier: "UTC")
        parser.dateFormat = "yyyy-MM-dd"
        guard let date = parser.date(from: iso) else { return iso }
        let out = DateFormatter()
        out.locale = locale
        out.timeZone = TimeZone(identifier: "UTC")
        out.setLocalizedDateFormatFromTemplate("MMMd")
        return out.string(from: date)
    }

    static func price(_ value: Double) -> String {
        value >= 1000 ? String(format: "%.0f", value) : String(format: "%.2f", value)
    }
    static func percent(_ value: Double) -> String { String(format: "%+.2f%%", value) }
    static func color(_ change: Double) -> Color {
        change > 0 ? Color(hex: 0x30D158) : (change < 0 ? Color(hex: 0xFF453A) : Color(white: 0.6))
    }
}

/// One ticker: symbol, real 30-day close chart, latest close and day change.
struct SingleQuoteView: View {
    var quote: StockQuote
    var feed: FeedState<[QuoteRow]>
    @ObservedObject var lang: LanguageSettings
    @Environment(\.widgetSide) private var side

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                Text(quote.symbol)
                    .font(.system(size: 14, weight: .bold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                Spacer(minLength: 2)
                if quote.closes.count >= 2 {
                    Text(lang.t(.daysShort, "\(quote.closes.count)"))
                        .font(.system(size: 8.5, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.5))
                }
                Image(systemName: quote.change >= 0 ? "arrowtriangle.up.fill" : "arrowtriangle.down.fill")
                    .font(.system(size: 8))
                    .foregroundStyle(QuoteFormat.color(quote.change))
            }
            if quote.closes.count >= 2 {
                // Drawn only from closes the provider actually returned.
                Sparkline(values: quote.closes, color: QuoteFormat.color(quote.closes.last! - quote.closes.first!))
                    .frame(height: side * 0.26)
                    .padding(.vertical, 3)
                    .help(lang.t(.dailyCloses, "\(quote.closes.count)"))
            } else {
                Spacer(minLength: 0)
            }
            Spacer(minLength: 0)
            Text(QuoteFormat.price(quote.price))
                .font(.system(size: 15, weight: .semibold).monospacedDigit())
                .contentTransition(.numericText())
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Text(QuoteFormat.percent(quote.changePercent))
                .font(.system(size: 10.5, weight: .semibold).monospacedDigit())
                .foregroundStyle(QuoteFormat.color(quote.change))
            CardFootnote(text: [QuoteFormat.asOf([quote], lang: lang).map { lang.t(.asOf, $0) },
                                QuoteFormat.shortProvider(quote.provider)].compactMap { $0 }.joined(separator: " · "))
                .padding(.top, 1)
        }
    }
}

/// Two or three tickers: iOS Stocks watchlist rows with change pills.
struct QuoteListView: View {
    var rows: [QuoteRow]
    var feed: FeedState<[QuoteRow]>
    @ObservedObject var lang: LanguageSettings

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                if index > 0 { Divider().overlay(.white.opacity(0.12)).padding(.vertical, 3) }
                HStack(spacing: 4) {
                    VStack(alignment: .leading, spacing: 0) {
                        Text(row.symbol)
                            .font(.system(size: 11, weight: .bold))
                            .lineLimit(1)
                            .minimumScaleFactor(0.65)
                        if let q = row.quote {
                            Text(QuoteFormat.price(q.price))
                                .font(.system(size: 9.5, weight: .medium).monospacedDigit())
                                .foregroundStyle(.white.opacity(0.6))
                                .lineLimit(1)
                                .minimumScaleFactor(0.7)
                        }
                    }
                    Spacer(minLength: 2)
                    if let q = row.quote {
                        Text(QuoteFormat.percent(q.changePercent))
                            .font(.system(size: 9.5, weight: .semibold).monospacedDigit())
                            .lineLimit(1)
                            .minimumScaleFactor(0.7)
                            .padding(.horizontal, 4)
                            .frame(minWidth: 46, minHeight: 17)
                            .background(RoundedRectangle(cornerRadius: 4, style: .continuous).fill(QuoteFormat.color(q.change)))
                    } else {
                        Text(lang.t(.unavailable))
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(.yellow)
                            .lineLimit(1)
                            .minimumScaleFactor(0.7)
                            .help(row.error.map { lang.t($0.messageKey) } ?? "")
                    }
                }
            }
            Spacer(minLength: 0)
            CardFootnote(text: [QuoteFormat.asOf(rows.compactMap(\.quote), lang: lang).map { lang.t(.asOf, $0) },
                                rows.compactMap(\.quote).first.map { QuoteFormat.shortProvider($0.provider) }].compactMap { $0 }.joined(separator: " · "))
        }
    }
}

/// Line + soft fill through real values only; draws in on appear.
struct Sparkline: View {
    var values: [Double]
    var color: Color
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var drawn = false

    var body: some View {
        GeometryReader { geo in
            let points = Self.points(values, in: geo.size)
            ZStack {
                Path { p in
                    guard let first = points.first, let last = points.last else { return }
                    p.move(to: CGPoint(x: first.x, y: geo.size.height))
                    points.forEach { p.addLine(to: $0) }
                    p.addLine(to: CGPoint(x: last.x, y: geo.size.height))
                    p.closeSubpath()
                }
                .fill(LinearGradient(colors: [color.opacity(0.35), color.opacity(0)], startPoint: .top, endPoint: .bottom))
                .opacity(drawn || reduceMotion ? 1 : 0)
                Path { p in
                    guard let first = points.first else { return }
                    p.move(to: first)
                    points.dropFirst().forEach { p.addLine(to: $0) }
                }
                .trim(from: 0, to: drawn || reduceMotion ? 1 : 0)
                .stroke(color, style: StrokeStyle(lineWidth: 1.6, lineCap: .round, lineJoin: .round))
            }
        }
        .onAppear {
            guard !reduceMotion else { return }
            withAnimation(.easeOut(duration: 0.8).delay(0.1)) { drawn = true }
        }
        .accessibilityHidden(true)
    }

    static func points(_ values: [Double], in size: CGSize) -> [CGPoint] {
        guard values.count >= 2, let lo = values.min(), let hi = values.max() else { return [] }
        let range = max(hi - lo, abs(hi) * 1e-6, 1e-9)
        let step = size.width / CGFloat(values.count - 1)
        return values.enumerated().map { i, v in
            CGPoint(x: CGFloat(i) * step, y: size.height * (1 - CGFloat((v - lo) / range)) * 0.92 + size.height * 0.04)
        }
    }
}

// MARK: - Stopwatch

/// iOS Clock style: light monospaced digits, grey Lap/Reset, green Start / red Stop.
struct StopwatchCard: View {
    @ObservedObject var lang: LanguageSettings
    @EnvironmentObject var stopwatch: Stopwatch
    @Environment(\.widgetSide) private var side

    var body: some View {
        WidgetCard {
            DarkCardBackground()
        } content: {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 4) {
                    Image(systemName: "stopwatch.fill").foregroundStyle(.orange)
                    Text(lang.t(.stopwatch)).lineLimit(1).minimumScaleFactor(0.8)
                }
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(.white.opacity(0.65))
                Spacer(minLength: 0)
                StopwatchReadout(stopwatch: stopwatch, size: side * 0.19, weight: .light, design: .default, activeTint: .white)
                Group {
                    if let last = stopwatch.laps.indices.last {
                        Text("\(lang.t(.lap)) \(last + 1)  \(Stopwatch.format(stopwatch.lapDuration(last), fraction: true))")
                    } else {
                        Text(verbatim: " ")
                    }
                }
                .font(.system(size: 9.5, weight: .medium).monospacedDigit())
                .foregroundStyle(.white.opacity(0.55))
                .lineLimit(1)
                Spacer(minLength: 0)
                HStack {
                    clockButton(symbol: stopwatch.phase == .running ? "flag.fill" : "arrow.counterclockwise",
                                fill: Color(white: 0.3), foreground: .white,
                                label: stopwatch.phase == .running ? lang.t(.lap) : lang.t(.reset)) {
                        stopwatch.phase == .running ? stopwatch.lap() : stopwatch.reset()
                    }
                    .disabled(stopwatch.phase == .idle)
                    .opacity(stopwatch.phase == .idle ? 0.45 : 1)
                    Spacer()
                    clockButton(symbol: stopwatch.phase == .running ? "pause.fill" : "play.fill",
                                fill: stopwatch.phase == .running ? Color(hex: 0x3A1513) : Color(hex: 0x0E2A13),
                                foreground: stopwatch.phase == .running ? Color(hex: 0xFF453A) : Color(hex: 0x30D158),
                                label: stopwatch.phase == .running ? lang.t(.pause) : (stopwatch.phase == .paused ? lang.t(.resume) : lang.t(.start))) {
                        stopwatch.toggle()
                    }
                }
            }
            .foregroundStyle(.white)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(lang.t(.stopwatch))
    }

    private func clockButton(symbol: String, fill: Color, foreground: Color, label: String,
                             action: @escaping () -> Void) -> some View {
        let size = side * 0.25
        return Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: size * 0.38, weight: .bold))
                .foregroundStyle(foreground)
                .frame(width: size, height: size)
                .background(Circle().fill(fill))
                // The double ring of the iOS Clock buttons.
                .overlay(Circle().strokeBorder(fill, lineWidth: 1).padding(-2.5))
                .contentTransition(.symbolEffect(.replace))
        }
        .buttonStyle(PressableStyle())
        .help(label)
        .accessibilityLabel(label)
        .animation(.snappy(duration: 0.2), value: stopwatch.phase)
    }
}

// MARK: - Timer (iOS Clock timer style)

/// Countdown widget: choose a duration and start it here. While it runs it is
/// also a live activity (compact indicators + Live Activities page).
struct TimerCard: View {
    @ObservedObject var lang: LanguageSettings
    @EnvironmentObject var timer: CountdownTimer
    @Environment(\.widgetSide) private var side

    static let presets = [5, 10, 25]

    var body: some View {
        WidgetCard {
            DarkCardBackground()
        } content: {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 4) {
                    Image(systemName: timer.phase == .finished ? "bell.fill" : "timer").foregroundStyle(.orange)
                    Text(lang.t(.timer)).lineLimit(1).minimumScaleFactor(0.8)
                    Spacer(minLength: 2)
                    if timer.isActive {
                        Text(lang.t(timer.phase == .running ? .running : (timer.phase == .paused ? .paused : .timesUp)))
                            .lineLimit(1).minimumScaleFactor(0.7)
                            .foregroundStyle(timer.phase == .finished ? .orange : .white.opacity(0.5))
                    }
                }
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(.white.opacity(0.65))
                Spacer(minLength: 0)
                Text(CountdownTimer.format(timer.isActive ? timer.remaining : timer.selectedDuration))
                    .font(.system(size: side * 0.2, weight: .light))
                    .monospacedDigit()
                    .foregroundStyle(timer.isActive ? Color.orange : .white)
                    .contentTransition(.numericText(countsDown: true))
                    .animation(.snappy(duration: 0.25), value: Int((timer.isActive ? timer.remaining : timer.selectedDuration).rounded(.up)))
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                if timer.isActive {
                    Capsule().fill(.white.opacity(0.12))
                        .overlay(alignment: .leading) {
                            GeometryReader { geo in
                                Capsule().fill(Color.orange).frame(width: geo.size.width * timer.progress)
                            }
                        }
                        .frame(height: 3)
                        .padding(.vertical, 3)
                } else {
                    HStack(spacing: 3) {
                        ForEach(Self.presets, id: \.self) { minutes in
                            let selected = Int(timer.selectedDuration) == minutes * 60
                            Button { timer.select(minutes: minutes) } label: {
                                Text("\(minutes)\(lang.t(.minuteShort))")
                                    .font(.system(size: 9.5, weight: .semibold))
                                    .lineLimit(1).minimumScaleFactor(0.7)
                                    .frame(maxWidth: .infinity, minHeight: 17)
                                    .background(Capsule().fill(selected ? Color.orange.opacity(0.35) : .white.opacity(0.12)))
                            }
                            .buttonStyle(PressableStyle())
                            .accessibilityLabel(lang.t(.timerMinutes, "\(minutes)"))
                        }
                    }
                    .padding(.top, 2)
                }
                Spacer(minLength: 0)
                HStack(spacing: 6) {
                    if timer.isActive {
                        circle(symbol: "xmark", fill: Color(white: 0.3), tint: .white, label: lang.t(.reset)) { timer.reset() }
                    } else {
                        circle(symbol: "minus", fill: Color(white: 0.3), tint: .white, label: lang.t(.timerLess)) { timer.adjust(minutes: -1) }
                        circle(symbol: "plus", fill: Color(white: 0.3), tint: .white, label: lang.t(.timerMore)) { timer.adjust(minutes: 1) }
                    }
                    Spacer(minLength: 0)
                    circle(symbol: timer.phase == .running ? "pause.fill" : "play.fill",
                           fill: timer.phase == .running ? Color(hex: 0x3A2A0E) : Color(hex: 0x0E2A13),
                           tint: timer.phase == .running ? .orange : Color(hex: 0x30D158),
                           label: timer.phase == .running ? lang.t(.pause) : (timer.phase == .paused ? lang.t(.resume) : lang.t(.start))) {
                        timer.toggle()
                    }
                }
            }
            .foregroundStyle(.white)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(lang.t(.timer))
    }

    private func circle(symbol: String, fill: Color, tint: Color, label: String, action: @escaping () -> Void) -> some View {
        let size = side * 0.22
        return Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: size * 0.4, weight: .bold))
                .foregroundStyle(tint)
                .frame(width: size, height: size)
                .background(Circle().fill(fill))
                .contentTransition(.symbolEffect(.replace))
        }
        .buttonStyle(PressableStyle())
        .help(label)
        .accessibilityLabel(label)
    }
}

// MARK: - Color helper

extension Color {
    init(hex: UInt32, opacity: Double = 1) {
        self.init(.sRGB,
                  red: Double((hex >> 16) & 0xFF) / 255,
                  green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255,
                  opacity: opacity)
    }
}
