import Foundation
import ImageIO

struct NormalizedPDDImage: Sendable {
    let data: Data
    let extensionName: String
    let mimeType: String
    let width: Int
    let height: Int
}

enum PDDImageNormalizer {
    static func normalize(data: Data, maximumBytes: Int) -> NormalizedPDDImage? {
        guard !data.isEmpty, data.count <= maximumBytes,
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
              image.width > 0, image.height > 0 else { return nil }

        let bytes = [UInt8](data.prefix(8))
        if bytes.count >= 3, bytes[0...2].elementsEqual([0xff, 0xd8, 0xff]) {
            return NormalizedPDDImage(
                data: data, extensionName: "jpg", mimeType: "image/jpeg",
                width: image.width, height: image.height
            )
        }
        if bytes == [0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a] {
            return NormalizedPDDImage(
                data: data, extensionName: "png", mimeType: "image/png",
                width: image.width, height: image.height
            )
        }

        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            output, "public.jpeg" as CFString, 1, nil
        ) else { return nil }
        CGImageDestinationAddImage(
            destination,
            image,
            [kCGImageDestinationLossyCompressionQuality: 0.9] as CFDictionary
        )
        guard CGImageDestinationFinalize(destination) else { return nil }
        let converted = output as Data
        guard !converted.isEmpty, converted.count <= maximumBytes else { return nil }
        return NormalizedPDDImage(
            data: converted, extensionName: "jpg", mimeType: "image/jpeg",
            width: image.width, height: image.height
        )
    }
}
