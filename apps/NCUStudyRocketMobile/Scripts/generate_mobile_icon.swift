import AppKit

guard CommandLine.arguments.count == 3 else {
    fputs("usage: generate_mobile_icon.swift <source-image> <output.png>\n", stderr)
    exit(64)
}

let sourceURL = URL(fileURLWithPath: CommandLine.arguments[1])
let outputURL = URL(fileURLWithPath: CommandLine.arguments[2])
guard let source = NSImage(contentsOf: sourceURL) else {
    throw NSError(domain: "NCUStudyRocketMobileIcon", code: 1)
}

// App icons must be opaque. The supplied product mark already carries its
// background, and this fallback also keeps future transparent sources valid.
let background = NSColor(srgbRed: 40 / 255, green: 78 / 255, blue: 109 / 255, alpha: 1)
let pixelSize = 1024
guard let context = CGContext(
    data: nil,
    width: pixelSize,
    height: pixelSize,
    bitsPerComponent: 8,
    bytesPerRow: 0,
    space: CGColorSpaceCreateDeviceRGB(),
    bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
) else {
    throw NSError(domain: "NCUStudyRocketMobileIcon", code: 2)
}
let graphicsContext = NSGraphicsContext(cgContext: context, flipped: false)
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = graphicsContext
background.setFill()
NSRect(x: 0, y: 0, width: pixelSize, height: pixelSize).fill()
source.draw(
    in: NSRect(x: 0, y: 0, width: pixelSize, height: pixelSize),
    from: NSRect(origin: .zero, size: source.size),
    operation: .sourceOver,
    fraction: 1
)
NSGraphicsContext.restoreGraphicsState()

try FileManager.default.createDirectory(at: outputURL.deletingLastPathComponent(), withIntermediateDirectories: true)
guard let image = context.makeImage(),
      let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else {
    throw NSError(domain: "NCUStudyRocketMobileIcon", code: 3)
}
try png.write(to: outputURL)
