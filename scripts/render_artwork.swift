import AppKit

let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!

func color(_ hex: UInt32, alpha: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 255) / 255,
            green: CGFloat((hex >> 8) & 255) / 255,
            blue: CGFloat(hex & 255) / 255, alpha: alpha)
}

func rounded(_ x: CGFloat, _ y: CGFloat, _ width: CGFloat, _ height: CGFloat, _ radius: CGFloat) -> CGPath {
    CGPath(roundedRect: CGRect(x: x, y: y, width: width, height: height),
           cornerWidth: radius, cornerHeight: radius, transform: nil)
}

func fill(_ context: CGContext, _ path: CGPath, _ value: CGColor) {
    context.addPath(path)
    context.setFillColor(value)
    context.fillPath()
}

func gradient(_ context: CGContext, _ path: CGPath, _ colors: [CGColor], from: CGPoint, to: CGPoint) {
    context.saveGState()
    context.addPath(path)
    context.clip()
    let fill = CGGradient(colorsSpace: sRGB, colors: colors as CFArray, locations: nil)!
    context.drawLinearGradient(fill, start: from, end: to, options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
    context.restoreGState()
}

func drawIcon(_ context: CGContext) {
    context.saveGState()
    context.setShadow(offset: CGSize(width: 0, height: -12), blur: 28, color: color(0x193858, alpha: 0.30))
    fill(context, rounded(96, 96, 832, 832, 193), color(0xACC7E5))
    context.restoreGState()
    gradient(context, rounded(96, 96, 832, 832, 193), [color(0xF6FAFF), color(0xAED0FF), color(0x769FE1)],
             from: CGPoint(x: 226, y: 917), to: CGPoint(x: 796, y: 103))
    fill(context, rounded(143, 155, 738, 36, 18), color(0x40628D, alpha: 0.20))

    // The high-contrast laptop silhouette stays legible at 16 pt.
    fill(context, rounded(199, 290, 626, 448, 47), color(0x111B2B))
    gradient(context, rounded(220, 312, 584, 404, 29), [color(0x91D7F5), color(0x6AA5F4), color(0x274B9C)],
             from: CGPoint(x: 298, y: 725), to: CGPoint(x: 721, y: 323))

    // Hardware cutout meets the top bezel. The island expands just below it.
    let notch = CGMutablePath()
    notch.move(to: CGPoint(x: 395, y: 722))
    notch.addQuadCurve(to: CGPoint(x: 413, y: 698), control: CGPoint(x: 413, y: 722))
    notch.addQuadCurve(to: CGPoint(x: 435, y: 676), control: CGPoint(x: 413, y: 676))
    notch.addLine(to: CGPoint(x: 589, y: 676))
    notch.addQuadCurve(to: CGPoint(x: 611, y: 698), control: CGPoint(x: 611, y: 676))
    notch.addQuadCurve(to: CGPoint(x: 629, y: 722), control: CGPoint(x: 611, y: 722))
    notch.closeSubpath()
    fill(context, notch, color(0x111B2B))
    fill(context, rounded(505, 692, 14, 14, 7), color(0x587A9B))

    gradient(context, rounded(323, 574, 378, 90, 42), [color(0x263651), color(0x101927)],
             from: CGPoint(x: 511, y: 664), to: CGPoint(x: 511, y: 574))
    fill(context, rounded(350, 596, 52, 46, 13), color(0x83C8FC))
    fill(context, rounded(420, 625, 91, 10, 5), color(0xEFF7FF))
    fill(context, rounded(420, 604, 63, 8, 4), color(0x9CB3D4))
    for (index, height) in [18.0, 33.0, 24.0, 13.0].enumerated() {
        fill(context, rounded(596 + CGFloat(index) * 18, 619 - height / 2, 9, height, 4.5), color(0x8AD9FD))
    }

    fill(context, rounded(159, 265, 706, 36, 18), color(0x19283C))
    fill(context, rounded(450, 280, 124, 13, 6.5), color(0xB1CAE6))
}

func label(_ string: String, at origin: CGPoint, size: CGFloat, weight: NSFont.Weight, ink: UInt32) {
    (string as NSString).draw(at: origin, withAttributes: [
        .font: NSFont.systemFont(ofSize: size, weight: weight),
        .foregroundColor: NSColor(cgColor: color(ink))!,
    ])
}

func drawInstaller(_ context: CGContext) {
    let background = CGPath(rect: CGRect(x: 0, y: 0, width: 620, height: 360), transform: nil)
    gradient(context, background, [color(0xF6F9FE), color(0xDEE9F9)],
             from: CGPoint(x: 40, y: 360), to: CGPoint(x: 590, y: 0))

    let header = CGPath(rect: CGRect(x: 0, y: 238, width: 620, height: 122), transform: nil)
    gradient(context, header, [color(0x14223A), color(0x263D65)],
             from: CGPoint(x: 0, y: 360), to: CGPoint(x: 620, y: 238))
    fill(context, rounded(33, 321, 24, 3, 1.5), color(0x8ED9FF))
    label("Notch Island", at: CGPoint(x: 33, y: 275), size: 35, weight: .bold, ink: 0xFFFFFF)
    label("Drag the app to Applications", at: CGPoint(x: 34, y: 252), size: 14, weight: .medium, ink: 0xCDDEF4)

    let arrow = CGMutablePath()
    arrow.move(to: CGPoint(x: 262, y: 137))
    arrow.addLine(to: CGPoint(x: 355, y: 137))
    arrow.move(to: CGPoint(x: 340, y: 152))
    arrow.addLine(to: CGPoint(x: 355, y: 137))
    arrow.addLine(to: CGPoint(x: 340, y: 122))
    context.addPath(arrow)
    context.setStrokeColor(color(0x365986))
    context.setLineWidth(3)
    context.setLineCap(.round)
    context.setLineJoin(.round)
    context.strokePath()
}

func render(width: Int, height: Int, scale: Int, to output: URL, draw: (CGContext) -> Void) throws {
    let context = CGContext(data: nil, width: width * scale, height: height * scale,
                            bitsPerComponent: 8, bytesPerRow: 0, space: sRGB,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    context.scaleBy(x: CGFloat(scale), y: CGFloat(scale))
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
    draw(context)
    NSGraphicsContext.restoreGraphicsState()
    let bitmap = NSBitmapImageRep(cgImage: context.makeImage()!)
    try bitmap.representation(using: .png, properties: [:])!.write(to: output)
}

let args = CommandLine.arguments
guard args.count == 3 else {
    fatalError("Usage: swift scripts/render_artwork.swift icon|installer output-directory")
}
let output = URL(fileURLWithPath: args[2], isDirectory: true)
try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
switch args[1] {
case "icon":
    for size in [16, 32, 128, 256, 512] {
        for scale in [1, 2] {
            let pixels = size * scale
            let filename = "icon_\(size)x\(size)\(scale == 2 ? "@2x" : "").png"
            try render(width: pixels, height: pixels, scale: 1, to: output.appendingPathComponent(filename)) { context in
                let factor = CGFloat(pixels) / 1024
                context.scaleBy(x: factor, y: factor)
                drawIcon(context)
            }
        }
    }
case "installer":
    for scale in [1, 2] {
        let suffix = scale == 2 ? "@2x" : ""
        let filename = "installer\(suffix).png"
        try render(width: 620, height: 360, scale: scale, to: output.appendingPathComponent(filename), draw: drawInstaller)
    }
default:
    fatalError("Choose icon or installer")
}
