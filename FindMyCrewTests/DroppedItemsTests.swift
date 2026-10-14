import Foundation
import Testing
import UniformTypeIdentifiers

@MainActor
struct DroppedItemsTests {
    private func urlProvider(_ url: URL) -> NSItemProvider {
        NSItemProvider(object: url as NSURL)
    }

    private func register(_ type: UTType, on provider: NSItemProvider, file: URL?,
                          error: Error? = nil, loads: ResultLog? = nil, delay: Bool = false) {
        provider.registerFileRepresentation(forTypeIdentifier: type.identifier, fileOptions: [], visibility: .all) { done in
            loads?.record(URL(filePath: "/\(type.identifier)"))
            if delay {
                DispatchQueue.global().asyncAfter(deadline: .now() + 0.03) { done(file, false, error) }
            } else { done(file, false, error) }
            return nil
        }
    }

    @Test(arguments: ["../../escaped", "/outside/photo.jpg", "a/b/c", "..\\..\\escape", ".", "..", "", "\u{0000}evil", "name.jpg", "percent%2fpath.jpg", String(repeating: "📷", count: 100)])
    func copyNamesStayInsideTheirUUIDDirectory(_ name: String) throws {
        let dir = try TempDir()
        let source = try dir.file("payload.tmp", Data(contentsOf: Fixtures.url("harris_2021.jpg")))
        let copy = try DroppedItems.copy(source, type: .jpeg, name: name, root: dir.url)
        let allocated = copy.url.deletingLastPathComponent()
        #expect(UUID(uuidString: allocated.lastPathComponent) != nil)
        #expect(allocated.deletingLastPathComponent() == dir.url)
        #expect(copy.url.standardizedFileURL.deletingLastPathComponent() == allocated)
        #expect(copy.url.pathExtension == UTType.jpeg.preferredFilenameExtension)
        #expect(ImageLoader.isSupported(copy.url))
        #expect(try ImageLoader.thumbnail(copy.url).width > 0)
        #expect(copy.url.lastPathComponent != "name.jpg.jpg")
    }

    @Test(arguments: ["jpg", "jpeg", "tmp", "png"])
    func extensionMatchesDeclaredType(_ ext: String) throws {
        let dir = try TempDir()
        let source = try dir.file("source.\(ext)", Data(contentsOf: Fixtures.url("harris_2021.jpg")))
        let copy = try DroppedItems.copy(source, type: .jpeg, name: nil, root: dir.url)
        #expect(copy.url.pathExtension == (["jpg", "jpeg"].contains(ext) ? ext : UTType.jpeg.preferredFilenameExtension))
    }

    @Test func finderURLWinsWithoutLoadingAnImageRepresentation() async throws {
        let dir = try TempDir(), loads = ResultLog()
        let provider = urlProvider(Fixtures.url("harris_2021.jpg"))
        register(.jpeg, on: provider, file: Fixtures.url("harris_2021.jpg"), loads: loads)
        let result = await DroppedItems.resolve([provider], copyRoot: dir.url)
        #expect(result.files.map(\.url) == [Fixtures.url("harris_2021.jpg")])
        #expect(result.files.first?.contentID == nil)
        #expect(result.failures.isEmpty && loads.count == 0)
        #expect(try FileManager.default.contentsOfDirectory(atPath: dir.url.path).isEmpty)
    }

    @Test func inaccessibleURLFallsBackToAReadableCopy() async throws {
        let dir = try TempDir()
        let provider = urlProvider(dir.url.appending(path: "missing.jpg"))
        register(.jpeg, on: provider, file: Fixtures.url("harris_2021.jpg"))
        let result = await DroppedItems.resolve([provider], copyRoot: dir.url)
        let file = try #require(result.files.first)
        #expect(result.failures.isEmpty && file.contentID != nil)
        #expect(try Data(contentsOf: file.url) == Data(contentsOf: Fixtures.url("harris_2021.jpg")))
    }

    @Test func unsupportedAndFailingRepresentationsDoNotHideLaterPhotos() async throws {
        let dir = try TempDir(), loads = ResultLog(), provider = NSItemProvider()
        register(.svg, on: provider, file: nil, loads: loads)
        register(.jpeg, on: provider, file: nil, error: CocoaError(.fileReadNoPermission), loads: loads)
        let png = dir.url.appending(path: "payload.tmp")
        try TestImages.write(TestImages.make(width: 16, height: 16, left: TestImages.grey), to: png, type: .png)
        register(.png, on: provider, file: png, loads: loads, delay: true)
        let result = await DroppedItems.resolve([provider], copyRoot: dir.url)
        #expect(result.files.count == 1 && result.failures.isEmpty)
        #expect(result.files.first?.url.pathExtension == "png")
        #expect(try ImageLoader.thumbnail(try #require(result.files.first?.url)).width == 16)
        #expect(loads.paths == [URL(filePath: "/\(UTType.jpeg.identifier)"), URL(filePath: "/\(UTType.png.identifier)")])
    }

    @Test func missingRepresentationTriesTheNextTypeWithoutLeavingCopies() async throws {
        let dir = try TempDir(), provider = NSItemProvider()
        register(.jpeg, on: provider, file: dir.url.appending(path: "missing.jpg"))
        register(.png, on: provider, file: Fixtures.url("harris_2021.jpg"))
        let result = await DroppedItems.resolve([provider], copyRoot: dir.url)
        #expect(result.files.count == 1 && result.failures.isEmpty)
        #expect(try FileManager.default.contentsOfDirectory(atPath: dir.url.path).count == 1)
    }

    @Test func folderTargetNeverLoadsOrCopiesImagesAndNormalizesDirectoryURLs() async throws {
        let dir = try TempDir(), root = try TempDir(), loads = ResultLog(), image = NSItemProvider()
        register(.jpeg, on: image, file: Fixtures.url("harris_2021.jpg"), loads: loads)
        let folder = urlProvider(URL(filePath: dir.url.path, directoryHint: .notDirectory))
        let result = await DroppedItems.resolve([image, urlProvider(Fixtures.url("harris_2021.jpg")), folder],
                                               kind: .folders, copyRoot: root.url)
        #expect(DropKind.folders.acceptedTypes == [.fileURL])
        #expect(result.files.count == 1 && result.files[0].url.hasDirectoryPath)
        #expect(result.files[0].url == dir.url)
        #expect(result.failures.count == 2 && loads.count == 0)
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.url.path).isEmpty)
        let model = AppModel()
        model.chooseSource(result.files[0].url, access: result.files[0].access)
        #expect(model.sourceRoot == dir.url)
    }

    @Test func mixedAndCompleteFailuresHaveActionableFeedback() async throws {
        let dir = try TempDir(), bad = NSItemProvider()
        bad.suggestedName = "Failed photo"
        register(.jpeg, on: bad, file: nil, error: CocoaError(.fileReadNoPermission))
        let mixed = await DroppedItems.resolve([bad, urlProvider(Fixtures.url("harris_2021.jpg"))], copyRoot: dir.url)
        #expect(mixed.files.count == 1 && mixed.failures.count == 1)
        #expect(mixed.failureMessage?.contains("Failed photo") == true)
        #expect(mixed.failureMessage?.contains("Finder") == true)
        let failed = await DroppedItems.resolve([bad], copyRoot: dir.url)
        #expect(failed.files.isEmpty && failed.failureMessage != nil)
        let blocker = try dir.file("not-a-directory")
        let provider = NSItemProvider()
        register(.jpeg, on: provider, file: Fixtures.url("harris_2021.jpg"))
        let copyFailure = await DroppedItems.resolve([provider], copyRoot: blocker)
        #expect(copyFailure.files.isEmpty && copyFailure.failureMessage != nil)
    }

    @Test func copiedFileSurvivesProviderCleanupAndOverlappingReaders() async throws {
        let dir = try TempDir(), root = try TempDir(), provider = NSItemProvider()
        let source = try dir.file("temporary.tmp", Data(contentsOf: Fixtures.url("harris_2021.jpg")))
        register(.jpeg, on: provider, file: source, delay: true)
        var result: DropResult? = await DroppedItems.resolve([provider], copyRoot: root.url)
        let url = try #require(result?.files.first?.url)
        try FileManager.default.removeItem(at: source)
        let first = Task.detached { [file = result?.files.first] in
            try await Task.sleep(for: .milliseconds(30))
            #expect(try ImageLoader.thumbnail(url).width > 0)
            withExtendedLifetime(file) { }
        }
        let second = Task.detached { [file = result?.files.first] in
            try await Task.sleep(for: .milliseconds(60))
            #expect(FileManager.default.fileExists(atPath: url.path))
            withExtendedLifetime(file) { }
        }
        result = nil
        #expect(FileManager.default.fileExists(atPath: url.path))
        try await first.value
        try await second.value
        #expect(!FileManager.default.fileExists(atPath: url.path))
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.url.path).isEmpty)
    }

    @Test func overlappingProviderDeliveriesKeepIndependentReadableCopies() async throws {
        let root = try TempDir()
        do {
            let firstProvider = NSItemProvider(), secondProvider = NSItemProvider()
            register(.jpeg, on: firstProvider, file: Fixtures.url("harris_2021.jpg"), delay: true)
            register(.jpeg, on: secondProvider, file: Fixtures.url("harris_2021.jpg"))
            let firstLoad = Task { await DroppedItems.resolve([firstProvider], copyRoot: root.url) }
            let secondLoad = Task { await DroppedItems.resolve([secondProvider], copyRoot: root.url) }
            let second = await secondLoad.value, first = await firstLoad.value
            let a = try #require(first.files.first), b = try #require(second.files.first)
            #expect(first.failures.isEmpty && second.failures.isEmpty)
            #expect(a.url != b.url && a.contentID == b.contentID)
            #expect(try Data(contentsOf: a.url) == Data(contentsOf: b.url))
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.url.path).isEmpty)
    }

    @Test func failedCopiesAndRejectedCopiesAreRemoved() throws {
        let dir = try TempDir()
        #expect(throws: (any Error).self) {
            _ = try DroppedItems.copy(dir.url.appending(path: "missing"), type: .jpeg, name: nil, root: dir.url)
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: dir.url.path).isEmpty)
        do {
            let rejected = try DroppedItems.copy(Fixtures.url("harris_2021.jpg"), type: .jpeg, name: nil, root: dir.url)
            #expect(FileManager.default.fileExists(atPath: rejected.url.path))
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: dir.url.path).isEmpty)
    }

    @Test func launchPurgeRemovesAbandonedCopiesButPreservesLiveAndUnownedFiles() throws {
        let root = try TempDir()
        let abandoned = try root.directory(UUID().uuidString)
        let recent = try root.directory(UUID().uuidString)
        let unrelated = try root.directory("not-an-owned-copy")
        let live = try DroppedItems.copy(Fixtures.url("harris_2021.jpg"), type: .jpeg, name: nil, root: root.url)
        for directory in [abandoned, unrelated, live.url.deletingLastPathComponent()] {
            try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -120)], ofItemAtPath: directory.path)
        }
        DroppedItems.purgeStaleCopies(root: root.url)
        #expect(!FileManager.default.fileExists(atPath: abandoned.path))
        #expect(FileManager.default.fileExists(atPath: recent.path))
        #expect(FileManager.default.fileExists(atPath: unrelated.path))
        #expect(FileManager.default.fileExists(atPath: live.url.path))
    }
}
