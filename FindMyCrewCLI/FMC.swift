import ArgumentParser
import CoreGraphics
import Foundation

// fmc — Find My Crew from the command line. Compiles the app's Core sources (same detection, embedding,
// matching and copy code as the app); see `fmc help <subcommand>`.

@main
struct FMC: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "fmc",
        abstract: "Find photos of your crew from the command line.",
        subcommands: [Extract.self, Filter.self]
    )
}

/// Options shared by the subcommands that run face detection.
struct DetectionOptions: ParsableArguments {
    @Option(help: "Long-edge size photos are decoded to for detection (larger finds smaller faces, slower).")
    var resolution = PipelineOptions().workingResolution

    @Option(help: "Ignore faces smaller than this many pixels (at the detection resolution).")
    var minFaceSize = Int(PipelineOptions().minimumFaceSize)

    func validate() throws {
        guard resolution >= 256 else { throw ValidationError("--resolution must be at least 256.") }
        guard minFaceSize >= 1 else { throw ValidationError("--min-face-size must be at least 1.") }
    }

    var pipelineOptions: PipelineOptions {
        var o = PipelineOptions()
        o.workingResolution = resolution
        o.minimumFaceSize = CGFloat(minFaceSize)
        return o
    }
}

enum CLI {
    static func log(_ message: String) {
        FileHandle.standardError.write(Data((message + "\n").utf8))
    }

    /// Overwrites one status line on a terminal; silent when stderr is redirected.
    static func progress(_ message: String) {
        guard isatty(STDERR_FILENO) == 1 else { return }
        FileHandle.standardError.write(Data("\r\u{1B}[2K\(message)".utf8))
    }

    static func endProgress() {
        if isatty(STDERR_FILENO) == 1 { FileHandle.standardError.write(Data("\r\u{1B}[2K".utf8)) }
    }

    static func url(_ path: String, directory: Bool? = nil) -> URL {
        let expanded = (path as NSString).expandingTildeInPath
        let hint: URL.DirectoryHint = directory.map { $0 ? .isDirectory : .notDirectory } ?? .checkFileSystem
        return URL(filePath: expanded, directoryHint: hint, relativeTo: .currentDirectory()).standardizedFileURL
    }

    static func isDirectory(_ url: URL) -> Bool {
        var dir: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &dir) && dir.boolValue
    }

    /// The images at `url`: the file itself, or every supported image under the folder (recursively, as the app
    /// scans). Paths are relative to the folder, or just the file name for a single file.
    static func images(at url: URL) throws -> [ScanItem] {
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw ValidationError("No such file or folder: \(url.path)")
        }
        if isDirectory(url) { return try FolderEnumerator.enumerate(root: url).items }
        guard ImageLoader.isSupported(url) else { throw ValidationError("Not a supported image: \(url.path)") }
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        return [ScanItem(url: url, relativePath: url.lastPathComponent, fileSize: Int64(size))]
    }

    /// The face model: `--model` if given, else the built-in SFace model next to this executable (where the build
    /// puts it) or inside an installed copy of the app.
    static func loadEmbedder(path: String?) async throws -> FaceEmbedder {
        if let path {
            let model = url(path)
            return try await FaceEmbedder.load(modelAt: model, displayName: model.lastPathComponent)
        }
        let name = "\(ModelStore.builtInName).mlmodelc"
        let executableDir = (Bundle.main.executableURL ?? URL(filePath: CommandLine.arguments[0]))
            .resolvingSymlinksInPath().deletingLastPathComponent()
        let candidates = [
            executableDir.appending(path: name),
            URL(filePath: "/Applications/Find My Crew.app/Contents/Resources").appending(path: name),
        ]
        guard let found = candidates.first(where: { FileManager.default.fileExists(atPath: $0.path) }) else {
            throw ValidationError("Built-in face model not found (looked in \(candidates.map(\.path).joined(separator: ", "))). Pass --model.")
        }
        return try FaceEmbedder(compiledModelURL: found, displayName: ModelStore.builtInDisplayName)
    }

    /// Runs `body` over `items` with at most `limit` in flight, handing each result to `onResult` as it completes.
    static func forEach<Item: Sendable, Result: Sendable>(
        _ items: [Item], limit: Int = ProcessInfo.processInfo.activeProcessorCount,
        _ body: @escaping @Sendable (Item) async -> Result, onResult: (Result) -> Void
    ) async {
        await withTaskGroup(of: Result.self) { group in
            var iterator = items.makeIterator()
            for _ in 0..<max(1, limit) {
                guard let item = iterator.next() else { break }
                group.addTask { await body(item) }
            }
            while let result = await group.next() {
                onResult(result)
                if let item = iterator.next() { group.addTask { await body(item) } }
            }
        }
    }
}
