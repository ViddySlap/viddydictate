#!/usr/bin/env swift
//
// make-app-icon.swift - generate ViddyDictate's AppIcon.iconset with AppKit.
//
// Re-runnable, committed generator for the app icon: a white SF Symbol `mic.fill` glyph
// centred on a mid-gray macOS-style rounded square. Usage:
//
//   swift -module-cache-path "$TMPDIR/mc" Tools/make-app-icon.swift /tmp/iconbuild
//   iconutil -c icns /tmp/iconbuild/AppIcon.iconset -o AppIcon.icns
//
// The script takes the output directory as argv[1] (default: the current directory) and
// writes <outdir>/AppIcon.iconset/icon_<n>x<n>[@2x].png for the ten standard sizes.

import AppKit
import Foundation

/// (filename, pixel size) for the ten members of a complete .iconset.
let entries: [(name: String, pixels: Int)] = [
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

// macOS icon artwork proportions, expressed against a 1024-point canvas.
let bodyFraction: CGFloat = 824.0 / 1024.0      // rounded-square body width/height
let cornerFraction: CGFloat = 185.0 / 1024.0    // corner radius
let glyphHeightFraction: CGFloat = 0.53         // glyph height relative to the body

let outputRoot = CommandLine.arguments.count > 1
    ? CommandLine.arguments[1]
    : FileManager.default.currentDirectoryPath
let iconsetURL = URL(fileURLWithPath: outputRoot)
    .appendingPathComponent("AppIcon.iconset", isDirectory: true)

let fileManager = FileManager.default
if fileManager.fileExists(atPath: iconsetURL.path) {
    try fileManager.removeItem(at: iconsetURL)
}
try fileManager.createDirectory(at: iconsetURL, withIntermediateDirectories: true)

/// The flat mid-gray of the rounded square, matching macOS #8E8E93.
func bodyColor() -> NSColor {
    return NSColor(srgbRed: 142.0 / 255.0,
                   green: 142.0 / 255.0,
                   blue: 147.0 / 255.0,
                   alpha: 1.0)
}

/// Rasterises `mic.fill` as a fully opaque white image whose height is `targetHeight` points.
/// The symbol is drawn once, then recoloured white with a source-in fill so it can never fall
/// back to the black template rendering.
func whiteMicGlyph(targetHeight: CGFloat) -> NSImage {
    let base = NSImage(systemSymbolName: "mic.fill", accessibilityDescription: nil)!
    let configuration = NSImage.SymbolConfiguration(pointSize: targetHeight, weight: .regular)
    let symbol = base.withSymbolConfiguration(configuration) ?? base

    var size = symbol.size
    if size.width <= 0 || size.height <= 0 {
        size = NSSize(width: targetHeight, height: targetHeight)
    }
    if abs(size.height - targetHeight) > 0.01 {
        size = NSSize(width: size.width * (targetHeight / size.height), height: targetHeight)
    }

    let tinted = NSImage(size: size)
    tinted.lockFocus()
    NSColor.clear.set()
    NSRect(origin: .zero, size: size).fill()
    symbol.draw(in: NSRect(origin: .zero, size: size),
                from: .zero,
                operation: .sourceOver,
                fraction: 1.0)
    NSColor.white.set()
    NSRect(origin: .zero, size: size).fill(using: .sourceIn)
    tinted.unlockFocus()
    return tinted
}

/// Draws one square icon at `pixels` x `pixels` and returns its bitmap.
func renderIcon(pixels: Int) -> NSBitmapImageRep {
    let side = CGFloat(pixels)
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil,
                               pixelsWide: pixels,
                               pixelsHigh: pixels,
                               bitsPerSample: 8,
                               samplesPerPixel: 4,
                               hasAlpha: true,
                               isPlanar: false,
                               colorSpaceName: .deviceRGB,
                               bytesPerRow: 0,
                               bitsPerPixel: 0)!
    rep.size = NSSize(width: side, height: side)

    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

    // Transparent canvas; the rounded square is the only opaque body.
    let canvas = NSRect(x: 0, y: 0, width: side, height: side)
    NSColor.clear.set()
    canvas.fill()

    // Centred mid-gray rounded square.
    let bodySide = side * bodyFraction
    let bodyRect = NSRect(x: (side - bodySide) / 2,
                          y: (side - bodySide) / 2,
                          width: bodySide,
                          height: bodySide)
    let radius = side * cornerFraction
    let body = NSBezierPath(roundedRect: bodyRect, xRadius: radius, yRadius: radius)
    bodyColor().setFill()
    body.fill()

    // Centred opaque-white microphone glyph.
    let glyphTarget = bodySide * glyphHeightFraction
    let glyph = whiteMicGlyph(targetHeight: glyphTarget)
    let glyphSize = glyph.size
    let glyphRect = NSRect(x: (side - glyphSize.width) / 2,
                           y: (side - glyphSize.height) / 2,
                           width: glyphSize.width,
                           height: glyphSize.height)
    glyph.draw(in: glyphRect, from: .zero, operation: .sourceOver, fraction: 1.0)

    NSGraphicsContext.restoreGraphicsState()
    return rep
}

for entry in entries {
    let rep = renderIcon(pixels: entry.pixels)
    guard let png = rep.representation(using: .png, properties: [:]) else {
        FileHandle.standardError.write("ERROR: could not encode \(entry.name)\n".data(using: .utf8)!)
        exit(1)
    }
    let destination = iconsetURL.appendingPathComponent(entry.name)
    do {
        try png.write(to: destination)
    } catch {
        FileHandle.standardError.write("ERROR: could not write \(destination.path): \(error)\n".data(using: .utf8)!)
        exit(1)
    }
}

print("wrote \(entries.count) PNGs to \(iconsetURL.path)")
