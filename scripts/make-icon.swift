// Draws the app icon (an eye on a dark rounded square) into an .iconset folder.
// Usage: swift scripts/make-icon.swift <output.iconset>
import AppKit

let out = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "AppIcon.iconset")
try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)

func render(_ px: Int) -> Data? {
    let s = CGFloat(px)
    guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8,
                                     samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                     colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let inset = s * 0.09
    let rect = NSRect(x: inset, y: inset, width: s - inset * 2, height: s - inset * 2)
    let bg = NSBezierPath(roundedRect: rect, xRadius: s * 0.2, yRadius: s * 0.2)
    NSGradient(colors: [NSColor(calibratedRed: 0.07, green: 0.16, blue: 0.20, alpha: 1),
                        NSColor(calibratedRed: 0.02, green: 0.05, blue: 0.08, alpha: 1)])?.draw(in: bg, angle: -90)
    // Eye outline
    let w = rect.width * 0.62, h = rect.height * 0.36
    let c = NSPoint(x: rect.midX, y: rect.midY)
    let eye = NSBezierPath()
    eye.move(to: NSPoint(x: c.x - w / 2, y: c.y))
    eye.curve(to: NSPoint(x: c.x + w / 2, y: c.y), controlPoint1: NSPoint(x: c.x - w / 4, y: c.y + h), controlPoint2: NSPoint(x: c.x + w / 4, y: c.y + h))
    eye.curve(to: NSPoint(x: c.x - w / 2, y: c.y), controlPoint1: NSPoint(x: c.x + w / 4, y: c.y - h), controlPoint2: NSPoint(x: c.x - w / 4, y: c.y - h))
    eye.lineWidth = s * 0.035
    NSColor(calibratedRed: 0.35, green: 0.85, blue: 0.85, alpha: 1).setStroke()
    eye.stroke()
    // Iris + pupil, glancing slightly right
    let r = h * 0.42
    let iris = NSBezierPath(ovalIn: NSRect(x: c.x - r + w * 0.08, y: c.y - r, width: r * 2, height: r * 2))
    NSColor(calibratedRed: 0.35, green: 0.85, blue: 0.85, alpha: 1).setFill()
    iris.fill()
    let pr = r * 0.45
    NSColor(calibratedRed: 0.02, green: 0.05, blue: 0.08, alpha: 1).setFill()
    NSBezierPath(ovalIn: NSRect(x: c.x - pr + w * 0.08, y: c.y - pr, width: pr * 2, height: pr * 2)).fill()
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])
}

for (name, px) in [("16x16", 16), ("16x16@2x", 32), ("32x32", 32), ("32x32@2x", 64), ("128x128", 128),
                   ("128x128@2x", 256), ("256x256", 256), ("256x256@2x", 512), ("512x512", 512), ("512x512@2x", 1024)] {
    if let data = render(px) {
        try? data.write(to: out.appendingPathComponent("icon_\(name).png"))
    }
}
