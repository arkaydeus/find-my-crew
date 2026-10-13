import Foundation

/// An image file found under the source root.
struct ScanItem: Sendable, Hashable, Identifiable {
    var url: URL
    /// Path relative to the source root, e.g. `2024/Holiday/IMG_0001.HEIC`.
    var relativePath: String
    var fileSize: Int64

    var id: URL { url }
}

struct EnumerationResult: Sendable {
    var items: [ScanItem] = []
    var folderCount = 0
    /// Packages (e.g. Photos libraries) that were not entered.
    var skippedPackages: [String] = []
}

enum FolderEnumerator {
    /// Recursively lists supported images under `root`, skipping hidden files and package contents.
    /// `progress` is called periodically with the number of images found so far.
    static func enumerate(root: URL, progress: (@Sendable (Int) -> Void)? = nil) throws -> EnumerationResult {
        let keys: [URLResourceKey] = [.isRegularFileKey, .isDirectoryKey, .isPackageKey, .fileSizeKey]
        guard let enumerator = FileManager.default.enumerator(
            at: root, includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { return EnumerationResult() }

        var result = EnumerationResult()
        for case let url as URL in enumerator {
            try Task.checkCancellation()
            guard let values = try? url.resourceValues(forKeys: Set(keys)) else { continue }
            if values.isPackage == true {
                result.skippedPackages.append(relativePath(of: url, under: root))
                continue
            }
            if values.isDirectory == true { result.folderCount += 1; continue }
            guard values.isRegularFile == true, ImageLoader.isSupported(url) else { continue }
            result.items.append(ScanItem(
                url: url, relativePath: relativePath(of: url, under: root),
                fileSize: Int64(values.fileSize ?? 0)
            ))
            if result.items.count % 250 == 0 { progress?(result.items.count) }
        }
        result.items.sort { $0.relativePath.localizedStandardCompare($1.relativePath) == .orderedAscending }
        progress?(result.items.count)
        return result
    }

    static func relativePath(of url: URL, under root: URL) -> String {
        let rootParts = root.standardizedFileURL.resolvingSymlinksInPath().pathComponents
        let parts = url.standardizedFileURL.resolvingSymlinksInPath().pathComponents
        if parts.count > rootParts.count, Array(parts.prefix(rootParts.count)) == rootParts {
            return parts.dropFirst(rootParts.count).joined(separator: "/")
        }
        return url.lastPathComponent
    }

    /// True when `url` is `ancestor` itself or lies inside it.
    static func isSameOrInside(_ url: URL, _ ancestor: URL) -> Bool {
        let a = ancestor.standardizedFileURL.resolvingSymlinksInPath().pathComponents
        let p = url.standardizedFileURL.resolvingSymlinksInPath().pathComponents
        return p.count >= a.count && Array(p.prefix(a.count)) == a
    }
}
