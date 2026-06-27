import AppKit
import Foundation
import ImageIO
import UniformTypeIdentifiers

guard CommandLine.arguments.count == 3 else {
    fputs("Usage: PrepareAppIcon <input.png> <output.png>\n", stderr)
    exit(2)
}

let inputURL = URL(fileURLWithPath: CommandLine.arguments[1])
let outputURL = URL(fileURLWithPath: CommandLine.arguments[2])

guard let image = NSImage(contentsOf: inputURL),
      let source = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
    fputs("Cannot read icon source: \(inputURL.path)\n", stderr)
    exit(1)
}

let size = 1024
let bytesPerPixel = 4
let bytesPerRow = size * bytesPerPixel
var pixels = [UInt8](repeating: 0, count: size * bytesPerRow)

guard let context = CGContext(
    data: &pixels,
    width: size,
    height: size,
    bitsPerComponent: 8,
    bytesPerRow: bytesPerRow,
    space: CGColorSpaceCreateDeviceRGB(),
    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
) else {
    fputs("Cannot create icon canvas\n", stderr)
    exit(1)
}

context.interpolationQuality = .high
context.draw(source, in: CGRect(x: 0, y: 0, width: size, height: size))

let inset = 46.0
let cornerRadius = 178.0
let feather = 7.0
let center = Double(size) / 2.0
let half = Double(size) / 2.0 - inset

func roundedRectangleAlpha(x: Double, y: Double) -> Double {
    let qx = abs(x - center) - (half - cornerRadius)
    let qy = abs(y - center) - (half - cornerRadius)
    let outsideX = max(qx, 0)
    let outsideY = max(qy, 0)
    let outsideDistance = sqrt(outsideX * outsideX + outsideY * outsideY)
    let insideDistance = min(max(qx, qy), 0)
    let signedDistance = outsideDistance + insideDistance - cornerRadius

    if signedDistance <= -feather {
        return 1
    }
    if signedDistance >= feather {
        return 0
    }
    return max(0, min(1, (feather - signedDistance) / (2 * feather)))
}

for y in 0..<size {
    for x in 0..<size {
        let index = y * bytesPerRow + x * bytesPerPixel
        let red = Int(pixels[index])
        let green = Int(pixels[index + 1])
        let blue = Int(pixels[index + 2])
        let maxChannel = max(red, green, blue)
        let minChannel = min(red, green, blue)
        let spread = maxChannel - minChannel

        if maxChannel < 24 {
            pixels[index + 3] = 0
        } else if maxChannel < 74 && spread < 16 {
            let alpha = Double(maxChannel - 24) / 50.0
            pixels[index + 3] = UInt8(max(0, min(255, Int(alpha * 255))))
        }

        let maskAlpha = roundedRectangleAlpha(x: Double(x) + 0.5, y: Double(y) + 0.5)
        pixels[index + 3] = UInt8(Double(pixels[index + 3]) * maskAlpha)
    }
}

guard let outputContext = CGContext(
    data: &pixels,
    width: size,
    height: size,
    bitsPerComponent: 8,
    bytesPerRow: bytesPerRow,
    space: CGColorSpaceCreateDeviceRGB(),
    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
), let outputImage = outputContext.makeImage() else {
    fputs("Cannot create output image\n", stderr)
    exit(1)
}

guard let destination = CGImageDestinationCreateWithURL(outputURL as CFURL, UTType.png.identifier as CFString, 1, nil) else {
    fputs("Cannot write icon file: \(outputURL.path)\n", stderr)
    exit(1)
}

CGImageDestinationAddImage(destination, outputImage, nil)
if !CGImageDestinationFinalize(destination) {
    fputs("Failed to finalize icon file: \(outputURL.path)\n", stderr)
    exit(1)
}
