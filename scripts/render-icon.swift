import AppKit
import Foundation

guard CommandLine.arguments.count == 2 else {
    fatalError("usage: render-icon.swift <Aurora.iconset>")
}

let iconset = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

let variants: [(String, Int)] = [
    ("icon_16x16.png", 16),
    ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32),
    ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128),
    ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256),
    ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512),
    ("icon_512x512@2x.png", 1024),
]

func scaled(_ value: CGFloat, by factor: CGFloat) -> CGFloat { value * factor }

for (name, pixels) in variants {
    guard let bitmap = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: pixels,
        pixelsHigh: pixels,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
    ), let context = NSGraphicsContext(bitmapImageRep: bitmap) else {
        fatalError("Could not create icon bitmap")
    }

    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = context
    let scale = CGFloat(pixels) / 512

    NSColor.clear.setFill()
    NSRect(x: 0, y: 0, width: pixels, height: pixels).fill()

    let tile = NSBezierPath(
        roundedRect: NSRect(
            x: scaled(18, by: scale),
            y: scaled(18, by: scale),
            width: scaled(476, by: scale),
            height: scaled(476, by: scale)
        ),
        xRadius: scaled(108, by: scale),
        yRadius: scaled(108, by: scale)
    )
    NSGradient(colors: [
        NSColor(calibratedRed: 0.022, green: 0.026, blue: 0.05, alpha: 1),
        NSColor(calibratedRed: 0.105, green: 0.035, blue: 0.16, alpha: 1),
    ])?.draw(in: tile, angle: -45)

    let orbRect = NSRect(
        x: scaled(82, by: scale),
        y: scaled(82, by: scale),
        width: scaled(348, by: scale),
        height: scaled(348, by: scale)
    )
    let orb = NSBezierPath(ovalIn: orbRect)
    NSGradient(colors: [
        NSColor(calibratedRed: 1, green: 0.42, blue: 0.75, alpha: 0.96),
        NSColor(calibratedRed: 0.39, green: 0.45, blue: 1, alpha: 0.86),
        NSColor(calibratedRed: 0.16, green: 0.08, blue: 0.34, alpha: 0.94),
    ])?.draw(in: orb, relativeCenterPosition: NSPoint(x: -0.22, y: 0.24))

    NSColor.white.withAlphaComponent(0.42).setStroke()
    let outerOrbit = NSBezierPath(ovalIn: NSRect(
        x: scaled(105, by: scale),
        y: scaled(105, by: scale),
        width: scaled(302, by: scale),
        height: scaled(302, by: scale)
    ))
    outerOrbit.lineWidth = max(1, scaled(5, by: scale))
    outerOrbit.stroke()

    NSColor.white.withAlphaComponent(0.22).setStroke()
    let innerOrbit = NSBezierPath(ovalIn: NSRect(
        x: scaled(132, by: scale),
        y: scaled(132, by: scale),
        width: scaled(248, by: scale),
        height: scaled(248, by: scale)
    ))
    innerOrbit.lineWidth = max(1, scaled(2.5, by: scale))
    innerOrbit.stroke()

    NSColor.white.withAlphaComponent(0.78).setFill()
    NSBezierPath(ovalIn: NSRect(
        x: scaled(230, by: scale),
        y: scaled(230, by: scale),
        width: scaled(52, by: scale),
        height: scaled(52, by: scale)
    )).fill()

    NSGraphicsContext.restoreGraphicsState()
    guard let png = bitmap.representation(using: .png, properties: [:]) else {
        fatalError("Could not encode icon")
    }
    try png.write(to: iconset.appendingPathComponent(name), options: .atomic)
}
