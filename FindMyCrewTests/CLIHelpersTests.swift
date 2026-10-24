import Foundation
import Testing

struct CLIHelpersTests {
    @Test func expandsPathsAndEnumeratesFilesAndFolders() throws {
        let dir = try TempDir()
        let photo = try dir.file("sub/photo.jpg")
        try dir.file("sub/ignored.svg")
        try dir.file(".hidden.jpg")
        #expect(CLI.url("~/Pictures/../photo.jpg").path == NSHomeDirectory() + "/photo.jpg")
        #expect(CLI.url("./photo.jpg").path == URL.currentDirectory().appending(path: "photo.jpg").path)
        #expect(CLI.isDirectory(dir.url))
        #expect(!CLI.isDirectory(photo))
        #expect(try CLI.images(at: photo).map(\.relativePath) == ["photo.jpg"])
        #expect(try CLI.images(at: dir.url).map(\.relativePath) == ["sub/photo.jpg"])
        #expect(throws: (any Error).self) { try CLI.images(at: dir.url.appending(path: "missing")) }
        #expect(throws: (any Error).self) { try CLI.images(at: dir.url.appending(path: "sub/ignored.svg")) }
    }

    @Test func overlappingInputsAliasesAndRawSidecars() throws {
        let dir = try TempDir()
        let jpeg = try dir.file("a/IMG.JPG"), raw = try dir.file("a/img.NEF")
        try dir.file("b/img.nef") // Same stem in another directory is a different photo.
        let alias = dir.url.appending(path: "alias.jpg")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: jpeg)
        let items = try CLI.images(at: raw) + CLI.images(at: jpeg) + CLI.images(at: dir.url) + CLI.images(at: alias)
        let selected = CLI.extractionItems(items)
        #expect(selected.count == 2)
        #expect(selected.map(\.relativePath) == ["IMG.JPG", "b/img.nef"])
        #expect(selected.first?.url == jpeg)
        // Parent paths remain case-sensitive: only the photo's stem is compared case-insensitively.
        let separateFolders = ["Upper/img.nef", "upper/img.jpg"].map {
            ScanItem(url: dir.url.appending(path: $0), relativePath: $0, fileSize: 1)
        }
        #expect(CLI.extractionItems(separateFolders).count == 2)
    }

    @Test func modelLookupResolvesSymlinkedExecutable() throws {
        let dir = try TempDir()
        let binary = try dir.file("install/fmc")
        let alias = dir.url.appending(path: "bin/fmc")
        try dir.directory("bin")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: binary)
        #expect(CLI.modelCandidates(executable: alias).first == binary.deletingLastPathComponent().appending(path: "SFace.mlmodelc"))
    }

    @Test(arguments: [0, 1, 3]) func boundedConcurrencyAndEveryResult(_ limit: Int) async {
        let probe = ConcurrencyProbe(limit: max(1, limit))
        var results: [Int] = []
        await CLI.forEach(Array(0..<12), limit: limit, { value in
            await probe.enter()
            await Task.yield()
            await probe.leave()
            return value
        }) { results.append($0) }
        #expect(results.sorted() == Array(0..<12))
        #expect(await probe.peak == max(1, limit))
        var empty = 0
        await CLI.forEach([Int](), limit: limit, { $0 }) { _ in empty += 1 }
        #expect(empty == 0)
    }

    @Test(arguments: ["ValidVector", "ValidBatch", "ValidSpatial", "Flexible"])
    func customModelsAreValidated(_ name: String) async throws {
        let embedder = try await CLI.loadEmbedder(path: Fixtures.url("Contracts/\(name).mlmodel").path)
        #expect(embedder.dimension == 32)
    }

    @Test(arguments: ["TooSmall", "Nonfinite"])
    func invalidCustomModelsFailAtLoad(_ name: String) async {
        await #expect(throws: EmbedderError.self) {
            _ = try await CLI.loadEmbedder(path: Fixtures.url("Contracts/\(name).mlmodel").path)
        }
    }
}

private actor ConcurrencyProbe {
    let limit: Int
    var active = 0, peak = 0
    var released = false
    var waiters: [CheckedContinuation<Void, Never>] = []
    init(limit: Int) { self.limit = limit }
    func enter() async {
        active += 1
        peak = max(peak, active)
        if active == limit && !released {
            released = true
            waiters.forEach { $0.resume() }
            waiters.removeAll()
        }
        if !released { await withCheckedContinuation { waiters.append($0) } }
    }
    func leave() { active -= 1 }
}
