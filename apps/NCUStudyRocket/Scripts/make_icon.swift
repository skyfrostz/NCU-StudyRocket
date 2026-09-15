import AppKit
import CoreGraphics
import Foundation

let fm = FileManager.default
let buildDirectory = URL(fileURLWithPath: CommandLine.arguments[1])
let projectRoot = buildDirectory.deletingLastPathComponent()
let sourceURL = projectRoot.appendingPathComponent("Assets/NCUStudyRocketLogo.png")
guard let source = NSImage(contentsOf: sourceURL) else {
    throw NSError(domain: "NCUStudyRocketIcon", code: 1, userInfo: [NSLocalizedDescriptionKey: "Missing logo source at \(sourceURL.path)"])
}
let iconset = buildDirectory.appendingPathComponent("NCUStudyRocket.iconset")
try? fm.removeItem(at: iconset)
try fm.createDirectory(at: iconset, withIntermediateDirectories: true)
let sourceRect = NSRect(origin: .zero, size: source.size)
let sizes = [(16, "icon_16x16"), (32, "icon_16x16@2x"), (32, "icon_32x32"), (64, "icon_32x32@2x"), (128, "icon_128x128"), (256, "icon_128x128@2x"), (256, "icon_256x256"), (512, "icon_256x256@2x"), (512, "icon_512x512"), (1024, "icon_512x512@2x")]
for (size, name) in sizes {
    let image = NSImage(size: NSSize(width: size, height: size))
    image.lockFocus()
    source.draw(
        in: NSRect(x: 0, y: 0, width: size, height: size),
        from: sourceRect,
        operation: .sourceOver,
        fraction: 1
    )
    image.unlockFocus()
    guard let tiff = image.tiffRepresentation,
          let rep = NSBitmapImageRep(data: tiff),
          let png = rep.representation(using: .png, properties: [:]) else {
        continue
    }
    try png.write(to: iconset.appendingPathComponent(name + ".png"))
}
print(iconset.path)
