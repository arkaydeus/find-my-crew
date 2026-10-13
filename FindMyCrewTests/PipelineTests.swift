import CoreGraphics
import Foundation
import Testing

/// Integration tests: Vision detection + the bundled SFace model on public-domain fixture photos.
@Suite(.serialized)
struct PipelineTests {
    static let embedder = try! FaceEmbedder(compiledModelURL: Fixtures.modelURL, displayName: ModelStore.builtInDisplayName)

    var pipeline: FacePipeline { FacePipeline(embedder: Self.embedder) }

    private func faces(_ name: String) async throws -> [DetectedFace] {
        try await pipeline.process(url: Fixtures.url(name)).faces
    }

    private func onlyFace(_ name: String) async throws -> DetectedFace {
        let found = try await faces(name)
        try #require(found.count == 1, "\(name): expected 1 face, found \(found.count)")
        return found[0]
    }

    @Test func bundledModelFollowsTheContract() throws {
        let e = Self.embedder
        #expect(e.inputSize == 112)
        #expect(e.dimension == 128)
        #expect(e.defaultThreshold > 0.2 && e.defaultThreshold < 0.6)
        #expect(try e.selfTest() == 128)
    }

    @Test func detectsOneFaceWithLandmarksAndUnitEmbedding() async throws {
        let face = try await onlyFace("biden_2013.jpg")
        #expect(face.hasLandmarks)
        #expect(face.embedding.count == 128)
        let norm = Vector.dot(face.embedding, face.embedding).squareRoot()
        #expect(abs(norm - 1) < 1e-4)
        #expect(face.pixelSize > 64)
        #expect(face.qualityWarning == nil)
        let box = face.normalizedBox
        #expect(box.minX >= 0 && box.maxX <= 1 && box.minY >= 0 && box.maxY <= 1)
        // Portrait: the face is in the upper-middle part of the frame.
        #expect(box.midX > 0.3 && box.midX < 0.7 && box.midY < 0.6)
    }

    @Test func handlesImagesWithManyFaces() async throws {
        let found = try await faces("apollo11_crew.jpg")
        #expect(found.count == 3)
        #expect(Set(found.map { Int($0.boundingBox.midX / 50) }).count == 3)   // three distinct people
    }

    @Test func handlesImagesWithNoFaces() async throws {
        let blank = TestImages.make(width: 800, height: 600, left: TestImages.grey)
        #expect(try await pipeline.process(image: blank).isEmpty)
    }

    @Test func samePersonScoresAboveAndDifferentPeopleBelowTheDefaultThreshold() async throws {
        let biden2013 = try await onlyFace("biden_2013.jpg").embedding
        let biden2021 = try await onlyFace("biden_2021.jpg").embedding
        let harris = try await onlyFace("harris_2021.jpg").embedding
        let obama = try await onlyFace("obama_2012.jpg").embedding
        let t = Self.embedder.defaultThreshold

        let same = Vector.dot(biden2013, biden2021)
        #expect(same > t, "same person cosine \(same) ≤ threshold \(t)")
        for (name, other) in [("harris", harris), ("obama", obama)] {
            for (refName, ref) in [("biden2013", biden2013), ("biden2021", biden2021)] {
                let s = Vector.dot(ref, other)
                #expect(s < t, "\(refName) vs \(name) cosine \(s) ≥ threshold \(t)")
            }
        }
        #expect(Vector.dot(harris, obama) < t)
    }

    @Test func flipAugmentationKeepsEmbeddingsConsistent() async throws {
        var options = PipelineOptions()
        options.flipAugmentation = false
        let plain = try await FacePipeline(embedder: Self.embedder, options: options)
            .process(url: Fixtures.url("biden_2013.jpg")).faces
        let tta = try await onlyFace("biden_2013.jpg")
        try #require(plain.count == 1)
        #expect(Vector.dot(plain[0].embedding, tta.embedding) > 0.9)
    }

    /// Regression: Vision landmarks revision 4 collapses every point to one off-face location for faces that
    /// are small relative to the frame; the warped crops were identical, so unrelated people "matched".
    @Test func smallFacesInLargeFramesGetRealLandmarks() async throws {
        let portrait = try ImageLoader.load(Fixtures.url("obama_2012.jpg"), maxPixel: 2048)
        let (w, h) = (2400, 1800)
        let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: ImageUtils.sRGB,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(CGColor(srgbRed: 0.3, green: 0.35, blue: 0.4, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        let pw = CGFloat(portrait.width) / 2, ph = CGFloat(portrait.height) / 2
        ctx.draw(portrait, in: CGRect(x: CGFloat(w) * 0.55, y: CGFloat(h) - ph - 40, width: pw, height: ph))

        let found = try await pipeline.process(image: ctx.makeImage()!)
        try #require(found.count == 1)
        #expect(found[0].hasLandmarks)
        let reference = try await onlyFace("obama_2012.jpg").embedding
        #expect(Vector.dot(reference, found[0].embedding) > Self.embedder.defaultThreshold)
        // A different person must not match the collapsed-landmark crop either.
        let biden = try await onlyFace("biden_2021.jpg").embedding
        #expect(Vector.dot(biden, found[0].embedding) < Self.embedder.defaultThreshold)
    }

    @Test func implausibleLandmarksAreRejected() {
        let box = CGRect(x: 100, y: 100, width: 100, height: 100)
        let good = FaceAligner.landmarks(approximatingBox: box)
        #expect(FaceDetector.isPlausible(good, in: box))
        #expect(!FaceDetector.isPlausible(Array(repeating: CGPoint(x: -605, y: 0), count: 5), in: box))
        #expect(!FaceDetector.isPlausible(Array(repeating: CGPoint(x: 150, y: 150), count: 5), in: box))
        #expect(!FaceDetector.isPlausible(good.map { CGPoint(x: $0.x + 400, y: $0.y) }, in: box))
        #expect(!FaceDetector.isPlausible(Array(good.prefix(4)), in: box))
    }

    @Test func rotatedPhotosStillMatch() async throws {
        // The same portrait saved with EXIF "rotate 90° CW": ImageLoader must undo it before detection.
        let dir = try TempDir()
        let upright = try ImageLoader.load(Fixtures.url("biden_2021.jpg"), maxPixel: 2048)
        let ctx = CGContext(data: nil, width: upright.height, height: upright.width, bitsPerComponent: 8, bytesPerRow: 0,
                            space: ImageUtils.sRGB, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        // Store it rotated 90° counter-clockwise; orientation 6 tells viewers to rotate it back.
        ctx.translateBy(x: 0, y: CGFloat(upright.width))
        ctx.rotate(by: -.pi / 2)
        ctx.draw(upright, in: CGRect(x: 0, y: 0, width: upright.width, height: upright.height))
        let url = dir.url.appending(path: "rotated.jpg")
        try TestImages.write(ctx.makeImage()!, to: url, orientation: 6)

        let reference = try await onlyFace("biden_2013.jpg").embedding
        let rotated = try await pipeline.process(url: url).faces
        try #require(rotated.count == 1)
        #expect(Vector.dot(reference, rotated[0].embedding) > Self.embedder.defaultThreshold)
    }
}

/// End-to-end scan over a folder (ScanEngine + matching), including corrupt files and cancellation.
@Suite(.serialized)
struct ScanEngineTests {
    var pipeline: FacePipeline { FacePipeline(embedder: PipelineTests.embedder) }

    private func references() async throws -> ReferenceSet {
        let faces = try await pipeline.process(url: Fixtures.url("biden_2013.jpg")).faces
        return ReferenceSet(embeddings: faces.map(\.embedding))
    }

    @Test func scansAFolderAndScoresEveryPhoto() async throws {
        let dir = try TempDir()
        for name in ["biden_2021.jpg", "harris_2021.jpg", "obama_2012.jpg", "apollo11_crew.jpg"] {
            try dir.directory("sub/\(name.prefix(5))")
            try FileManager.default.copyItem(at: Fixtures.url(name), to: dir.url.appending(path: "sub/\(name.prefix(5))/\(name)"))
        }
        try dir.file("broken.jpg", Data(repeating: 0xFF, count: 300))
        try dir.file("blank.png", { () -> Data in
            let url = dir.url.appending(path: "tmp.png")
            try! TestImages.write(TestImages.make(width: 64, height: 64, left: TestImages.grey), to: url, type: .png)
            defer { try? FileManager.default.removeItem(at: url) }
            return try! Data(contentsOf: url)
        }())

        let items = try FolderEnumerator.enumerate(root: dir.url).items
        #expect(items.count == 6)
        var results: [PhotoResult] = []
        for await r in ScanEngine.run(items: items, references: try await references(), pipeline: pipeline, concurrency: 3) {
            results.append(r)
        }
        #expect(results.count == 6)
        let byName = Dictionary(uniqueKeysWithValues: results.map { ($0.item.url.lastPathComponent, $0) })
        #expect(byName["broken.jpg"]?.error != nil)
        #expect(byName["blank.png"]?.faces.isEmpty == true)
        #expect(byName["blank.png"]?.error == nil)
        #expect(byName["apollo11_crew.jpg"]?.faces.count == 3)

        let matched = Matcher(threshold: PipelineTests.embedder.defaultThreshold).selected(results)
        #expect(matched.map(\.item.url.lastPathComponent) == ["biden_2021.jpg"])
        #expect(byName["biden_2021.jpg"]?.bestFace?.referenceIndex == 0)
    }

    /// Plan 06: a 1 000-image folder scans with bounded memory (growth < 300 MB).
    @Test func thousandImageScanUsesConstantMemory() async throws {
        let dir = try TempDir()
        try dir.linkedCopies(of: Fixtures.url("apollo11_crew.jpg"), count: 500, prefix: "a")
        try dir.linkedCopies(of: Fixtures.url("biden_2021.jpg"), count: 500, prefix: "b")
        let items = try FolderEnumerator.enumerate(root: dir.url).items
        try #require(items.count == 1000)
        let refs = try await references()

        let baseline = Memory.footprint
        var peak = baseline
        var results: [PhotoResult] = []
        let start = ContinuousClock.now
        for await r in ScanEngine.run(items: items, references: refs, pipeline: pipeline) {
            results.append(r)
            if results.count.isMultiple(of: 50) { peak = max(peak, Memory.footprint) }
        }
        let seconds = Double((ContinuousClock.now - start).components.seconds) + 0.001
        print("Scanned 1000 images in \(String(format: "%.1f", seconds)) s (\(Int(1000 / seconds)) photos/s); "
              + "memory growth \((peak - baseline) >> 20) MB")

        #expect(results.count == 1000)
        #expect(results.allSatisfy { $0.error == nil })
        #expect(peak - baseline < 300 << 20, "memory grew by \((peak - baseline) >> 20) MB")
        let matched = Matcher(threshold: PipelineTests.embedder.defaultThreshold).selected(results)
        #expect(matched.count == 500)
        #expect(matched.allSatisfy { $0.item.relativePath.hasPrefix("b") })
    }

    @Test func cancellationStopsQuickly() async throws {
        let dir = try TempDir()
        try dir.linkedCopies(of: Fixtures.url("apollo11_crew.jpg"), count: 400)
        let items = try FolderEnumerator.enumerate(root: dir.url).items
        let refs = try await references()
        let pipeline = pipeline

        let scan = Task {
            var count = 0
            for await _ in ScanEngine.run(items: items, references: refs, pipeline: pipeline) { count += 1 }
            return count
        }
        try await Task.sleep(for: .milliseconds(300))
        let clock = ContinuousClock()
        let start = clock.now
        scan.cancel()
        let processed = await scan.value
        #expect(clock.now - start < .seconds(1))
        #expect(processed < items.count)
    }

    @Test func pauseHoldsTheScanUntilResumed() async throws {
        let dir = try TempDir()
        try dir.linkedCopies(of: Fixtures.url("harris_2021.jpg"), count: 40)
        let items = try FolderEnumerator.enumerate(root: dir.url).items
        let gate = PauseGate()
        await gate.setPaused(true)
        let refs = try await references()
        let pipeline = pipeline
        let seen = ResultCounter()
        let scan = Task {
            for await _ in ScanEngine.run(items: items, references: refs, pipeline: pipeline, concurrency: 2, gate: gate) {
                seen.increment()
            }
        }
        try await Task.sleep(for: .milliseconds(1500))
        // While paused, at most the first result gets through before the engine stops at the gate.
        #expect(seen.value <= 1)
        await gate.setPaused(false)
        await scan.value
        #expect(seen.value == 40)
    }
}

private final class ResultCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func increment() { lock.withLock { count += 1 } }
    var value: Int { lock.withLock { count } }
}

/// Custom-model import (Settings → Import Core ML Model…): file types and contract validation.
struct ModelImportTests {
    @Test func importPanelAcceptsEveryCoreMLFormat() throws {
        let dir = try TempDir()
        let mlmodel = try dir.file("A.mlmodel", Data("x".utf8))
        let compiled = dir.url.appending(path: "C.mlmodelc", directoryHint: .isDirectory)
        try FileManager.default.copyItem(at: Fixtures.modelURL, to: compiled)
        for url in [Fixtures.url("NoImageInput.mlpackage"), mlmodel, compiled] {
            let type = try #require(try url.resourceValues(forKeys: [.contentTypeKey]).contentType)
            #expect(ModelStore.importableTypes.contains { type.conforms(to: $0) }, "\(url.lastPathComponent) is \(type.identifier)")
        }
    }

    @Test func corruptFilesGetAPlainMessage() async throws {
        let dir = try TempDir()
        let bogus = try dir.file("Bogus.mlmodel", Data("not a model".utf8))
        do {
            _ = try await ModelStore.importModel(from: bogus)
            Issue.record("corrupt model was imported")
        } catch let error as EmbedderError {
            guard case .notACoreMLModel = error else { Issue.record("unexpected \(error)"); return }
            #expect(error.localizedDescription.hasPrefix("This file isn’t a Core ML model"))
        }
    }

    @Test func contractViolationsAreReportedPrecisely() async throws {
        await #expect(throws: EmbedderError.noImageInput) {
            _ = try await ModelStore.importModel(from: Fixtures.url("NoImageInput.mlpackage"))
        }
        #expect(!ModelStore.installedCustomModels().contains("NoImageInput.mlmodelc"))
    }
}
