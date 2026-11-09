import AppKit
import ApplicationServices

/// Opt-in UI control using only macOS accessibility actions. No media is
/// read from the Control Center panel, and it is never opened by polling.
enum ControlCenterMedia {
    enum Command { case playPause, next, previous }
    enum Result: Equatable { case sent, permissionNeeded, unavailable, playerUnavailable, uncertain }
    /// Outcome of the user's "Recognize Music" press.
    enum MusicRecognitionResult: Equatable {
        /// Control Center shows its own "Listening…" state.
        case listening
        /// We pressed Recognize Music / Start Listening but couldn't read a listening state.
        case uncertain
        case permissionNeeded
        /// No Recognize Music control in Control Center (add it under Edit Controls).
        case notInControlCenter
        case unavailable
    }

    struct Node<Element> {
        let element: Element
        let names: [String]
        let pressable: Bool
        var children: [Node<Element>] = []

        func matches(_ labels: Set<String>) -> Bool {
            names.contains { labels.contains($0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()) }
        }
    }

    private static let nowPlaying: Set<String> = [
        "now playing", "nowplaying", "播放中", "正在播放", "com.apple.controlcenter.nowplaying",
        "com.apple.menuextra.nowplaying"
    ]
    private static let controlCenter: Set<String> = [
        "control center", "control centre", "控制中心", "com.apple.menuextra.controlcenter"
    ]
    private static let playPause: Set<String> = ["play", "pause", "play/pause", "播放", "暫停", "暂停"]
    private static let next: Set<String> = ["next", "next track", "下一首"]
    private static let previous: Set<String> = ["previous", "previous track", "上一首"]
    /// Find transport controls inside a named Now Playing region. If a version
    /// omits that label, accept a complete sibling transport group. Ambiguous
    /// matches are left alone rather than choosing an arbitrary player.
    static func target<Element>(for command: Command, in windows: [Node<Element>],
                                openedDedicatedPanel: Bool = false) -> Element? {
        let labels: Set<String>
        switch command {
        case .playPause: labels = playPause
        case .next: labels = next
        case .previous: labels = previous
        }
        func find(_ node: Node<Element>, scoped: Bool) -> [Element] {
            let namedRegion = scoped || node.matches(nowPlaying)
            let buttons = node.children.filter(\.pressable)
            let transportGroup = [playPause, next, previous].allSatisfy { names in
                buttons.contains { $0.matches(names) }
            }
            if transportGroup && !namedRegion {
                return buttons.filter { $0.matches(labels) }.map(\.element)
            }
            let here = namedRegion && node.pressable && node.matches(labels) ? [node.element] : []
            return here + node.children.flatMap { find($0, scoped: namedRegion) }
        }
        let matches = windows.flatMap { find($0, scoped: openedDedicatedPanel) }
        return matches.count == 1 ? matches.first : nil
    }

    static var hasAccess: Bool { AXIsProcessTrusted() }

    static func requestAccess() {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        _ = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
    }

    // Identifiers below are literal strings inside macOS 27's ControlCenter binary.
    static let musicModule: Set<String> = ["controlcenter-musicrecognition", "com.apple.controlcenter.musicrecognition"]
    static let musicMenu: Set<String> = ["com.apple.menuextra.musicrecognition"]
    static let musicPanel: Set<String> = ["musicrecognition-header", "musicrecognition-history"]

    /// Labels of the panel's "Start Listening" button and "Listening…" state,
    /// read from Control Center's own MusicRecognition.loctable (all languages),
    /// plus the English/Chinese values as a fallback.
    struct MusicLabels: Equatable {
        var start: Set<String>
        var listening: Set<String>

        static let builtIn = MusicLabels(
            start: ["start listening", "開始聆聽", "开始听取"].reduce(into: Set<String>()) { $0.insert(normalize($1)) },
            listening: ["Listening…", "聆聽中⋯", "正在听取…", "正在聆聽⋯"].reduce(into: Set<String>()) { $0.insert(normalize($1)) })

        static let loctable = URL(fileURLWithPath: "/System/Library/CoreServices/ControlCenter.app/Contents/Resources/MusicRecognition.loctable")

        /// Parses a loctable: `[locale: [key: value]]`.
        static func from(loctable data: Data) -> MusicLabels? {
            guard let table = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else { return nil }
            var labels = MusicLabels(start: [], listening: [])
            for case let strings as [String: Any] in table.values {
                if let value = strings["Start Listening"] as? String { labels.start.insert(normalize(value)) }
                if let value = strings["Listening…"] as? String { labels.listening.insert(normalize(value)) }
            }
            return labels.start.isEmpty || labels.listening.isEmpty ? nil : labels
        }

        static let system: MusicLabels = {
            guard let data = try? Data(contentsOf: loctable), let parsed = from(loctable: data) else { return builtIn }
            return MusicLabels(start: parsed.start.union(builtIn.start), listening: parsed.listening.union(builtIn.listening))
        }()

        /// Case-insensitive; "…", "⋯" and "..." compare equal.
        static func normalize(_ text: String) -> String {
            text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                .replacingOccurrences(of: "...", with: "…").replacingOccurrences(of: "⋯", with: "…")
        }
    }

    enum MusicStep<Element> {
        case listening
        case pressStart(Element)
        case pressModule(Element)
        /// The Recognize Music panel is open but has no single Start Listening button yet.
        case panelOpen
        case nothing
    }

    /// Pure decision over a Control Center AX snapshot. Only acts on a single,
    /// identified control; several candidates mean "don't press anything".
    static func musicStep<Element>(in windows: [Node<Element>], labels: MusicLabels = .system) -> MusicStep<Element> {
        func all(_ nodes: [Node<Element>]) -> [Node<Element>] { nodes.flatMap { [$0] + all($0.children) } }
        let nodes = all(windows)
        func named(_ node: Node<Element>, _ set: Set<String>) -> Bool {
            node.names.contains { set.contains(MusicLabels.normalize($0)) }
        }
        if nodes.contains(where: { named($0, labels.listening) }) { return .listening }
        func panelNodes(_ node: Node<Element>, inside: Bool) -> [Node<Element>] {
            let isPanel = inside || node.matches(musicPanel) || node.names.contains { $0.lowercased().hasPrefix("musicrecognition-") }
            return (isPanel ? [node] : []) + node.children.flatMap { panelNodes($0, inside: isPanel) }
        }
        // The header id is the panel's own; its parent window holds the button.
        let panelWindows = windows.filter { window in all([window]).contains { $0.matches(musicPanel) } }
        let scope = panelWindows.isEmpty ? windows.flatMap { panelNodes($0, inside: false) } : all(panelWindows)
        let starts = scope.filter { $0.pressable && named($0, labels.start) }
        if starts.count == 1 { return .pressStart(starts[0].element) }
        if !panelWindows.isEmpty || !scope.isEmpty { return .panelOpen }
        let modules = nodes.filter { $0.pressable && $0.matches(musicModule) }
        if modules.count == 1 { return .pressModule(modules[0].element) }
        return .nothing
    }

    /// Presses Control Center's own Recognize Music for the user. Called only
    /// from the user's button; macOS does the listening and shows the result.
    /// Uses AX identifiers/labels only — never screen coordinates.
    static func startMusicRecognition(labels: MusicLabels = .system) -> MusicRecognitionResult {
        guard hasAccess else { return .permissionNeeded }
        guard let process = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.controlcenter").first
        else { return .unavailable }
        let app = AXUIElementCreateApplication(process.processIdentifier)
        let client = Client(deadline: ProcessInfo.processInfo.systemUptime + 3)
        let actionable = musicModule.union(musicMenu).union(controlCenter).union(labels.start)
        func snapshot() -> [Node<AXUIElement>] { client.tree(client.windows(app), maxDepth: 14, maxNodes: 600, actionableLabels: actionable) }

        var pressedModule = false, pressedStart = false, openedMenu = false, pressedPinned = false
        while client.remaining > 0 {
            let nodes = snapshot()
            switch musicStep(in: nodes, labels: labels) {
            case .listening:
                return .listening
            case .pressStart(let button):
                if !pressedStart {
                    guard client.action(kAXPressAction, on: button) == .success else { return .unavailable }
                    pressedStart = true
                }
            case .pressModule(let module):
                if !pressedModule {
                    guard client.action(kAXPressAction, on: module) == .success else { return .unavailable }
                    pressedModule = true
                }
            case .panelOpen:
                break // Still loading; wait for the button or the listening state.
            case .nothing:
                // Something the user opened (e.g. another menu-bar popover) without our
                // control in it: leave it alone rather than toggling Control Center.
                if !openedMenu && !nodes.isEmpty { return .unavailable }
                if !openedMenu {
                    openedMenu = true
                    let menu = client.elements(app, kAXExtrasMenuBarAttribute) + client.elements(app, kAXMenuBarAttribute)
                    let entries = client.tree(menu, maxDepth: 4, actionableLabels: actionable)
                    let pinned = client.unique(musicMenu, in: entries)
                    guard let entry = pinned ?? client.unique(controlCenter, in: entries),
                          client.action(kAXPressAction, on: entry) == .success else { return .unavailable }
                    pressedPinned = pinned != nil
                }
            }
            let wait = min(client.remaining, 0.08)
            if wait > 0 { Thread.sleep(forTimeInterval: wait) }
        }
        if pressedStart || pressedModule || pressedPinned { return .uncertain }
        return openedMenu ? .notInControlCenter : .unavailable
    }

    /// Run on a worker queue: AX requests are synchronous cross-process calls.
    static func send(_ command: Command) -> Result {
        guard hasAccess else { return .permissionNeeded }
        guard let process = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.controlcenter").first
        else { return .unavailable }

        let ax = AXUIElementCreateApplication(process.processIdentifier)
        let client = Client(deadline: ProcessInfo.processInfo.systemUptime + 1.6)
        let initial = client.windows(ax)
        let initialNodes = client.tree(initial)
        if let button = target(for: command, in: initialNodes) {
            return client.send(button)
        }

        // Leave an existing panel alone unless it contains the explicitly
        // labelled Now Playing module. Never dismiss a panel the user opened.
        if !initial.isEmpty {
            guard let module = client.unique(nowPlaying, in: initialNodes),
                  client.action(kAXPressAction, on: module) == .success else { return .unavailable }
            return client.waitForTarget(command, app: ax, dedicated: false)
        }

        let menu = client.elements(ax, kAXExtrasMenuBarAttribute) + client.elements(ax, kAXMenuBarAttribute)
        let menuNodes = client.tree(menu, maxDepth: 3)
        let pinned = client.unique(nowPlaying, in: menuNodes)
        let entry = pinned ?? client.unique(controlCenter, in: menuNodes)
        guard let entry, client.action(kAXPressAction, on: entry) == .success else { return .unavailable }

        if pinned != nil {
            return client.waitForTarget(command, app: ax, dedicated: true, closeAfterSend: true)
        }
        return client.waitForTarget(command, app: ax, dedicated: false, openModule: true, closeAfterSend: true)
    }

    private struct Client {
        let deadline: TimeInterval
        var remaining: TimeInterval { deadline - ProcessInfo.processInfo.systemUptime }

        func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
            guard remaining > 0 else { return nil }
            var value: CFTypeRef?
            AXUIElementSetMessagingTimeout(element, Float(min(remaining, 0.12)))
            return AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success ? value : nil
        }

        func elements(_ element: AXUIElement, _ name: String) -> [AXUIElement] {
            guard let value = attribute(element, name) else { return [] }
            if CFGetTypeID(value) == AXUIElementGetTypeID() {
                // The Core Foundation type check above guarantees this downcast.
                return [value as! AXUIElement]
            }
            return value as? [AXUIElement] ?? []
        }

        func windows(_ app: AXUIElement) -> [AXUIElement] {
            var result = elements(app, kAXWindowsAttribute)
            for window in elements(app, kAXFocusedWindowAttribute) where !result.contains(window) {
                result.append(window)
            }
            return result
        }

        private func actions(_ element: AXUIElement) -> [String] {
            guard remaining > 0 else { return [] }
            AXUIElementSetMessagingTimeout(element, Float(min(remaining, 0.12)))
            var list: CFArray?
            guard AXUIElementCopyActionNames(element, &list) == .success else { return [] }
            return list as? [String] ?? []
        }

        func tree(_ roots: [AXUIElement], maxDepth: Int = 12, maxNodes: Int = 180,
                  actionableLabels: Set<String> = nowPlaying.union(controlCenter).union(playPause).union(next).union(previous)) -> [Node<AXUIElement>] {
            var seen = Set<AXUIElement>()
            let attributes = [kAXIdentifierAttribute, kAXTitleAttribute, kAXDescriptionAttribute,
                              kAXLabelValueAttribute, kAXEnabledAttribute, kAXChildrenAttribute, kAXValueAttribute]
            func visit(_ element: AXUIElement, depth: Int) -> Node<AXUIElement>? {
                guard depth <= maxDepth, remaining > 0, seen.count < maxNodes,
                      seen.insert(element).inserted else { return nil }
                AXUIElementSetMessagingTimeout(element, Float(min(remaining, 0.12)))
                var response: CFArray?
                guard AXUIElementCopyMultipleAttributeValues(element, attributes as CFArray, [], &response) == .success,
                      let values = response as? [Any], values.count == attributes.count else { return nil }
                // AXValue of static text carries states such as "Listening…". It is
                // matched against known labels only; nothing is stored or logged.
                let names = (Array(values.prefix(4)) + [values[6]]).compactMap { $0 as? String }
                let enabled = values[4] as? Bool ?? true
                let actionable = names.contains {
                    actionableLabels.contains($0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())
                }
                let pressable = enabled && actionable && actions(element).contains(kAXPressAction)
                let children = (values[5] as? [AXUIElement] ?? []).compactMap { visit($0, depth: depth + 1) }
                return Node(element: element, names: names, pressable: pressable, children: children)
            }
            return roots.compactMap { visit($0, depth: 0) }
        }

        func unique(_ labels: Set<String>, in roots: [Node<AXUIElement>]) -> AXUIElement? {
            func find(_ node: Node<AXUIElement>) -> [AXUIElement] {
                if node.pressable && node.matches(labels) { return [node.element] }
                return node.children.flatMap(find)
            }
            let candidates = roots.flatMap(find)
            return candidates.count == 1 ? candidates.first : nil
        }

        func action(_ name: String, on element: AXUIElement) -> AXError {
            guard remaining > 0 else { return .actionUnsupported }
            AXUIElementSetMessagingTimeout(element, Float(min(remaining, 0.2)))
            return AXUIElementPerformAction(element, name as CFString)
        }

        func send(_ button: AXUIElement) -> Result {
            switch action(kAXPressAction, on: button) {
            case .success: return .sent
            case .cannotComplete, .failure: return .uncertain
            default: return .unavailable
            }
        }

        func waitForTarget(_ command: Command, app: AXUIElement, dedicated: Bool,
                           openModule: Bool = false, closeAfterSend: Bool = false) -> Result {
            var shouldOpen = openModule
            while remaining > 0 {
                let nodes = tree(windows(app))
                if let button = target(for: command, in: nodes, openedDedicatedPanel: dedicated) {
                    let result = send(button)
                    if result == .sent && closeAfterSend && nodes.count == 1, let window = nodes.first?.element {
                        dismiss(window, in: app)
                    }
                    return result
                }
                if shouldOpen, let module = unique(nowPlaying, in: nodes) {
                    shouldOpen = false
                    if action(kAXPressAction, on: module) != .success { return .unavailable }
                }
                let wait = min(remaining, 0.07)
                if wait > 0 { Thread.sleep(forTimeInterval: wait) }
            }
            return .unavailable
        }

        private func dismiss(_ window: AXUIElement, in app: AXUIElement) {
            // Close only the popup we operated on, if it supports AXCancel.
            let cleanup = Client(deadline: ProcessInfo.processInfo.systemUptime + 0.2)
            guard cleanup.windows(app) == [window],
                  cleanup.actions(window).contains(kAXCancelAction) else { return }
            _ = cleanup.action(kAXCancelAction, on: window)
        }
    }
}
