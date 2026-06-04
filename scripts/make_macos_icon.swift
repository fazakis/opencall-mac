import AppKit
import Foundation

let outDir = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? "build/icon-output")
try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
let iconset = outDir.appendingPathComponent("OpenCall.iconset", isDirectory: true)
try? FileManager.default.removeItem(at: iconset)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

func phonePath() -> NSBezierPath {
    let p = NSBezierPath()
    p.move(to: NSPoint(x: 6.62, y: 10.79))
    p.curve(to: NSPoint(x: 13.21, y: 17.38), controlPoint1: NSPoint(x: 8.06, y: 13.62), controlPoint2: NSPoint(x: 10.38, y: 15.93))
    p.line(to: NSPoint(x: 15.41, y: 15.18))
    p.curve(to: NSPoint(x: 16.43, y: 14.94), controlPoint1: NSPoint(x: 15.68, y: 14.91), controlPoint2: NSPoint(x: 16.08, y: 14.82))
    p.curve(to: NSPoint(x: 20, y: 15.5), controlPoint1: NSPoint(x: 17.55, y: 15.31), controlPoint2: NSPoint(x: 18.75, y: 15.5))
    p.curve(to: NSPoint(x: 21, y: 16.5), controlPoint1: NSPoint(x: 20.55, y: 15.5), controlPoint2: NSPoint(x: 21, y: 15.95))
    p.line(to: NSPoint(x: 21, y: 20))
    p.curve(to: NSPoint(x: 20, y: 21), controlPoint1: NSPoint(x: 21, y: 20.55), controlPoint2: NSPoint(x: 20.55, y: 21))
    p.curve(to: NSPoint(x: 3, y: 4), controlPoint1: NSPoint(x: 10.61, y: 21), controlPoint2: NSPoint(x: 3, y: 13.39))
    p.curve(to: NSPoint(x: 4, y: 3), controlPoint1: NSPoint(x: 3, y: 3.45), controlPoint2: NSPoint(x: 3.45, y: 3))
    p.line(to: NSPoint(x: 7.5, y: 3))
    p.curve(to: NSPoint(x: 8.5, y: 4), controlPoint1: NSPoint(x: 8.05, y: 3), controlPoint2: NSPoint(x: 8.5, y: 3.45))
    p.curve(to: NSPoint(x: 9.06, y: 7.57), controlPoint1: NSPoint(x: 8.5, y: 5.25), controlPoint2: NSPoint(x: 8.69, y: 6.45))
    p.curve(to: NSPoint(x: 8.81, y: 8.59), controlPoint1: NSPoint(x: 9.17, y: 7.92), controlPoint2: NSPoint(x: 9.09, y: 8.31))
    p.line(to: NSPoint(x: 6.62, y: 10.79))
    p.close()
    return p
}

func drawIcon(size: CGFloat) -> NSImage {
    let image = NSImage(size: NSSize(width: size, height: size))
    image.lockFocus()
    NSGraphicsContext.current?.imageInterpolation = .high

    let rect = NSRect(x: 0, y: 0, width: size, height: size)
    NSColor(calibratedRed: 37/255, green: 99/255, blue: 235/255, alpha: 1).setFill()
    NSBezierPath(ovalIn: rect.insetBy(dx: size * 0.04, dy: size * 0.04)).fill()
    NSColor(calibratedRed: 96/255, green: 165/255, blue: 250/255, alpha: 0.35).setFill()
    NSBezierPath(ovalIn: rect.insetBy(dx: size * 0.18, dy: size * 0.18)).fill()

    let path = phonePath()
    var transform = AffineTransform()
    transform.translate(x: size * 0.20, y: size * 0.20)
    transform.scale(size * 0.028)
    path.transform(using: transform)
    NSColor.white.setFill()
    path.fill()

    image.unlockFocus()
    return image
}

func writePNG(_ image: NSImage, to url: URL) throws {
    guard let tiff = image.tiffRepresentation,
          let rep = NSBitmapImageRep(data: tiff),
          let png = rep.representation(using: .png, properties: [:]) else {
        throw NSError(domain: "OpenCallIcon", code: 1, userInfo: [NSLocalizedDescriptionKey: "Could not render PNG"])
    }
    try png.write(to: url)
}

let entries: [(String, CGFloat)] = [
    ("icon_16x16.png", 16), ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32), ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128), ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256), ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512), ("icon_512x512@2x.png", 1024)
]
for (name, size) in entries {
    try writePNG(drawIcon(size: size), to: iconset.appendingPathComponent(name))
}
try writePNG(drawIcon(size: 64), to: outDir.appendingPathComponent("StatusIcon.png"))
