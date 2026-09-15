import AppKit

guard CommandLine.arguments.count == 3 else {
    fputs("usage: generate_host_icon.swift <logo-source> <iconset-directory>\n", stderr)
    exit(64)
}

let sourceURL = URL(fileURLWithPath: CommandLine.arguments[1])
let iconset = URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true)
guard let source = NSImage(contentsOf: sourceURL) else {
    throw NSError(domain: "StudyRocketHostIcon", code: 1, userInfo: [NSLocalizedDescriptionKey: "Unable to load logo source at \(sourceURL.path)"])
}
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
let sourceRect = NSRect(origin: .zero, size: source.size)

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
    source.draw(in: bounds, from: sourceRect, operation: .sourceOver, fraction: 1)

    // Keep the Host recognizable as the Mac-side companion while sharing the product mark.
    let terminal = NSRect(x: size * 0.58, y: size * 0.10, width: size * 0.30, height: size * 0.22)
    let terminalPath = NSBezierPath(roundedRect: terminal, xRadius: size * 0.045, yRadius: size * 0.045)
    NSColor(srgbRed: 0.015, green: 0.08, blue: 0.18, alpha: 0.82).setFill()
    terminalPath.fill()
    NSColor.white.withAlphaComponent(0.50).setStroke()
    terminalPath.lineWidth = max(1, size * 0.010)
    terminalPath.stroke()

    let prompt = NSBezierPath()
    prompt.move(to: CGPoint(x: size * 0.64, y: size * 0.23))
    prompt.line(to: CGPoint(x: size * 0.69, y: size * 0.19))
    prompt.line(to: CGPoint(x: size * 0.64, y: size * 0.15))
    NSColor.white.setStroke()
    prompt.lineWidth = max(1.25, size * 0.020)
    prompt.lineCapStyle = .round
    prompt.lineJoinStyle = .round
    prompt.stroke()
    let cursor = NSBezierPath()
    cursor.move(to: CGPoint(x: size * 0.73, y: size * 0.15))
    cursor.line(to: CGPoint(x: size * 0.82, y: size * 0.15))
    cursor.lineWidth = max(1.25, size * 0.020)
    cursor.lineCapStyle = .round
    cursor.stroke()
    image.unlockFocus()

    guard let tiff = image.tiffRepresentation,
          let bitmap = NSBitmapImageRep(data: tiff),
          let png = bitmap.representation(using: .png, properties: [:]) else {
        throw NSError(domain: "StudyRocketHostIcon", code: 2)
    }
    try png.write(to: iconset.appendingPathComponent(variant.name))
}
