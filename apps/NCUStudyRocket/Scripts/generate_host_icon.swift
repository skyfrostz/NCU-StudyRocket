import AppKit

guard CommandLine.arguments.count == 2 else {
    fputs("usage: generate_host_icon.swift <iconset-directory>\n", stderr)
    exit(64)
}

let iconset = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

let variants: [(name: String, pixels: Int)] = [
    ("icon_16x16.png", 16), ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32), ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128), ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256), ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512), ("icon_512x512@2x.png", 1024)
]

for variant in variants {
    let size = CGFloat(variant.pixels)
    let image = NSImage(size: NSSize(width: size, height: size))
    image.lockFocus()
    let bounds = NSRect(x: 0, y: 0, width: size, height: size)
    NSColor(srgbRed: 0.035, green: 0.125, blue: 0.16, alpha: 1).setFill()
    NSBezierPath(roundedRect: bounds.insetBy(dx: size * 0.035, dy: size * 0.035), xRadius: size * 0.22, yRadius: size * 0.22).fill()

    // A terminal window distinguishes the Mac-side Host from the main StudyRocket app.
    let terminal = NSRect(x: size * 0.14, y: size * 0.19, width: size * 0.72, height: size * 0.62)
    let terminalPath = NSBezierPath(roundedRect: terminal, xRadius: size * 0.075, yRadius: size * 0.075)
    NSColor(srgbRed: 0.055, green: 0.19, blue: 0.23, alpha: 1).setFill()
    terminalPath.fill()
    NSColor(srgbRed: 0.30, green: 0.62, blue: 0.64, alpha: 0.62).setStroke()
    terminalPath.lineWidth = max(1, size * 0.014)
    terminalPath.stroke()

    NSColor(srgbRed: 0.15, green: 0.82, blue: 0.84, alpha: 1).setFill()
    for multiplier in [0.29, 0.35, 0.41] {
        NSBezierPath(ovalIn: NSRect(x: size * multiplier, y: size * 0.72, width: size * 0.035, height: size * 0.035)).fill()
    }

    let prompt = NSBezierPath()
    prompt.move(to: CGPoint(x: size * 0.27, y: size * 0.54))
    prompt.line(to: CGPoint(x: size * 0.37, y: size * 0.47))
    prompt.line(to: CGPoint(x: size * 0.27, y: size * 0.40))
    NSColor.white.setStroke()
    prompt.lineWidth = max(1.5, size * 0.027)
    prompt.lineCapStyle = .round
    prompt.lineJoinStyle = .round
    prompt.stroke()
    let cursor = NSBezierPath()
    cursor.move(to: CGPoint(x: size * 0.43, y: size * 0.39))
    cursor.line(to: CGPoint(x: size * 0.58, y: size * 0.39))
    cursor.lineWidth = max(1.5, size * 0.027)
    cursor.lineCapStyle = .round
    cursor.stroke()

    let nodes = [CGPoint(x: size * 0.53, y: size * 0.27), CGPoint(x: size * 0.66, y: size * 0.16), CGPoint(x: size * 0.78, y: size * 0.31)]
    let rail = NSBezierPath()
    rail.move(to: nodes[0]); rail.line(to: nodes[1]); rail.line(to: nodes[2])
    NSColor(srgbRed: 0.15, green: 0.82, blue: 0.84, alpha: 1).setStroke()
    rail.lineWidth = max(2, size * 0.045)
    rail.lineCapStyle = .round
    rail.stroke()
    for point in nodes {
        NSColor(srgbRed: 0.15, green: 0.82, blue: 0.84, alpha: 1).setFill()
        NSBezierPath(ovalIn: NSRect(x: point.x - size * 0.045, y: point.y - size * 0.045, width: size * 0.09, height: size * 0.09)).fill()
    }
    let check = NSBezierPath()
    check.move(to: CGPoint(x: size * 0.59, y: size * 0.22))
    check.line(to: CGPoint(x: size * 0.65, y: size * 0.16))
    check.line(to: CGPoint(x: size * 0.76, y: size * 0.27))
    NSColor.white.setStroke()
    check.lineWidth = max(2, size * 0.055)
    check.lineCapStyle = .round
    check.lineJoinStyle = .round
    check.stroke()
    image.unlockFocus()

    guard let tiff = image.tiffRepresentation,
          let bitmap = NSBitmapImageRep(data: tiff),
          let png = bitmap.representation(using: .png, properties: [:]) else {
        throw NSError(domain: "StudyRocketHostIcon", code: 1)
    }
    try png.write(to: iconset.appendingPathComponent(variant.name))
}
