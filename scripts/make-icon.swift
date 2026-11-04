#!/usr/bin/env swift
import AppKit
import Foundation

// Native vector drawing only; no downloaded artwork, fonts or third-party tools.
let destination = CommandLine.arguments.dropFirst().first ?? "build/AppIcon.iconset"
let iconset = URL(fileURLWithPath: destination, isDirectory: true)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

func rounded(_ rect: NSRect, radius: CGFloat, color: NSColor) {
    color.setFill()
    NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
}

func drawIcon() {
    let background = NSBezierPath(roundedRect: NSRect(x: 20, y: 20, width: 984, height: 984),
                                  xRadius: 220, yRadius: 220)
    NSGradient(starting: NSColor(srgbRed: 0.045, green: 0.22, blue: 0.18, alpha: 1),
               ending: NSColor(srgbRed: 0.15, green: 0.38, blue: 0.31, alpha: 1))!
        .draw(in: background, angle: 90)

    // A restrained page shadow, warm paper and a visible book spine.
    rounded(NSRect(x: 248, y: 188, width: 548, height: 650), radius: 52,
            color: NSColor.black.withAlphaComponent(0.13))
    rounded(NSRect(x: 232, y: 214, width: 548, height: 634), radius: 48,
            color: NSColor(srgbRed: 0.83, green: 0.81, blue: 0.72, alpha: 1))
    rounded(NSRect(x: 270, y: 214, width: 510, height: 634), radius: 43,
            color: NSColor(srgbRed: 0.98, green: 0.96, blue: 0.88, alpha: 1))

    let spine = NSBezierPath()
    spine.move(to: NSPoint(x: 303, y: 270))
    spine.line(to: NSPoint(x: 303, y: 792))
    spine.lineWidth = 7
    NSColor(srgbRed: 0.82, green: 0.81, blue: 0.72, alpha: 1).setStroke()
    spine.stroke()

    // Three quiet lines suggest text without becoming a miniature UI.
    let ink = NSColor(srgbRed: 0.12, green: 0.35, blue: 0.28, alpha: 0.73)
    rounded(NSRect(x: 362, y: 642, width: 196, height: 23), radius: 11, color: ink)
    rounded(NSRect(x: 362, y: 579, width: 171, height: 18), radius: 9,
            color: ink.withAlphaComponent(0.37))
    rounded(NSRect(x: 362, y: 518, width: 215, height: 18), radius: 9,
            color: ink.withAlphaComponent(0.27))

    let bookmark = NSBezierPath()
    bookmark.move(to: NSPoint(x: 611, y: 848))
    bookmark.line(to: NSPoint(x: 709, y: 848))
    bookmark.line(to: NSPoint(x: 709, y: 526))
    bookmark.line(to: NSPoint(x: 660, y: 566))
    bookmark.line(to: NSPoint(x: 611, y: 526))
    bookmark.close()
    NSColor(srgbRed: 0.88, green: 0.66, blue: 0.27, alpha: 1).setFill()
    bookmark.fill()

    // The page edge is intentionally simple enough to remain legible in the Dock.
    rounded(NSRect(x: 361, y: 300, width: 316, height: 8), radius: 4,
            color: NSColor(srgbRed: 0.77, green: 0.75, blue: 0.66, alpha: 0.8))
}

func writePNG(pixels: Int, name: String) throws {
    guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
                                        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                        isPlanar: false, colorSpaceName: .deviceRGB,
                                        bytesPerRow: 0, bitsPerPixel: 0),
          let graphics = NSGraphicsContext(bitmapImageRep: bitmap) else {
        throw NSError(domain: "InkReadIcon", code: 1,
                      userInfo: [NSLocalizedDescriptionKey: "无法创建图标绘图上下文。"])
    }
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = graphics
    graphics.cgContext.scaleBy(x: CGFloat(pixels) / 1024, y: CGFloat(pixels) / 1024)
    graphics.imageInterpolation = .high
    drawIcon()
    graphics.flushGraphics()
    NSGraphicsContext.restoreGraphicsState()
    guard let png = bitmap.representation(using: .png, properties: [:]) else {
        throw NSError(domain: "InkReadIcon", code: 2,
                      userInfo: [NSLocalizedDescriptionKey: "无法编码 PNG 图标。"])
    }
    try png.write(to: iconset.appendingPathComponent(name), options: .atomic)
}

for size in [16, 32, 128, 256, 512] {
    try writePNG(pixels: size, name: "icon_\(size)x\(size).png")
    try writePNG(pixels: size * 2, name: "icon_\(size)x\(size)@2x.png")
}
print("已生成图标：\(iconset.path)")
