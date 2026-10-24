import CoreGraphics
import Foundation

/// Face crops as written by `fmc extract`: square, centred on the detected face, with enough margin that the
/// crop is detected again when it is used as a reference photo.
enum FaceCrops {
    /// The default margin, as a fraction of the face's long side added on every edge.
    static let defaultPadding: CGFloat = 0.4

    /// A square around `box` (pixel coords, top-left origin), grown by `padding` × its long side on every edge,
    /// shifted to stay inside an image of `size` where it fits. A square larger than the image is left to the
    /// crop to clip.
    static func cropRect(around box: CGRect, padding: CGFloat, in size: CGSize) -> CGRect {
        let side = max(box.width, box.height) * (1 + 2 * max(0, padding))
        var r = CGRect(x: box.midX - side / 2, y: box.midY - side / 2, width: side, height: side)
        if side <= size.width { r.origin.x = min(max(0, r.minX), size.width - side) }
        if side <= size.height { r.origin.y = min(max(0, r.minY), size.height - side) }
        return r
    }

    /// Faces in reading order (left to right, then top to bottom), so face numbers are stable between runs.
    static func readingOrder(_ boxes: [CGRect]) -> [Int] {
        boxes.indices.sorted { a, b in
            let p = boxes[a], q = boxes[b]
            return p.minX != q.minX ? p.minX < q.minX : p.minY < q.minY
        }
    }

    /// `2024/IMG_0001.HEIC`, face 2, `webp` → `2024/IMG_0001_face2.webp`.
    static func outputPath(for relativePath: String, face: Int, fileExtension: String) -> String {
        let base = (relativePath as NSString).deletingPathExtension
        return "\(base)_face\(face).\(fileExtension)"
    }
}
