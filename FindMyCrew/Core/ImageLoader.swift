import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

enum ImageLoadError: LocalizedError {
    case unreadable(URL)
    case decodeFailed(URL)

    var errorDescription: String? {
        switch self {
        case .unreadable(let url): "Could not open \(url.lastPathComponent)"
        case .decodeFailed(let url): "Could not decode \(url.lastPathComponent)"
        }
    }
}

/// Decodes images (including HEIC and camera RAW) via ImageIO at a bounded size,
/// with EXIF orientation applied so pixels are always upright.
enum ImageLoader {
    /// Camera RAW extensions. Listed explicitly because not every RAW UTType
    /// is registered on every macOS version.
    static let rawExtensions: Set<String> = [
        "cr2", "cr3", "crw", "nef", "nrw", "arw", "srf", "sr2", "dng", "raf",
        "orf", "rw2", "pef", "srw", "x3f", "3fr", "iiq", "erf", "mos", "mef", "rwl",
    ]

    /// Types that conform to `public.image` but are not photos ImageIO can decode usefully.
    static let excludedExtensions: Set<String> = ["svg", "svgz", "pdf", "ai", "eps", "icns", "ico", "cur"]

    static func isSupported(_ url: URL) -> Bool {
        let ext = url.pathExtension.lowercased()
        guard !ext.isEmpty, !excludedExtensions.contains(ext) else { return false }
        if rawExtensions.contains(ext) { return true }
        guard let type = UTType(filenameExtension: ext) else { return false }
        return type.conforms(to: .image)
    }

    static func isRaw(_ url: URL) -> Bool {
        rawExtensions.contains(url.pathExtension.lowercased())
    }

    /// Loads `url` so that its long edge is at most `maxPixel`, upright.
    static func load(_ url: URL, maxPixel: Int) throws -> CGImage {
        let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithURL(url as CFURL, sourceOptions),
              CGImageSourceGetCount(source) > 0
        else { throw ImageLoadError.unreadable(url) }

        // RAW files usually embed a full-size JPEG preview, which is far cheaper
        // than demosaicing. Use it when it is big enough.
        if isRaw(url),
           let preview = thumbnail(source, maxPixel: maxPixel, always: false),
           max(preview.width, preview.height) >= min(maxPixel, 1024) {
            return preview
        }
        guard let image = thumbnail(source, maxPixel: maxPixel, always: true) else {
            throw ImageLoadError.decodeFailed(url)
        }
        return image
    }

    /// Small upright preview for UI grids.
    static func thumbnail(_ url: URL, maxPixel: Int = 400) throws -> CGImage {
        try load(url, maxPixel: maxPixel)
    }

    private static func thumbnail(_ source: CGImageSource, maxPixel: Int, always: Bool) -> CGImage? {
        let options: [CFString: Any] = [
            always ? kCGImageSourceCreateThumbnailFromImageAlways
                : kCGImageSourceCreateThumbnailFromImageIfAbsent: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }
}

enum ImageUtils {
    static let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!

    /// Copies `rect` (pixel coords, top-left origin) out of `image` into a new,
    /// independent bitmap whose long edge is at most `maxSide`.
    static func crop(_ image: CGImage, to rect: CGRect, maxSide: Int) -> CGImage? {
        let bounds = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        let r = rect.integral.intersection(bounds)
        guard r.width >= 1, r.height >= 1 else { return nil }
        let scale = min(1, CGFloat(maxSide) / max(r.width, r.height))
        let w = max(1, Int(r.width * scale)), h = max(1, Int(r.height * scale))
        guard let ctx = CGContext(
            data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: sRGB,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        ctx.interpolationQuality = .high
        // Draw the full image offset so that `r` lands on the context (CG is bottom-left origin).
        let drawRect = CGRect(
            x: -r.minX * scale,
            y: -(bounds.height - r.maxY) * scale,
            width: bounds.width * scale,
            height: bounds.height * scale
        )
        ctx.draw(image, in: drawRect)
        return ctx.makeImage()
    }
}
