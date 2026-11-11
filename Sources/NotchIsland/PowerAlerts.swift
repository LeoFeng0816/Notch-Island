import AppKit
import SwiftUI
import Combine

/// Charger and low-battery moments, decided from IOKit power-source readings.
///
/// Pure and clock-injected (unit-tested). Designed against jitter:
/// - "Connected" fires only on a real battery → AC transition (never for the
///   first reading at launch), at most once per `connectCooldown` (a loose
///   cable that flaps doesn't repeat the banner).
/// - Each low threshold fires once per discharge cycle and re-arms only after
///   the level is back `rearmMargin` points above it — 21 → 20 → 21 → 20 shows
///   one alert, and plugging in / unplugging at 19 % doesn't show it again.
/// - Several thresholds crossed at once (launch at 8 %) give one alert.
struct PowerEventDetector: Equatable {
    enum Event: Equatable {
        case connected(percent: Int, charging: Bool)
        case low(percent: Int, threshold: Int)
    }

    /// Like iPhone: 20 % and 10 %.
    static let lowThresholds = [20, 10]
    static let rearmMargin = 5
    static let connectCooldown: TimeInterval = 10

    private var lastOnAC: Bool?
    private var lastConnectedAt: Date?
    private var fired: Set<Int> = []

    mutating func observe(_ snapshot: BatterySnapshot?, at date: Date) -> [Event] {
        guard let snapshot else { return [] } // no battery or unreadable: nothing to say
        defer { lastOnAC = snapshot.onACPower }
        var events: [Event] = []
        fired = fired.filter { snapshot.percent < $0 + Self.rearmMargin }
        if lastOnAC == false, snapshot.onACPower,
           lastConnectedAt.map({ date.timeIntervalSince($0) >= Self.connectCooldown }) ?? true {
            lastConnectedAt = date
            events.append(.connected(percent: snapshot.percent, charging: snapshot.isCharging))
        }
        if !snapshot.onACPower {
            let crossed = Self.lowThresholds.filter { snapshot.percent <= $0 }
            if let lowest = crossed.min(), !fired.contains(lowest) {
                fired.formUnion(crossed)
                events.append(.low(percent: snapshot.percent, threshold: lowest))
            }
        }
        return events
    }
}

/// Banner below the notch (iPhone-style low-battery alert).
struct IslandBanner: Equatable {
    enum Kind: Equatable { case lowBattery(percent: Int) }
    var kind: Kind
}

/// Turns battery readings into island moments. Local only (IOKit), no
/// permission. Low Power Mode can't be switched by an app: macOS offers no
/// public API for it (`ProcessInfo.isLowPowerModeEnabled` is read-only and
/// `pmset lowpowermode` needs administrator rights), so the banner's button
/// opens System Settings › Battery and the user turns it on there.
@MainActor
final class PowerAlertController: ObservableObject {
    @Published private(set) var enabled: Bool
    static let enabledKey = "NotchIsland.power.alerts"

    private var detector = PowerEventDetector()
    private let defaults: UserDefaults
    private let now: () -> Date
    private weak var model: IslandViewModel?
    private let lang: LanguageSettings

    init(model: IslandViewModel?, lang: LanguageSettings? = nil, defaults: UserDefaults = .standard,
         now: @escaping () -> Date = Date.init) {
        self.model = model
        self.lang = lang ?? .shared
        self.defaults = defaults
        self.now = now
        enabled = defaults.object(forKey: Self.enabledKey) as? Bool ?? true
    }

    func setEnabled(_ on: Bool) {
        enabled = on
        defaults.set(on, forKey: Self.enabledKey)
        // Next reading is a fresh baseline: turning it on never fakes a "connected" moment.
        detector = PowerEventDetector()
        if !on { model?.dismissBanner() }
    }

    func handle(_ status: BatteryStatus) {
        guard enabled, case .available(let snapshot) = status else { return }
        for event in detector.observe(snapshot, at: now()) { present(event) }
    }

    private func present(_ event: PowerEventDetector.Event) {
        guard let model else { return }
        switch event {
        case .connected(let percent, let charging):
            if case .lowBattery = model.banner?.kind { model.dismissBanner() }
            model.showToast(.init(symbol: charging ? "bolt.fill" : "powerplug.fill",
                                  text: "\(percent)%", style: .success,
                                  accessibilityText: lang.t(charging ? .powerChargingToast : .powerConnectedToast, "\(percent)")),
                            duration: 2.6)
        case .low(let percent, _):
            model.showBanner(.init(kind: .lowBattery(percent: percent)))
        }
    }

    static func openBatterySettings() -> Bool { SystemSettingsLink.open(SystemSettingsLink.battery) }
}

/// iPhone-style low-battery card: red battery, remaining level, a Low Power
/// Mode button (opens Battery settings) and a close button.
struct PowerBannerView: View {
    var banner: IslandBanner
    @ObservedObject var model: IslandViewModel
    @ObservedObject var lang: LanguageSettings
    @EnvironmentObject var battery: BatteryMonitor

    var body: some View {
        switch banner.kind {
        case .lowBattery(let percent):
            HStack(spacing: 10) {
                Image(systemName: percent <= 10 ? "battery.0percent" : "battery.25percent")
                    .font(.system(size: 22, weight: .regular))
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(Color(hex: 0xFF453A), .white.opacity(0.35))
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 1) {
                    Text(lang.t(.lowBatteryTitle)).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                    Text(lang.t(.lowBatteryRemaining, "\(percent)"))
                        .font(.system(size: 10.5)).foregroundStyle(.white.opacity(0.65)).lineLimit(1).minimumScaleFactor(0.8)
                }
                .accessibilityElement(children: .combine)
                Spacer(minLength: 6)
                if battery.lowPowerMode {
                    Label(lang.t(.lowPowerModeOn), systemImage: "checkmark.circle.fill")
                        .font(.system(size: 10.5, weight: .semibold)).foregroundStyle(Color(hex: 0xFFD60A)).lineLimit(1)
                } else {
                    Button {
                        _ = PowerAlertController.openBatterySettings()
                        model.dismissBanner()
                    } label: {
                        Text(lang.t(.lowPowerModeButton))
                            .font(.system(size: 11, weight: .semibold)).lineLimit(1).minimumScaleFactor(0.8)
                            .foregroundStyle(.black)
                            .padding(.horizontal, 10).frame(height: 24)
                            .background(Capsule().fill(Color(hex: 0xFFD60A)))
                            .contentShape(Capsule())
                    }
                    .buttonStyle(PressableStyle())
                    .help(lang.t(.lowPowerModeHelp))
                    .accessibilityHint(lang.t(.lowPowerModeHelp))
                }
                Button { model.dismissBanner() } label: {
                    Image(systemName: "xmark").font(.system(size: 9, weight: .bold))
                        .frame(width: 20, height: 20).background(Circle().fill(.white.opacity(0.14)))
                        .contentShape(Circle())
                }
                .buttonStyle(PressableStyle())
                .help(lang.t(.close))
                .accessibilityLabel(lang.t(.close))
            }
            .padding(.horizontal, 16)
            .foregroundStyle(.white)
        }
    }
}
