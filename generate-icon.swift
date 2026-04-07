#!/usr/bin/swift

import AppKit
import CoreGraphics

func generateIcon(size: Int) -> NSImage {
    let s = CGFloat(size)
    let image = NSImage(size: NSSize(width: s, height: s))
    image.lockFocus()

    let ctx = NSGraphicsContext.current!.cgContext

    // Background: rounded rectangle with gradient
    let cornerRadius = s * 0.22
    let bgRect = CGRect(x: s * 0.04, y: s * 0.04, width: s * 0.92, height: s * 0.92)
    let bgPath = CGPath(roundedRect: bgRect, cornerWidth: cornerRadius, cornerHeight: cornerRadius, transform: nil)

    // Dark gradient background
    ctx.saveGState()
    ctx.addPath(bgPath)
    ctx.clip()

    let colorSpace = CGColorSpaceCreateDeviceRGB()
    let gradientColors = [
        CGColor(red: 0.12, green: 0.12, blue: 0.16, alpha: 1.0),
        CGColor(red: 0.08, green: 0.08, blue: 0.12, alpha: 1.0)
    ] as CFArray
    let gradient = CGGradient(colorsSpace: colorSpace, colors: gradientColors, locations: [0.0, 1.0])!
    ctx.drawLinearGradient(gradient, start: CGPoint(x: 0, y: s), end: CGPoint(x: s, y: 0), options: [])
    ctx.restoreGState()

    // Subtle border
    ctx.saveGState()
    ctx.setStrokeColor(CGColor(red: 0.25, green: 0.25, blue: 0.32, alpha: 0.6))
    ctx.setLineWidth(s * 0.01)
    ctx.addPath(bgPath)
    ctx.strokePath()
    ctx.restoreGState()

    // Floating note paper - slightly tilted
    let noteW = s * 0.44
    let noteH = s * 0.52
    let noteX = s * 0.30
    let noteY = s * 0.24

    ctx.saveGState()
    // Slight rotation for "float" effect
    ctx.translateBy(x: noteX + noteW / 2, y: noteY + noteH / 2)
    ctx.rotate(by: 0.05)
    ctx.translateBy(x: -(noteX + noteW / 2), y: -(noteY + noteH / 2))

    // Shadow
    ctx.setShadow(offset: CGSize(width: s * 0.01, height: -s * 0.02), blur: s * 0.06, color: CGColor(red: 0, green: 0, blue: 0, alpha: 0.5))

    let noteRect = CGRect(x: noteX, y: noteY, width: noteW, height: noteH)
    let noteCorner = s * 0.04
    let notePath = CGPath(roundedRect: noteRect, cornerWidth: noteCorner, cornerHeight: noteCorner, transform: nil)

    // Note fill - warm white
    ctx.setFillColor(CGColor(red: 0.95, green: 0.93, blue: 0.90, alpha: 1.0))
    ctx.addPath(notePath)
    ctx.fillPath()

    ctx.setShadow(offset: .zero, blur: 0) // clear shadow

    // Lines on the note
    ctx.setStrokeColor(CGColor(red: 0.72, green: 0.70, blue: 0.66, alpha: 0.5))
    ctx.setLineWidth(s * 0.012)
    ctx.setLineCap(.round)

    let lineX = noteX + noteW * 0.15
    let lineEndX = noteX + noteW * 0.85
    let lineSpacing = noteH * 0.18
    let firstLineY = noteY + noteH * 0.28

    // Line 1 - longest
    ctx.move(to: CGPoint(x: lineX, y: firstLineY))
    ctx.addLine(to: CGPoint(x: lineEndX, y: firstLineY))
    ctx.strokePath()

    // Line 2
    ctx.move(to: CGPoint(x: lineX, y: firstLineY + lineSpacing))
    ctx.addLine(to: CGPoint(x: lineEndX - noteW * 0.1, y: firstLineY + lineSpacing))
    ctx.strokePath()

    // Line 3 - shorter
    ctx.move(to: CGPoint(x: lineX, y: firstLineY + lineSpacing * 2))
    ctx.addLine(to: CGPoint(x: lineEndX - noteW * 0.3, y: firstLineY + lineSpacing * 2))
    ctx.strokePath()

    // Line 4 - shortest
    ctx.move(to: CGPoint(x: lineX, y: firstLineY + lineSpacing * 3))
    ctx.addLine(to: CGPoint(x: lineEndX - noteW * 0.45, y: firstLineY + lineSpacing * 3))
    ctx.strokePath()

    ctx.restoreGState()

    // Accent dot - floating indicator (top-left of note)
    let dotSize = s * 0.07
    let dotX = s * 0.22
    let dotY = s * 0.68

    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -s * 0.005), blur: s * 0.03, color: CGColor(red: 0.3, green: 0.5, blue: 1.0, alpha: 0.6))

    let accentColors = [
        CGColor(red: 0.35, green: 0.55, blue: 1.0, alpha: 1.0),
        CGColor(red: 0.50, green: 0.70, blue: 1.0, alpha: 1.0)
    ] as CFArray
    let accentGradient = CGGradient(colorsSpace: colorSpace, colors: accentColors, locations: [0.0, 1.0])!
    let dotRect = CGRect(x: dotX, y: dotY, width: dotSize, height: dotSize)
    ctx.addEllipse(in: dotRect)
    ctx.clip()
    ctx.drawLinearGradient(accentGradient, start: CGPoint(x: dotX, y: dotY + dotSize), end: CGPoint(x: dotX + dotSize, y: dotY), options: [])
    ctx.restoreGState()

    // Second smaller accent dot
    let dot2Size = s * 0.04
    let dot2X = s * 0.17
    let dot2Y = s * 0.60

    ctx.saveGState()
    ctx.setFillColor(CGColor(red: 0.35, green: 0.55, blue: 1.0, alpha: 0.4))
    ctx.fillEllipse(in: CGRect(x: dot2X, y: dot2Y, width: dot2Size, height: dot2Size))
    ctx.restoreGState()

    image.unlockFocus()
    return image
}

// Generate all required sizes
let iconsetPath = "/Users/cagdas.agirtas/CodTemp/floatnote/FloatNote/AppIcon.iconset"
try? FileManager.default.createDirectory(atPath: iconsetPath, withIntermediateDirectories: true)

let sizes: [(String, Int)] = [
    ("icon_16x16", 16),
    ("icon_16x16@2x", 32),
    ("icon_32x32", 32),
    ("icon_32x32@2x", 64),
    ("icon_128x128", 128),
    ("icon_128x128@2x", 256),
    ("icon_256x256", 256),
    ("icon_256x256@2x", 512),
    ("icon_512x512", 512),
    ("icon_512x512@2x", 1024),
]

for (name, size) in sizes {
    let image = generateIcon(size: size)
    let rep = NSBitmapImageRep(data: image.tiffRepresentation!)!
    let pngData = rep.representation(using: .png, properties: [:])!
    let path = "\(iconsetPath)/\(name).png"
    try! pngData.write(to: URL(fileURLWithPath: path))
    print("Generated \(name).png (\(size)x\(size))")
}

print("Done. Now run: iconutil -c icns \(iconsetPath)")
