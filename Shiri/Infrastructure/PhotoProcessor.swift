import Foundation
import ImageIO
import UniformTypeIdentifiers
import ShiriCore
import UIKit

/// Decode visible-card images away from the main actor, with a bounded, purgeable cache.
/// Originals remain in the repository for editing, backup and export.
actor CardThumbnailCache {
    static let shared = CardThumbnailCache()
    private let cache = NSCache<NSString, UIImage>()
    init() { cache.totalCostLimit = 32 * 1024 * 1024; cache.countLimit = 24 }

    func image(data: Data, cacheKey: String? = nil, maximumPixelSize: Int = 1200) -> UIImage? {
        guard !Task.isCancelled else { return nil }
        let size = max(1, min(maximumPixelSize, 2048))
        let key = cacheKey.map { "\($0)/\(size)" as NSString }
        if let key, let image = cache.object(forKey: key) { return image }
        guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: size,
                kCGImageSourceShouldCacheImmediately: true
              ] as CFDictionary), !Task.isCancelled else { return nil }
        let image = UIImage(cgImage: thumbnail)
        if let key { cache.setObject(image, forKey: key, cost: thumbnail.bytesPerRow * thumbnail.height) }
        return image
    }
}

enum PhotoProcessor {
    static func prepare(_ data: Data, cardID: UUID, index: Int) throws -> Attachment {
        guard data.count <= 80_000_000, let source = CGImageSourceCreateWithData(data as CFData, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = props[kCGImagePropertyPixelWidth] as? Int, let height = props[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0, width <= 40_000, height <= 40_000 else { throw ShiriError.invalidFile("这张图片暂时无法读取，请选择其他图片") }
        var maximum = min(max(width, height), AppLimits.attachmentDimension)
        while maximum > 0 {
            let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways:true, kCGImageSourceCreateThumbnailWithTransform:true, kCGImageSourceThumbnailMaxPixelSize:maximum, kCGImageSourceShouldCacheImmediately:true]
            guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { throw ShiriError.invalidFile("图片压缩失败") }
            for quality in [0.86, 0.72, 0.58, 0.44] {
                let encoded = NSMutableData()
                guard let destination = CGImageDestinationCreateWithData(encoded, UTType.jpeg.identifier as CFString, 1, nil) else { throw ShiriError.invalidFile("无法写入图片") }
                // Only the transformed pixel image is copied. GPS, EXIF, maker notes and original identifiers are omitted.
                CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality:quality] as CFDictionary)
                if CGImageDestinationFinalize(destination), encoded.length <= AppLimits.attachmentBytes {
                    return Attachment(cardID: cardID, data: encoded as Data, width: image.width, height: image.height, sortIndex: index)
                }
            }
            if maximum <= 256 { break }
            maximum = max(256, Int(Double(maximum) * 0.75))
        }
        throw ShiriError.invalidFile("图片仍然超过 2 MB，请选择尺寸较小的图片")
    }
}
