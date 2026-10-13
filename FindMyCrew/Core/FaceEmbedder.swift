import CoreML
import CoreVideo
import Foundation

enum EmbedderError: LocalizedError, Equatable {
    case notACoreMLModel(String)
    case noImageInput
    case multipleImageInputs([String])
    case extraRequiredInputs([String])
    case nonSquareInput(Int, Int)
    case inputSizeOutOfRange(Int)
    case noEmbeddingOutput
    case embeddingTooSmall(Int)
    case unsupportedAlignment(String)
    case invalidThreshold(String)
    case badOutput(String)
    case predictionFailed(String)

    var errorDescription: String? {
        switch self {
        case .notACoreMLModel(let details):
            "This file isn’t a Core ML model the app can open. Convert the model with coremltools and import the .mlpackage (see scripts/models/README.md). Details: \(details)"
        case .noImageInput:
            "The model has no image input. Convert it with an ImageType input named “image” (see scripts/models/README.md)."
        case .multipleImageInputs(let names):
            "The model has several image inputs (\(names.joined(separator: ", "))); exactly one is expected."
        case .extraRequiredInputs(let names):
            "The model needs inputs the app can’t provide: \(names.joined(separator: ", ")). Only a single image input is supported."
        case .nonSquareInput(let w, let h):
            "The model input must be square, e.g. 112×112 (found \(w)×\(h))."
        case .inputSizeOutOfRange(let size):
            "The model input size \(size)×\(size) is not supported (expected 64–512, normally 112)."
        case .noEmbeddingOutput:
            "The model has no multi-array output. The embedding output should be named “embedding” with shape [1, D]."
        case .embeddingTooSmall(let d):
            "The model output has only \(d) value(s); a face embedding needs at least 32."
        case .unsupportedAlignment(let value):
            "The model expects face alignment “\(value)”, but the app only produces “\(FaceEmbedder.supportedAlignment)” crops."
        case .invalidThreshold(let value):
            "The model’s fmc.defaultThreshold “\(value)” is not a number between -1 and 1."
        case .badOutput(let msg):
            "The model produced an unusable embedding: \(msg)"
        case .predictionFailed(let msg):
            "Face embedding failed: \(msg)"
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
    static let metadataAlignmentKey = "fmc.alignment"
    static let supportedAlignment = "arcface5"
    static let fallbackThreshold: Float = 0.36

    init(compiledModelURL url: URL, displayName: String, computeUnits: MLComputeUnits = .all) throws {
        let config = MLModelConfiguration()
        config.computeUnits = computeUnits
        model = try MLModel(contentsOf: url, configuration: config)
        self.displayName = displayName

        let description = model.modelDescription
        let imageInputs = description.inputDescriptionsByName
            .compactMap { name, d in d.imageConstraint.map { (name, $0) } }
            .sorted { $0.0 < $1.0 }
        guard let (input, constraint) = imageInputs.first(where: { $0.0 == "image" }) ?? imageInputs.first else {
            throw EmbedderError.noImageInput
        }
        if imageInputs.count > 1, !imageInputs.contains(where: { $0.0 == "image" }) {
            throw EmbedderError.multipleImageInputs(imageInputs.map(\.0))
        }
        let extra = description.inputDescriptionsByName
            .filter { $0.key != input && !$0.value.isOptional }
            .map(\.key).sorted()
        guard extra.isEmpty else { throw EmbedderError.extraRequiredInputs(extra) }
        guard constraint.pixelsWide == constraint.pixelsHigh else {
            throw EmbedderError.nonSquareInput(constraint.pixelsWide, constraint.pixelsHigh)
        }
        guard (64...512).contains(constraint.pixelsWide) else {
            throw EmbedderError.inputSizeOutOfRange(constraint.pixelsWide)
        }

        let outputs = description.outputDescriptionsByName.filter { $0.value.type == .multiArray }
        guard let output = outputs["embedding"] != nil ? "embedding" : outputs.keys.sorted().first else {
            throw EmbedderError.noEmbeddingOutput
        }
        inputName = input
        outputName = output
        inputSize = constraint.pixelsWide

        let meta = description.metadata[.creatorDefinedKey] as? [String: String] ?? [:]
        if let alignment = meta[Self.metadataAlignmentKey], alignment != Self.supportedAlignment {
            throw EmbedderError.unsupportedAlignment(alignment)
        }
        if let raw = meta[Self.metadataThresholdKey] {
            guard let t = Float(raw), (-1...1).contains(t) else { throw EmbedderError.invalidThreshold(raw) }
            defaultThreshold = t
        } else {
            defaultThreshold = Self.fallbackThreshold
        }

        // [1, D], [D] or e.g. [1, D, 1, 1]: the embedding is every element of the output.
        let shape = outputs[output]?.multiArrayConstraint?.shape.map(\.intValue) ?? []
        if !shape.isEmpty, shape.allSatisfy({ $0 > 0 }) {
            dimension = shape.reduce(1, *)
        } else {
            // Flexible output shape: find out by running the model once.
            let probe = FaceAligner.blankCrop(size: inputSize).map { [$0] } ?? []
            dimension = (try? Self.predict(model, input: input, output: output, crops: probe).first?.count) ?? 0
        }
    }

    /// Runs the model on a blank face and checks the output is a usable embedding. Returns its length.
    @discardableResult
    func selfTest() throws -> Int {
        guard let probe = FaceAligner.blankCrop(size: inputSize) else {
            throw EmbedderError.predictionFailed("could not allocate a test image")
        }
        let output: [Float]
        do {
            guard let first = try embed([probe]).first else { throw EmbedderError.badOutput("no output") }
            output = first
        } catch let error as EmbedderError {
            throw error
        } catch {
            throw EmbedderError.predictionFailed(error.localizedDescription)
        }
        guard output.count >= 32 else { throw EmbedderError.embeddingTooSmall(output.count) }
        if dimension > 0, output.count != dimension {
            throw EmbedderError.badOutput("expected \(dimension) values, got \(output.count)")
        }
        guard output.allSatisfy(\.isFinite) else { throw EmbedderError.badOutput("contains NaN or infinity") }
        return output.count
    }

    /// Loads an `.mlpackage`/`.mlmodel` (compiling it first) or an `.mlmodelc`.
    static func load(modelAt url: URL, displayName: String) async throws -> FaceEmbedder {
        let compiled = url.pathExtension == "mlmodelc" ? url : try await MLModel.compileModel(at: url)
        return try FaceEmbedder(compiledModelURL: compiled, displayName: displayName)
    }

    /// Returns one raw (not normalised) embedding per input crop.
    func embed(_ crops: [CVPixelBuffer]) throws -> [[Float]] {
        try Self.predict(model, input: inputName, output: outputName, crops: crops)
    }

    private static func predict(_ model: MLModel, input: String, output: String, crops: [CVPixelBuffer]) throws -> [[Float]] {
        guard !crops.isEmpty else { return [] }
        let inputs = try crops.map {
            try MLDictionaryFeatureProvider(dictionary: [input: MLFeatureValue(pixelBuffer: $0)])
        }
        let results = try model.predictions(from: MLArrayBatchProvider(array: inputs), options: MLPredictionOptions())
        return try (0..<results.count).map { i in
            guard let array = results.features(at: i).featureValue(for: output)?.multiArrayValue else {
                throw EmbedderError.predictionFailed("missing output \(output)")
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
