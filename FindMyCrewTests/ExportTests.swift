import CryptoKit
import Foundation
import Testing

struct ExportPlannerTests {
    private func item(_ rel: String, root: URL) -> ScanItem {
        let url = root.appending(path: rel)
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? nil
        return ScanItem(url: url, relativePath: FolderEnumerator.relativePath(of: url, under: root), fileSize: Int64(size ?? 0))
    }

    @Test func mirrorsNestedFolderStructure() throws {
        let dir = try TempDir()
        try dir.file("src/a/b/c.jpg")
        try dir.file("src/top.jpg")
        let src = dir.url.appending(path: "src"), dest = dir.url.appending(path: "dest")
        let ops = try ExportPlanner.plan(
            items: [item("a/b/c.jpg", root: src), item("top.jpg", root: src)],
            source: src, destination: dest, includeSidecars: false
        )
        #expect(ops.map(\.to.path) == [dest.appending(path: "a/b/c.jpg").path, dest.appending(path: "top.jpg").path])
        #expect(ops.allSatisfy { !$0.isSidecar })
    }

    @Test func rejectsDestinationThatIsOrIsInsideTheSource() throws {
        let dir = try TempDir()
        let src = try dir.directory("src")
        let inside = try dir.directory("src/out")
        #expect(throws: ExportError.destinationIsSource) {
            try ExportPlanner.validate(source: src, destination: src)
        }
        #expect(throws: ExportError.destinationInsideSource) {
            try ExportPlanner.validate(source: src, destination: inside)
        }
        // Trailing slashes / `..` don't fool the check.
        #expect(throws: ExportError.destinationInsideSource) {
            try ExportPlanner.validate(source: src, destination: URL(filePath: src.path + "/x/../out/"))
        }
        // A sibling whose name merely starts with the source name is fine.
        let sibling = try dir.directory("src-copy")
        try ExportPlanner.validate(source: src, destination: sibling)
        #expect(ExportError.destinationInsideSource.errorDescription?.isEmpty == false)
    }

    @Test func includesSidecarsSharingTheBaseName() throws {
        let dir = try TempDir()
        try dir.file("src/2024/IMG_1.JPG")
        try dir.file("src/2024/IMG_1.CR3", Data(count: 10))
        try dir.file("src/2024/IMG_1.xmp")
        try dir.file("src/2024/img_1.aae")
        try dir.file("src/2024/IMG_1.mov")      // not a sidecar type
        try dir.file("src/2024/IMG_10.xmp")     // different base name
        try dir.file("src/2024/IMG_2.JPG")
        let src = dir.url.appending(path: "src"), dest = dir.url.appending(path: "dest")
        let items = [item("2024/IMG_1.JPG", root: src), item("2024/IMG_2.JPG", root: src)]

        let ops = try ExportPlanner.plan(items: items, source: src, destination: dest, includeSidecars: true)
        let names = Set(ops.map(\.to.lastPathComponent))
        #expect(names == ["IMG_1.JPG", "IMG_2.JPG", "IMG_1.CR3", "IMG_1.xmp", "img_1.aae"])
        #expect(ops.filter(\.isSidecar).count == 3)
        #expect(ops.first { $0.to.lastPathComponent == "IMG_1.CR3" }?.bytes == 10)
        #expect(ops.allSatisfy { $0.to.deletingLastPathComponent().lastPathComponent == "2024" })

        let without = try ExportPlanner.plan(items: items, source: src, destination: dest, includeSidecars: false)
        #expect(without.count == 2)
    }

    @Test func selectedRawJpegPairIsNotDuplicated() throws {
        let dir = try TempDir()
        try dir.file("src/IMG_1.JPG")
        try dir.file("src/IMG_1.DNG")
        let src = dir.url.appending(path: "src"), dest = dir.url.appending(path: "dest")
        let ops = try ExportPlanner.plan(
            items: [item("IMG_1.JPG", root: src), item("IMG_1.DNG", root: src)],
            source: src, destination: dest, includeSidecars: true
        )
        #expect(ops.count == 2)
        #expect(ops.allSatisfy { !$0.isSidecar })
    }
}

struct ExportServiceTests {
    private func sha(_ url: URL) throws -> Data { Data(SHA256.hash(data: try Data(contentsOf: url))) }
    private func mtime(_ url: URL) throws -> Date {
        try url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate!
    }

    @Test func copiesPreservingStructureAndMetadataWithoutTouchingOriginals() async throws {
        let dir = try TempDir()
        let a = try dir.file("src/a/b/c.jpg", Data("photo-c".utf8))
        let top = try dir.file("src/top.jpg", Data("photo-top".utf8))
        let old = Date(timeIntervalSince1970: 1_500_000_000)
        try FileManager.default.setAttributes([.modificationDate: old, .creationDate: old], ofItemAtPath: a.path)
        let before = try [a, top].map { (try sha($0), try mtime($0)) }

        let src = dir.url.appending(path: "src"), dest = dir.url.appending(path: "dest")
        let items = try FolderEnumerator.enumerate(root: src).items
        // Enumeration only lists images; these test files are named .jpg so they qualify.
        #expect(items.count == 2)
        let ops = try ExportPlanner.plan(items: items, source: src, destination: dest, includeSidecars: true)
        let summary = await ExportService.execute(ops) { _, _ in }

        #expect(summary.copied == 2)
        #expect(summary.failures.isEmpty)
        let copied = dest.appending(path: "a/b/c.jpg")
        #expect(try Data(contentsOf: copied) == Data("photo-c".utf8))
        #expect(try mtime(copied) == old)   // FR-6.4: dates preserved

        let after = try [a, top].map { (try sha($0), try mtime($0)) }
        #expect(before.map(\.0) == after.map(\.0))
        #expect(before.map(\.1) == after.map(\.1))
    }

    @Test func skipsIdenticalFilesAndRenamesCollisions() async throws {
        let dir = try TempDir()
        let photo = try dir.file("src/x/p.jpg", Data("12345".utf8))
        let dest = dir.url.appending(path: "dest")
        let op = CopyOperation(from: photo, to: dest.appending(path: "x/p.jpg"), bytes: 5, isSidecar: false)

        // First copy.
        var summary = await ExportService.execute([op]) { _, _ in }
        #expect(summary.copied == 1)

        // Same size already there → skipped, nothing renamed.
        summary = await ExportService.execute([op]) { _, _ in }
        #expect(summary.skippedIdentical == 1 && summary.copied == 0)
        #expect(!FileManager.default.fileExists(atPath: dest.appending(path: "x/p (1).jpg").path))

        // A different file with the same name → " (1)", then " (2)".
        try Data("different".utf8).write(to: dest.appending(path: "x/p.jpg"))
        summary = await ExportService.execute([op]) { _, _ in }
        #expect(summary.renamed == 1 && summary.copied == 1)
        #expect(try Data(contentsOf: dest.appending(path: "x/p (1).jpg")) == Data("12345".utf8))
        #expect(try Data(contentsOf: dest.appending(path: "x/p.jpg")) == Data("different".utf8))

        try Data("other".utf8).write(to: dest.appending(path: "x/p (1).jpg"))
        _ = await ExportService.execute([op]) { _, _ in }
        #expect(FileManager.default.fileExists(atPath: dest.appending(path: "x/p (2).jpg").path))
    }

    @Test func reportsFailuresAndProgress() async throws {
        let dir = try TempDir()
        let good = try dir.file("src/good.jpg")
        let dest = dir.url.appending(path: "dest")
        let ops = [
            CopyOperation(from: dir.url.appending(path: "src/missing.jpg"), to: dest.appending(path: "missing.jpg"), bytes: 1, isSidecar: false),
            CopyOperation(from: good, to: dest.appending(path: "good.jpg"), bytes: 1, isSidecar: false),
        ]
        let counter = Counter()
        let summary = await ExportService.execute(ops) { done, total in counter.record(done, total) }
        #expect(summary.copied == 1)
        #expect(summary.failures.count == 1)
        #expect(summary.failures.first?.path.hasSuffix("missing.jpg") == true)
        #expect(counter.last == (2, 2))
    }

    @Test func cancelledExportReportsOnlyCompletedCopies() async throws {
        let source = try TempDir(), dest = try TempDir()
        let ops = try (0..<4).map { index in
            CopyOperation(from: try source.file("\(index).jpg"), to: dest.url.appending(path: "\(index).jpg"), bytes: 1, isSidecar: false)
        }
        let worker = Task {
            await ExportService.execute(ops) { done, _ in
                if done == 1 { withUnsafeCurrentTask { $0?.cancel() } }
            }
        }
        let summary = await worker.value
        #expect(summary.cancelled && summary.copied == 1)
        #expect(summary.outputs.count == 1 && summary.failures.isEmpty)
        #expect(summary.completionTitle == "Copy stopped")
        #expect(try FileManager.default.contentsOfDirectory(atPath: dest.url.path).count == 1)
    }

    @Test func uniqueURLHandlesFilesWithoutExtension() throws {
        let dir = try TempDir()
        let f = try dir.file("README")
        #expect(ExportService.uniqueURL(for: f).lastPathComponent == "README (1)")
    }
}

private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var value: (Int, Int) = (0, 0)
    func record(_ done: Int, _ total: Int) { lock.withLock { value = (done, total) } }
    var last: (Int, Int) { lock.withLock { value } }
}
