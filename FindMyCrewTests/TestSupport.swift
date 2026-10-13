import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

private final class BundleToken {}

enum Fixtures {
    static var directory: URL {
        Bundle(for: BundleToken.self).url(forResource: "Fixtures", withExtension: nil)!
    }

    static func url(_ name: String) -> URL { directory.appending(path: name) }

    /// The bundled SFace model, compiled into the test bundle.
    static var modelURL: URL {
        Bundle(for: BundleToken.self).url(forResource: ModelStore.builtInName, withExtension: "mlmodelc")!
    }
}

/// A temporary directory removed when the value is deinitialised.
final class TempDir {
    let url: URL

    init() throws {
        url = FileManager.default.temporaryDirectory.appending(path: "fmc-tests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    deinit { try? FileManager.default.removeItem(at: url) }

    /// Creates `relativePath` (and its parent folders) containing `data`.
    @discardableResult
    func file(_ relativePath: String, _ data: Data = Data("x".utf8)) throws -> URL {
        let u = url.appending(path: relativePath, directoryHint: .notDirectory)
        try FileManager.default.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: u)
        return u
    }

    /// `count` hard links to one copy of `source` (cheap way to build a big folder).
    func linkedCopies(of source: URL, count: Int, prefix: String = "p") throws {
        let original = url.appending(path: ".original-\(source.lastPathComponent)")
        try FileManager.default.copyItem(at: source, to: original)
        for i in 0..<count {
            try FileManager.default.linkItem(at: original, to: url.appending(path: "\(prefix)\(i).\(source.pathExtension)"))
        }
    }

    @discardableResult
    func directory(_ relativePath: String) throws -> URL {
        let u = url.appending(path: relativePath, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }
}

enum TestImages {
    /// A solid-colour (or two-colour, split vertically) RGB bitmap.
    static func make(width: Int, height: Int, left: CGColor, right: CGColor? = nil) -> CGImage {
        let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                            space: ImageUtils.sRGB, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(left)
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        if let right {
            ctx.setFillColor(right)
            ctx.fill(CGRect(x: width / 2, y: 0, width: width - width / 2, height: height))
        }
        return ctx.makeImage()!
    }

    static func write(_ image: CGImage, to url: URL, type: UTType = .jpeg, orientation: Int? = nil) throws {
        let dest = CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, 1, nil)!
        var props: [CFString: Any] = [kCGImageDestinationLossyCompressionQuality: 0.95]
        if let orientation { props[kCGImagePropertyOrientation] = orientation }
        CGImageDestinationAddImage(dest, image, props as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { throw CocoaError(.fileWriteUnknown) }
    }

    /// RGBA of the pixel at (x, y), top-left origin.
    static func pixel(_ image: CGImage, x: Int, y: Int) -> (r: UInt8, g: UInt8, b: UInt8) {
        var data = [UInt8](repeating: 0, count: 4)
        let ctx = CGContext(data: &data, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                            space: ImageUtils.sRGB, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.draw(image, in: CGRect(x: -x, y: -(image.height - 1 - y), width: image.width, height: image.height))
        return (data[0], data[1], data[2])
    }

    static let red = CGColor(srgbRed: 1, green: 0, blue: 0, alpha: 1)
    static let blue = CGColor(srgbRed: 0, green: 0, blue: 1, alpha: 1)
    static let grey = CGColor(srgbRed: 0.5, green: 0.5, blue: 0.5, alpha: 1)
}

func makeResult(_ name: String, scores: [Float], error: String? = nil) -> PhotoResult {
    let item = ScanItem(url: URL(filePath: "/photos/\(name)"), relativePath: name, fileSize: 1)
    let faces = scores.enumerated().map { FaceHit(box: .zero, score: $1, referenceIndex: $0) }
    return PhotoResult(item: item, faces: faces, error: error)
}

enum Memory {
    /// Physical footprint of this process in bytes (what Activity Monitor shows as "Memory").
    static var footprint: Int {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return kr == KERN_SUCCESS ? Int(info.phys_footprint) : 0
    }
}
