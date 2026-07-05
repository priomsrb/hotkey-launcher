#!/usr/bin/env swift
//
// Generates assets/AppIcon.icns.
// Draws a macOS-style rounded-rect icon with a keyboard glyph (the same
// SF Symbol used in the menu bar) and packs all required sizes with iconutil.
//
// Usage: swift scripts/make-icon.swift

import AppKit

let masterSize: CGFloat = 1024

func renderMaster() -> NSImage {
    let image = NSImage(size: NSSize(width: masterSize, height: masterSize), flipped: false) { _ in
        // Standard macOS icon grid: 824pt rounded rect centered on a 1024pt canvas
        let inset: CGFloat = 100
        let rect = NSRect(x: inset, y: inset, width: masterSize - inset * 2, height: masterSize - inset * 2)
        let path = NSBezierPath(roundedRect: rect, xRadius: 185, yRadius: 185)

        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.3)
        shadow.shadowBlurRadius = 24
        shadow.shadowOffset = NSSize(width: 0, height: -12)
        shadow.set()

        NSGradient(
            starting: NSColor(calibratedRed: 0.32, green: 0.42, blue: 0.98, alpha: 1),
            ending: NSColor(calibratedRed: 0.16, green: 0.20, blue: 0.55, alpha: 1)
        )?.draw(in: path, angle: -90)

        // Keyboard glyph, tinted white
        let config = NSImage.SymbolConfiguration(pointSize: 440, weight: .medium)
        guard let symbol = NSImage(systemSymbolName: "keyboard", accessibilityDescription: nil)?
            .withSymbolConfiguration(config) else {
            fputs("error: could not load keyboard symbol\n", stderr)
            exit(1)
        }
        let tinted = NSImage(size: symbol.size, flipped: false) { symbolRect in
            symbol.draw(in: symbolRect)
            NSColor.white.set()
            symbolRect.fill(using: .sourceAtop)
            return true
        }

        let glyphWidth = rect.width * 0.62
        let glyphHeight = glyphWidth * (tinted.size.height / tinted.size.width)
        let glyphRect = NSRect(
            x: rect.midX - glyphWidth / 2,
            y: rect.midY - glyphHeight / 2,
            width: glyphWidth,
            height: glyphHeight
        )
        tinted.draw(in: glyphRect, from: .zero, operation: .sourceOver, fraction: 1)
        return true
    }
    return image
}

func writePNG(_ image: NSImage, pixels: Int, to url: URL) {
    guard let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
    ) else { fputs("error: could not create bitmap rep\n", stderr); exit(1) }

    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    NSGraphicsContext.current?.imageInterpolation = .high
    image.draw(in: NSRect(x: 0, y: 0, width: pixels, height: pixels),
               from: .zero, operation: .copy, fraction: 1)
    NSGraphicsContext.restoreGraphicsState()

    guard let data = rep.representation(using: .png, properties: [:]) else {
        fputs("error: could not encode PNG\n", stderr); exit(1)
    }
    try! data.write(to: url)
}

let scriptDir = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent()
let repoRoot = scriptDir.deletingLastPathComponent()
let assetsDir = repoRoot.appendingPathComponent("assets")
let iconsetDir = assetsDir.appendingPathComponent("AppIcon.iconset")

try? FileManager.default.removeItem(at: iconsetDir)
try! FileManager.default.createDirectory(at: iconsetDir, withIntermediateDirectories: true)

let master = renderMaster()
for base in [16, 32, 128, 256, 512] {
    writePNG(master, pixels: base, to: iconsetDir.appendingPathComponent("icon_\(base)x\(base).png"))
    writePNG(master, pixels: base * 2, to: iconsetDir.appendingPathComponent("icon_\(base)x\(base)@2x.png"))
}

let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", iconsetDir.path, "-o", assetsDir.appendingPathComponent("AppIcon.icns").path]
try! iconutil.run()
iconutil.waitUntilExit()
guard iconutil.terminationStatus == 0 else {
    fputs("error: iconutil failed\n", stderr); exit(1)
}

try? FileManager.default.removeItem(at: iconsetDir)
print("✅ Wrote assets/AppIcon.icns")
