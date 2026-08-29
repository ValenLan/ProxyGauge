#!/usr/bin/env swift

import AppKit
import Foundation

guard CommandLine.arguments.count == 3 else {
    fputs("usage: apply-icon-mask.swift <input.png> <output.png>\n", stderr)
    exit(2)
}

let inputPath = CommandLine.arguments[1]
let outputPath = CommandLine.arguments[2]
let pixelSize = 1024

guard let image = NSImage(contentsOfFile: inputPath) else {
    fputs("could not open the icon source\n", stderr)
    exit(1)
}

guard let bitmap = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: pixelSize,
        pixelsHigh: pixelSize,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .calibratedRGB,
        bitmapFormat: [],
        bytesPerRow: 0,
        bitsPerPixel: 0
      ) else {
    fputs("could not create the icon bitmap\n", stderr)
    exit(1)
}

guard let context = NSGraphicsContext(bitmapImageRep: bitmap) else {
    fputs("could not create the icon graphics context\n", stderr)
    exit(1)
}

NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = context
context.imageInterpolation = .high

let canvas = NSRect(x: 0, y: 0, width: pixelSize, height: pixelSize)
NSColor.clear.setFill()
canvas.fill()

// Keep the generated pale tile intact while making its outer corners genuine
// alpha. The inset also gives Windows and macOS enough optical safe area.
let tile = canvas.insetBy(dx: 64, dy: 64)
NSBezierPath(roundedRect: tile, xRadius: 176, yRadius: 176).addClip()
image.draw(
    in: canvas,
    from: NSRect(origin: .zero, size: image.size),
    operation: .sourceOver,
    fraction: 1
)
context.flushGraphics()
NSGraphicsContext.restoreGraphicsState()

guard let pngData = bitmap.representation(using: .png, properties: [:]) else {
    fputs("could not encode the icon bitmap\n", stderr)
    exit(1)
}

try pngData.write(to: URL(fileURLWithPath: outputPath), options: .atomic)
