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
        guard !items.isEmpty else { throw ValidationError("No supported images found.") }
        try FileManager.default.createDirectory(at: outputURL, withIntermediateDirectories: true)

        let job = Job(output: outputURL, format: format, quality: quality, size: size, padding: CGFloat(padding),
                      overwrite: overwrite, options: detection.pipelineOptions)
        var done = 0, faces = 0, withoutFaces = 0, failed = 0
        await CLI.forEach(items, { await job.extract($0) }) { outcome in
            done += 1
            faces += outcome.written.count
            if let error = outcome.error {
                failed += 1
                CLI.endProgress()
                CLI.log("\(outcome.item.relativePath): \(error)")
            } else if outcome.written.isEmpty {
                withoutFaces += 1
            }
            CLI.progress("Extracting \(done)/\(items.count) photos, \(faces) faces")
        }
        CLI.endProgress()
        CLI.log("\(faces) faces from \(items.count - failed - withoutFaces) photos → \(outputURL.path)"
                + (withoutFaces > 0 ? "; \(withoutFaces) photos had no faces" : "")
                + (failed > 0 ? "; \(failed) failed" : ""))
        if failed > 0 { throw ExitCode.failure }
    }

    struct Job: Sendable {
        var output: URL
        var format: ImageFormat
        var quality: Int
        var size: Int
        var padding: CGFloat
        var overwrite: Bool
        var options: PipelineOptions

        func extract(_ item: ScanItem) async -> Outcome {
            var outcome = Outcome(item: item)
            do {
                let image = try autoreleasepool { try ImageLoader.load(item.url, maxPixel: options.workingResolution) }
                let imageSize = CGSize(width: image.width, height: image.height)
                let boxes = try await FaceDetector().detect(in: image).map(\.boundingBox)
                    .filter { max($0.width, $0.height) >= options.minimumFaceSize }
                for (n, i) in FaceCrops.readingOrder(boxes).enumerated() {
                    let rect = FaceCrops.cropRect(around: boxes[i], padding: padding, in: imageSize)
                    guard let crop = ImageUtils.crop(image, to: rect, maxSide: size) else { continue }
                    let path = FaceCrops.outputPath(for: item.relativePath, face: n + 1, fileExtension: format.fileExtension)
                    var dest = output.appending(path: path, directoryHint: .notDirectory)
                    try FileManager.default.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
                    if !overwrite, FileManager.default.fileExists(atPath: dest.path) { dest = ExportService.uniqueURL(for: dest) }
                    try ImageWriter.write(crop, to: dest, format: format, quality: quality)
                    outcome.written.append(dest)
                }
            } catch {
                outcome.error = error.localizedDescription
            }
            return outcome
        }
    }
}
