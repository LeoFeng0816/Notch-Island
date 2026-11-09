import AppKit
import ApplicationServices

/// Operates the actual transport in a running Chrome YouTube Music web app.
/// Used only for a user's skip press in the opt-in Accessibility mode.
enum YouTubeMusicTransport {
    enum Direction { case previous, next }
    enum Result { case unavailable, blocked, sent, uncertain }

    struct Control {
        let role: String
        let classes: [String]
        let enabled: Bool
    }

    private static let playClass = "ytmusicPlayerControlsPlayPauseButton"

    static func skipButtonIndex(for direction: Direction, in controls: [Control]) -> Int? {
        let anchors = controls.indices.filter { controls[$0].classes.contains(playClass) }
        guard anchors.count == 1, let play = anchors.first,
              controls[play].role == kAXGroupRole,
              play > 0, play + 1 < controls.count,
              controls[play - 1].role == kAXButtonRole, controls[play + 1].role == kAXButtonRole,
              controls.filter({ $0.role == kAXButtonRole }).count == 2 else { return nil }
        let index = direction == .previous ? play - 1 : play + 1
        return controls[index].enabled ? index : nil
    }

    static func send(_ direction: Direction, expectedTitle: String? = nil) -> Result {
        guard ControlCenterMedia.hasAccess else { return .unavailable }
        let apps = BrowserMedia.youtubeMusicApps()
        guard !apps.isEmpty else { return .unavailable }
        guard apps.count == 1, let process = apps.first else { return .blocked }
        let ax = AXUIElementCreateApplication(process.processIdentifier)
        let reader = Reader(deadline: ProcessInfo.processInfo.systemUptime + 1.2)
        guard let windows = reader.children(of: ax, attribute: kAXWindowsAttribute),
              let pages = reader.find(in: windows, depth: 12, matching: { $0.role == "AXWebArea" }) else { return .blocked }
        let music = pages.filter { page in
            guard let url = reader.read(page.element, [kAXURLAttribute])?.first else { return false }
            return (url as? URL).map { BrowserMedia.site(for: $0.absoluteString) == .youtubeMusic } ?? false
        }
        guard music.count == 1, let page = music.first,
              let mini = reader.find(in: page.children, depth: 4, matching: { $0.classes.contains("ytMusicMiniPlayerHost") }),
              mini.count == 1, let player = mini.first,
              let groups = reader.nodes(player.children),
              let info = groups.only(withClass: "ytmusicTrackInfoHost"),
              let infoChildren = reader.nodes(info.children),
              let title = infoChildren.only(withClass: "ytmusicTrackInfoTitle"),
              let text = title.children.first.flatMap({ reader.read($0, [kAXValueAttribute])?.first as? String }),
              !text.isEmpty,
              let group = groups.only(withClass: "ytmusicPlayerControlsHost"),
              let controls = reader.nodes(group.children),
              let index = skipButtonIndex(for: direction, in: controls.map(\.control)) else { return .blocked }

        if let expectedTitle {
            guard text == expectedTitle else { return .blocked }
        } else {
            // Without a readable browser tab, require an active web app before
            // giving it priority over macOS's system-wide controls.
            guard let play = controls.only(withClass: playClass)?.children.first,
                  let caption = reader.read(play, [kAXDescriptionAttribute])?.first as? String,
                  ["pause", "暫停", "暂停"].contains(caption.lowercased()) else { return .unavailable }
        }

        let button = controls[index].element
        guard reader.prepare(button) else { return .blocked }
        var actions: CFArray?
        guard AXUIElementCopyActionNames(button, &actions) == .success,
              (actions as? [String])?.contains(kAXPressAction) == true,
              reader.prepare(button) else { return .blocked }
        switch AXUIElementPerformAction(button, kAXPressAction as CFString) {
        case .success: return .sent
        // The action was attempted. Another route could skip a second track.
        default: return .uncertain
        }
    }

    fileprivate struct Node {
        let element: AXUIElement
        let control: Control
        let children: [AXUIElement]
        var role: String { control.role }
        var classes: [String] { control.classes }
    }

    private struct Reader {
        let deadline: TimeInterval

        func prepare(_ element: AXUIElement) -> Bool {
            let remaining = deadline - ProcessInfo.processInfo.systemUptime
            guard remaining > 0 else { return false }
            AXUIElementSetMessagingTimeout(element, Float(min(remaining, 0.12)))
            return true
        }

        func read(_ element: AXUIElement, _ attributes: [String]) -> [Any]? {
            guard prepare(element) else { return nil }
            var response: CFArray?
            guard AXUIElementCopyMultipleAttributeValues(element, attributes as CFArray, [], &response) == .success,
                  let values = response as? [Any], values.count == attributes.count else { return nil }
            return values
        }

        func children(of element: AXUIElement, attribute: String) -> [AXUIElement]? {
            read(element, [attribute])?.first as? [AXUIElement]
        }

        func node(_ element: AXUIElement) -> Node? {
            guard let values = read(element, [kAXRoleAttribute, "AXDOMClassList", kAXEnabledAttribute, kAXChildrenAttribute]),
                  let role = values[0] as? String else { return nil }
            return Node(element: element,
                        control: .init(role: role, classes: values[1] as? [String] ?? [], enabled: values[2] as? Bool ?? false),
                        children: values[3] as? [AXUIElement] ?? [])
        }

        func nodes(_ elements: [AXUIElement]) -> [Node]? {
            let nodes = elements.compactMap(node)
            return nodes.count == elements.count ? nodes : nil
        }

        /// Breadth first, with a strict budget and no descent into a matching
        /// web area/player. A failed or incomplete scan can't pick a button.
        func find(in roots: [AXUIElement], depth: Int, matching predicate: (Node) -> Bool) -> [Node]? {
            var level = roots
            var results: [Node] = []
            var seen = Set<AXUIElement>()
            for _ in 0...depth where !level.isEmpty {
                var next: [AXUIElement] = []
                for element in level where seen.insert(element).inserted {
                    guard seen.count <= 400, let node = node(element) else { return nil }
                    if predicate(node) { results.append(node) }
                    else { next.append(contentsOf: node.children) }
                }
                level = next
            }
            return results
        }
    }
}

private extension Array where Element == YouTubeMusicTransport.Node {
    func only(withClass name: String) -> Element? {
        let matches = filter { $0.classes.contains(name) }
        return matches.count == 1 ? matches.first : nil
    }
}
