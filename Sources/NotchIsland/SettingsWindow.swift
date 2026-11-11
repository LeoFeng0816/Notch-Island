import AppKit
import SwiftUI
import Combine

/// Regular window for configuration (text entry doesn't belong in the
/// non-activating island panel).
@MainActor
final class SettingsWindowController: NSObject, NSWindowDelegate {
    private var window: NSWindow?
    private let makeView: () -> AnyView
    private let lang: LanguageSettings
    private var cancellable: AnyCancellable?

    init(lang: LanguageSettings, makeView: @escaping () -> AnyView) {
        self.lang = lang
        self.makeView = makeView
    }

    func show() {
        if window == nil {
            let hosting = NSHostingController(rootView: makeView())
            let window = NSWindow(contentViewController: hosting)
            window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
            window.setContentSize(NSSize(width: 520, height: 640))
            window.minSize = NSSize(width: 460, height: 420)
            window.isReleasedWhenClosed = false
            window.delegate = self
            window.center()
            self.window = window
            // Window title follows the in-app language.
            cancellable = lang.$language.sink { [weak self] _ in
                DispatchQueue.main.async { MainActor.assumeIsolated { self?.window?.title = self?.lang.t(.settingsTitle) ?? "" } }
            }
        }
        window?.title = lang.t(.settingsTitle)
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    var isVisible: Bool { window?.isVisible ?? false }
}

struct SettingsView: View {
    @ObservedObject var lang: LanguageSettings
    @ObservedObject var settings: WidgetSettings
    @ObservedObject var model: IslandViewModel
    @ObservedObject var music: MusicController
    @ObservedObject var calendar: CalendarStore
    @ObservedObject var location: LocationProvider
    @ObservedObject var audioMonitor: AudioLevelMonitor
    @ObservedObject var stockSearch: StockSearchModel
    @ObservedObject var clipboard: ClipboardStore
    @ObservedObject var power: PowerAlertController
    @ObservedObject var audDRecognition: AudDRecognition
    /// Shared with the island (controller); asks Location Services once.
    var useCurrentLocation: () -> Void
    let device: DeviceInfo
    let weatherProvider: OpenMeteoProvider
    var redetect: () -> Void

    /// Widget the user tried to turn on while four were already shown.
    @State private var limitAlertKind: WidgetKind?
    @AppStorage(MusicRecognitionMode.defaultsKey) private var recognitionMode = MusicRecognitionMode.system.rawValue

    var body: some View {
        Form {
            generalSection
            widgetsSection
            weatherSection
            stocksSection
            calendarSection
            clockSection
            clipboardSection
            recognitionSection
            MediaSettingsSection(lang: lang, music: music, audioMonitor: audioMonitor)
            deviceSection
        }
        .formStyle(.grouped)
        .alert(lang.t(.widgetLimitTitle, "\(WidgetSettings.maxEnabled)"),
               isPresented: Binding(get: { limitAlertKind != nil }, set: { if !$0 { limitAlertKind = nil } })) {
            Button(lang.t(.ok), role: .cancel) { limitAlertKind = nil }
        } message: {
            Text(WidgetSettings.limitMessage(trying: limitAlertKind, enabled: settings.enabledInOrder, lang: lang))
        }
        .frame(minWidth: 440)
    }

    // MARK: General

    private var recognitionSection: some View {
        Section {
            Picker(lang.t(.recognitionSettings), selection: Binding(
                get: { MusicRecognitionMode.resolve(recognitionMode).rawValue },
                set: { newValue in
                    // Leaving AudD stops anything in flight; nothing more is captured or sent.
                    if MusicRecognitionMode.resolve(newValue) != .audd { audDRecognition.cancel() }
                    recognitionMode = newValue
                }
            )) {
                Text(lang.t(.recognitionSystem)).tag(MusicRecognitionMode.system.rawValue)
                Text(lang.t(.recognitionThirdParty)).tag(MusicRecognitionMode.audd.rawValue)
            }
            if MusicRecognitionMode.resolve(recognitionMode) == .audd {
                Button(lang.t(.audDSetup)) {
                    Task { await AudDSetup.present(lang: lang, recognition: audDRecognition) }
                }
                .disabled(audDRecognition.phase.busy || audDRecognition.isSettingUp)
            }
        } header: {
            Text(lang.t(.recognitionSettings))
        } footer: {
            Text(lang.t(.recognitionSettingsHelp)).font(.caption).foregroundStyle(.secondary)
        }
    }

    private var generalSection: some View {
        Section {
            Picker(lang.t(.language), selection: $lang.language) {
                ForEach(AppLanguage.allCases) { option in
                    Text(lang.displayName(option)).tag(option)
                }
            }
            Toggle(lang.t(.powerAlertsToggle), isOn: Binding(get: { power.enabled }, set: { power.setEnabled($0) }))
        } header: {
            Text(lang.t(.general))
        } footer: {
            Text(lang.t(.powerAlertsNote)).font(.caption).foregroundStyle(.secondary)
        }
    }

    // MARK: Widgets

    private var widgetsSection: some View {
        Section {
            List {
                ForEach(settings.order) { kind in
                    WidgetOrderRow(kind: kind, lang: lang, settings: settings, onEnabled: { enabled in
                        // Turning Weather on without a city: ask for the approximate location
                        // right away (user action); the city search stays as a fallback.
                        if enabled == .weather && settings.place == nil { useCurrentLocation() }
                    }, onLimit: { refused in limitAlertKind = refused })
                }
                .onMove { settings.move(fromOffsets: $0, toOffset: $1) }
            }
            .frame(height: CGFloat(settings.order.count) * 34 + 8)
        } header: {
            Text(lang.t(.widgetsSection))
        } footer: {
            VStack(alignment: .leading, spacing: 2) {
                Text(lang.t(.widgetsHint))
                Text(lang.t(.widgetLimit, "\(WidgetSettings.maxEnabled)"))
            }
            .font(.caption).foregroundStyle(.secondary)
        }
    }

    // MARK: Weather

    @State private var cityQuery = ""
    @State private var searchResults: [Place] = []
    @State private var searchError: ProviderError?
    @State private var isSearching = false

    private var weatherSection: some View {
        Section {
            HStack {
                TextField(lang.t(.city), text: $cityQuery)
                    .onSubmit(search)
                Button(isSearching ? lang.t(.searching) : lang.t(.search), action: search)
                    .disabled(isSearching || cityQuery.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            if let searchError {
                Label(lang.t(searchError.messageKey), systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
            }
            ForEach(searchResults) { place in
                Button {
                    settings.place = place
                    searchResults = []
                    cityQuery = ""
                } label: {
                    HStack {
                        VStack(alignment: .leading) {
                            Text(place.name)
                            if !place.subtitle.isEmpty {
                                Text(place.subtitle).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        Spacer()
                        Text(String(format: "%.2f, %.2f", place.latitude, place.longitude))
                            .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            HStack {
                if let place = settings.place {
                    Text(place.fromLocationServices
                         ? lang.t(.selectedCity, lang.t(.currentLocation))
                         : lang.t(.selectedCity, [place.name, place.subtitle].filter { !$0.isEmpty }.joined(separator: ", ")))
                    Spacer()
                    Button(lang.t(.clear)) { settings.place = nil }
                } else {
                    Text(lang.t(.noCitySelected)).foregroundStyle(.secondary)
                }
            }
            HStack {
                Button {
                    useCurrentLocation()
                } label: {
                    Label(location.isLocating ? lang.t(.locating) : (settings.place?.fromLocationServices == true ? lang.t(.updateLocation) : lang.t(.useCurrentLocation)),
                          systemImage: "location.fill")
                }
                .disabled(location.isLocating)
                if let failure = location.lastFailure {
                    Spacer()
                    if failure.opensSettings {
                        Button(lang.t(.openSettings)) { location.openLocationSettings() }
                    }
                }
            }
            if let failure = location.lastFailure {
                Label(lang.t(failure.messageKey), systemImage: "exclamationmark.triangle.fill")
                    .font(.caption).foregroundStyle(.orange)
            }
            Picker(lang.t(.temperatureUnit), selection: $settings.unit) {
                Text(lang.t(.celsius)).tag(TemperatureUnit.celsius)
                Text(lang.t(.fahrenheit)).tag(TemperatureUnit.fahrenheit)
            }
        } header: {
            Text(lang.t(.weatherSection))
        } footer: {
            VStack(alignment: .leading, spacing: 4) {
                Text(lang.t(.weatherPrivacy))
                Text(lang.t(.locationPrivacy))
                Link(lang.t(.weatherAttribution), destination: URL(string: "https://open-meteo.com/")!)
            }
            .font(.caption).foregroundStyle(.secondary)
        }
    }

    private func search() {
        let query = cityQuery
        guard !query.trimmingCharacters(in: .whitespaces).isEmpty, !isSearching else { return }
        isSearching = true
        searchError = nil
        Task {
            do {
                searchResults = try await weatherProvider.searchPlaces(query, language: lang.providerLanguage)
            } catch {
                searchResults = []
                searchError = ProviderError(error)
            }
            isSearching = false
        }
    }

    // MARK: Stocks

    @State private var tickerError: WidgetSettings.SymbolError?
    @State private var keyInput = ""

    private var stocksSection: some View {
        Section {
            Picker(lang.t(.stockSource), selection: $settings.stockProvider) {
                Text(lang.t(.yahooOption)).tag(StockProviderKind.yahoo)
                Text(lang.t(.alphaVantageOption)).tag(StockProviderKind.alphaVantage)
            }
            // Search by company name or ticker; pick the listing (exchange) to add.
            TextField(lang.t(.stockSearchPlaceholder), text: Binding(get: { stockSearch.query },
                                                                     set: { stockSearch.update(query: $0) }))
                .onSubmit { addTyped() }
            stockSearchResults
            if let tickerError {
                Text(lang.t(tickerError == .invalid ? .tickerInvalid : (tickerError == .duplicate ? .tickerDuplicate : .tickerLimit)))
                    .font(.caption).foregroundStyle(.orange)
            }
            ForEach(settings.symbols, id: \.self) { symbol in
                HStack {
                    Text(symbol).font(.body.monospaced())
                    Spacer()
                    Button(role: .destructive) { settings.removeSymbol(symbol) } label: {
                        Image(systemName: "minus.circle.fill")
                    }
                    .buttonStyle(.borderless)
                    .help(lang.t(.remove))
                }
            }
            if settings.stockProvider == .alphaVantage {
            HStack {
                SecureField(lang.t(.apiKey), text: $keyInput)
                Button(lang.t(.save)) {
                    settings.setStockAPIKey(keyInput)
                    keyInput = ""
                }
                .disabled(keyInput.trimmingCharacters(in: .whitespaces).isEmpty)
                if settings.hasStockAPIKey {
                    Button(lang.t(.remove), role: .destructive) { settings.setStockAPIKey(nil) }
                }
            }
            HStack {
                Label(settings.hasStockAPIKey ? lang.t(.apiKeySaved) : lang.t(.apiKeyMissing),
                      systemImage: settings.hasStockAPIKey ? "key.fill" : "key")
                    .foregroundStyle(settings.hasStockAPIKey ? Color.green : .secondary)
                Spacer()
                Link(lang.t(.getFreeKey), destination: URL(string: "https://www.alphavantage.co/support/#api-key")!)
            }
            .font(.callout)
            }
        } header: {
            Text(lang.t(.stocksSection))
        } footer: {
            Text(lang.t(settings.stockProvider == .yahoo ? .yahooNote : .stocksNote)).font(.caption).foregroundStyle(.secondary)
        }
    }

    // MARK: Calendar

    private var calendarSection: some View {
        Section {
            HStack {
                Label(calendarStatusText, systemImage: calendar.access == .granted ? "checkmark.circle.fill" : "calendar.badge.exclamationmark")
                    .foregroundStyle(calendar.access == .granted ? Color.green : .secondary)
                Spacer()
                switch calendar.access {
                case .notDetermined:
                    Button(lang.t(.calendarAllow)) { calendar.requestAccess() }
                        .disabled(calendar.isRequesting)
                case .denied, .writeOnly, .restricted:
                    Button(lang.t(.openSettings)) { calendar.openPrivacySettings() }
                        .disabled(calendar.access == .restricted)
                case .granted:
                    EmptyView()
                }
            }
            Picker(lang.t(.calendarRange), selection: $settings.calendarDays) {
                Text(lang.t(.rangeToday)).tag(1)
                Text(lang.t(.rangeDays, "3")).tag(3)
                Text(lang.t(.rangeDays, "7")).tag(7)
            }
            Toggle(lang.t(.showAllDay), isOn: $settings.calendarShowsAllDay)
        } header: {
            Text(lang.t(.calendarWidget))
        } footer: {
            Text(lang.t(.calendarPrivacy)).font(.caption).foregroundStyle(.secondary)
        }
    }

    private var calendarStatusText: String {
        switch calendar.access {
        case .granted: return lang.t(.calendarGranted)
        case .notDetermined: return lang.t(.calendarNotAsked)
        case .writeOnly: return lang.t(.calendarWriteOnly)
        case .denied, .restricted: return lang.t(.calendarDenied)
        }
    }

    // MARK: Clock

    @State private var zoneQuery = ""

    private var clockSection: some View {
        Section {
            ForEach(settings.timeZones, id: \.self) { id in
                HStack {
                    Text(TimeZone(identifier: id).map(ClockText.city) ?? id)
                    Text(id).font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button(role: .destructive) { settings.removeTimeZone(id) } label: { Image(systemName: "minus.circle.fill") }
                        .buttonStyle(.borderless)
                        .help(lang.t(.remove))
                }
            }
            if settings.timeZones.count < WidgetSettings.maxExtraTimeZones {
                TextField(lang.t(.searchTimeZone), text: $zoneQuery)
                ForEach(Self.matchingZones(zoneQuery, excluding: settings.timeZones), id: \.self) { id in
                    Button {
                        settings.addTimeZone(id)
                        zoneQuery = ""
                    } label: {
                        HStack {
                            Text(id.replacingOccurrences(of: "_", with: " "))
                            Spacer()
                            Image(systemName: "plus.circle")
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        } header: {
            Text(lang.t(.clockWidget))
        } footer: {
            Text(lang.t(.clockHint, "\(WidgetSettings.maxExtraTimeZones)")).font(.caption).foregroundStyle(.secondary)
        }
    }

    static func matchingZones(_ query: String, excluding: [String]) -> [String] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased().replacingOccurrences(of: " ", with: "_")
        guard q.count >= 2 else { return [] }
        return TimeZone.knownTimeZoneIdentifiers
            .filter { $0.lowercased().contains(q) && !excluding.contains($0) && $0 != TimeZone.current.identifier }
            .prefix(6).map { $0 }
    }

    // MARK: Clipboard

    private var clipboardSection: some View {
        Section {
            Toggle(lang.t(.clipboardHistoryToggle), isOn: Binding(get: { clipboard.enabled }, set: { clipboard.setEnabled($0) }))
            Picker(lang.t(.clipboardRetention), selection: Binding(get: { clipboard.retention }, set: { clipboard.setRetention($0) })) {
                Text(lang.t(.retention1)).tag(ClipboardRetention.oneDay)
                Text(lang.t(.retention3)).tag(ClipboardRetention.threeDays)
                Text(lang.t(.retention7)).tag(ClipboardRetention.sevenDays)
                Text(lang.t(.retention30)).tag(ClipboardRetention.thirtyDays)
            }
            HStack {
                Text(lang.t(.clipboardCount, "\(clipboard.items.count)")).foregroundStyle(.secondary)
                Spacer()
                Button(lang.t(.clipboardClear), role: .destructive) { clipboard.clear() }.disabled(clipboard.items.isEmpty)
            }
            ClipboardPermissionRows(lang: lang, historyEnabled: clipboard.enabled)
        } header: {
            Text(lang.t(.qaClipboard))
        } footer: {
            Text(lang.t(.clipboardPrivacy)).font(.caption).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private var stockSearchResults: some View {
        switch stockSearch.phase {
        case .idle:
            EmptyView()
        case .searching:
            HStack(spacing: 6) { ProgressView().controlSize(.small); Text(lang.t(.searching)).font(.caption).foregroundStyle(.secondary) }
        case .empty:
            Text(lang.t(.stockSearchEmpty)).font(.caption).foregroundStyle(.secondary)
        case .failed(let error):
            Label(lang.t(error.messageKey), systemImage: "exclamationmark.triangle.fill").font(.caption).foregroundStyle(.orange)
        case .results:
            if stockSearch.exchanges.count > 1 {
                Picker(lang.t(.exchange), selection: $stockSearch.exchangeFilter) {
                    Text(lang.t(.allExchanges)).tag(String?.none)
                    ForEach(stockSearch.exchanges, id: \.self) { Text($0).tag(String?.some($0)) }
                }
            }
            ForEach(stockSearch.filtered) { match in
                Button { add(match.symbol) } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(match.symbol).font(.body.monospaced())
                            Text(match.name).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                        Spacer()
                        Text([match.exchangeName, match.type].filter { !$0.isEmpty }.joined(separator: " · "))
                            .font(.caption).foregroundStyle(.secondary)
                        Image(systemName: settings.symbols.contains(match.symbol) ? "checkmark.circle.fill" : "plus.circle")
                            .foregroundStyle(settings.symbols.contains(match.symbol) ? Color.green : .accentColor)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(settings.symbols.contains(match.symbol))
                .accessibilityLabel("\(match.symbol), \(match.name), \(match.exchangeName)")
            }
        }
        // Exact ticker typed (e.g. 2330.TW): can be added directly.
        if let typed = WidgetSettings.normalizeSymbol(stockSearch.query), !stockSearch.results.contains(where: { $0.symbol == typed }),
           !settings.symbols.contains(typed) {
            Button(lang.t(.addTypedTicker, typed)) { add(typed) }
        }
    }

    private func add(_ symbol: String) {
        switch settings.addSymbol(symbol) {
        case .success:
            tickerError = nil
            stockSearch.clear()
        case .failure(let error):
            tickerError = error
        }
    }

    private func addTyped() {
        if let first = stockSearch.filtered.first { add(first.symbol) }
        else if let typed = WidgetSettings.normalizeSymbol(stockSearch.query) { add(typed) }
    }


    // MARK: Device

    private var deviceSection: some View {
        Section {
            LabeledContent(lang.t(.modelIdentifier), value: device.modelIdentifier)
            LabeledContent(lang.t(.firstSeen), value: device.firstLaunch.formatted(Date.FormatStyle(date: .abbreviated, time: .shortened).locale(lang.locale)))
            let g = model.geometry
            LabeledContent(lang.t(.display), value: "\(g.screenName.isEmpty ? "—" : g.screenName) (\(lang.t(g.isBuiltIn ? .builtIn : .external)))")
            LabeledContent(lang.t(.notch)) {
                HStack {
                    Text(g.hasNotch
                         ? lang.t(.notchDetected) + " · " + lang.t(.notchSize, String(format: "%.0f", g.notchSize.width), String(format: "%.0f", g.notchSize.height))
                         : lang.t(.virtualNotch))
                    Button(lang.t(.redetect), action: redetect)
                }
            }
        } header: {
            Text(lang.t(.deviceSection))
        } footer: {
            Text(lang.t(.deviceNote)).font(.caption).foregroundStyle(.secondary)
        }
    }
}

struct WidgetOrderRow: View {
    var kind: WidgetKind
    @ObservedObject var lang: LanguageSettings
    @ObservedObject var settings: WidgetSettings
    var onEnabled: (WidgetKind) -> Void = { _ in }
    /// Called when turning this widget on was refused because the limit is reached.
    var onLimit: (WidgetKind) -> Void = { _ in }

    var body: some View {
        let index = settings.order.firstIndex(of: kind) ?? 0
        HStack(spacing: 8) {
            Image(systemName: "line.3.horizontal").foregroundStyle(.tertiary)
            Image(systemName: kind.symbol).frame(width: 20)
            Toggle(isOn: Binding(get: { settings.isEnabled(kind) },
                                 set: { on in
                                     if settings.setEnabled(kind, on) {
                                         if on { onEnabled(kind) }
                                     } else {
                                         onLimit(kind) // explain instead of silently refusing
                                     }
                                 })) {
                HStack(spacing: 6) {
                    Text(lang.t(kind.titleKey))
                    if kind.needsPermission {
                        Text(lang.t(.needsPermission))
                            .font(.caption2)
                            .padding(.horizontal, 5).padding(.vertical, 1)
                            .background(Capsule().fill(Color.secondary.opacity(0.15)))
                            .foregroundStyle(.secondary)
                    }
                    if kind.usesNetwork {
                        Text(lang.t(.usesNetwork))
                            .font(.caption2)
                            .padding(.horizontal, 5).padding(.vertical, 1)
                            .background(Capsule().fill(Color.secondary.opacity(0.15)))
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .toggleStyle(.switch)
            .controlSize(.small)
            .accessibilityHint(!settings.isEnabled(kind) && !settings.canEnableMore
                               ? lang.t(.widgetLimitTitle, "\(WidgetSettings.maxEnabled)") : "")
            Button { settings.move(kind, by: -1) } label: { Image(systemName: "chevron.up") }
                .buttonStyle(.borderless)
                .disabled(index == 0)
                .help(lang.t(.moveUp))
            Button { settings.move(kind, by: 1) } label: { Image(systemName: "chevron.down") }
                .buttonStyle(.borderless)
                .disabled(index == settings.order.count - 1)
                .help(lang.t(.moveDown))
        }
        .frame(height: 26)
    }
}

/// Permission rows for clipboard history and automatic paste. Both buttons
/// always do something visible: "Allow…" asks macOS the first time and opens
/// System Settings after that; "Open Settings" opens the exact pane. Status is
/// re-checked when the app becomes active and while Settings is open.
struct ClipboardPermissionRows: View {
    @ObservedObject var lang: LanguageSettings
    var historyEnabled: Bool
    @StateObject private var postEvents = PostEventAccess()
    @State private var pasteboard = PasteboardAccess.current()

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top) {
                Text(lang.t(postEvents.granted ? .pasteAllowed : .pasteNeedsPermission)).font(.caption)
                    .foregroundStyle(postEvents.granted ? Color.green : .secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer()
                if !postEvents.granted {
                    Button(lang.t(.permAllow)) { postEvents.request() }
                    Button(lang.t(.openSettings)) { postEvents.showSettings() }
                }
            }
            if !postEvents.granted, let note = feedbackText {
                Text(note).font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
            }
            if historyEnabled, let text = pasteboardText {
                HStack(alignment: .top) {
                    Text(text).font(.caption)
                        .foregroundStyle(pasteboard == .denied ? Color.orange : (pasteboard.needsAttention ? .secondary : .green))
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer()
                    if pasteboard.needsAttention {
                        Button(lang.t(.openSettings)) { SystemSettingsLink.open(.pasteboard) }
                    }
                }
            }
        }
        .onAppear { refresh() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in refresh() }
        .onReceive(Timer.publish(every: 2, on: .main, in: .common).autoconnect()) { _ in refresh() }
    }

    private func refresh() {
        postEvents.refresh()
        let now = PasteboardAccess.current()
        if now != pasteboard { pasteboard = now }
    }

    private var feedbackText: String? {
        if postEvents.grantLooksStale { return lang.t(.mediaKeysStaleGrant) }
        switch postEvents.feedback {
        case .none: return nil
        case .prompted: return lang.t(.permPromptedHint)
        case .openedSettings: return lang.t(.permOpenedSettingsHint)
        case .couldNotOpen: return lang.t(.permCouldNotOpen)
        }
    }

    private var pasteboardText: String? {
        switch pasteboard {
        case .unrestricted: return nil
        case .notAskedYet, .asks: return lang.t(.pasteboardAsks)
        case .allowed: return lang.t(.pasteboardAllowed)
        case .denied: return lang.t(.pasteboardDenied)
        }
    }
}

/// Browser media opt-in, permission status and setup instructions.
struct MediaSettingsSection: View {
    @ObservedObject var lang: LanguageSettings
    @ObservedObject var music: MusicController
    @ObservedObject var audioMonitor: AudioLevelMonitor
    @State private var permissions: [BrowserMedia.Browser: BrowserMedia.Permission] = [:]

    var body: some View {
        Section {
            controlCenterSettings
            // Real audio levels (Core Audio process tap; opt-in, System Audio Recording permission).
            VStack(alignment: .leading, spacing: 4) {
                Toggle(lang.t(.audioLevelsToggle), isOn: Binding(get: { audioMonitor.enabled },
                                                                 set: { audioMonitor.setEnabled($0, mediaPlaying: music.isPlaying) }))
                    .toggleStyle(.switch)
                    .disabled(!AudioLevelMonitor.isSupported)
                HStack {
                    Text(lang.t(audioStatusKey)).font(.caption)
                        .foregroundStyle(audioMonitor.state == .running ? Color.green : (audioMonitor.state == .silent || audioMonitor.state == .failed ? .orange : .secondary))
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer()
                    if audioMonitor.state == .silent || audioMonitor.state == .failed {
                        Button(lang.t(.openSettings)) { audioMonitor.openPrivacySettings() }
                    }
                }
                Text(lang.t(.audioLevelsNote)).font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            // 1) System-wide Now Playing (private MediaRemote; only if macOS shares it).
            VStack(alignment: .leading, spacing: 4) {
                Toggle(lang.t(.systemNowPlaying), isOn: Binding(get: { music.useSystemNowPlaying },
                                                                set: { music.setUseSystemNowPlaying($0) }))
                    .toggleStyle(.switch)
                Text(systemStatus).font(.caption).foregroundStyle(music.systemNowPlayingWorks ? Color.green : .secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            // 2) Control whatever is playing via system media keys (opt-in permission).
            VStack(alignment: .leading, spacing: 4) {
                Toggle(lang.t(.mediaKeysToggle), isOn: Binding(get: { music.useMediaKeys },
                                                               set: { music.setUseMediaKeys($0) }))
                    .toggleStyle(.switch)
                if music.useMediaKeys {
                    HStack {
                        Text(lang.t(music.mediaKeyAccess ? .mediaKeysGranted : (music.mediaKeyGrantStale ? .mediaKeysStaleGrant : .mediaKeysNeedAccess)))
                            .font(.caption).foregroundStyle(music.mediaKeyAccess ? Color.green : .orange)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer()
                        if !music.mediaKeyAccess {
                            Button(lang.t(.openSettings)) { SystemMedia.openAccessibilitySettings() }
                        }
                    }
                }
                Text(lang.t(.mediaKeysNote)).font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .onAppear { music.recheckMediaKeyAccess() }
            ForEach(BrowserMedia.Browser.allCases) { browser in
                VStack(alignment: .leading, spacing: 4) {
                    Toggle(isOn: Binding(get: { music.enabledBrowsers.contains(browser) },
                                         set: { music.setBrowser(browser, enabled: $0); check(browser) })) {
                        Text(lang.t(browser == .chrome ? .chromeMedia : .safariMedia))
                    }
                    .toggleStyle(.switch)
                    .disabled(!browser.isInstalled)
                    if music.enabledBrowsers.contains(browser) {
                        HStack {
                            Text(statusText(browser)).font(.caption).foregroundStyle(statusColor(browser))
                            Spacer()
                            if permissions[browser] == .notDetermined || music.browserIssues[browser] == .needsAutomation {
                                Button(lang.t(.allowAutomation)) {
                                    music.requestAutomation(for: browser) { permissions[browser] = $0; music.refresh() }
                                }
                            } else if permissions[browser] == .denied || music.browserIssues[browser] == .automationDenied {
                                Button(lang.t(.openSettings)) { music.openAutomationSettings() }
                            }
                        }
                        if let d = music.browserDiagnostics[browser] {
                            Text(diagnosticsText(d))
                                .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                                .textSelection(.enabled)
                        }
                        Text(lang.t(browser == .chrome ? .chromeJSHelp : .safariJSHelp))
                            .font(.caption).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .onAppear { check(browser) }
            }
        } header: {
            Text(lang.t(.mediaSection))
        } footer: {
            Text(lang.t(.mediaPrivacy)).font(.caption).foregroundStyle(.secondary)
        }
    }

    private var controlCenterSettings: some View {
        VStack(alignment: .leading, spacing: 4) {
            Toggle(lang.t(.controlCenterToggle), isOn: Binding(get: { music.useControlCenter },
                                                               set: { music.setUseControlCenter($0) }))
                .toggleStyle(.switch)
            Text(lang.t(.controlCenterNote))
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if music.useControlCenter && !music.controlCenterAccess {
                Text(lang.t(.controlCenterPermission)).font(.caption).foregroundStyle(.orange)
                Button(lang.t(.openSettings)) { SystemMedia.openAccessibilitySettings() }
            }
        }
        .onAppear { music.recheckControlCenterAccess() }
    }

    private var audioStatusKey: L10nKey {
        switch audioMonitor.state {
        case .off: return .audioLevelsOff
        case .unsupported: return .audioLevelsUnsupported
        case .idle: return .audioLevelsIdle
        case .running: return .audioLevelsRunning
        case .silent: return .audioLevelsSilent
        case .failed: return .audioLevelsFailed
        }
    }

    private var systemStatus: String {
        let version = ProcessInfo.processInfo.operatingSystemVersionString
        if !music.useSystemNowPlaying { return lang.t(.systemNPOff) }
        if music.systemNowPlayingWorks { return lang.t(.systemNPWorks, music.systemAppName ?? lang.t(.nowPlaying)) }
        if SystemMedia.isRestrictedOS() { return lang.t(.systemNPRestricted, version) }
        return lang.t(.systemNPNoData)
    }

    /// Counts only — no URLs or titles.
    private func diagnosticsText(_ d: BrowserMedia.Diagnostics) -> String {
        var parts = [lang.t(.diagChecked, lang.time(d.date)),
                     lang.t(.diagTabs, "YouTube Music", "\(d.musicTabs)", "\(d.musicPlaying)"),
                     lang.t(.diagTabs, "YouTube", "\(d.videoTabs)", "\(d.videoPlaying)")]
        if d.unreadable > 0 { parts.append(lang.t(.diagUnreadable, "\(d.unreadable)")) }
        if d.youtubeMusicAppRunning { parts.append(lang.t(.diagAppRunning)) }
        let shown = d.shownSite.map { $0.displayName + " (" + lang.t(d.shownIsPlaying ? .nowPlaying : .paused) + ")" } ?? lang.t(.diagNothing)
        parts.append(lang.t(.diagShowing, shown))
        if let source = d.shownTimeSource {
            let key: L10nKey = source == "player" ? .timeFromPlayerAPI
                : (source == "ui" ? .timeFromPlayerBar : (source == "ad" ? .timeAd : (source == "element" ? .timeFromElement : .timeNone)))
            parts.append(lang.t(.diagTime, lang.t(key), "\(d.shownMediaElements)"))
        }
        return parts.joined(separator: " · ")
    }

    private func check(_ browser: BrowserMedia.Browser) {
        guard music.enabledBrowsers.contains(browser) else { return }
        music.checkAutomation(for: browser) { permissions[browser] = $0 }
    }

    private func statusText(_ browser: BrowserMedia.Browser) -> String {
        if !browser.isInstalled { return lang.t(.browserNotInstalled) }
        if music.browserIssues[browser] == .automationDenied || permissions[browser] == .denied { return lang.t(.automationDenied) }
        if music.browserIssues[browser] == .javascriptDisabled { return lang.t(.jsDisabled) }
        if music.browserIssues[browser] == .youtubeMusicAppNotVisible { return lang.t(.ytmAppNotVisible) }
        switch permissions[browser] {
        case .granted: return lang.t(.automationAllowed)
        case .notDetermined: return lang.t(.automationNotAsked)
        case .browserNotRunning: return lang.t(.browserNotRunning)
        default: return lang.t(.automationUnknown)
        }
    }

    private func statusColor(_ browser: BrowserMedia.Browser) -> Color {
        if music.browserIssues[browser] != nil || permissions[browser] == .denied { return .orange }
        return permissions[browser] == .granted ? .green : .secondary
    }
}
