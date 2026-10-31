// Renders the original YTGrab app icon (downward arrow into a tray on a
// blue→teal gradient squircle) at all AppIcon sizes. No dependencies.
// Usage: swift scripts/make_icon.swift  →  AppIcon.iconset/
import AppKit
import CoreGraphics
import Foundation

let outDir = CommandLine.arguments.count > 1
    ? CommandLine.arguments[1] : "assets/AppIcon.iconset"
try? FileManager.default.createDirectory(atPath: outDir,
                                         withIntermediateDirectories: true)

func render(size: CGFloat) -> NSImage? {
    guard let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: Int(size),
        pixelsHigh: Int(size), bitsPerSample: 8,
        samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .calibratedRGB, bytesPerRow: 0,
        bitsPerPixel: 0) else { return nil }
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    defer { NSGraphicsContext.restoreGraphicsState() }

    let rect = CGRect(x: 0, y: 0, width: size, height: size)
    let inset = size * 0.04
    let iconRect = rect.insetBy(dx: inset, dy: inset)
    let radius = iconRect.width * 0.235

    // Squircle-ish rounded rect clip.
    let squircle = NSBezierPath(roundedRect: iconRect,
                                xRadius: radius, yRadius: radius)
    // Blue → teal diagonal gradient.
    if let gradient = NSGradient(
        starting: NSColor(calibratedRed: 0.10, green: 0.35, blue: 0.85,
                          alpha: 1),
        ending: NSColor(calibratedRed: 0.05, green: 0.70, blue: 0.75,
                        alpha: 1)) {
        gradient.draw(in: squircle, angle: -55)
    }

    NSGraphicsContext.current?.cgContext.setAllowsAntialiasing(true)
    let white = NSColor.white
    white.setFill()
    white.setStroke()

    // Downward arrow: shaft + chevron head, centered above a tray.
    let arrowWidth = size * 0.085
    let shaftX = size * 0.5 - arrowWidth / 2
    let shaftTop = size * 0.72
    let shaftBottom = size * 0.47
    let shaft = NSBezierPath(roundedRect:
        CGRect(x: shaftX, y: shaftBottom,
               width: arrowWidth, height: shaftTop - shaftBottom),
        xRadius: arrowWidth / 2, yRadius: arrowWidth / 2)
    shaft.fill()

    // Chevron arrowhead.
    let headWidth = size * 0.30
    let headDrop = size * 0.13
    let tip = CGPoint(x: size * 0.5, y: size * 0.30)
    let chevron = NSBezierPath()
    chevron.lineWidth = arrowWidth
    chevron.lineCapStyle = .round
    chevron.lineJoinStyle = .round
    chevron.move(to: CGPoint(x: tip.x - headWidth / 2,
                             y: tip.y + headDrop))
    chevron.line(to: tip)
    chevron.line(to: CGPoint(x: tip.x + headWidth / 2,
                             y: tip.y + headDrop))
    chevron.stroke()

    // Tray: two side walls + base line.
    let trayWidth = size * 0.46
    let trayY = size * 0.20
    let trayH = size * 0.07
    let wallW = size * 0.075
    let leftWall = NSBezierPath(roundedRect:
        CGRect(x: size * 0.5 - trayWidth / 2, y: trayY,
               width: wallW, height: trayH),
        xRadius: wallW / 2, yRadius: wallW / 2)
    let rightWall = NSBezierPath(roundedRect:
        CGRect(x: size * 0.5 + trayWidth / 2 - wallW, y: trayY,
               width: wallW, height: trayH),
        xRadius: wallW / 2, yRadius: wallW / 2)
    leftWall.fill()
    rightWall.fill()
    let base = NSBezierPath()
    base.lineWidth = wallW
    base.lineCapStyle = .round
    base.move(to: CGPoint(x: size * 0.5 - trayWidth / 2 + wallW / 2,
                          y: trayY))
    base.line(to: CGPoint(x: size * 0.5 + trayWidth / 2 - wallW / 2,
                          y: trayY))
    base.stroke()

    let image = NSImage(size: NSSize(width: size, height: size))
    image.addRepresentation(rep)
    return image
}

let specs: [(name: String, pixels: CGFloat)] = [
    ("icon_16x16.png", 16), ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32), ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128), ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256), ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512), ("icon_512x512@2x.png", 1024)
]
for spec in specs {
    guard let image = render(size: spec.pixels),
          let tiff = image.tiffRepresentation,
          let rep = NSBitmapImageRep(data: tiff),
          let png = rep.representation(using: .png, properties: [:]) else {
        print("FAILED", spec.name); continue
    }
    try png.write(to: URL(fileURLWithPath: outDir + "/" + spec.name))
    print("wrote", spec.name)
}
