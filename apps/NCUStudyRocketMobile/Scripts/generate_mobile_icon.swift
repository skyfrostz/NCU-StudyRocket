import AppKit

guard CommandLine.arguments.count == 3 else {
    fputs("usage: generate_mobile_icon.swift <source.icns> <output.png>\n", stderr)
    exit(64)
}

let sourceURL = URL(fileURLWithPath: CommandLine.arguments[1])
let outputURL = URL(fileURLWithPath: CommandLine.arguments[2])
guard let source = NSImage(contentsOf: sourceURL),
      let sourceRep = source.representations.compactMap({ $0 as? NSBitmapImageRep }).first else {
    throw NSError(domain: "NCUStudyRocketMobileIcon", code: 1)
}

// The original icon uses this solid blue behind its rounded artwork. Filling
// the transparent corners with the same color keeps the iOS asset opaque
// without introducing a visible halo around the source icon.
let background = NSColor(srgbRed: 40 / 255, green: 78 / 255, blue: 109 / 255, alpha: 1)
let pixelSize = 1024
let image = NSImage(size: NSSize(width: pixelSize, height: pixelSize))
image.lockFocus()
background.setFill()
NSRect(x: 0, y: 0, width: pixelSize, height: pixelSize).fill()
source.draw(
    in: NSRect(x: 0, y: 0, width: pixelSize, height: pixelSize),
    from: NSRect(origin: .zero, size: source.size),
    operation: .sourceOver,
    fraction: 1
)
image.unlockFocus()

try FileManager.default.createDirectory(at: outputURL.deletingLastPathComponent(), withIntermediateDirectories: true)
guard let tiff = image.tiffRepresentation,
      let bitmap = NSBitmapImageRep(data: tiff),
      let png = bitmap.representation(using: NSBitmapImageRep.FileType.png, properties: [:]) else {
    throw NSError(domain: "NCUStudyRocketMobileIcon", code: 2)
}
try png.write(to: outputURL)
