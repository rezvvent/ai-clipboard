import AppKit
import Foundation

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let iconset = root.appendingPathComponent("work/AppIcon.iconset", isDirectory: true)
try? FileManager.default.removeItem(at: iconset)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

let variants: [(String, Int)] = [
    ("icon_16x16.png", 16), ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32), ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128), ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256), ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512), ("icon_512x512@2x.png", 1024)
]

for (name, pixels) in variants {
    let size = NSSize(width: pixels, height: pixels)
    let image = NSImage(size: size)
    image.lockFocus()

    let outer = NSRect(origin: .zero, size: size).insetBy(dx: CGFloat(pixels) * 0.06, dy: CGFloat(pixels) * 0.06)
    NSColor(calibratedWhite: 0.04, alpha: 1).setFill()
    NSBezierPath(
        roundedRect: outer,
        xRadius: CGFloat(pixels) * 0.22,
        yRadius: CGFloat(pixels) * 0.22
    ).fill()

    let cardSize = CGFloat(pixels) * 0.55
    let card = NSRect(
        x: (CGFloat(pixels) - cardSize) / 2,
        y: (CGFloat(pixels) - cardSize) / 2,
        width: cardSize,
        height: cardSize
    )
    NSColor.white.setFill()
    NSBezierPath(
        roundedRect: card,
        xRadius: CGFloat(pixels) * 0.11,
        yRadius: CGFloat(pixels) * 0.11
    ).fill()

    let centerX = CGFloat(pixels) / 2
    let barHeight = max(1, CGFloat(pixels) * 0.025)
    let widths: [CGFloat] = [0.25, 0.18, 0.11]
    for (index, width) in widths.enumerated() {
        let barWidth = CGFloat(pixels) * width
        let y = CGFloat(pixels) * (0.57 - CGFloat(index) * 0.08)
        let rect = NSRect(x: centerX - barWidth / 2, y: y, width: barWidth, height: barHeight)
        NSColor(calibratedWhite: 0.08 + CGFloat(index) * 0.18, alpha: 1).setFill()
        NSBezierPath(roundedRect: rect, xRadius: barHeight / 2, yRadius: barHeight / 2).fill()
    }
    image.unlockFocus()

    guard let tiff = image.tiffRepresentation,
          let bitmap = NSBitmapImageRep(data: tiff),
          let png = bitmap.representation(using: .png, properties: [:])
    else { continue }
    try png.write(to: iconset.appendingPathComponent(name), options: .atomic)
}
