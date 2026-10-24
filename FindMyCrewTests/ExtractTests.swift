import CoreGraphics
import Foundation
import Testing

struct ExtractTests {
    @Test(arguments: [false, true])
    func concurrentCollidingJobsKeepEveryCrop(_ overwrite: Bool) async throws {
        let dir = try TempDir()
        var items: [ScanItem] = []
        // Two roots plus a same-stem, different-format photo. Hold every writer until all jobs
        // have chosen their destinations, deterministically exposing an exists-then-write race.
        for (index, path) in ["a/sub/photo.jpg", "b/sub/photo.jpg", "b/sub/photo.png"].enumerated() {
            let image = TestImages.make(width: 80, height: 80, left: [TestImages.red, TestImages.blue, TestImages.grey][index])
            let url = try dir.file(path)
            try TestImages.write(image, to: url, type: .png)
            items.append(ScanItem(url: url, relativePath: "sub/" + url.lastPathComponent, fileSize: 1))
        }
        let output = try dir.directory("out")
        let base = try dir.file("out/sub/photo_face1.png", Data("original".utf8))
        let numbered = try dir.file("out/sub/photo_face1 (1).png", Data("numbered".utf8))
        let job = Extract.Job(output: output, format: .png, quality: 90, size: 32, padding: 0,
                              destinations: .init(overwrite: overwrite), options: PipelineOptions())
        let barrier = CropWriteBarrier(count: items.count)
        var outcomes: [Extract.Outcome] = []
        await CLI.forEach(items, limit: 3, { item in
            await job.extract(item, detect: { _ in [CGRect(x: 10, y: 10, width: 40, height: 40)] }, write: { image, url, format, quality in
                await barrier.arrive()
                try ImageWriter.write(image, to: url, format: format, quality: quality)
            })
        }) { outcomes.append($0) }
        #expect(outcomes.allSatisfy { $0.error == nil })
        let written = outcomes.flatMap(\.written)
        #expect(written.count == 3)
        #expect(Set(written).count == 3)
        for outcome in outcomes {
            let url = try #require(outcome.written.first)
            let original = try ImageLoader.load(outcome.item.url, maxPixel: 80)
            let decoded = try ImageLoader.load(url, maxPixel: 512)
            #expect(decoded.width == 32 && decoded.height == 32)
            #expect(TestImages.pixel(decoded, x: 10, y: 10) == TestImages.pixel(original, x: 10, y: 10))
            #expect(url.deletingLastPathComponent() == output.appending(path: "sub", directoryHint: .isDirectory))
        }
        #expect(try Data(contentsOf: numbered) == Data("numbered".utf8))
        if overwrite { #expect(written.contains(base)) }
        else { #expect(try Data(contentsOf: base) == Data("original".utf8)) }
    }

    @Test func partialWriteFailureStillCountsThePhoto() async throws {
        let dir = try TempDir()
        let item = ScanItem(url: Fixtures.url("apollo11_crew.jpg"), relativePath: "crew.jpg", fileSize: 1)
        let job = Extract.Job(output: dir.url, format: .png, quality: 90, size: 32, padding: 0,
                              destinations: .init(overwrite: false), options: PipelineOptions())
        let outcome = await job.extract(item, detect: { _ in [
            CGRect(x: 0, y: 0, width: 40, height: 40), CGRect(x: 50, y: 0, width: 40, height: 40)
        ] }, write: { image, url, format, quality in
            if url.lastPathComponent.contains("face2") { throw CocoaError(.fileWriteNoPermission) }
            try ImageWriter.write(image, to: url, format: format, quality: quality)
        })
        #expect(outcome.written.count == 1)
        #expect(outcome.error != nil)
        #expect(FileManager.default.fileExists(atPath: outcome.written[0].path))
        var summary = Extract.Summary()
        summary.add(outcome)
        summary.add(.init(item: item))
        summary.add(.init(item: item, error: "unreadable"))
        #expect(summary.done == 3 && summary.photos == 1 && summary.faces == 1)
        #expect(summary.failed == 2 && summary.withoutFaces == 1)
    }
}

private actor CropWriteBarrier {
    var remaining: Int
    var waiters: [CheckedContinuation<Void, Never>] = []
    init(count: Int) { remaining = count }
    func arrive() async {
        remaining -= 1
        if remaining == 0 {
            waiters.forEach { $0.resume() }
            waiters.removeAll()
        } else { await withCheckedContinuation { waiters.append($0) } }
    }
}
