import AppKit
import Foundation

guard CommandLine.arguments.count >= 2 else {
    fputs("Usage: swift generate-icon.swift /path/to/output.png\n", stderr)
    exit(1)
}

let outputPath = CommandLine.arguments[1]
let sourcePath = "Assets/AppIconSource.png"
let canvasSize = CGSize(width: 1024, height: 1024)

guard let sourceImage = NSImage(contentsOfFile: sourcePath),
      let sourceTiff = sourceImage.tiffRepresentation,
      let sourceRep = NSBitmapImageRep(data: sourceTiff),
      let sourceCG = sourceRep.cgImage else {
    fputs("Missing icon source at \(sourcePath)\n", stderr)
    exit(1)
}

let srcW = CGFloat(sourceCG.width)
let srcH = CGFloat(sourceCG.height)
let minSide = min(srcW, srcH)

// Keep a tighter crop than the original source to avoid the gray checkerboard border.
let cropSide = max(1, minSide * 0.64)
let cropRect = CGRect(
    x: (srcW - cropSide) / 2,
    y: (srcH - cropSide) / 2,
    width: cropSide,
    height: cropSide
)
let cgCropRect = CGRect(
    x: cropRect.origin.x,
    y: srcH - cropRect.origin.y - cropRect.height,
    width: cropRect.width,
    height: cropRect.height
).integral

guard let croppedCG = sourceCG.cropping(to: cgCropRect) else {
    fputs("Failed to crop icon source.\n", stderr)
    exit(1)
}

let width = Int(canvasSize.width)
let height = Int(canvasSize.height)
let bytesPerPixel = 4
let bytesPerRow = width * bytesPerPixel
var pixelData = [UInt8](repeating: 0, count: width * height * bytesPerPixel)
let bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue
guard let context = CGContext(
    data: &pixelData,
    width: width,
    height: height,
    bitsPerComponent: 8,
    bytesPerRow: bytesPerRow,
    space: CGColorSpaceCreateDeviceRGB(),
    bitmapInfo: bitmapInfo
) else {
    fputs("Failed to create drawing context.\n", stderr)
    exit(1)
}

let inset = canvasSize.width * 0.07
let iconRect = CGRect(
    x: inset,
    y: inset,
    width: canvasSize.width - (inset * 2),
    height: canvasSize.height - (inset * 2)
)
let cornerRadius = iconRect.width * 0.22

context.setShouldAntialias(true)
context.interpolationQuality = .high
context.clear(CGRect(origin: .zero, size: canvasSize))
let clipPath = CGPath(
    roundedRect: iconRect,
    cornerWidth: cornerRadius,
    cornerHeight: cornerRadius,
    transform: nil
)
context.addPath(clipPath)
context.clip()
context.draw(croppedCG, in: iconRect)

func insideRoundedRect(x: Int, y: Int, rect: CGRect, radius: CGFloat) -> Bool {
    let px = CGFloat(x) + 0.5
    let py = CGFloat(y) + 0.5
    if px < rect.minX || px > rect.maxX || py < rect.minY || py > rect.maxY {
        return false
    }
    if px >= rect.minX + radius && px <= rect.maxX - radius {
        return true
    }
    if py >= rect.minY + radius && py <= rect.maxY - radius {
        return true
    }
    let cx = px < rect.minX + radius ? rect.minX + radius : rect.maxX - radius
    let cy = py < rect.minY + radius ? rect.minY + radius : rect.maxY - radius
    let dx = px - cx
    let dy = py - cy
    return (dx * dx) + (dy * dy) <= (radius * radius)
}

func pixelOffset(_ x: Int, _ y: Int) -> Int {
    (y * bytesPerRow) + (x * bytesPerPixel)
}

var holes = [Bool](repeating: false, count: width * height)
for y in 0..<height {
    for x in 0..<width {
        guard insideRoundedRect(x: x, y: y, rect: iconRect, radius: cornerRadius) else { continue }
        let idx = y * width + x
        let offset = pixelOffset(x, y)
        let alpha = pixelData[offset + 3]
        if alpha < 8 {
            holes[idx] = true
        }
    }
}

for _ in 0..<128 {
    var changed = 0
    var nextHoles = holes

    for y in 1..<(height - 1) {
        for x in 1..<(width - 1) {
            let idx = y * width + x
            guard holes[idx] else { continue }

            var sumR = 0
            var sumG = 0
            var sumB = 0
            var count = 0

            for ny in (y - 1)...(y + 1) {
                for nx in (x - 1)...(x + 1) {
                    if nx == x && ny == y { continue }
                    guard insideRoundedRect(x: nx, y: ny, rect: iconRect, radius: cornerRadius) else { continue }
                    let nIdx = ny * width + nx
                    if holes[nIdx] { continue }
                    let nOffset = pixelOffset(nx, ny)
                    let nAlpha = pixelData[nOffset + 3]
                    if nAlpha < 8 { continue }
                    sumR += Int(pixelData[nOffset + 0])
                    sumG += Int(pixelData[nOffset + 1])
                    sumB += Int(pixelData[nOffset + 2])
                    count += 1
                }
            }

            if count >= 3 {
                let offset = pixelOffset(x, y)
                pixelData[offset + 0] = UInt8(sumR / count)
                pixelData[offset + 1] = UInt8(sumG / count)
                pixelData[offset + 2] = UInt8(sumB / count)
                pixelData[offset + 3] = 255
                nextHoles[idx] = false
                changed += 1
            }
        }
    }

    holes = nextHoles
    if changed == 0 { break }
}

guard let cgOutput = context.makeImage() else {
    fputs("Failed to finalize icon image.\n", stderr)
    exit(1)
}

let rep = NSBitmapImageRep(cgImage: cgOutput)
guard let pngData = rep.representation(using: .png, properties: [:]) else {
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
