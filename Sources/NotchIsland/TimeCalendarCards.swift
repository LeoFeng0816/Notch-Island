import SwiftUI
import AppKit

// MARK: - Calendar (iOS Calendar small widget style)

struct CalendarCard: View {
    @ObservedObject var lang: LanguageSettings
    @EnvironmentObject var calendar: CalendarStore
    @EnvironmentObject var settings: WidgetSettings
    @Environment(\.widgetSide) private var side

    var body: some View {
        WidgetCard(action: action, help: help) {
            DarkCardBackground()
        } content: {
            TimelineView(.everyMinute) { context in
                VStack(alignment: .leading, spacing: 0) {
                    Text(context.date.formatted(Date.FormatStyle().weekday(.wide).locale(lang.locale)).uppercased(with: lang.locale))
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(Color(hex: 0xFF453A))
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                    Text(context.date.formatted(Date.FormatStyle().day(.defaultDigits).locale(lang.locale)))
                        .font(.system(size: side * 0.22, weight: .regular))
                        .monospacedDigit()
                        .padding(.bottom, 2)
                    content(now: context.date)
                    Spacer(minLength: 0)
                }
            }
            .foregroundStyle(.white)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityText)
        .animation(.smooth(duration: 0.3), value: calendar.items)
    }

    @ViewBuilder private func content(now: Date) -> some View {
        switch calendar.access {
        case .granted:
            if calendar.items.isEmpty {
                Text(lang.t(settings.calendarDays == 1 ? .noEventsToday : .noUpcomingEvents))
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(.white.opacity(0.6))
                    .lineLimit(3)
                    .minimumScaleFactor(0.8)
            } else {
                let shown = Array(calendar.items.prefix(2))
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(shown) { item in EventRow(item: item, now: now, lang: lang) }
                    if calendar.items.count > shown.count {
                        Text(lang.t(.moreEvents, "\(calendar.items.count - shown.count)"))
                            .font(.system(size: 9, weight: .medium))
                            .foregroundStyle(.white.opacity(0.5))
                    }
                }
            }
        case .notDetermined:
            Label(lang.t(.calendarAllow), systemImage: "lock.open.fill")
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(.white.opacity(0.9))
                .lineLimit(3)
                .minimumScaleFactor(0.8)
        case .denied, .restricted, .writeOnly:
            VStack(alignment: .leading, spacing: 2) {
                Label(lang.t(.unavailable), systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.yellow)
                Text(lang.t(calendar.access == .writeOnly ? .calendarWriteOnly : .calendarDenied))
                    .font(.system(size: 9.5))
                    .foregroundStyle(.white.opacity(0.7))
                    .lineLimit(3)
                    .minimumScaleFactor(0.8)
            }
        }
    }

    private var action: (() -> Void)? {
        switch calendar.access {
        case .notDetermined: return { calendar.requestAccess() }
        case .denied, .writeOnly: return { calendar.openPrivacySettings() }
        default: return nil
        }
    }

    private var help: String {
        switch calendar.access {
        case .notDetermined: return lang.t(.calendarAllow)
        case .denied, .writeOnly: return lang.t(.openSettings)
        default: return lang.t(.calendarWidget)
        }
    }

    private var accessibilityText: String {
        var parts = [lang.t(.calendarWidget)]
        switch calendar.access {
        case .granted:
            if calendar.items.isEmpty { parts.append(lang.t(settings.calendarDays == 1 ? .noEventsToday : .noUpcomingEvents)) }
            for item in calendar.items.prefix(3) {
                parts.append(item.title.isEmpty ? lang.t(.untitledEvent) : item.title)
                parts.append(EventRow.timeText(item, now: Date(), lang: lang))
            }
        case .notDetermined: parts.append(lang.t(.calendarAllow))
        case .writeOnly: parts.append(lang.t(.calendarWriteOnly))
        case .denied, .restricted: parts.append(lang.t(.calendarDenied))
        }
        return parts.joined(separator: ", ")
    }
}

struct EventRow: View {
    var item: CalendarStore.Item
    var now: Date
    @ObservedObject var lang: LanguageSettings

    var body: some View {
        HStack(alignment: .top, spacing: 5) {
            RoundedRectangle(cornerRadius: 1.5)
                .fill(Color(.sRGB, red: item.color[safe: 0] ?? 1, green: item.color[safe: 1] ?? 0.3, blue: item.color[safe: 2] ?? 0.3))
                .frame(width: 3)
            VStack(alignment: .leading, spacing: 0) {
                Text(item.title.isEmpty ? lang.t(.untitledEvent) : item.title)
                    .font(.system(size: 10.5, weight: .semibold))
                    .lineLimit(1)
                Text(Self.timeText(item, now: now, lang: lang))
                    .font(.system(size: 9, weight: .medium).monospacedDigit())
                    .foregroundStyle(.white.opacity(0.6))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    /// Local-time label: "10:00 AM", "Tomorrow 9:30 AM", "Mon", "All day"…
    static func timeText(_ item: CalendarStore.Item, now: Date, lang: LanguageSettings) -> String {
        let calendar = Calendar.current
        let time = Date.FormatStyle(date: .omitted, time: .shortened).locale(lang.locale)
        var day: String?
        if !calendar.isDate(item.start, inSameDayAs: now) && item.start > now {
            let tomorrow = calendar.date(byAdding: .day, value: 1, to: now) ?? now
            day = calendar.isDate(item.start, inSameDayAs: tomorrow)
                ? lang.t(.tomorrow)
                : item.start.formatted(Date.FormatStyle().weekday(.abbreviated).locale(lang.locale))
        }
        if item.isAllDay { return [day, lang.t(.allDay)].compactMap { $0 }.joined(separator: " · ") }
        if item.start <= now { return lang.t(.nowUntil, item.end.formatted(time)) }
        return [day, item.start.formatted(time)].compactMap { $0 }.joined(separator: " ")
    }
}

extension Array {
    subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}

// MARK: - Clock (iOS Clock / World Clock style)

struct ClockCard: View {
    @ObservedObject var lang: LanguageSettings
    @EnvironmentObject var settings: WidgetSettings
    @Environment(\.widgetSide) private var side

    var body: some View {
        WidgetCard {
            DarkCardBackground()
        } content: {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                if settings.timeZones.isEmpty {
                    VStack(spacing: 3) {
                        AnalogClock(date: context.date, timeZone: .current, label: ClockText.city(TimeZone.current))
                            .frame(width: side * 0.66, height: side * 0.66)
                        Text(context.date.formatted(Date.FormatStyle(date: .omitted, time: .shortened).locale(lang.locale)))
                            .font(.system(size: 11, weight: .semibold).monospacedDigit())
                            .foregroundStyle(.white.opacity(0.75))
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    VStack(alignment: .leading, spacing: 5) {
                        ClockRow(timeZone: .current, isLocal: true, now: context.date, lang: lang)
                        ForEach(settings.timeZones, id: \.self) { id in
                            if let zone = TimeZone(identifier: id) {
                                Divider().overlay(.white.opacity(0.12))
                                ClockRow(timeZone: zone, isLocal: false, now: context.date, lang: lang)
                            }
                        }
                        Spacer(minLength: 0)
                    }
                }
            }
            .foregroundStyle(.white)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityText)
    }

    private var accessibilityText: String {
        let now = Date()
        var parts = [lang.t(.clockWidget)]
        for zone in [TimeZone.current] + settings.timeZones.compactMap(TimeZone.init(identifier:)) {
            parts.append("\(ClockText.city(zone)) \(ClockText.time(now, zone: zone, locale: lang.locale))")
        }
        return parts.joined(separator: ", ")
    }
}

enum ClockText {
    /// "America/New_York" → "New York".
    static func city(_ zone: TimeZone) -> String {
        (zone.identifier.split(separator: "/").last.map(String.init) ?? zone.identifier).replacingOccurrences(of: "_", with: " ")
    }

    static func time(_ date: Date, zone: TimeZone, locale: Locale) -> String {
        var style = Date.FormatStyle(date: .omitted, time: .shortened).locale(locale)
        style.timeZone = zone
        return date.formatted(style)
    }

    /// Hours relative to local time, e.g. "+1", "-13", "+5.5"; nil when equal.
    static func offset(_ zone: TimeZone, at date: Date, local: TimeZone = .current) -> String? {
        let seconds = zone.secondsFromGMT(for: date) - local.secondsFromGMT(for: date)
        guard seconds != 0 else { return nil }
        let hours = Double(seconds) / 3600
        let text = hours == hours.rounded() ? String(Int(hours)) : String(format: "%.1f", hours)
        return hours > 0 ? "+" + text : text
    }

    /// -1 yesterday, 0 today, 1 tomorrow (calendar day in `zone` vs local).
    static func dayDelta(_ zone: TimeZone, at date: Date, local: TimeZone = .current) -> Int {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        let there = calendar.dateComponents([.year, .month, .day], from: date)
        calendar.timeZone = local
        let here = calendar.dateComponents([.year, .month, .day], from: date)
        guard let a = calendar.date(from: there), let b = calendar.date(from: here) else { return 0 }
        return calendar.dateComponents([.day], from: b, to: a).day ?? 0
    }
}

struct ClockRow: View {
    var timeZone: TimeZone
    var isLocal: Bool
    var now: Date
    @ObservedObject var lang: LanguageSettings

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 4) {
            VStack(alignment: .leading, spacing: 0) {
                Text(ClockText.city(timeZone))
                    .font(.system(size: 10.5, weight: .semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                Text(subtitle)
                    .font(.system(size: 8.5, weight: .medium))
                    .foregroundStyle(.white.opacity(0.55))
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
            Spacer(minLength: 2)
            Text(ClockText.time(now, zone: timeZone, locale: lang.locale))
                .font(.system(size: 14, weight: .light).monospacedDigit())
                .lineLimit(1)
                .minimumScaleFactor(0.6)
        }
    }

    private var subtitle: String {
        if isLocal { return lang.t(.localTime) }
        let day: String
        switch ClockText.dayDelta(timeZone, at: now) {
        case 1: day = lang.t(.tomorrow)
        case -1: day = lang.t(.yesterday)
        default: day = lang.t(.today)
        }
        guard let offset = ClockText.offset(timeZone, at: now) else { return day }
        return day + " " + lang.t(.hoursOffset, offset)
    }
}

/// Dark analog face with an orange second hand, like the iOS Clock widget.
struct AnalogClock: View {
    var date: Date
    var timeZone: TimeZone
    var label: String

    var body: some View {
        GeometryReader { geo in
            let size = min(geo.size.width, geo.size.height)
            let parts = Self.angles(date, timeZone: timeZone)
            ZStack {
                Circle().fill(Color(hex: 0x111113))
                Circle().strokeBorder(.white.opacity(0.12), lineWidth: 1)
                ForEach(0..<60, id: \.self) { tick in
                    let major = tick % 5 == 0
                    Capsule()
                        .fill(.white.opacity(major ? 0.9 : 0.3))
                        .frame(width: major ? 1.6 : 0.8, height: major ? size * 0.07 : size * 0.035)
                        .offset(y: -size * 0.43)
                        .rotationEffect(.degrees(Double(tick) * 6))
                }
                Text(label)
                    .font(.system(size: size * 0.09, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.55))
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                    .frame(width: size * 0.5)
                    .offset(y: size * 0.2)
                hand(width: size * 0.045, length: size * 0.26, angle: parts.hour, color: .white)
                hand(width: size * 0.035, length: size * 0.38, angle: parts.minute, color: .white)
                hand(width: size * 0.015, length: size * 0.42, angle: parts.second, color: .orange)
                Circle().fill(.orange).frame(width: size * 0.06, height: size * 0.06)
                Circle().fill(Color(hex: 0x111113)).frame(width: size * 0.025, height: size * 0.025)
            }
            .frame(width: size, height: size)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .accessibilityHidden(true)
    }

    private func hand(width: CGFloat, length: CGFloat, angle: Double, color: Color) -> some View {
        Capsule()
            .fill(color)
            .frame(width: width, height: length)
            .offset(y: -length / 2)
            .rotationEffect(.degrees(angle))
    }

    /// Hand angles in degrees (0 = 12 o'clock) for `date` in `timeZone`.
    static func angles(_ date: Date, timeZone: TimeZone) -> (hour: Double, minute: Double, second: Double) {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let c = calendar.dateComponents([.hour, .minute, .second], from: date)
        let h = Double((c.hour ?? 0) % 12), m = Double(c.minute ?? 0), s = Double(c.second ?? 0)
        return ((h + m / 60) * 30, (m + s / 60) * 6, s * 6)
    }
}
