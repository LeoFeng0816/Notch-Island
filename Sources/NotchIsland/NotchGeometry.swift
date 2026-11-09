import AppKit
import CoreGraphics

/// Physical (or virtual) notch geometry of one screen, in global screen coordinates.
///
/// Everything is derived from what the system reports for the screen at
/// runtime (safe-area inset and the two unobscured top areas); there is no
/// per-model table, so new or scaled resolutions adapt automatically.
struct NotchGeometry: Equatable {
    var screenFrame: NSRect
    var hasNotch: Bool
    /// Rect occupied by the hardware notch; on displays without one, a virtual
    /// rect of the same proportions centred in the menu bar.
    var notchRect: NSRect
    /// Display name reported by the system (e.g. "Built-in Retina Display").
    var screenName: String = ""
    var isBuiltIn: Bool = false

    var notchSize: CGSize { notchRect.size }

    /// Centre gap between the compact indicators on displays without a notch;
    /// also the idle hover target there. Nothing is drawn in it while idle.
    static let virtualNotchWidth: CGFloat = 110

    init(screen: NSScreen) {
        self = Self.compute(frame: screen.frame,
                            visibleFrame: screen.visibleFrame,
                            safeAreaTop: screen.safeAreaInsets.top,
                            leftArea: screen.auxiliaryTopLeftArea,
                            rightArea: screen.auxiliaryTopRightArea,
                            fallbackMenuBarHeight: NSStatusBar.system.thickness)
        screenName = screen.localizedName
        isBuiltIn = screen.displayID.map { CGDisplayIsBuiltin($0) != 0 } ?? false
    }

    init(screenFrame: NSRect, hasNotch: Bool, notchRect: NSRect) {
        self.screenFrame = screenFrame
        self.hasNotch = hasNotch
        self.notchRect = notchRect
    }

    /// Pure computation (unit-tested) from the values `NSScreen` reports.
    static func compute(frame: NSRect, visibleFrame: NSRect, safeAreaTop: CGFloat,
                        leftArea: NSRect?, rightArea: NSRect?,
                        fallbackMenuBarHeight: CGFloat) -> NotchGeometry {
        if safeAreaTop > 0, let left = leftArea, let right = rightArea,
           left.width > 0, right.width > 0 {
            // Preferred: the gap between the two areas, when they are reported in
            // this screen's global coordinates (they are on current macOS).
            let tolerance: CGFloat = 1
            let inScreenSpace = left.minX >= frame.minX - tolerance && right.maxX <= frame.maxX + tolerance
                && left.maxX < right.minX
            var minX: CGFloat
            var width: CGFloat
            if inScreenSpace {
                minX = left.maxX
                width = right.minX - left.maxX
            } else {
                // Otherwise rely on the widths only, which don't depend on the space.
                minX = frame.minX + left.width
                width = frame.width - left.width - right.width
            }
            // A notch is a narrow centre cut-out; reject implausible results
            // instead of drawing a huge island.
            if width > 0, width < frame.width * 0.6 {
                minX = max(frame.minX, minX)
                return NotchGeometry(screenFrame: frame, hasNotch: true,
                                     notchRect: NSRect(x: minX, y: frame.maxY - safeAreaTop,
                                                       width: width, height: safeAreaTop))
            }
        }

        var menuBarHeight = frame.maxY - visibleFrame.maxY
        if menuBarHeight < 18 || menuBarHeight > 60 {
            // Auto-hidden menu bar or Dock on top: fall back to the system value.
            menuBarHeight = fallbackMenuBarHeight
        }
        let width = virtualNotchWidth
        return NotchGeometry(screenFrame: frame, hasNotch: false,
                             notchRect: NSRect(x: frame.midX - width / 2,
                                               y: frame.maxY - menuBarHeight,
                                               width: width, height: menuBarHeight))
    }

    /// Prefer a built-in notched display, then any notched display, then the
    /// menu-bar screen (external monitor, lid closed, Mac without a notch).
    static func preferredScreen() -> NSScreen? {
        let notched = NSScreen.screens.filter { $0.safeAreaInsets.top > 0 }
        if let builtIn = notched.first(where: { $0.displayID.map { CGDisplayIsBuiltin($0) != 0 } ?? false }) {
            return builtIn
        }
        if let any = notched.first { return any }
        return NSScreen.screens.first ?? NSScreen.main
    }
}

extension NSScreen {
    var displayID: CGDirectDisplayID? {
        (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
    }
}
