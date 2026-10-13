import Foundation
import Testing

/// Drives the wizard state machine (`AppModel`) through the same calls the SwiftUI views make.
@MainActor
@Suite(.serialized)
struct AppModelTests {
    /// Polls until `condition` holds (the model does its work in background tasks).
    private func waitUntil(_ what: String, timeout: Duration = .seconds(60),
                           _ condition: @MainActor () -> Bool) async throws {
        let deadline = ContinuousClock.now + timeout
        while !condition() {
            guard ContinuousClock.now < deadline else {
                Issue.record("timed out waiting for \(what)")
                throw CancellationError()
            }
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    private func makeModel() async throws -> AppModel {
        UserDefaults.standard.removeObject(forKey: "customModelName")
        UserDefaults.standard.removeObject(forKey: "flipAugmentation")
        UserDefaults.standard.removeObject(forKey: "workingResolution")
        let model = AppModel()
        try await waitUntil("model load") { model.embedder != nil || model.modelError != nil }
        try #require(model.embedder != nil, "\(model.modelError ?? "")")
        return model
    }

    private func addReferences(_ model: AppModel, _ names: [String]) async throws {
        model.addReferencePhotos(names.map(Fixtures.url))
        try await waitUntil("reference faces") { !model.isProcessingReferences }
    }

    private func photo(_ model: AppModel, _ name: String) throws -> ReferencePhoto {
        try #require(model.referencePhotos.first { $0.url.lastPathComponent == name })
    }

    private func library(_ dir: TempDir) throws -> URL {
        let lib = try dir.directory("Library")
        let place = [("2021/Inauguration/IMG_1.jpg", "biden_2021.jpg"), ("2021/Inauguration/IMG_2.jpg", "harris_2021.jpg"),
                     ("2012/Oval Office/IMG_3.jpg", "obama_2012.jpg"), ("1969/Moon/IMG_4.jpg", "apollo11_crew.jpg")]
        for (rel, fixture) in place {
            try dir.directory("Library/" + (rel as NSString).deletingLastPathComponent)
            try FileManager.default.copyItem(at: Fixtures.url(fixture), to: lib.appending(path: rel))
        }
        try dir.file("Library/2021/Inauguration/IMG_1.xmp", Data("<x/>".utf8))
        try dir.file("Library/Broken/bad.jpg", Data(repeating: 0xAB, count: 200))
        return lib
    }

    @Test func wizardEndToEnd() async throws {
        let model = try await makeModel()
        #expect(model.step == .references)
        #expect(!model.canEnter(.source))

        // ① ② Add reference photos (unsupported files are ignored, duplicates too).
        model.addReferencePhotos([Fixtures.url("README.md")])
        try await addReferences(model, ["biden_2013.jpg", "apollo11_crew.jpg", "harris_2021.jpg", "biden_2013.jpg"])
        #expect(model.referencePhotos.count == 3)
        let biden = try photo(model, "biden_2013.jpg"), crew = try photo(model, "apollo11_crew.jpg")
        #expect(biden.faces.count == 1 && biden.faces[0].accepted)            // one face → Yes by default
        #expect(crew.faces.count == 3 && crew.faces.allSatisfy { !$0.accepted }) // several → user must choose
        #expect(biden.faces[0].crop != nil)
        let harrisFace = try photo(model, "harris_2021.jpg").faces[0]
        model.setAccepted(false, faceID: harrisFace.id)
        #expect(model.acceptedFaces.count == 1)
        #expect(model.canEnter(.source) && !model.canEnter(.scan))

        // ③ Choose the folder.
        let dir = try TempDir()
        let lib = try library(dir)
        model.chooseSource(lib)
        try await waitUntil("enumeration") { model.enumeration != nil }
        #expect(model.enumeration?.items.count == 5)
        #expect(model.canEnter(.scan))

        // ④ Scan; the wizard moves to Review by itself. One reference face → the model's own threshold.
        model.startScan()
        #expect(model.threshold == model.embedder?.defaultThreshold)
        #expect(model.step == .scan && model.scanStatus == .running)
        #expect(!model.canEnter(.review))
        try await waitUntil("scan") { model.scanStatus == .finished }
        #expect(model.step == .review)
        #expect(model.processedCount == 5)
        #expect(model.failedResults.map(\.item.relativePath) == ["Broken/bad.jpg"])
        #expect(model.results.map(\.bestScore) == model.results.map(\.bestScore).sorted(by: >))
        #expect(model.photosPerSecond > 0)
        #expect(model.selectedResults.map(\.item.relativePath) == ["2021/Inauguration/IMG_1.jpg"])

        // ⑤ Review: rescue a non-match, exclude the match, move the slider.
        let harris = try #require(model.results.first { $0.item.relativePath.hasSuffix("IMG_2.jpg") })
        model.setIncluded(true, for: harris)
        #expect(model.selectedResults.count == 2)
        let bidenResult = model.results[0]
        model.setIncluded(false, for: bidenResult)
        model.threshold = model.thresholdRange.lowerBound
        model.threshold = model.defaultThreshold
        #expect(model.selectedResults.map(\.item.relativePath) == ["2021/Inauguration/IMG_2.jpg"])
        model.setIncluded(true, for: bidenResult)
        #expect(model.canEnter(.export))

        // ⑥ Export: inside the source is refused; outside copies photos + sidecars, mirroring folders.
        model.destination = lib.appending(path: "2021")
        guard case .failure(let error)? = model.plannedOperations() else { Issue.record("inside-source accepted"); return }
        #expect(error as? ExportError == .destinationInsideSource)
        let dest = try dir.directory("Copied")
        model.destination = dest
        model.startExport()
        #expect(model.isExporting)
        try await waitUntil("export") { model.exportSummary != nil }
        let summary = try #require(model.exportSummary)
        #expect(summary.copied == 3 && summary.failures.isEmpty)
        for rel in ["2021/Inauguration/IMG_1.jpg", "2021/Inauguration/IMG_1.xmp", "2021/Inauguration/IMG_2.jpg"] {
            #expect(FileManager.default.fileExists(atPath: dest.appending(path: rel).path), "\(rel)")
        }
        #expect(!model.isExporting)

        // Changing the reference faces marks the results stale.
        #expect(!model.referencesAreStale)
        model.setAccepted(true, faceID: harrisFace.id)
        #expect(model.referencesAreStale)

        // Removing a photo removes its faces.
        model.removeReferencePhoto(biden.id)
        #expect(model.acceptedFaces.map(\.id) == [harrisFace.id])
    }

    @Test func changingTheModelSettingsKeepsYesNoChoices() async throws {
        let model = try await makeModel()
        try await addReferences(model, ["apollo11_crew.jpg", "obama_2012.jpg"])
        let crew = try photo(model, "apollo11_crew.jpg")
        let chosen = try #require(crew.faces.max { $0.face.boundingBox.minX < $1.face.boundingBox.minX })
        model.setAccepted(true, faceID: chosen.id)
        model.setAccepted(false, faceID: try photo(model, "obama_2012.jpg").faces[0].id)

        model.settings.flipAugmentation = false
        await model.pipelineChanged()
        try await waitUntil("re-embedding") { model.referencePhotos.count == 2 && !model.isProcessingReferences }
        let after = try photo(model, "apollo11_crew.jpg")
        #expect(after.faces.count == 3)
        #expect(after.faces.filter(\.accepted).count == 1)
        let accepted = try #require(after.faces.first { $0.accepted })
        #expect(abs(accepted.face.boundingBox.minX - chosen.face.boundingBox.minX) < 5)
        #expect(try photo(model, "obama_2012.jpg").faces.allSatisfy { !$0.accepted })
        #expect(model.results.isEmpty && model.step == .references)
        model.settings.flipAugmentation = true
    }

    @Test func stopThenRescanNeverMixesResults() async throws {
        let model = try await makeModel()
        try await addReferences(model, ["biden_2013.jpg"])
        let dir = try TempDir()
        try dir.linkedCopies(of: Fixtures.url("apollo11_crew.jpg"), count: 150, prefix: "a")
        try dir.linkedCopies(of: Fixtures.url("biden_2021.jpg"), count: 50, prefix: "b")
        model.chooseSource(dir.url)
        try await waitUntil("enumeration") { model.enumeration != nil }

        model.startScan()
        #expect(model.threshold == model.defaultThreshold)
        try await waitUntil("first results") { model.processedCount >= 20 }
        model.cancelScan()
        #expect(model.scanStatus == .cancelled)
        #expect(model.canEnter(.review))           // partial results are reviewable
        let partial = model.processedCount
        #expect(partial < 200)

        // Restart immediately: late results from the stopped scan must not leak in.
        model.startScan()
        try await waitUntil("rescan") { model.scanStatus == .finished }
        #expect(model.processedCount == 200)
        #expect(Set(model.results.map(\.id)).count == 200)
        #expect(model.selectedResults.count == 50)
    }

    @Test func pauseFreezesProgressAndTheClock() async throws {
        let model = try await makeModel()
        try await addReferences(model, ["harris_2021.jpg"])
        let dir = try TempDir()
        try dir.linkedCopies(of: Fixtures.url("harris_2021.jpg"), count: 120)
        model.chooseSource(dir.url)
        try await waitUntil("enumeration") { model.enumeration != nil }

        model.startScan()
        try await waitUntil("some results") { model.processedCount >= 10 }
        model.togglePause()
        #expect(model.scanStatus == .paused)
        try await Task.sleep(for: .milliseconds(400))   // let in-flight photos land
        let frozen = model.processedCount, elapsed = model.scanElapsed
        try await Task.sleep(for: .seconds(1))
        #expect(model.processedCount == frozen)
        #expect(model.scanElapsed - elapsed < 0.2)     // paused time is not counted
        #expect(!model.canEnter(.review))
        model.togglePause()
        try await waitUntil("finish") { model.scanStatus == .finished }
        #expect(model.processedCount == 120)
        #expect(model.selectedResults.count == 120)
    }

    @Test func brokenCustomModelFallsBackToBuiltIn() async throws {
        let model = try await makeModel()
        model.settings.customModelName = "DoesNotExist.mlmodelc"
        await model.reloadModel()
        #expect(model.embedder?.displayName == ModelStore.builtInDisplayName)
        #expect(model.settings.customModelName.isEmpty)
        #expect(model.modelError?.contains("DoesNotExist") == true)
    }
}
