import CoreML
import CoreVideo
import Foundation

enum EmbedderError: LocalizedError {
    case noImageInput
    case noEmbeddingOutput
    case nonSquareInput(Int, Int)
    case predictionFailed(String)

    var errorDescription: String? {
        switch self {
        case .noImageInput: "The model has no image input."
        case .noEmbeddingOutput: "The model has no multi-array (embedding) output."
        case .nonSquareInput(let w, let h): "The model input must be square (found \(w)×\(h))."
        case .predictionFailed(let msg): "Face embedding failed: \(msg)"
        }
    }
}

/// Runs a Core ML face-recognition model that follows the app's I/O contract
/// (square RGB image in, `[1, D]` embedding out). See docs/plan/02-face-models.md.
final class FaceEmbedder: @unchecked Sendable {
    // MLModel predictions are thread-safe; all other state is immutable.
    let model: MLModel
    let inputName: String
    let outputName: String
    let inputSize: Int
    let dimension: Int
    let defaultThreshold: Float
    let displayName: String

    static let metadataThresholdKey = "fmc.defaultThreshold"

    init(compiledModelURL url: URL, displayName: String, computeUnits: MLComputeUnits = .all) throws {
        let config = MLModelConfiguration()
        config.computeUnits = computeUnits
        model = try MLModel(contentsOf: url, configuration: config)
        self.displayName = displayName

        let description = model.modelDescription
        guard let (input, constraint) = description.inputDescriptionsByName
            .compactMap({ name, d in d.imageConstraint.map { (name, $0) } })
            .sorted(by: { $0.0 < $1.0 }).first
        else { throw EmbedderError.noImageInput }
        guard constraint.pixelsWide == constraint.pixelsHigh else {
            throw EmbedderError.nonSquareInput(constraint.pixelsWide, constraint.pixelsHigh)
        }
        let outputs = description.outputDescriptionsByName.filter { $0.value.type == .multiArray }
        guard let output = outputs["embedding"] != nil ? "embedding" : outputs.keys.sorted().first else {
            throw EmbedderError.noEmbeddingOutput
        }
        inputName = input
        outputName = output
        inputSize = constraint.pixelsWide

        let shape = outputs[output]?.multiArrayConstraint?.shape.map(\.intValue) ?? []
        dimension = shape.last ?? 0

        let meta = description.metadata[.creatorDefinedKey] as? [String: String] ?? [:]
        defaultThreshold = meta[Self.metadataThresholdKey].flatMap(Float.init) ?? 0.36
    }

    /// Loads an `.mlpackage`/`.mlmodel` (compiling it first) or an `.mlmodelc`.
    static func load(modelAt url: URL, displayName: String) async throws -> FaceEmbedder {
        let compiled = url.pathExtension == "mlmodelc" ? url : try await MLModel.compileModel(at: url)
        return try FaceEmbedder(compiledModelURL: compiled, displayName: displayName)
    }

    /// Returns one raw (not normalised) embedding per input crop.
    func embed(_ crops: [CVPixelBuffer]) throws -> [[Float]] {
        guard !crops.isEmpty else { return [] }
        let inputs = try crops.map {
            try MLDictionaryFeatureProvider(dictionary: [inputName: MLFeatureValue(pixelBuffer: $0)])
        }
        let results = try model.predictions(from: MLArrayBatchProvider(array: inputs), options: MLPredictionOptions())
        return try (0..<results.count).map { i in
            guard let array = results.features(at: i).featureValue(for: outputName)?.multiArrayValue else {
                throw EmbedderError.predictionFailed("missing output \(outputName)")
            }
            return MLShapedArray<Float>(converting: array).scalars
        }
    }

    /// Embeds an aligned face; with two crops (original + mirror) their embeddings are summed (flip TTA).
    func faceEmbedding(_ crops: [CVPixelBuffer]) throws -> [Float] {
        let vectors = try embed(crops)
        guard var sum = vectors.first else { throw EmbedderError.predictionFailed("no output") }
        for v in vectors.dropFirst() { sum = Vector.add(sum, v) }
        return Vector.normalized(sum)
    }
}
