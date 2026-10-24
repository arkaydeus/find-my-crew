import Foundation

struct CopyOperation: Sendable, Hashable {
    var from: URL
    var to: URL
    var bytes: Int64
    var isSidecar: Bool
}

enum ExportError: LocalizedError, Equatable {
    case destinationIsSource
    case destinationInsideSource

    var errorDescription: String? {
        switch self {
        case .destinationIsSource: "The destination can’t be the folder you scanned."
        case .destinationInsideSource: "The destination can’t be inside the folder you scanned. Choose a folder outside it."
        }
    }
}

enum ExportPlanner {
    /// Files that travel with a photo when they share its base name.
    static let sidecarExtensions: Set<String> =
        Set(["xmp", "aae", "jpg", "jpeg", "heic", "heif", "png", "tif", "tiff"]).union(ImageLoader.rawExtensions)

    static func validate(source: URL, destination: URL) throws {
        let s = FolderEnumerator.resolved(source)
        let d = FolderEnumerator.resolved(destination)
        if s.pathComponents == d.pathComponents { throw ExportError.destinationIsSource }
        if FolderEnumerator.isSameOrInside(d, s) { throw ExportError.destinationInsideSource }
    }

    /// Maps each selected photo (and optionally its sidecars) to `destination/<relative path>`.
    static func plan(
        items: [ScanItem], source: URL, destination: URL, includeSidecars: Bool
    ) throws -> [CopyOperation] {
        try validate(source: source, destination: destination)
        var ops: [CopyOperation] = []
        var seen = Set<String>()
        var directoryListings: [URL: [URL]] = [:]

        func add(_ from: URL, relativePath: String, bytes: Int64, sidecar: Bool) {
            let key = from.standardizedFileURL.path
            guard seen.insert(key).inserted else { return }
            let to = destination.appending(path: relativePath, directoryHint: .notDirectory)
            // Never write anywhere inside the source tree.
            guard !FolderEnumerator.isSameOrInside(to, source) else { return }
            ops.append(CopyOperation(from: from, to: to, bytes: bytes, isSidecar: sidecar))
        }

        for item in items { add(item.url, relativePath: item.relativePath, bytes: item.fileSize, sidecar: false) }

        guard includeSidecars else { return ops }
        for item in items {
            let dir = item.url.deletingLastPathComponent()
            let listing = directoryListings[dir] ?? {
                let urls = (try? FileManager.default.contentsOfDirectory(
                    at: dir, includingPropertiesForKeys: [.fileSizeKey], options: [.skipsHiddenFiles]
                )) ?? []
                directoryListings[dir] = urls
                return urls
            }()
            let base = item.url.deletingPathExtension().lastPathComponent.lowercased()
            let relDir = (item.relativePath as NSString).deletingLastPathComponent
            for candidate in listing where candidate.lastPathComponent != item.url.lastPathComponent {
                guard candidate.deletingPathExtension().lastPathComponent.lowercased() == base,
                      sidecarExtensions.contains(candidate.pathExtension.lowercased())
                else { continue }
                let size = (try? candidate.resourceValues(forKeys: [.fileSizeKey]).fileSize).flatMap { $0 } ?? 0
                let rel = relDir.isEmpty ? candidate.lastPathComponent : relDir + "/" + candidate.lastPathComponent
                add(candidate, relativePath: rel, bytes: Int64(size), sidecar: true)
            }
        }
        return ops
    }
}

struct ExportSummary: Sendable {
    struct Output: Sendable {
        let operation: CopyOperation
        let destination: URL
    }
    var outputs: [Output] = []
    var cancelled = false
    var completionTitle: String { cancelled ? "Copy stopped" : (failures.isEmpty ? "Done" : "Copy finished with errors") }
    var copied = 0
    var skippedIdentical = 0
    var renamed = 0
    var failures: [(path: String, message: String)] = []
    var bytesCopied: Int64 = 0
}

enum ExportService {
    /// Copies files, creating directories as needed. Never overwrites: an existing file of the same
    /// size is treated as already copied, anything else gets a ` (n)` suffix.
    static func execute(
        _ operations: [CopyOperation],
        progress: @Sendable (_ done: Int, _ total: Int) -> Void
    ) async -> ExportSummary {
        let fm = FileManager.default
        var summary = ExportSummary()
        for (index, op) in operations.enumerated() {
            if Task.isCancelled { summary.cancelled = true; break }
            do {
                try fm.createDirectory(at: op.to.deletingLastPathComponent(), withIntermediateDirectories: true)
                var target = op.to
                if fm.fileExists(atPath: target.path) {
                    // Read the size from disk: URL resource values are cached per URL instance.
                    let existing = (try? fm.attributesOfItem(atPath: target.path)[.size] as? NSNumber)?.int64Value
                    if let existing, existing == op.bytes {
                        summary.skippedIdentical += 1
                        summary.outputs.append(.init(operation: op, destination: target))
                        progress(index + 1, operations.count)
                        continue
                    }
                    target = uniqueURL(for: target)
                    summary.renamed += 1
                }
                // copyItem clones on APFS and preserves dates and extended attributes.
                try fm.copyItem(at: op.from, to: target)
                summary.outputs.append(.init(operation: op, destination: target))
                summary.copied += 1
                summary.bytesCopied += op.bytes
            } catch {
                summary.failures.append((op.from.path, error.localizedDescription))
            }
            progress(index + 1, operations.count)
            await Task.yield()
        }
        return summary
    }

    static func uniqueURL(for url: URL) -> URL {
        let dir = url.deletingLastPathComponent()
        let base = url.deletingPathExtension().lastPathComponent
        let ext = url.pathExtension
        var n = 1
        while true {
            let name = ext.isEmpty ? "\(base) (\(n))" : "\(base) (\(n)).\(ext)"
            let candidate = dir.appending(path: name, directoryHint: .notDirectory)
            if !FileManager.default.fileExists(atPath: candidate.path) { return candidate }
            n += 1
        }
    }
}
