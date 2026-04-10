#!/usr/bin/env swift
// Generates an iconset for Clawbridge.app.
// Usage: swift Resources/make-icon.swift <output-dir>
//   output-dir is the .iconset directory (e.g. build/Clawbridge.iconset)
// After running, invoke:
//   iconutil -c icns <output-dir> -o build/Clawbridge.icns
import AppKit
import Foundation

let args = CommandLine.arguments
guard args.count >= 2 else {
    FileHandle.standardError.write(Data("usage: make-icon.swift <iconset-dir>\n".utf8))
    exit(2)
}
let outputDir = args[1]
try? FileManager.default.createDirectory(atPath: outputDir, withIntermediateDirectories: true)

// iconutil requires these exact filenames.
let sizes: [(name: String, px: Int)] = [
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

func renderIcon(size: Int) -> Data? {
    let w = CGFloat(size)
    let h = CGFloat(size)

    guard let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: size, pixelsHigh: size,
        bitsPerSample: 8, samplesPerPixel: 4,
        hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0, bitsPerPixel: 32
    ) else { return nil }

    NSGraphicsContext.saveGraphicsState()
    defer { NSGraphicsContext.restoreGraphicsState() }
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

    let rect = NSRect(x: 0, y: 0, width: w, height: h)
    let radius = w * 0.225

    // Rounded-rect clip (standard macOS "squircle-ish" look).
    let clipPath = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
    clipPath.addClip()

    // Background gradient: deep teal → darker teal, subtle diagonal.
    let top = NSColor(red: 0.12, green: 0.45, blue: 0.52, alpha: 1.0)
    let bot = NSColor(red: 0.05, green: 0.18, blue: 0.26, alpha: 1.0)
    let gradient = NSGradient(colors: [top, bot])!
    gradient.draw(in: rect, angle: -90)

    // Subtle inner highlight at the top for depth.
    let highlight = NSGradient(colors: [
        NSColor(white: 1.0, alpha: 0.18),
        NSColor(white: 1.0, alpha: 0.0),
    ])!
    highlight.draw(in: NSRect(x: 0, y: h * 0.55, width: w, height: h * 0.45), angle: -90)

    // Bridge silhouette: three arched piers + deck line.
    // All geometry is size-relative so it scales cleanly.
    let deckY = h * 0.42
    let deckThickness = max(1.5, h * 0.035)
    let pierTop = h * 0.42
    let pierBot = h * 0.20
    let nPiers = 3
    let pierWidth = max(2, h * 0.055)
    let totalPierSpan = w * 0.62
    let pierStart = (w - totalPierSpan) / 2
    let pierStep = totalPierSpan / CGFloat(nPiers - 1)

    NSColor.white.withAlphaComponent(0.95).setFill()

    // Deck
    let deck = NSBezierPath(rect: NSRect(
        x: w * 0.12,
        y: deckY,
        width: w * 0.76,
        height: deckThickness
    ))
    deck.fill()

    // Piers
    for i in 0..<nPiers {
        let cx = pierStart + CGFloat(i) * pierStep
        let pier = NSBezierPath(rect: NSRect(
            x: cx - pierWidth / 2,
            y: pierBot,
            width: pierWidth,
            height: pierTop - pierBot + deckThickness
        ))
        pier.fill()
    }

    // Cable arches above the deck (two cables for a suspension feel).
    NSColor.white.withAlphaComponent(0.85).setStroke()
    let cableWidth = max(1.2, h * 0.02)
    for cableIdx in 0..<2 {
        let archHeight = h * (0.22 - CGFloat(cableIdx) * 0.05)
        let archTop = deckY + deckThickness + archHeight
        let arch = NSBezierPath()
        arch.move(to: NSPoint(x: w * 0.18, y: deckY + deckThickness))
        arch.curve(
            to: NSPoint(x: w * 0.82, y: deckY + deckThickness),
            controlPoint1: NSPoint(x: w * 0.32, y: archTop),
            controlPoint2: NSPoint(x: w * 0.68, y: archTop)
        )
        arch.lineWidth = cableWidth
        arch.stroke()
    }

    // Small "claw mark" accent in the top-right corner — three diagonal slashes.
    NSColor(red: 1.0, green: 0.72, blue: 0.25, alpha: 0.95).setStroke()
    let clawLen = h * 0.14
    let clawStartX = w * 0.72
    let clawStartY = h * 0.72
    let clawGap = h * 0.055
    let clawWidth = max(1.2, h * 0.025)
    for i in 0..<3 {
        let off = CGFloat(i) * clawGap
        let line = NSBezierPath()
        line.move(to: NSPoint(x: clawStartX + off, y: clawStartY))
        line.line(to: NSPoint(x: clawStartX + off + clawLen, y: clawStartY + clawLen))
        line.lineWidth = clawWidth
        line.lineCapStyle = .round
        line.stroke()
    }

    return rep.representation(using: .png, properties: [:])
}

for (name, px) in sizes {
    guard let data = renderIcon(size: px) else {
        FileHandle.standardError.write(Data("Failed to render \(name)\n".utf8))
        exit(1)
    }
    let path = "\(outputDir)/\(name)"
    do {
        try data.write(to: URL(fileURLWithPath: path))
        print("  rendered \(name) (\(px)×\(px))")
    } catch {
        FileHandle.standardError.write(Data("Failed to write \(path): \(error)\n".utf8))
        exit(1)
    }
}
print("Icon set written to \(outputDir)")
