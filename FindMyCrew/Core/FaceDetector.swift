import CoreGraphics
import Foundation
import Vision

/// A face found by Vision, in pixel coordinates of the analysed image (top-left origin).
struct RawFace: Sendable {
    var boundingBox: CGRect
    /// ArcFace order: image-left eye, image-right eye, nose tip, left mouth corner, right mouth corner
    /// (left/right as seen in an upright face). `nil` when Vision found no landmarks.
    var landmarks5: [CGPoint]?
    var quality: Float?
    var yaw: Double
    var roll: Double
    var pitch: Double
    var confidence: Float
}

/// Face detection, landmarks and capture quality using Apple Vision (runs on the Neural Engine).
struct FaceDetector: Sendable {
    func detect(in image: CGImage) async throws -> [RawFace] {
        let size = CGSize(width: image.width, height: image.height)

        var rectangles = DetectFaceRectanglesRequest()
        if #available(macOS 27.0, *) { rectangles = DetectFaceRectanglesRequest(.revision4) }
        let faces = try await rectangles.perform(on: image)
        guard !faces.isEmpty else { return [] }

        // Landmarks revision 3, deliberately. Revision 4 (the macOS 27 default) returns every point at the same
        // off-face location for most faces that are small relative to the frame (67 % of faces in a test library
        // of event photos), is ~2× slower, and is no more accurate on LFW (TAR@FAR=1 %: 99.5 vs 99.4 %).
        var landmarks = DetectFaceLandmarksRequest(.revision3)
        landmarks.inputFaceObservations = faces
        var quality = DetectFaceCaptureQualityRequest()
        quality.inputFaceObservations = faces
        let landmarkRequest = landmarks, qualityRequest = quality
        async let landmarked = landmarkRequest.perform(on: image)
        async let scored = qualityRequest.perform(on: image)
        let withLandmarks = (try? await landmarked) ?? []
        let withQuality = (try? await scored) ?? []

        var points: [UUID: [CGPoint]] = [:]
        for face in faces {
            let box = face.boundingBox.toImageCoordinates(size, origin: .upperLeft)
            // Implausible landmarks fall back to box-based alignment rather than warping garbage.
            if let lm = Self.closest(to: face, in: withLandmarks)?.landmarks,
               let five = Self.fivePoints(from: lm, imageSize: size), Self.isPlausible(five, in: box) {
                points[face.uuid] = five
            }
        }

        return faces.map { face in
            RawFace(
                boundingBox: face.boundingBox.toImageCoordinates(size, origin: .upperLeft),
                landmarks5: points[face.uuid],
                quality: Self.closest(to: face, in: withQuality)?.captureQuality?.score,
                yaw: face.yaw.converted(to: .degrees).value,
                roll: face.roll.converted(to: .degrees).value,
                pitch: face.pitch.converted(to: .degrees).value,
                confidence: face.confidence
            )
        }
    }

    /// Rejects degenerate landmark sets: every point must lie in (or near) the face box, and the eyes must be
    /// a sensible distance apart. A bad set would warp the crop into garbage that matches other garbage.
    static func isPlausible(_ five: [CGPoint], in box: CGRect) -> Bool {
        guard five.count == 5, five.allSatisfy({ $0.x.isFinite && $0.y.isFinite }) else { return false }
        let area = box.insetBy(dx: -box.width * 0.35, dy: -box.height * 0.35)
        guard five.allSatisfy(area.contains) else { return false }
        let eyes = hypot(five[1].x - five[0].x, five[1].y - five[0].y)
        let size = max(box.width, box.height)
        return eyes > size * 0.15 && eyes < size * 1.2
    }

    /// Follow-up requests may return observations in a different order; match by UUID, then by box overlap.
    private static func closest(to face: FaceObservation, in candidates: [FaceObservation]) -> FaceObservation? {
        if let same = candidates.first(where: { $0.uuid == face.uuid }) { return same }
        let a = face.boundingBox.cgRect
        return candidates
            .map { ($0, iou(a, $0.boundingBox.cgRect)) }
            .filter { $0.1 > 0.5 }
            .max { $0.1 < $1.1 }?.0
    }

    static func iou(_ a: CGRect, _ b: CGRect) -> CGFloat {
        let i = a.intersection(b)
        guard !i.isNull else { return 0 }
        let inter = i.width * i.height
        let union = a.width * a.height + b.width * b.height - inter
        return union > 0 ? inter / union : 0
    }

    /// Reduces Vision's dense landmarks to the 5 ArcFace alignment points.
    ///
    /// Left/right are resolved geometrically (relative to the face's own up direction) rather than
    /// from Vision's naming, so the result is correct for any roll angle.
    static func fivePoints(from lm: FaceObservation.Landmarks2D, imageSize: CGSize) -> [CGPoint]? {
        func points(_ region: FaceObservation.Landmarks2D.Region) -> [CGPoint] {
            region.pointsInImageCoordinates(imageSize, origin: .upperLeft)
        }
        func centroid(_ p: [CGPoint]) -> CGPoint? {
            guard !p.isEmpty else { return nil }
            let s = p.reduce(CGPoint.zero) { CGPoint(x: $0.x + $1.x, y: $0.y + $1.y) }
            return CGPoint(x: s.x / CGFloat(p.count), y: s.y / CGFloat(p.count))
        }

        let lips = points(lm.outerLips)
        guard let eyeA = centroid(points(lm.leftPupil)) ?? centroid(points(lm.leftEye)),
              let eyeB = centroid(points(lm.rightPupil)) ?? centroid(points(lm.rightEye)),
              let nose = centroid(points(lm.nose)) ?? points(lm.noseCrest).last,
              let mouth = centroid(lips), lips.count >= 2
        else { return nil }

        let eyeMid = CGPoint(x: (eyeA.x + eyeB.x) / 2, y: (eyeA.y + eyeB.y) / 2)
        // Face "up" (mouth → eyes), then rotate to get the image-left direction of an upright face.
        let up = CGPoint(x: eyeMid.x - mouth.x, y: eyeMid.y - mouth.y)
        let left = CGPoint(x: up.y, y: -up.x)
        func leftness(_ p: CGPoint) -> CGFloat { (p.x - eyeMid.x) * left.x + (p.y - eyeMid.y) * left.y }

        let (leftEye, rightEye) = leftness(eyeA) >= leftness(eyeB) ? (eyeA, eyeB) : (eyeB, eyeA)
        let sortedLips = lips.sorted { leftness($0) > leftness($1) }
        return [leftEye, rightEye, nose, sortedLips.first!, sortedLips.last!]
    }
}
