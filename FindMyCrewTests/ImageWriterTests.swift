import CoreGraphics
import Foundation
import ImageIO
import libwebp
import Testing
import UniformTypeIdentifiers

struct ImageWriterTests {
    @Test(arguments: [(ImageFormat.webp, "webp", UTType.webP), (.jpeg, "jpg", .jpeg), (.png, "png", .png),
                      (.heic, "heic", .heic), (.tiff, "tiff", .tiff)])
    func formatsRoundTripAndRejectUnwritablePaths(_ format: ImageFormat, _ ext: String, _ type: UTType) throws {
        let dir = try TempDir()
        let url = dir.url.appending(path: "image.\(format.fileExtension)")
        #expect(format.fileExtension == ext)
        let context = try #require(CGContext(data: nil, width: 80, height: 48, bitsPerComponent: 8, bytesPerRow: 0,
                                             space: ImageUtils.sRGB, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(TestImages.make(width: 80, height: 48, left: TestImages.red, right: TestImages.blue),
                     in: CGRect(x: 0, y: 0, width: 80, height: 48))
        context.setFillColor(CGColor(srgbRed: 0, green: 1, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 40, height: 24))
        let image = try #require(context.makeImage())
        try ImageWriter.write(image, to: url, format: format, quality: 95)
        let source = try #require(CGImageSourceCreateWithURL(url as CFURL, nil))
        #expect(CGImageSourceGetType(source) as String? == type.identifier)
        let decoded = try ImageLoader.load(url, maxPixel: 512)
        #expect(decoded.width == 80 && decoded.height == 48)
        for (x, y) in [(10, 5), (10, 40), (70, 10)] {
            let expected = TestImages.pixel(image, x: x, y: y), actual = TestImages.pixel(decoded, x: x, y: y)
            #expect(abs(Int(actual.r) - Int(expected.r)) < 30)
            #expect(abs(Int(actual.g) - Int(expected.g)) < 30)
            #expect(abs(Int(actual.b) - Int(expected.b)) < 30)
        }
        let props = try #require(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
        #expect((props[kCGImagePropertyOrientation] as? Int ?? 1) == 1)
        #expect(throws: (any Error).self) {
            try ImageWriter.write(image, to: dir.url.appending(path: "missing/out.\(format.fileExtension)"), format: format, quality: 90)
        }
    }

    @Test func webpPreservesStraightColorsAndAlpha() throws {
        let dir = try TempDir()
        let image = TestImages.make(width: 96, height: 64,
                                    left: CGColor(srgbRed: 0.8, green: 0.4, blue: 0.2, alpha: 0.5),
                                    right: CGColor(srgbRed: 0.2, green: 0.6, blue: 0.8, alpha: 1))
        let url = dir.url.appending(path: "alpha.webp")
        try ImageWriter.write(image, to: url, format: .webp, quality: 100)
        let data = try Data(contentsOf: url)
        var width: Int32 = 0, height: Int32 = 0
        let rgba = try #require(data.withUnsafeBytes {
            WebPDecodeRGBA($0.bindMemory(to: UInt8.self).baseAddress, data.count, &width, &height)
        })
        defer { WebPFree(rgba) }
        #expect(width == 96 && height == 64)
        for (x, expected) in [(20, [204, 102, 51, 128]), (75, [51, 153, 204, 255])] {
            let offset = (20 * Int(width) + x) * 4
            for channel in 0..<4 { #expect(abs(Int(rgba[offset + channel]) - expected[channel]) < 8) }
        }
    }

    @Test func webpEncodingFailureIsReported() throws {
        let dir = try TempDir()
        let image = TestImages.make(width: 16, height: 16, left: TestImages.red)
        let url = dir.url.appending(path: "invalid.webp")
        #expect(throws: ImageWriteError.self) {
            try ImageWriter.write(image, to: url, format: .webp, quality: -1)
        }
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }

    @Test(arguments: [ImageFormat.webp, .jpeg, .heic])
    func lossyQualityChangesEncoding(_ format: ImageFormat) throws {
        let dir = try TempDir()
        let context = try #require(CGContext(data: nil, width: 128, height: 128, bitsPerComponent: 8, bytesPerRow: 0,
                                             space: ImageUtils.sRGB, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        for y in 0..<128 {
            for x in 0..<128 {
                context.setFillColor(CGColor(srgbRed: Double((x * 17 + y * 31) % 256) / 255,
                                             green: Double((x * 23 + y * 7) % 256) / 255,
                                             blue: Double((x * 3 + y * 13) % 256) / 255, alpha: 1))
                context.fill(CGRect(x: x, y: y, width: 1, height: 1))
            }
        }
        let image = try #require(context.makeImage())
        let low = dir.url.appending(path: "low.\(format.fileExtension)"), high = dir.url.appending(path: "high.\(format.fileExtension)")
        try ImageWriter.write(image, to: low, format: format, quality: 10)
        try ImageWriter.write(image, to: high, format: format, quality: 100)
        #expect(try Data(contentsOf: high).count > Data(contentsOf: low).count)
    }
}
