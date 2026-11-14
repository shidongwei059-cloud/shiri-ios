import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

// Export the selected C artwork at the size required by the iOS asset catalog.
// The original artwork stays in Docs/BrandOptions20260913; no mark is redrawn here.
guard CommandLine.arguments.count >= 2 else {
    fatalError("Usage: swift render_icon.swift output.png [source.png]")
}
let output = URL(fileURLWithPath: CommandLine.arguments[1])
let defaultSource = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    .appendingPathComponent("../Docs/BrandOptions20260913/C_shiri_warm.png").standardizedFileURL
let source = CommandLine.arguments.count > 2 ? URL(fileURLWithPath: CommandLine.arguments[2]) : defaultSource
guard let input = CGImageSourceCreateWithURL(source as CFURL, nil),
      let artwork = CGImageSourceCreateImageAtIndex(input, 0, nil),
      artwork.width == artwork.height else { fatalError("A square source image is required") }
let size = 1024
guard let context = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8,
                              bytesPerRow: size * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                              bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else {
    fatalError("Cannot create icon export context")
}
context.interpolationQuality = .high
context.draw(artwork, in: CGRect(x: 0, y: 0, width: size, height: size))
guard let image = context.makeImage(),
      let destination = CGImageDestinationCreateWithURL(output as CFURL, UTType.png.identifier as CFString, 1, nil) else {
    fatalError("Cannot open icon output")
}
CGImageDestinationAddImage(destination, image, nil)
guard CGImageDestinationFinalize(destination) else { fatalError("Cannot write app icon") }
