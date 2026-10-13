import CoreGraphics
import Foundation

/// A detected face with its identity embedding.
struct DetectedFace: Sendable, Identifiable {
    let id = UUID()
    /// Pixel coordinates in the analysed image, top-left origin.
    var boundingBox: CGRect
    var imageSize: CGSize
    var quality: Float?
    var yaw: Double
    var roll: Double
    var hasLandmarks: Bool
    /// Unit-length embedding.
    var embedding: [Float]

    /// Bounding box normalised to 0…1, top-left origin (independent of decode size).
    var normalizedBox: CGRect {
        CGRect(x: boundingBox.minX / imageSize.width, y: boundingBox.minY / imageSize.height,
               width: boundingBox.width / imageSize.width, height: boundingBox.height / imageSize.height)
    }

    var pixelSize: CGFloat { max(boundingBox.width, boundingBox.height) }

    /// Faces that are likely to give unreliable matches.
    var qualityWarning: String? {
        if pixelSize < 64 { return "Small face" }
        if abs(yaw) > 45 { return "Face turned away" }
        if let quality, quality < 0.3 { return "Blurry or poorly lit" }
        if !hasLandmarks { return "Facial features unclear" }
        return nil
    }
}

struct PipelineOptions: Sendable, Equatable {
    /// Long-edge size images are decoded to for detection.
    var workingResolution: Int = 2048
    /// Embed the mirrored crop too and average (more robust, ~2× embedding cost).
    var flipAugmentation = true
    /// Faces smaller than this (pixels at working resolution) are ignored.
    var minimumFaceSize: CGFloat = 20
}

/// Image → faces → aligned crops → embeddings.
struct FacePipeline: Sendable {
    let embedder: FaceEmbedder
    var options = PipelineOptions()
    private let detector = FaceDetector()

    init(embedder: FaceEmbedder, options: PipelineOptions = PipelineOptions()) {
        self.embedder = embedder
        self.options = options
    }

    func process(url: URL) async throws -> (image: CGImage, faces: [DetectedFace]) {
        let image = try ImageLoader.load(url, maxPixel: options.workingResolution)
        return (image, try await process(image: image))
    }

    func process(image: CGImage) async throws -> [DetectedFace] {
        let size = CGSize(width: image.width, height: image.height)
        let raw = try await detector.detect(in: image)
        var faces: [DetectedFace] = []
        for face in raw where max(face.boundingBox.width, face.boundingBox.height) >= options.minimumFaceSize {
            try Task.checkCancellation()
            let points = face.landmarks5 ?? FaceAligner.landmarks(approximatingBox: face.boundingBox)
            let crops = FaceAligner.alignedCrops(
                from: image, landmarks: points, size: embedder.inputSize,
                includeFlipped: options.flipAugmentation
            )
            let embedding = try embedder.faceEmbedding(crops)
            faces.append(DetectedFace(
                boundingBox: face.boundingBox, imageSize: size, quality: face.quality,
                yaw: face.yaw, roll: face.roll, hasLandmarks: face.landmarks5 != nil,
                embedding: embedding
            ))
        }
        return faces
    }
}
