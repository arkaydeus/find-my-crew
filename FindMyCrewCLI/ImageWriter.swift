import ArgumentParser
import CoreGraphics
import Foundation
import ImageIO
import libwebp
import UniformTypeIdentifiers

enum ImageFormat: String, CaseIterable, ExpressibleByArgument {
    case webp, jpeg, png, heic, tiff

    var fileExtension: String { self == .jpeg ? "jpg" : rawValue }

    var type: UTType {
        switch self {
        case .webp: .webP
        case .jpeg: .jpeg
        case .png: .png
        case .heic: .heic
        case .tiff: .tiff
        }
    }

    var isLossy: Bool { self == .webp || self == .jpeg || self == .heic }
}

enum ImageWriteError: LocalizedError {
    case encodeFailed(URL)

    var errorDescription: String? {
        switch self {
        case .encodeFailed(let url): "Could not encode \(url.lastPathComponent)"
        }
    }
}

/// Writes images as WebP (libwebp: ImageIO decodes WebP but can't encode it) or via ImageIO.
enum ImageWriter {
    /// `quality` is 0…100 and applies to the lossy formats.
    static func write(_ image: CGImage, to url: URL, format: ImageFormat, quality: Int) throws {
        if format == .webp {
            try encodeWebP(image, quality: quality, url: url).write(to: url)
            return
        }
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, format.type.identifier as CFString, 1, nil)
        else { throw ImageWriteError.encodeFailed(url) }
        let properties = format.isLossy
            ? [kCGImageDestinationLossyCompressionQuality: Double(quality) / 100] as CFDictionary : nil
        CGImageDestinationAddImage(dest, image, properties)
        guard CGImageDestinationFinalize(dest) else { throw ImageWriteError.encodeFailed(url) }
    }

    private static func encodeWebP(_ image: CGImage, quality: Int, url: URL) throws -> Data {
        let w = image.width, h = image.height, stride = w * 4
        var pixels = [UInt8](repeating: 0, count: stride * h)
        // Straight (non-premultiplied) RGBA is what libwebp expects; CG only renders premultiplied, which is
        // identical for opaque photos.
        let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let ctx = CGContext(
                data: buffer.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: stride,
                space: ImageUtils.sRGB, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return false }
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        guard drawn else { throw ImageWriteError.encodeFailed(url) }
        var output: UnsafeMutablePointer<UInt8>?
        let size = WebPEncodeRGBA(pixels, Int32(w), Int32(h), Int32(stride), Float(quality), &output)
        defer { WebPFree(output) }
        guard size > 0, let output else { throw ImageWriteError.encodeFailed(url) }
        return Data(bytes: output, count: size)
    }
}
