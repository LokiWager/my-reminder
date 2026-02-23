import AppKit
import Foundation

guard CommandLine.arguments.count >= 2 else {
    fputs("Usage: swift generate-icon.swift /path/to/output.png\n", stderr)
    exit(1)
}

let outputPath = CommandLine.arguments[1]
let sourcePath = "Assets/AppIconSource.png"
let canvasSize = NSSize(width: 1024, height: 1024)

guard let sourceImage = NSImage(contentsOfFile: sourcePath) else {
    fputs("Missing icon source at \(sourcePath)\n", stderr)
    exit(1)
}

let srcW = sourceImage.size.width
let srcH = sourceImage.size.height
let minSide = min(srcW, srcH)

// Slight zoom-in so the character fills the icon better.
let cropSide = max(1, minSide * 0.82)
let cropRect = CGRect(
    x: (srcW - cropSide) / 2,
    y: (srcH - cropSide) / 2,
    width: cropSide,
    height: cropSide
)

let outputImage = NSImage(size: canvasSize)
outputImage.lockFocus()
NSColor.clear.setFill()
NSBezierPath(rect: CGRect(origin: .zero, size: canvasSize)).fill()

sourceImage.draw(
    in: CGRect(origin: .zero, size: canvasSize),
    from: cropRect,
    operation: .copy,
    fraction: 1.0,
    respectFlipped: true,
    hints: [.interpolation: NSImageInterpolation.high]
)

outputImage.unlockFocus()

guard let tiff = outputImage.tiffRepresentation,
      let rep = NSBitmapImageRep(data: tiff),
      let pngData = rep.representation(using: .png, properties: [:]) else {
    fputs("Failed to render icon image.\n", stderr)
    exit(1)
}

do {
    try pngData.write(to: URL(fileURLWithPath: outputPath))
    print("Generated icon source: \(outputPath)")
} catch {
    fputs("Failed writing icon: \(error.localizedDescription)\n", stderr)
    exit(1)
}
