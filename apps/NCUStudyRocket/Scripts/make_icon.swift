import AppKit
import CoreGraphics
import Foundation

let fm = FileManager.default
let root = URL(fileURLWithPath: CommandLine.arguments[1])
let iconset = root.appendingPathComponent("NCUStudyRocket.iconset")
try? fm.removeItem(at: iconset)
try fm.createDirectory(at: iconset, withIntermediateDirectories: true)
let sizes = [(16, "icon_16x16"), (32, "icon_16x16@2x"), (32, "icon_32x32"), (64, "icon_32x32@2x"), (128, "icon_128x128"), (256, "icon_128x128@2x"), (256, "icon_256x256"), (512, "icon_256x256@2x"), (512, "icon_512x512"), (1024, "icon_512x512@2x")]
for (size, name) in sizes {
    let image = NSImage(size: NSSize(width: size, height: size)); image.lockFocus()
    NSColor(calibratedRed: 0.08, green: 0.24, blue: 0.36, alpha: 1).setFill(); NSBezierPath(roundedRect: NSRect(x: 0, y: 0, width: size, height: size), xRadius: CGFloat(size) * 0.2, yRadius: CGFloat(size) * 0.2).fill()
    NSColor(calibratedRed: 0.13, green: 0.62, blue: 0.63, alpha: 1).setStroke(); let orbit = NSBezierPath(ovalIn: NSRect(x: CGFloat(size) * 0.18, y: CGFloat(size) * 0.29, width: CGFloat(size) * 0.64, height: CGFloat(size) * 0.42)); orbit.lineWidth = CGFloat(size) * 0.07; orbit.stroke()
    NSColor.white.setStroke(); let check = NSBezierPath(); check.move(to: NSPoint(x: CGFloat(size) * 0.30, y: CGFloat(size) * 0.48)); check.line(to: NSPoint(x: CGFloat(size) * 0.44, y: CGFloat(size) * 0.36)); check.line(to: NSPoint(x: CGFloat(size) * 0.70, y: CGFloat(size) * 0.64)); check.lineWidth = CGFloat(size) * 0.075; check.lineCapStyle = .round; check.lineJoinStyle = .round; check.stroke()
    image.unlockFocus(); guard let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff), let png = rep.representation(using: .png, properties: [:]) else { continue }; try png.write(to: iconset.appendingPathComponent(name + ".png"))
}
print(iconset.path)
