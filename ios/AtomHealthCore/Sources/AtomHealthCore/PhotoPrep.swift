import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Shrinks photos before they leave the phone: a 12-megapixel camera shot is 3 to 5 MB, far too much for the relay
/// (64 KB records, a free-tier budget) and more than the meal analysis needs. The result is a JPEG with the EXIF
/// rotation applied and all metadata (GPS, camera, time) dropped.
public enum PhotoPrep {
    public struct Result: Equatable, Sendable {
        public let jpeg: Data
        public let width: Int
        public let height: Int
        public let originalBytes: Int
    }

    public static let maxSide = 1280
    public static let maxBytes = 300_000
    static let minSide = 640

    public static func resize(_ data: Data, maxSide: Int = PhotoPrep.maxSide, maxBytes: Int = PhotoPrep.maxBytes) -> Result? {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
              let w = props[kCGImagePropertyPixelWidth] as? Int, let h = props[kCGImagePropertyPixelHeight] as? Int,
              w > 0, h > 0 else { return nil }
        var side = min(maxSide, max(w, h))               // never upscale
        var best: Result?
        while true {
            for q in [0.8, 0.7, 0.6, 0.5] as [CGFloat] {
                guard let (jpeg, rw, rh) = encode(src, side: side, quality: q) else { return best }
                let r = Result(jpeg: jpeg, width: rw, height: rh, originalBytes: data.count)
                if best == nil || jpeg.count < best!.jpeg.count { best = r }
                if jpeg.count <= maxBytes { return r }
            }
            let next = Int(Double(side) * 0.8)
            if next < minSide || side <= minSide { return best }
            side = next
        }
    }

    public static func thumbnail(_ data: Data, maxSide: Int = 480) -> Data? {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return encode(src, side: maxSide, quality: 0.7)?.0
    }

    /// Consecutive pieces of at most `size` bytes.
    public static func chunks(_ data: Data, size: Int) -> [Data] {
        guard size > 0, !data.isEmpty else { return [] }
        return stride(from: 0, to: data.count, by: size).map { data.subdata(in: $0..<min($0 + size, data.count)) }
    }

    static func encode(_ src: CGImageSource, side: Int, quality: CGFloat) -> (Data, Int, Int)? {
        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,        // apply the EXIF orientation
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: side]
        guard var cg = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) else { return nil }
        cg = flattened(cg) ?? cg
        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(out, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, cg, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return (out as Data, cg.width, cg.height)
    }

    /// PNG screenshots with transparency would turn black as JPEG; put them on white.
    static func flattened(_ img: CGImage) -> CGImage? {
        switch img.alphaInfo {
        case .none, .noneSkipFirst, .noneSkipLast: return nil
        default: break
        }
        guard let ctx = CGContext(data: nil, width: img.width, height: img.height, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: img.width, height: img.height))
        ctx.draw(img, in: CGRect(x: 0, y: 0, width: img.width, height: img.height))
        return ctx.makeImage()
    }
}
