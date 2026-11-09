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
    // A quiet gradient tile and one silhouette keep the notch recognizable at small sizes.
    gradient(context, rounded(96, 96, 832, 832, 193), [color(0xB4EDFA), color(0x9B9EF5)],
             from: CGPoint(x: 136, y: 928), to: CGPoint(x: 894, y: 96))

    let bezel = CGMutablePath()
    bezel.move(to: CGPoint(x: 270, y: 678))
    bezel.addLine(to: CGPoint(x: 754, y: 678))
    bezel.addCurve(to: CGPoint(x: 816, y: 616), control1: CGPoint(x: 791, y: 678), control2: CGPoint(x: 816, y: 653))
    bezel.addLine(to: CGPoint(x: 816, y: 292))
    bezel.addLine(to: CGPoint(x: 781, y: 292))
    bezel.addLine(to: CGPoint(x: 781, y: 609))
    bezel.addCurve(to: CGPoint(x: 750, y: 640), control1: CGPoint(x: 781, y: 628), control2: CGPoint(x: 769, y: 640))
    bezel.addLine(to: CGPoint(x: 622, y: 640))
    bezel.addCurve(to: CGPoint(x: 606, y: 624), control1: CGPoint(x: 612, y: 640), control2: CGPoint(x: 606, y: 634))
    bezel.addCurve(to: CGPoint(x: 568, y: 587), control1: CGPoint(x: 606, y: 603), control2: CGPoint(x: 589, y: 587))
    bezel.addLine(to: CGPoint(x: 456, y: 587))
    bezel.addCurve(to: CGPoint(x: 418, y: 624), control1: CGPoint(x: 435, y: 587), control2: CGPoint(x: 418, y: 603))
    bezel.addCurve(to: CGPoint(x: 402, y: 640), control1: CGPoint(x: 418, y: 634), control2: CGPoint(x: 412, y: 640))
    bezel.addLine(to: CGPoint(x: 274, y: 640))
    bezel.addCurve(to: CGPoint(x: 243, y: 609), control1: CGPoint(x: 255, y: 640), control2: CGPoint(x: 243, y: 628))
    bezel.addLine(to: CGPoint(x: 243, y: 292))
    bezel.addLine(to: CGPoint(x: 208, y: 292))
    bezel.addLine(to: CGPoint(x: 208, y: 616))
    bezel.addCurve(to: CGPoint(x: 270, y: 678), control1: CGPoint(x: 208, y: 653), control2: CGPoint(x: 233, y: 678))
    bezel.closeSubpath()
    gradient(context, bezel, [color(0x071231), color(0x071231), color(0x071231, alpha: 0)],
             from: CGPoint(x: 512, y: 678), to: CGPoint(x: 512, y: 292))
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
