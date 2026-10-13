import Foundation
import Testing

struct ScenarioValidationTests {
    @Test func unexpectedDecodeFailureCountsAsAMissAndFailsScenario() {
        let found = makeResult("found.jpg", scores: [0.8])
        let failed = makeResult("failed.jpg", scores: [], error: "decode failed")
        let corrupt = makeResult("corrupt.jpg", scores: [], error: "expected corruption")
        let results = [found, failed, corrupt]
        let labels = ["found.jpg": "Person", "failed.jpg": "Person", "corrupt.jpg": "#unreadable"]
        let counts = ScenarioValidation.accuracy(results, labels: labels, targets: ["Person"], threshold: 0.5)
        #expect(counts.tp == 1 && counts.fn == 1 && counts.fp == 0)
        #expect(Double(counts.tp) / Double(counts.tp + counts.fn) == 0.5)
        let problems = ScenarioValidation.scanProblems(items: results.map(\.item), results: results, labels: labels,
                                                       expectations: .init(mustSkipUnreadable: ["corrupt.jpg"]))
        #expect(problems == ["unexpected unreadable input: failed.jpg"])
        #expect(ScenarioValidation.accuracy([found], labels: labels, targets: ["Person"], threshold: 0.5).fn == 1)
    }

    @Test func enforcesSkipsForbiddenEnumerationAndRequiredInputs() {
        let hidden = makeResult("hidden/.hidden_photo.jpg", scores: [])
        let readable = makeResult("bad.jpg", scores: [])
        let items = [hidden, readable].map(\.item)
        let e = ScenarioValidation.Expectations(mustSkipUnreadable: ["bad.jpg"], mustNotEnumerate: [".hidden_"],
                                               rawPairs: ["pair.RAW"], duplicates: ["duplicate.jpg"])
        let problems = ScenarioValidation.scanProblems(items: items, results: [hidden, readable],
                                                       labels: ["bad.jpg": "#unreadable", "missing.jpg": "Person"], expectations: e)
        #expect(problems.contains("forbidden enumeration: hidden/.hidden_photo.jpg"))
        #expect(problems.contains("unlabelled input: hidden/.hidden_photo.jpg"))
        #expect(problems.contains("required unreadable skip absent: bad.jpg"))
        #expect(problems.contains("labelled input not enumerated: missing.jpg"))
        #expect(problems.contains("required input not enumerated: pair.RAW"))
        #expect(problems.contains("required input not enumerated: duplicate.jpg"))
    }

    @Test func selectedSidecarsAreRequiredButUnselectedOnesAreNot() throws {
        let dir = try TempDir(), dest = try TempDir()
        let jpg = try dir.file("event/photo.jpg"), xmp = try dir.file("event/photo.XMP")
        let raw = try dir.file("event/photo.DNG")
        let item = ScanItem(url: jpg, relativePath: "event/photo.jpg", fileSize: 1)
        let e = ScenarioValidation.Expectations(sidecars: ["event/photo.XMP", "other.XMP"], rawPairs: ["event/photo.DNG"])
        let without = try ExportPlanner.plan(items: [item], source: dir.url, destination: dest.url, includeSidecars: false)
        #expect(ScenarioValidation.sidecarProblems(selected: [item], operations: without, source: dir.url, expectations: e).count == 2)
        let with = try ExportPlanner.plan(items: [item], source: dir.url, destination: dest.url, includeSidecars: true)
        #expect(with.contains { $0.from.resolvingSymlinksInPath().path == xmp.resolvingSymlinksInPath().path })
        #expect(with.contains { $0.from.resolvingSymlinksInPath().path == raw.resolvingSymlinksInPath().path })
        #expect(ScenarioValidation.sidecarProblems(selected: [item], operations: with, source: dir.url,
                    expectations: .init(sidecars: ["event/photo.XMP", "other.XMP"], rawPairs: ["event/photo.DNG"])).isEmpty)
        #expect(FileManager.default.fileExists(atPath: raw.path))
    }

    @Test func verifiesActualCollisionOutputsAndEveryDigestIndependently() async throws {
        let source = try TempDir(), dest = try TempDir()
        let a = try source.file("nested/a.jpg", Data("a".utf8))
        let b = try source.file("nested/b.jpg", Data("bb".utf8))
        let collision = try dest.file("nested/a.jpg", Data("collision".utf8))
        // Same-size unrelated output is incorrectly considered identical by the copy service;
        // the benchmark must still catch its bad bytes when another operation was renamed.
        try dest.file("nested/b.jpg", Data("xx".utf8))
        let ops = try ExportPlanner.plan(items: [ScanItem(url: a, relativePath: "nested/a.jpg", fileSize: 1),
                                                ScanItem(url: b, relativePath: "nested/b.jpg", fileSize: 2)],
                                         source: source.url, destination: dest.url, includeSidecars: false)
        let before = try Dictionary(uniqueKeysWithValues: ops.map { ($0.from, try ScenarioValidation.digest($0.from)) })
        let summary = await ExportService.execute(ops) { _, _ in }
        #expect(summary.renamed == 1 && summary.outputs.count == 2)
        let actual = try #require(summary.outputs.first { $0.operation.from == a }?.destination)
        #expect(actual.lastPathComponent == "a (1).jpg")
        #expect(try Data(contentsOf: actual) == Data("a".utf8))
        #expect(try Data(contentsOf: collision) == Data("collision".utf8))
        let problems = ScenarioValidation.exportProblems(operations: ops, summary: summary, before: before)
        #expect(problems.contains("content differs: \(dest.url.appending(path: "nested/b.jpg").path)"))
        #expect(!problems.contains { $0.contains(actual.path) })
        try FileManager.default.removeItem(at: dest.url.appending(path: "nested/b.jpg"))
        try FileManager.default.copyItem(at: b, to: dest.url.appending(path: "nested/b.jpg"))
        #expect(ScenarioValidation.exportProblems(operations: ops, summary: summary, before: before).isEmpty)
        try Data("z".utf8).write(to: actual)
        #expect(ScenarioValidation.exportProblems(operations: ops, summary: summary, before: before)
                    .contains("content differs: \(actual.path)"))
    }
}
