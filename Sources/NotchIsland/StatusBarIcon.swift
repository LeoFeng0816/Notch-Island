import AppKit

/// Menu-bar icon: the Notch Island logo (rounded tile with the MacBook bezel and
/// notch, see `scripts/render_artwork.swift` / docs/notch-island-icon.png) as a
/// one-colour template image, so macOS draws it black or white for light/dark
/// menu bars, dims it when inactive and highlights it when the menu is open.
///
/// The logo's dark bezel on a light tile becomes a cut-out in a solid tile: on a
/// dark menu bar this reads exactly like the logo (light tile, dark bezel). At
/// 16 pt the logo's 35/1024 strokes would be ~0.6 pt and disappear, so the
/// bezel and notch are drawn thicker/deeper here (optical sizing only — the
/// shape, proportions and the downward fade of the sides are the logo's).
enum StatusBarIcon {
    /// Canvas and tile size in points. A filled tile reads heavier than outline
    /// symbols, so it's 14 pt: about the visual weight of the Wi-Fi/battery icons.
    static let canvas = NSSize(width: 18, height: 18)
    static let tile: CGFloat = 14

    static func image() -> NSImage {
        let image = NSImage(size: canvas, flipped: false) { rect in
            guard let context = NSGraphicsContext.current?.cgContext else { return false }
            draw(in: context, rect: rect)
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "Notch Island"
        return image
    }

    /// Draws into `rect` (y up). Shared by the app and the QA renderer.
    static func draw(in context: CGContext, rect: CGRect) {
        let side = min(rect.width, rect.height) * tile / canvas.width
        let origin = CGPoint(x: rect.midX - side / 2, y: rect.midY - side / 2)
        // Design space: the logo's 1024 grid, tile at 96…928.
        let scale = side / 832
        func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(x: origin.x + (x - 96) * scale, y: origin.y + (y - 96) * scale)
        }
        func r(_ x0: CGFloat, _ y0: CGFloat, _ x1: CGFloat, _ y1: CGFloat) -> CGRect {
            let a = p(x0, y0), b = p(x1, y1)
            return CGRect(x: a.x, y: a.y, width: b.x - a.x, height: b.y - a.y)
        }

        context.saveGState()
        // Tile: the logo's rounded square (corner 193 on 832).
        let tilePath = CGPath(roundedRect: r(96, 96, 928, 928), cornerWidth: 193 * scale, cornerHeight: 193 * scale, transform: nil)
        context.addPath(tilePath)
        context.setFillColor(NSColor.black.cgColor)
        context.fillPath()

        // Bezel: top edge with rounded outer corners, two sides that fade out
        // downwards (as in the logo) and the notch hanging from the top edge.
        let thickness: CGFloat = 76      // logo: ~36
        let top: CGFloat = 678, bottom: CGFloat = 292
        let left: CGFloat = 208, right: CGFloat = 816
        let notchHalfWidth: CGFloat = 118, notchDepth: CGFloat = 86 // logo: 94 / 53
        let pieces: [CGPath] = [
            CGPath(roundedRect: r(left, top - thickness, right, top), cornerWidth: 30 * scale, cornerHeight: 30 * scale, transform: nil),
            CGPath(rect: r(left, bottom, left + thickness, top - thickness / 2), transform: nil),
            CGPath(rect: r(right - thickness, bottom, right, top - thickness / 2), transform: nil),
            CGPath(roundedRect: r(512 - notchHalfWidth, top - thickness - notchDepth, 512 + notchHalfWidth, top - thickness / 2),
                   cornerWidth: 34 * scale, cornerHeight: 34 * scale, transform: nil),
        ]
        // Cut each piece separately (overlaps can't cancel out by winding direction).
        context.setBlendMode(.destinationOut)
        let colors = [NSColor.black.cgColor, NSColor.black.cgColor, NSColor.black.withAlphaComponent(0).cgColor] as CFArray
        let fade = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: colors, locations: [0, 0.45, 1])
        for piece in pieces {
            context.saveGState()
            context.addPath(piece)
            context.clip()
            if let fade {
                context.drawLinearGradient(fade, start: p(512, top), end: p(512, bottom),
                                           options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
            }
            context.restoreGState()
        }
        context.restoreGState()
    }
}
