import AppKit
import Foundation

guard CommandLine.arguments.count == 3 else {
    fputs("usage: render-app-icon.swift INPUT.svg OUTPUT.png\n", stderr)
    exit(2)
}

let inputURL = URL(fileURLWithPath: CommandLine.arguments[1])
let outputURL = URL(fileURLWithPath: CommandLine.arguments[2])

guard let source = NSImage(contentsOf: inputURL),
      let bitmap = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: 1024,
        pixelsHigh: 1024,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
      ) else {
    fputs("Unable to load or render icon source.\n", stderr)
    exit(1)
}

NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
NSColor.clear.setFill()
NSRect(x: 0, y: 0, width: 1024, height: 1024).fill()
source.draw(
    in: NSRect(x: 0, y: 0, width: 1024, height: 1024),
    from: .zero,
    operation: .sourceOver,
    fraction: 1
)
NSGraphicsContext.restoreGraphicsState()

guard let png = bitmap.representation(using: .png, properties: [:]) else {
    fputs("Unable to encode icon PNG.\n", stderr)
    exit(1)
}

try png.write(to: outputURL, options: .atomic)
