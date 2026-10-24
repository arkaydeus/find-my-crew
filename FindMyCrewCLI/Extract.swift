import ArgumentParser
import CoreGraphics
import Foundation

struct Extract: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Save every face found in photos as its own image file.",
        discussion: """
        Each face is cropped square with some margin and written to the output folder, mirroring the input's \
        sub-folders: Party/IMG_0001.HEIC → <output>/Party/IMG_0001_face1.webp (faces numbered left to right). \
        The crops can be used directly as the --faces folder of `fmc filter`.
        """
    )

    @Argument(help: "Photos or folders of photos (folders are searched recursively).")
    var inputs: [String]

    @Option(name: .shortAndLong, help: "Folder to write the face images to (created if needed).")
    var output: String

    @Option(name: .shortAndLong, help: "Image format of the face files.")
    var format = ImageFormat.webp

    @Option(help: "Quality for webp, jpeg and heic, 0–100.")
    var quality = 90

    @Option(help: "Maximum width and height of a face image in pixels (crops are never upscaled).")
    var size = 512

    @Option(help: "Margin around each face, as a fraction of the face size on every side.")
    var padding = Double(FaceCrops.defaultPadding)

    @Flag(help: "Replace existing files instead of adding a numbered copy.")
    var overwrite = false

    @OptionGroup var detection: DetectionOptions

    func validate() throws {
        guard (0...100).contains(quality) else { throw ValidationError("--quality must be between 0 and 100.") }
        guard size >= 16 else { throw ValidationError("--size must be at least 16.") }
        guard (0...2).contains(padding) else { throw ValidationError("--padding must be between 0 and 2.") }
    }

    struct Outcome: Sendable {
        var item: ScanItem
        var written: [URL] = []
        var error: String?
    }

    func run() async throws {
        let outputURL = CLI.url(output, directory: true)
        var items: [ScanItem] = []
        for input in inputs {
            let url = CLI.url(input)
            // Re-running would otherwise pick up its own output as input photos.
            if CLI.isDirectory(url) { try ExportPlanner.validate(source: url, destination: outputURL) }
            items += try CLI.images(at: url)
        }
        items = CLI.extractionItems(items)
        guard !items.isEmpty else { throw ValidationError("No supported images found.") }
        try FileManager.default.createDirectory(at: outputURL, withIntermediateDirectories: true)

        let job = Job(output: outputURL, format: format, quality: quality, size: size, padding: CGFloat(padding),
                      destinations: Destinations(overwrite: overwrite), options: detection.pipelineOptions)
        var summary = Summary()
        await CLI.forEach(items, { await job.extract($0) }) { outcome in
            summary.add(outcome)
            if let error = outcome.error {
                CLI.endProgress()
                CLI.log("\(outcome.item.relativePath): \(error)")
            }
            CLI.progress("Extracting \(summary.done)/\(items.count) photos, \(summary.faces) faces")
        }
        CLI.endProgress()
        CLI.log("\(summary.faces) faces from \(summary.photos) photos → \(outputURL.path)"
                + (summary.withoutFaces > 0 ? "; \(summary.withoutFaces) photos had no faces" : "")
                + (summary.failed > 0 ? "; \(summary.failed) failed" : ""))
        if summary.failed > 0 { throw ExitCode.failure }
    }

    struct Summary {
        var done = 0, faces = 0, photos = 0, withoutFaces = 0, failed = 0

        mutating func add(_ outcome: Outcome) {
            done += 1
            faces += outcome.written.count
            if !outcome.written.isEmpty { photos += 1 }
            if outcome.error != nil { failed += 1 }
            else if outcome.written.isEmpty { withoutFaces += 1 }
        }
    }

    /// One allocator for the entire run, including failed writes. Even --overwrite may claim a path
    /// only once, so jobs never replace another job's crop. Suffixes preserve existing numbered copies.
    actor Destinations {
        let overwrite: Bool
        private var claimed = Set<String>()

        init(overwrite: Bool) { self.overwrite = overwrite }

        func claim(_ proposed: URL) -> URL {
            var candidate = proposed
            var suffix = 0
            while claimed.contains(FolderEnumerator.resolved(candidate).path.lowercased())
                    || ((!overwrite || suffix > 0) && FileManager.default.fileExists(atPath: candidate.path)) {
                suffix += 1
                candidate = proposed.deletingLastPathComponent().appendingPathComponent(
                    "\(proposed.deletingPathExtension().lastPathComponent) (\(suffix)).\(proposed.pathExtension)")
            }
            claimed.insert(FolderEnumerator.resolved(candidate).path.lowercased())
            return candidate
        }
    }

    struct Job: Sendable {
        var output: URL
        var format: ImageFormat
        var quality: Int
        var size: Int
        var padding: CGFloat
        var destinations: Destinations
        var options: PipelineOptions

        func extract(
            _ item: ScanItem,
            detect: @Sendable (CGImage) async throws -> [CGRect] = { image in
                try await FaceDetector().detect(in: image).map(\.boundingBox)
            },
            write: @Sendable (CGImage, URL, ImageFormat, Int) async throws -> Void = {
                try ImageWriter.write($0, to: $1, format: $2, quality: $3)
            }
        ) async -> Outcome {
            var outcome = Outcome(item: item)
            do {
                let image = try autoreleasepool { try ImageLoader.load(item.url, maxPixel: options.workingResolution) }
                let imageSize = CGSize(width: image.width, height: image.height)
                let boxes = try await detect(image)
                    .filter { max($0.width, $0.height) >= options.minimumFaceSize }
                for (n, i) in FaceCrops.readingOrder(boxes).enumerated() {
                    let rect = FaceCrops.cropRect(around: boxes[i], padding: padding, in: imageSize)
                    guard let crop = ImageUtils.crop(image, to: rect, maxSide: size) else { continue }
                    let path = FaceCrops.outputPath(for: item.relativePath, face: n + 1, fileExtension: format.fileExtension)
                    let dest = await destinations.claim(output.appending(path: path, directoryHint: .notDirectory))
                    try FileManager.default.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try await write(crop, dest, format, quality)
                    outcome.written.append(dest)
                }
            } catch {
                outcome.error = error.localizedDescription
            }
            return outcome
        }
    }
}
