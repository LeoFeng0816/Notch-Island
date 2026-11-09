import AppKit
import SwiftUI
import Combine

/// Borderless panel floating above the menu bar, never activating the app.
final class IslandPanel: NSPanel {
    init(contentRect: NSRect) {
        super.init(contentRect: contentRect,
                   styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered,
                   defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        level = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 3)
        collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        isMovable = false
        isReleasedWhenClosed = false
        becomesKeyOnlyIfNeeded = true
        hidesOnDeactivate = false
        ignoresMouseEvents = true
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    /// Allow the frame to overlap the menu bar instead of being pushed below it.
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
}

/// Buttons react on the first click even though the panel is never key.
final class FirstMouseHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

@MainActor
final class IslandController {
    let timer = CountdownTimer()
    let music = MusicController()
    let audioMonitor = AudioLevelMonitor()
    let clipboard = ClipboardStore()
    let shazam = ShazamRecognizer()
    /// The app that was in front before the island was used — where a chosen
    /// clipboard item is pasted. The island never becomes frontmost itself.
    private var pasteTarget: NSRunningApplication?
    /// Stock search in Settings, using the selected provider (Yahoo: no key;
    /// Alpha Vantage: documented SYMBOL_SEARCH with the saved key).
    lazy var stockSearch = StockSearchModel { [widgetSettings] query in
        let client = URLSessionHTTPClient()
        if widgetSettings.stockProvider == .alphaVantage {
            let key = try await widgetSettings.loadStockAPIKey().get()
            return try await AlphaVantageProvider(client: client).search(query, apiKey: key)
        }
        return try await YahooFinanceProvider(client: client).search(query)
    }
    let stopwatch = Stopwatch()
    let battery = BatteryMonitor()
    let widgetSettings = WidgetSettings()
    let widgetData: WidgetDataCenter
    let calendar = CalendarStore()
    let location = LocationProvider()
    let device = DeviceInfo.detect()
    let lang = LanguageSettings.shared
    let model: IslandViewModel
    private var settingsWindow: SettingsWindowController?
    /// Preview/screenshot aid (`--stay-expanded`): don't collapse when the pointer leaves.
    var pinExpanded = false

    private var panel: IslandPanel?
    private var monitors: [Any] = []
    private var hoverWork: DispatchWorkItem?
    private var collapseWork: DispatchWorkItem?
    private var cancellables: Set<AnyCancellable> = []

    static let hoverDelay: TimeInterval = 1.0
    static let collapseDelay: TimeInterval = 0.35

    init() {
        let screen = NotchGeometry.preferredScreen() ?? NSScreen.screens[0]
        model = IslandViewModel(geometry: NotchGeometry(screen: screen), timer: timer, music: music, stopwatch: stopwatch)
        widgetData = WidgetDataCenter(settings: widgetSettings)
        model.onOpenSettings = { [weak self] in self?.openSettings() }
        model.onUseCurrentLocation = { [weak self] in self?.useCurrentLocationForWeather() }
        model.onScreenshot = { [weak self] in self?.takeScreenshot() }
        model.onScreenRecording = { [weak self] in self?.openScreenRecording() }
        model.onPasteClipboardItem = { [weak self] item in self?.paste(item) }
    }

    func start() {
        layoutPanel()
        music.start()
        clipboard.startMonitoring()
        // Real audio levels are captured only while the user enabled them and media plays.
        music.$isPlaying
            .removeDuplicates()
            .sink { [weak self] playing in self?.audioMonitor.update(mediaPlaying: playing) }
            .store(in: &cancellables)
        installMouseMonitors()
        widgetData.start()

        // Battery is read locally (IOKit); only observe it while the widget is on.
        widgetSettings.$enabled
            .map { $0.contains(.battery) }
            .removeDuplicates()
            .sink { [weak self] on in
                guard let self else { return }
                on ? self.battery.start() : self.battery.stop()
            }
            .store(in: &cancellables)
        // Calendar: EventKit is only touched while the widget is on (no prompt here).
        Publishers.CombineLatest3(widgetSettings.$enabled.map { $0.contains(.calendar) },
                                  widgetSettings.$calendarDays, widgetSettings.$calendarShowsAllDay)
            .removeDuplicates { $0 == $1 }
            .sink { [weak self] on, days, allDay in
                self?.calendar.setActive(on, days: days, includeAllDay: allDay)
            }
            .store(in: &cancellables)

        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                               object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.layoutPanel() }
        }
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.activeSpaceDidChangeNotification,
                                                          object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.panel?.orderFrontRegardless() }
        }
        // Screens can change while asleep (lid closed, monitor unplugged); re-measure on wake.
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification,
                                                          object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.layoutPanel()
                self?.battery.refresh()
                self?.widgetData.refreshDue()
                if self?.calendar.isActive == true { self?.calendar.refresh() }
            }
        }
        // Content size changes with the mode: re-evaluate hit testing right away.
        model.$mode
            .sink { [weak self] mode in
                DispatchQueue.main.async { MainActor.assumeIsolated { self?.handleMouse() } }
                // Pick up a permission changed in System Settings (no prompt).
                if mode == .expanded { self?.calendar.reloadAccess() }
            }
            .store(in: &cancellables)
    }

    var isExpanded: Bool { model.isExpanded }

    func setExpanded(_ expanded: Bool) {
        if expanded, let front = NSWorkspace.shared.frontmostApplication,
           front.processIdentifier != ProcessInfo.processInfo.processIdentifier {
            pasteTarget = front
        }
        if !expanded, shazam.isListening { shazam.cancel() } // never keep listening once the island is closed
        hoverWork?.cancel(); hoverWork = nil
        collapseWork?.cancel(); collapseWork = nil
        model.isHovering = false
        model.setExpanded(expanded)
    }

    // MARK: Quick actions

    /// The user picks the area or window. Esc cancels without opening another tool.
    func takeScreenshot() {
        setExpanded(false)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
            MainActor.assumeIsolated {
                ScreenshotAction.run { outcome in self?.report(screenshot: outcome) }
            }
        }
    }

    private func report(screenshot outcome: ScreenshotAction.Outcome) {
        switch outcome {
        case .copied:
            model.showToast(.init(symbol: "checkmark.circle.fill", text: lang.t(.toastCopied), style: .success))
            IslandNotifier.post(title: lang.t(.qaScreenshot), body: lang.t(.screenshotCopied))
        case .cancelled:
            model.showToast(.init(symbol: "xmark.circle", text: lang.t(.toastCancelled), style: .info), duration: 1.8)
        case .busy:
            showCaptureBusy()
        case .refused(let advice):
            model.showToast(.init(symbol: "lock.fill", text: lang.t(.toastPermission), style: .failure), duration: 4)
            offerCaptureHelp(title: .qaScreenshot, fact: lang.t(.captureToolRefused), advice: advice, recording: false)
        case .noImage(let advice):
            model.showToast(.init(symbol: "exclamationmark.triangle.fill", text: lang.t(.toastFailed), style: .failure), duration: 4)
            offerCaptureHelp(title: .qaScreenshot, fact: lang.t(.captureToolNoImage), advice: advice, recording: false)
        case .failed(let status):
            model.showToast(.init(symbol: "exclamationmark.triangle.fill", text: lang.t(.toastFailed), style: .failure))
            offerCaptureHelp(title: .qaScreenshot, fact: lang.t(.captureToolFailed, String(status)), advice: nil, recording: false)
        }
    }

    /// With this copy's screen-recording grant: the macOS toolbar opens directly
    /// in video mode and the user clicks Record. Without it: explain and let the
    /// user choose QuickTime (its own capture rights), Screenshot, or Settings.
    func openScreenRecording() {
        setExpanded(false)
        let allowed = CGPreflightScreenCaptureAccess()
        switch ScreenRecordingAction.route(screenCaptureAllowed: allowed) {
        case .captureToolbar:
            CaptureTool.run(ScreenRecordingAction.recordingArguments) { [weak self] exit in
                guard let self else { return }
                let advice = CaptureAdvice.from(screenCaptureAllowed: CGPreflightScreenCaptureAccess(), identity: .current())
                switch exit {
                case .finished, .cancelled: break // Recorded or closed: the toolbar/Finder show the result, we don't claim one.
                case .busy: showCaptureBusy()
                case .refused: offerCaptureHelp(title: .qaScreenRecord, fact: lang.t(.captureToolRefused), advice: advice, recording: true)
                case .noImage: offerCaptureHelp(title: .qaScreenRecord, fact: lang.t(.captureToolNoImage), advice: advice, recording: true)
                case .failed(let status):
                    offerCaptureHelp(title: .qaScreenRecord, fact: lang.t(.captureToolFailed, String(status)), advice: nil, recording: true)
                }
            }
        case .askForFallback:
            let advice = CaptureAdvice.from(screenCaptureAllowed: false, identity: .current())
            offerCaptureHelp(title: .qaScreenRecord, fact: lang.t(.recordNeedsGrant), advice: advice, recording: true)
        }
    }

    private func showCaptureBusy() {
        model.showToast(.init(symbol: "viewfinder", text: lang.t(.toastCaptureBusy), style: .info))
    }

    private func adviceText(_ advice: CaptureAdvice?) -> String? {
        switch advice {
        case .grantProbablyForAnotherBuild: return lang.t(.captureAdviceStaleGrant)
        case .notGranted: return lang.t(.captureAdviceNotGranted)
        case .grantedButFailed: return lang.t(.captureAdviceUnknown)
        case nil: return nil
        }
    }

    /// One alert with the facts we observed, an explanation that is only as
    /// certain as the evidence, and the alternatives that actually work.
    private func offerCaptureHelp(title: L10nKey, fact: String, advice: CaptureAdvice?, recording: Bool) {
        enum Choice { case quickTime, screenshotApp, settings }
        let alert = NSAlert()
        alert.alertStyle = advice == nil ? .warning : .informational
        alert.messageText = lang.t(title)
        alert.informativeText = ([fact, adviceText(advice), lang.t(recording ? .recordFallbackHelp : .screenshotFallbackHelp)]
            .compactMap { $0 }).joined(separator: "\n\n")
        var choices: [Choice] = []
        if recording && ScreenRecordingAction.quickTimeInstalled {
            alert.addButton(withTitle: lang.t(.recordWithQuickTime)); choices.append(.quickTime)
        }
        alert.addButton(withTitle: lang.t(recording ? .recordOpenScreenshot : .screenshotOpenSystem)); choices.append(.screenshotApp)
        if advice == .grantProbablyForAnotherBuild || advice == .notGranted {
            alert.addButton(withTitle: lang.t(.openPrivacySettings)); choices.append(.settings)
        }
        alert.addButton(withTitle: lang.t(.cancel))
        NSApp.activate()
        let index = alert.runModal().rawValue - NSApplication.ModalResponse.alertFirstButtonReturn.rawValue
        guard choices.indices.contains(index) else { return }
        switch choices[index] {
        case .quickTime:
            ScreenRecordingAction.openQuickTimeRecording { [weak self] result in self?.report(quickTime: result) }
        case .settings:
            NSWorkspace.shared.open(ScreenRecordingAction.screenRecordingSettings)
        case .screenshotApp:
            Task { [weak self] in
                do {
                    try await ScreenRecordingAction.openSystemToolbar()
                    // Screenshot.app reopens in the last mode the user used; say which buttons switch to video.
                    if recording, let self {
                        self.model.showToast(.init(symbol: "record.circle", text: self.lang.t(.toastPickRecordMode), style: .info), duration: 6)
                    }
                } catch {
                    guard let self else { return }
                    let failure = NSAlert()
                    failure.messageText = self.lang.t(title)
                    failure.informativeText = self.lang.t(recording ? .recordToolbarFailed : .screenshotToolbarFailed)
                    failure.addButton(withTitle: self.lang.t(.ok))
                    failure.runModal()
                }
            }
        }
    }

    private func report(quickTime result: ScreenRecordingAction.QuickTimeResult) {
        switch result {
        case .requested:
            model.showToast(.init(symbol: "record.circle", text: lang.t(.toastQuickTimeRequested), style: .info), duration: 4)
        case .automationDenied:
            let alert = NSAlert()
            alert.messageText = lang.t(.qaScreenRecord)
            alert.informativeText = lang.t(.recordQuickTimeDenied)
            alert.addButton(withTitle: lang.t(.recordOpenScreenshot))
            alert.addButton(withTitle: lang.t(.cancel))
            NSApp.activate()
            if alert.runModal() == .alertFirstButtonReturn {
                Task { [weak self] in
                    try? await ScreenRecordingAction.openSystemToolbar()
                    if let self { self.model.showToast(.init(symbol: "record.circle", text: self.lang.t(.toastPickRecordMode), style: .info), duration: 6) }
                }
            }
        case .notInstalled, .failed:
            model.showToast(.init(symbol: "exclamationmark.triangle.fill", text: lang.t(.toastFailed), style: .failure))
            IslandNotifier.post(title: lang.t(.qaScreenRecord), body: lang.t(.recordToolbarFailed))
        }
    }

    /// Copies the item and pastes it into the app that was in front; says
    /// plainly when it could only copy.
    func paste(_ item: ClipboardItem) {
        let copied = clipboard.copyToPasteboard(item)
        let target = pasteTarget
        let decision = ClipboardPaste.plan(copied: copied, hasTarget: target != nil,
                                           targetIsSelf: target?.processIdentifier == ProcessInfo.processInfo.processIdentifier,
                                           targetTerminated: target?.isTerminated ?? true,
                                           canPostEvents: SystemMedia.canPostEvents)
        setExpanded(false)
        if let decision { report(paste: decision); return }
        guard let target else { return }
        ClipboardPaste.paste(into: target) { [weak self] outcome in self?.report(paste: outcome) }
    }

    private func report(paste outcome: ClipboardPaste.Outcome) {
        switch outcome {
        case .pasted:
            model.showToast(.init(symbol: "checkmark.circle.fill", text: lang.t(.toastPasted), style: .success))
        case .copiedOnly(.needsPermission):
            model.showToast(.init(symbol: "doc.on.clipboard", text: lang.t(.toastCopied), style: .info), duration: 4)
            IslandNotifier.post(title: lang.t(.qaClipboard), body: lang.t(.pasteNeedsPermission))
        case .copiedOnly:
            model.showToast(.init(symbol: "doc.on.clipboard", text: lang.t(.toastCopied), style: .info), duration: 3)
        case .failed:
            model.showToast(.init(symbol: "exclamationmark.triangle.fill", text: lang.t(.toastFailed), style: .failure))
        }
    }

    /// Called only from user actions (turning on Weather without a city, tapping
    /// the weather card, or the Settings button). Never at launch.
    func useCurrentLocationForWeather() {
        guard !location.isLocating else { return }
        Task {
            if case .success(let coordinate) = await location.requestCoarseLocation() {
                widgetSettings.place = Place.currentLocation(coordinate)
            }
        }
    }

    private var onboardingWindow: OnboardingWindowController?

    /// First-run guide (also from the menu). Only changes what the user changes there.
    func showOnboarding() {
        setExpanded(false)
        if onboardingWindow == nil {
            onboardingWindow = OnboardingWindowController(lang: lang) { [unowned self] done in
                AnyView(OnboardingView(lang: self.lang, clipboard: self.clipboard,
                                       openSettings: { [weak self] in self?.openSettings() }, done: done))
            }
        }
        onboardingWindow?.show()
    }

    func openSettings() {
        setExpanded(false)
        if settingsWindow == nil {
            settingsWindow = SettingsWindowController(lang: lang) { [unowned self] in
                AnyView(SettingsView(lang: self.lang, settings: self.widgetSettings, model: self.model,
                                     music: self.music, calendar: self.calendar, location: self.location,
                                     audioMonitor: self.audioMonitor, stockSearch: self.stockSearch,
                                     clipboard: self.clipboard,
                                     useCurrentLocation: { [weak self] in self?.useCurrentLocationForWeather() },
                                     device: self.device,
                                     weatherProvider: OpenMeteoProvider(client: URLSessionHTTPClient()),
                                     redetect: { [weak self] in self?.layoutPanel() }))
            }
        }
        settingsWindow?.show()
    }

    // MARK: Window

    /// Re-measures the notch from the current screens and repositions the panel.
    func layoutPanel() {
        guard let screen = NotchGeometry.preferredScreen() else { return }
        let geometry = NotchGeometry(screen: screen)
        if geometry != model.geometry { model.geometry = geometry }
        let frame = model.windowFrame
        if panel == nil {
            let panel = IslandPanel(contentRect: frame)
            let root = IslandRootView(model: model, timer: timer, music: music, lang: lang,
                                      stopwatch: stopwatch, battery: battery, data: widgetData, settings: widgetSettings,
                                      calendar: calendar, location: location, audioMonitor: audioMonitor,
                                      clipboard: clipboard, shazam: shazam)
            let hosting = FirstMouseHostingView(rootView: root)
            hosting.sizingOptions = []
            panel.contentView = hosting
            self.panel = panel
        }
        panel?.setFrame(frame, display: true)
        panel?.orderFrontRegardless()
    }

    // MARK: Hover / hit testing

    private func installMouseMonitors() {
        let moveEvents: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDragged]
        // Global monitors only see mouse events (no Accessibility permission needed).
        if let global = NSEvent.addGlobalMonitorForEvents(matching: moveEvents, handler: { [weak self] _ in
            MainActor.assumeIsolated { self?.handleMouse() }
        }) { monitors.append(global) }
        if let local = NSEvent.addLocalMonitorForEvents(matching: moveEvents, handler: { [weak self] event in
            MainActor.assumeIsolated { self?.handleMouse() }
            return event
        }) { monitors.append(local) }
        // Clicking anywhere outside the expanded island closes it. A left click on
        // the notch area that went to another app (panel not yet interactive)
        // still expands immediately.
        if let outside = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown], handler: { [weak self] event in
            MainActor.assumeIsolated {
                guard let self else { return }
                let point = NSEvent.mouseLocation
                if self.model.isExpanded {
                    if !self.model.shapeContains(point, mode: .expanded) { self.setExpanded(false) }
                } else if event.type == .leftMouseDown, self.model.activationContains(point) {
                    self.setExpanded(true)
                }
            }
        }) { monitors.append(outside) }
        // Left click on the island's activation area: expand right away (no 1 s wait).
        if let click = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown], handler: { [weak self] event in
            let handled = MainActor.assumeIsolated {
                guard let self, event.window === self.panel, self.model.mode != .expanded,
                      self.model.activationContains(NSEvent.mouseLocation) else { return false }
                self.setExpanded(true)
                return true
            }
            return handled ? nil : event
        }) { monitors.append(click) }
    }

    private func handleMouse() {
        let point = NSEvent.mouseLocation
        let mode = model.mode

        switch mode {
        case .expanded:
            if pinExpanded || model.keepOpenContains(point) {
                collapseWork?.cancel(); collapseWork = nil
            } else if collapseWork == nil {
                let work = DispatchWorkItem { [weak self] in
                    MainActor.assumeIsolated {
                        guard let self else { return }
                        self.collapseWork = nil
                        if !self.model.keepOpenContains(NSEvent.mouseLocation) {
                            self.setExpanded(false)
                        }
                    }
                }
                collapseWork = work
                DispatchQueue.main.asyncAfter(deadline: .now() + Self.collapseDelay, execute: work)
            }
        case .idle, .compact:
            let inside = isHoverTarget(point, mode: mode)
            if model.isHovering != inside { model.isHovering = inside }
            if inside {
                if hoverWork == nil {
                    let work = DispatchWorkItem { [weak self] in
                        MainActor.assumeIsolated {
                            guard let self else { return }
                            self.hoverWork = nil
                            if self.model.mode != .expanded,
                               self.isHoverTarget(NSEvent.mouseLocation, mode: self.model.mode) {
                                self.setExpanded(true)
                            }
                        }
                    }
                    hoverWork = work
                    DispatchQueue.main.asyncAfter(deadline: .now() + Self.hoverDelay, execute: work)
                }
            } else {
                hoverWork?.cancel(); hoverWork = nil
            }
        }

        // Clicks pass through everywhere except over the activation area / drawn
        // silhouette, so the menu bar beside the notch (and the flared corners)
        // stays usable.
        let interactive = model.acceptsMouse(at: point)
        if panel?.ignoresMouseEvents != !interactive { panel?.ignoresMouseEvents = !interactive }
    }

    /// Idle: the physical notch (or the invisible virtual zone on displays
    /// without one) plus the strip below it. Compact: the drawn silhouette plus the strip.
    private func isHoverTarget(_ point: NSPoint, mode: IslandMode) -> Bool {
        model.activationContains(point, mode: mode)
    }
}
