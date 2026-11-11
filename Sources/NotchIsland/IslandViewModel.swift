import AppKit
import SwiftUI
import Combine

enum IslandMode: Equatable {
    /// Matches the hardware notch exactly; menu bar on both sides stays free.
    case idle
    /// Timer or music active: small live content on the notch's left/right.
    case compact
    /// Hovered for 1 s (or clicked): panel emerging downward below the menu bar.
    case expanded
}

/// What the expanded island shows. Widgets never widen the menu-bar part:
/// only real live activities (timer, stopwatch, music) do.
/// Full-area pages opened from the quick actions under the widgets.
enum IslandSubpage: Equatable {
    case none, clipboard, audd
    case shazam(ControlCenterMedia.MusicRecognitionResult)
}

/// Short result shown in the notch for a moment (screenshot, paste, recording…).
struct IslandToast: Equatable {
    enum Style: Equatable { case success, info, failure }
    var symbol: String
    var text: String
    var style: Style
    /// Spoken instead of `text` when the text alone is terse (e.g. "82%").
    var accessibilityText: String? = nil
}

enum ExpandedPage: String, CaseIterable, Identifiable {
    case activities, widgets
    var id: String { rawValue }
}

enum ActivityTool: String, CaseIterable, Identifiable {
    case timer, stopwatch
    var id: String { rawValue }
}

@MainActor
final class IslandViewModel: ObservableObject {
    @Published var geometry: NotchGeometry
    @Published private(set) var mode: IslandMode = .idle
    /// Animated together with `mode`, so the neck width morphs smoothly.
    @Published private(set) var isActive = false
    @Published var isHovering = false
    @Published private(set) var isExpanded = false
    @Published var page: ExpandedPage = .widgets
    @Published var activityTool: ActivityTool = .timer
    @Published var subpage: IslandSubpage = .none
    @Published private(set) var checkingSystemRecognition = false
    @Published private(set) var toast: IslandToast?
    private var toastWork: DispatchWorkItem?
    /// Small card below the notch (low battery). Never shown over the expanded panel.
    @Published private(set) var banner: IslandBanner?
    private var pendingBanner: IslandBanner?
    private var bannerWork: DispatchWorkItem?
    /// Set by the controller while the pointer rests on the banner (keeps it up).
    var pointerOnBanner = false
    /// "Reduce motion" (System Settings › Accessibility › Display); injectable for tests.
    var reduceMotion: () -> Bool = { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }

    // Quick actions (set by the controller).
    var onScreenshot: (() -> Void)?
    var onScreenRecording: (() -> Void)?
    var onPasteClipboardItem: ((ClipboardItem) -> Void)?

    let timer: CountdownTimer
    let music: MusicController
    let stopwatch: Stopwatch
    /// Opens the settings window (set by the controller).
    var onOpenSettings: (() -> Void)?
    /// Asks for (coarse) current location for weather; user-initiated only.
    var onUseCurrentLocation: (() -> Void)?
    private var cancellables: Set<AnyCancellable> = []

    static let compactSideWidth: CGFloat = 64
    /// 0.1.1: 20 pt shorter than 0.1.0 (580). The widget page's padding and
    /// card spacing shrink by the same amount, so four cards keep their
    /// 127 pt size (see `widgetCardSide`).
    static let expandedWidth: CGFloat = 560
    /// Horizontal padding of the widget page and spacing between its cards.
    static let widgetsHorizontalPadding: CGFloat = 13
    static let widgetCardSpacing: CGFloat = 8
    static let bannerWidth: CGFloat = 360
    static let bannerHeight: CGFloat = 58
    static let expandedContentHeight: CGFloat = 170
    /// The widget page is a little taller so cards can be iOS-style squares.
    /// Widget cards plus the quick-action row (Clipboard, Screenshot, Record, Shazam).
    static let widgetsContentHeight: CGFloat = 230
    static let quickActionsHeight: CGFloat = 34
    static var maxContentHeight: CGFloat { max(expandedContentHeight, widgetsContentHeight) }

    /// Body height below the menu bar for the current page.
    var contentHeight: CGFloat { page == .widgets ? Self.widgetsContentHeight : Self.expandedContentHeight }
    /// Gap between the menu bar and a free-floating panel on displays without a notch.
    static let floatingGap: CGFloat = 6
    /// Extra transparent room in the window so the expanded shadow is not clipped.
    static let windowPadding: CGFloat = 40

    init(geometry: NotchGeometry, timer: CountdownTimer, music: MusicController, stopwatch: Stopwatch) {
        self.geometry = geometry
        self.timer = timer
        self.music = music
        self.stopwatch = stopwatch
        Publishers.CombineLatest3(timer.$phase, music.$isPlaying, stopwatch.$phase)
            .map { phase, playing, watch in phase != .idle || playing || watch != .idle }
            .removeDuplicates()
            .sink { [weak self] _ in
                // Defer so the publishers' new values are visible.
                DispatchQueue.main.async { MainActor.assumeIsolated { self?.updateMode() } }
            }
            .store(in: &cancellables)
    }

    func setExpanded(_ expanded: Bool) {
        guard isExpanded != expanded else { return }
        if expanded {
            subpage = .none
            // The user opened the island: the banner's message is in the battery widget too.
            bannerWork?.cancel(); bannerWork = nil
            banner = nil
            // Live activities first when there are any; otherwise the widget area.
            page = hasLiveActivity ? .activities : .widgets
            if stopwatch.isActive && !timer.isActive { activityTool = .stopwatch }
            if timer.isActive { activityTool = .timer }
        }
        isExpanded = expanded
        updateMode()
        if !expanded, let pending = pendingBanner {
            pendingBanner = nil
            showBanner(pending)
        }
    }

    func startSystemRecognition(feedbackDuration: Duration,
                                run: @escaping @Sendable () -> ControlCenterMedia.MusicRecognitionResult = {
                                    ControlCenterMedia.startMusicRecognition()
                                }) {
        guard !checkingSystemRecognition else { return }
        checkingSystemRecognition = true
        Task {
            let feedbackEnd = ContinuousClock.now + feedbackDuration
            let result = await Task.detached(priority: .userInitiated) {
                run()
            }.value
            try? await Task.sleep(until: feedbackEnd, clock: .continuous)
            checkingSystemRecognition = false
            guard result != .listening, isExpanded, page == .widgets, subpage == .none else { return }
            subpage = .shazam(result)
        }
    }

    /// Tools shown on the Live Activities page: only running/paused/finished ones.
    /// An idle timer lives in the Timer widget instead.
    nonisolated static func visibleTools(timerActive: Bool, stopwatchActive: Bool) -> [ActivityTool] {
        (timerActive ? [ActivityTool.timer] : []) + (stopwatchActive ? [.stopwatch] : [])
    }

    nonisolated static func resolvedTool(_ selected: ActivityTool, in tools: [ActivityTool]) -> ActivityTool? {
        tools.contains(selected) ? selected : tools.first
    }

    var hasLiveActivity: Bool { timer.isActive || music.isPlaying || stopwatch.isActive }

    /// Shows a short message in the notch (counts as a live indicator while visible).
    func showToast(_ toast: IslandToast, duration: TimeInterval = 2.8) {
        toastWork?.cancel()
        self.toast = toast
        updateMode()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                self?.toast = nil
                self?.updateMode()
            }
        }
        toastWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + duration, execute: work)
    }

    /// Shows the banner for a while (longer while the pointer rests on it).
    /// Arriving while expanded, it waits until the island collapses.
    func showBanner(_ new: IslandBanner, duration: TimeInterval = 9) {
        guard !isExpanded else { pendingBanner = new; return }
        bannerWork?.cancel()
        withAnimation(modeAnimation(expanding: false)) { banner = new }
        updateMode()
        scheduleBannerDismissal(after: duration)
    }

    private func scheduleBannerDismissal(after delay: TimeInterval) {
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                if self.pointerOnBanner { self.scheduleBannerDismissal(after: 2); return }
                self.dismissBanner()
            }
        }
        bannerWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    func dismissBanner() {
        bannerWork?.cancel(); bannerWork = nil
        pendingBanner = nil
        guard banner != nil else { return }
        withAnimation(modeAnimation(expanding: false)) { banner = nil }
        pointerOnBanner = false
        updateMode()
    }

    private func updateMode() {
        let active = hasLiveActivity || toast != nil || banner != nil
        let newMode: IslandMode = isExpanded ? .expanded : (active ? .compact : .idle)
        guard newMode != mode || active != isActive else { return }
        withAnimation(modeAnimation(expanding: newMode == .expanded)) {
            isActive = active
            mode = newMode
        }
    }

    /// Springs normally; a short fade-like ease when Reduce Motion is on.
    func modeAnimation(expanding: Bool) -> Animation {
        if reduceMotion() { return Self.reducedMotionAnimation }
        return expanding ? Self.expandAnimation : Self.collapseAnimation
    }

    static let reducedMotionAnimation = Animation.easeInOut(duration: 0.16)

    static let expandAnimation = Animation.spring(response: 0.42, dampingFraction: 0.8)
    static let collapseAnimation = Animation.spring(response: 0.34, dampingFraction: 0.92)

    // MARK: Layout

    var menuBarHeight: CGFloat { geometry.notchSize.height }
    var compactWidth: CGFloat { geometry.notchSize.width + 2 * Self.compactSideWidth }

    /// Width of the part that lives inside the menu bar: the physical notch when
    /// nothing is going on, the notch plus side indicators while active.
    func neckWidth(for mode: IslandMode, hovering: Bool) -> CGFloat {
        // Expanded: the panel hangs below the menu bar; inside the menu bar only
        // the physical notch is covered, so status items beside it stay visible
        // and clickable (live info is shown in the panel itself).
        if mode == .expanded { return geometry.hasNotch ? geometry.notchSize.width : 0 }
        if isActive && mode == .compact { return compactWidth }
        if geometry.hasNotch { return geometry.notchSize.width }
        // No notch and no activity: nothing is drawn in the menu bar except a
        // small hover tab that confirms the hover target.
        return mode == .idle && hovering ? 80 : 0
    }

    /// Y (from the screen top) where the expanded body starts.
    var bodyTop: CGFloat {
        neckWidth(for: .expanded, hovering: false) > 0 ? menuBarHeight : menuBarHeight + Self.floatingGap
    }

    func shapeParams(for mode: IslandMode, hovering: Bool, includeBanner: Bool = true) -> IslandShapeParams {
        let neck = neckWidth(for: mode, hovering: hovering)
        // The top flare only exists when indicators widen the neck past the notch.
        let flare: CGFloat = neck > geometry.notchSize.width ? 6 : 0
        switch mode {
        case .compact where includeBanner && banner != nil:
            // Banner: a short body below the menu bar, like a small expanded panel.
            return IslandShapeParams(neckWidth: neck, neckHeight: menuBarHeight + (hovering ? Self.hoverGrowth : 0),
                                     neckRadius: 11, flare: flare, bodyWidth: Self.bannerWidth, bodyTop: bodyTop,
                                     height: bodyTop + Self.bannerHeight, bodyRadius: 22)
        case .idle, .compact:
            // Zero-height body parked at the menu bar line, as wide as the neck,
            // so expanding grows it straight down from there.
            let neckHeight: CGFloat
            if mode == .idle && !geometry.hasNotch {
                neckHeight = hovering ? 9 : 0
            } else {
                // Hover feedback only grows downward, never into the menu bar sides.
                neckHeight = menuBarHeight + (hovering ? Self.hoverGrowth : 0)
            }
            let radius: CGFloat = mode == .compact ? 11 : (geometry.hasNotch ? 9 : 4.5)
            return IslandShapeParams(neckWidth: neck, neckHeight: neckHeight, neckRadius: radius, flare: flare,
                                     bodyWidth: neck, bodyTop: bodyTop, height: bodyTop, bodyRadius: 28)
        case .expanded:
            return IslandShapeParams(neckWidth: neck, neckHeight: menuBarHeight, neckRadius: 0, flare: flare,
                                     bodyWidth: Self.expandedWidth, bodyTop: bodyTop,
                                     height: bodyTop + contentHeight, bodyRadius: 28)
        }
    }

    var currentParams: IslandShapeParams {
        shapeParams(for: mode, hovering: isHovering && mode != .expanded)
    }

    var windowSize: CGSize {
        CGSize(width: max(Self.expandedWidth, compactWidth + 12) + 2 * Self.windowPadding,
               height: menuBarHeight + Self.floatingGap + Self.maxContentHeight + Self.windowPadding)
    }

    /// Window frame in screen coordinates: top-aligned, centred on the notch.
    var windowFrame: NSRect {
        let size = windowSize
        return NSRect(x: geometry.notchRect.midX - size.width / 2,
                      y: geometry.screenFrame.maxY - size.height,
                      width: size.width, height: size.height)
    }

    /// Converts a screen point into the SwiftUI (top-left origin) space of the window.
    func localPoint(_ screenPoint: NSPoint) -> CGPoint {
        let frame = windowFrame
        // The topmost pixel row counts as inside, so the screen edge is a valid target.
        return CGPoint(x: screenPoint.x - frame.minX, y: max(0.5, frame.maxY - screenPoint.y))
    }

    /// Exact hit test against the drawn silhouette (flared/rounded corners pass through).
    /// Click/hover strip just below the notch (or virtual zone). The hardware
    /// notch may not be clickable on every Mac, so this keeps a reliable target
    /// that lives below the menu bar line, never beside the notch.
    static let activationStripHeight: CGFloat = 8
    /// How far the hovered idle/compact island grows down (visual feedback for the strip).
    static let hoverGrowth: CGFloat = 6

    /// Rect (screen coordinates) of the strip under the notch / virtual zone.
    var activationStrip: NSRect {
        let notch = geometry.notchRect
        return NSRect(x: notch.minX, y: notch.minY - Self.activationStripHeight,
                      width: notch.width, height: Self.activationStripHeight)
    }

    /// Where a hover (1 s) or a click (immediate) expands the island.
    /// Idle: the notch / virtual zone plus the strip below it — never the menu
    /// bar to either side. Compact: the drawn indicators plus the strip.
    func activationContains(_ point: NSPoint, mode: IslandMode? = nil) -> Bool {
        let mode = mode ?? self.mode
        var notch = geometry.notchRect
        notch.size.height += 2 // NSRect excludes maxY; include the top pixel row.
        var strip = activationStrip
        strip.size.height += 0.5 // touch the notch without a gap
        switch mode {
        case .idle: return notch.contains(point) || strip.contains(point)
        // The banner body is not an expand target: its buttons must stay clickable.
        case .compact: return shapeContains(point, mode: .compact, includeBanner: false) || strip.contains(point)
        case .expanded: return false
        }
    }

    /// Union of everything that can open the island in its collapsed form
    /// (notch, strip below it and — with a live activity — the compact
    /// indicators, including their hover growth). Used for collapse hysteresis.
    func activationZoneContains(_ point: NSPoint) -> Bool {
        if activationContains(point, mode: .idle) { return true }
        guard isActive else { return false }
        let compact = shapeParams(for: .compact, hovering: true, includeBanner: false)
        let path = IslandShape(p: compact).path(in: CGRect(origin: .zero, size: windowSize))
        return path.contains(localPoint(point))
    }

    /// Whether the panel should take mouse events at `point` (otherwise clicks
    /// pass through to the menu bar / windows below).
    func acceptsMouse(at point: NSPoint) -> Bool {
        mode == .expanded ? shapeContains(point) : (activationContains(point) || bannerContains(point))
    }

    /// The banner card (screen coordinates), when one is shown.
    func bannerContains(_ screenPoint: NSPoint) -> Bool {
        guard banner != nil, mode == .compact else { return false }
        let size = windowSize
        let card = CGRect(x: (size.width - Self.bannerWidth) / 2, y: bodyTop, width: Self.bannerWidth, height: Self.bannerHeight)
        return card.contains(localPoint(screenPoint))
    }

    /// Edge of each widget card for `count` cards in the expanded page (layout check).
    static func widgetCardSide(count: Int, rowHeight: CGFloat) -> CGFloat {
        let n = CGFloat(max(1, count))
        let width = expandedWidth - 2 * widgetsHorizontalPadding
        return floor(min(rowHeight, (width - widgetCardSpacing * (n - 1)) / n))
    }

    func shapeContains(_ screenPoint: NSPoint, mode: IslandMode? = nil, includeBanner: Bool = true) -> Bool {
        let mode = mode ?? self.mode
        let params = shapeParams(for: mode, hovering: isHovering && mode != .expanded, includeBanner: includeBanner)
        let path = IslandShape(p: params).path(in: CGRect(origin: .zero, size: windowSize))
        return path.contains(localPoint(screenPoint))
    }

    /// Tolerant zone that keeps the expanded island open while the pointer is
    /// near the body, so small overshoots don't collapse it.
    ///
    /// It must contain every point that can *open* the island (hysteresis):
    /// with a live activity the compact indicators beside the notch are an
    /// activation area, but the expanded shape leaves that part of the menu bar
    /// free. Without this, resting the pointer on the right indicator expanded
    /// the island, the pointer was then "outside", it collapsed after 0.35 s,
    /// the indicator reappeared under the pointer and it expanded again ~1 s
    /// later — a loop. This zone only decides when to collapse; clicks there
    /// still go to the menu bar (see `acceptsMouse`).
    func keepOpenContains(_ screenPoint: NSPoint) -> Bool {
        if shapeContains(screenPoint, mode: .expanded) { return true }
        if activationZoneContains(screenPoint) { return true }
        let size = windowSize
        let body = CGRect(x: (size.width - Self.expandedWidth) / 2, y: bodyTop,
                          width: Self.expandedWidth, height: contentHeight)
        return body.insetBy(dx: -14, dy: -10).contains(localPoint(screenPoint))
    }
}
