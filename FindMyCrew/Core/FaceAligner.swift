import CoreGraphics
import CoreVideo
import Foundation

/// Warps a face into the canonical ArcFace 112×112 crop using a 5-point similarity transform.
enum FaceAligner {
    /// InsightFace/ArcFace reference landmarks for a 112×112 crop.
    static let template112: [CGPoint] = [
        CGPoint(x: 38.2946, y: 51.6963),
        CGPoint(x: 73.5318, y: 51.5014),
        CGPoint(x: 56.0252, y: 71.7366),
        CGPoint(x: 41.5493, y: 92.3655),
        CGPoint(x: 70.7299, y: 92.2041),
    ]

    static func template(size: Int) -> [CGPoint] {
        let s = CGFloat(size) / 112
        return template112.map { CGPoint(x: $0.x * s, y: $0.y * s) }
    }

    /// Least-squares similarity transform (rotation, uniform scale, translation) mapping `src` onto `dst`.
    /// Both point sets use the same (top-left) convention.
    static func similarityTransform(from src: [CGPoint], to dst: [CGPoint]) -> CGAffineTransform {
        precondition(src.count == dst.count && !src.isEmpty)
        let n = CGFloat(src.count)
        let ms = src.reduce(CGPoint.zero) { CGPoint(x: $0.x + $1.x / n, y: $0.y + $1.y / n) }
        let md = dst.reduce(CGPoint.zero) { CGPoint(x: $0.x + $1.x / n, y: $0.y + $1.y / n) }
        var a: CGFloat = 0, b: CGFloat = 0, norm: CGFloat = 0
        for (s, d) in zip(src, dst) {
            let sx = s.x - ms.x, sy = s.y - ms.y
            let dx = d.x - md.x, dy = d.y - md.y
            a += sx * dx + sy * dy
            b += sx * dy - sy * dx
            norm += sx * sx + sy * sy
        }
        guard norm > 0 else { return .identity }
        let c = a / norm, s = b / norm
        // u = c·x − s·y + tx ; v = s·x + c·y + ty
        let tx = md.x - (c * ms.x - s * ms.y)
        let ty = md.y - (s * ms.x + c * ms.y)
        return CGAffineTransform(a: c, b: s, c: -s, d: c, tx: tx, ty: ty)
    }

    /// Approximate landmarks from a bounding box, for faces where Vision gave no landmarks.
    static func landmarks(approximatingBox box: CGRect) -> [CGPoint] {
        // The ArcFace template occupies roughly the central region of a 112 crop around a detector box.
        template112.map {
            CGPoint(x: box.minX + ($0.x - 8) / 96 * box.width, y: box.minY + ($0.y - 8) / 104 * box.height)
        }
    }

    /// Renders the aligned crop (and optionally its mirror image) into BGRA pixel buffers.
    static func alignedCrops(
        from image: CGImage, landmarks: [CGPoint], size: Int, includeFlipped: Bool
    ) -> [CVPixelBuffer] {
        let m = similarityTransform(from: landmarks, to: template(size: size))
        var out: [CVPixelBuffer] = []
        if let b = render(image, transform: m, size: size, flipped: false) { out.append(b) }
        if includeFlipped, let b = render(image, transform: m, size: size, flipped: true) { out.append(b) }
        return out
    }

    private static func render(_ image: CGImage, transform m: CGAffineTransform, size: Int, flipped: Bool) -> CVPixelBuffer? {
        var buffer: CVPixelBuffer?
        let attrs: [CFString: Any] = [
            kCVPixelBufferCGImageCompatibilityKey: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey: true,
            kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
        ]
        guard CVPixelBufferCreate(kCFAllocatorDefault, size, size, kCVPixelFormatType_32BGRA,
                                  attrs as CFDictionary, &buffer) == kCVReturnSuccess,
              let buffer else { return nil }

        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let ctx = CGContext(
            data: CVPixelBufferGetBaseAddress(buffer), width: size, height: size, bitsPerComponent: 8,
            bytesPerRow: CVPixelBufferGetBytesPerRow(buffer), space: ImageUtils.sRGB,
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        ) else { return nil }

        let h = CGFloat(image.height), s = CGFloat(size)
        ctx.setFillColor(gray: 0, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: s, height: s))
        ctx.interpolationQuality = .high

        // CG user space (bottom-left) of the source → top-left image pixels → template → (mirror) → CG output space.
        let cgToImage = CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: h)
        let mirror = flipped ? CGAffineTransform(a: -1, b: 0, c: 0, d: 1, tx: s, ty: 0) : .identity
        let templateToCG = CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: s)
        ctx.concatenate(cgToImage.concatenating(m).concatenating(mirror).concatenating(templateToCG))
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: CGFloat(image.width), height: h))
        return buffer
    }
}
