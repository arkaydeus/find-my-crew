import CoreML
import Foundation
import Testing

struct ContractTests {
    private func load(_ name: String) async throws -> FaceEmbedder {
        try await FaceEmbedder.load(modelAt: Fixtures.url("Contracts/\(name).mlmodel"), displayName: name)
    }

    @Test(arguments: ["ValidVector", "ValidBatch", "ValidSpatial", "Flexible"])
    func validOutputShapesAndFlexibleProbe(_ name: String) async throws {
        let embedder = try await load(name)
        #expect(embedder.dimension == 32)
        #expect(try embedder.selfTest() == 32)
        #expect(try embedder.embed([]).isEmpty)
        let crop = try #require(FaceAligner.blankCrop(size: embedder.inputSize))
        let embedding = try embedder.faceEmbedding([crop, crop])
        #expect(embedding.count == 32)
        #expect(abs(Vector.dot(embedding, embedding) - 1) < 1e-5)
    }

    @Test func requiredInputAndImageConstraints() async {
        await #expect(throws: EmbedderError.extraRequiredInputs(["required"])) { _ = try await load("ExtraRequired") }
        await #expect(throws: EmbedderError.nonSquareInput(112, 96)) { _ = try await load("NonSquare") }
        await #expect(throws: EmbedderError.inputSizeOutOfRange(600)) { _ = try await load("TooLarge") }
        await #expect(throws: EmbedderError.unsupportedAlignment("other")) { _ = try await load("BadAlignment") }
    }

    @Test(arguments: [("BadThreshold", "1.01"), ("NaNThreshold", "nan"), ("TextThreshold", "strict")])
    func invalidThresholds(_ name: String, _ value: String) async {
        await #expect(throws: EmbedderError.invalidThreshold(value)) { _ = try await load(name) }
    }

    @Test func supportedThresholdLimitsAndFallback() async throws {
        #expect(try await load("NegativeThreshold").defaultThreshold == -1)
        #expect(try await load("HighThreshold").defaultThreshold == 1)
        #expect(try await load("ValidVector").defaultThreshold == FaceEmbedder.fallbackThreshold)
    }

    @Test func unusableEmbeddingsAreRejectedBeforeInstallation() async throws {
        let small = try await load("TooSmall")
        #expect(throws: EmbedderError.embeddingTooSmall(16)) { try small.selfTest() }
        let nonfinite = try await load("Nonfinite")
        #expect(throws: EmbedderError.badOutput("contains NaN or infinity")) { try nonfinite.selfTest() }
        for name in ["TooSmall", "Nonfinite", "BadThreshold", "ExtraRequired"] {
            await #expect(throws: EmbedderError.self) {
                _ = try await ModelStore.importModel(from: Fixtures.url("Contracts/\(name).mlmodel"))
            }
            #expect(!ModelStore.installedCustomModels().contains("\(name).mlmodelc"))
        }
    }
}
