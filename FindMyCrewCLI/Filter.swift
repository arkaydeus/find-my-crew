import ArgumentParser
import Foundation

struct Filter: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Copy the photos that show any of the given faces.",
        discussion: """
        Every photo under --source (recursively) is compared against the faces in --faces; photos where any \
        face matches are copied to --output with their sub-folders, dates and sidecar files (RAW+JPEG pairs, \
        .xmp, .aae), exactly as the app exports them. Existing files are never overwritten.

        Each image in --faces gives one reference face: its only face, or the largest one if it has several. \
        Face crops from `fmc extract` work well. Matches are listed on stdout as score<TAB>path<TAB>reference.
        """
    )

    @Option(name: .long, help: "Photos of the people to find: a folder (searched recursively) or a single image.")
    var faces: String

    @Option(name: .shortAndLong, help: "Folder of photos to search.")
    var source: String

    @Option(name: .shortAndLong, help: "Folder to copy the matching photos to (created if needed).")
    var output: String

    @Option(help: "Match threshold (cosine similarity, -1…1). Default: the model's, adjusted for the number of faces as in the app.")
    var threshold: Float?

    @Flag(help: "Don't copy sidecar files alongside the matching photos.")
    var noSidecars = false

    @Flag(help: "List the matches without copying anything.")
    var dryRun = false

    @Option(help: "Face model (.mlpackage, .mlmodel or .mlmodelc). Default: the built-in SFace model.")
    var model: String?

    @OptionGroup var detection: DetectionOptions

    func validate() throws {
        if let threshold, !(-1...1).contains(threshold) {
            throw ValidationError("--threshold must be between -1 and 1.")
        }
    }

    struct ReferencePhoto: Sendable {
        var item: ScanItem
        var faces: [DetectedFace] = []
        var error: String?
    }

    func run() async throws {
        let facesURL = CLI.url(faces), sourceURL = CLI.url(source, directory: true)
        let outputURL = CLI.url(output, directory: true)
        guard CLI.isDirectory(sourceURL) else { throw ValidationError("--source must be a folder: \(sourceURL.path)") }
        try ExportPlanner.validate(source: sourceURL, destination: outputURL)

        let embedder = try await CLI.loadEmbedder(path: model)
        let pipeline = FacePipeline(embedder: embedder, options: detection.pipelineOptions)

        // ① ② Reference faces.
        let referenceItems = try CLI.images(at: facesURL)
        var references: [(file: String, embedding: [Float])] = []
        await CLI.forEach(referenceItems, { item in
            do { return ReferencePhoto(item: item, faces: try await pipeline.process(url: item.url).faces) }
            catch { return ReferencePhoto(item: item, error: error.localizedDescription) }
        }) { photo in
            let path = photo.item.relativePath
            if let error = photo.error { return CLI.log("\(path): \(error)") }
            guard let face = photo.faces.max(by: { $0.pixelSize < $1.pixelSize }) else {
                return CLI.log("\(path): no face found, skipped")
            }
            if photo.faces.count > 1 { CLI.log("\(path): \(photo.faces.count) faces, using the largest") }
            references.append((path, face.embedding))
        }
        guard !references.isEmpty else { throw ValidationError("No faces found in \(facesURL.path).") }
        references.sort { $0.file.localizedStandardCompare($1.file) == .orderedAscending }
        let referenceSet = ReferenceSet(embeddings: references.map(\.embedding))
        let threshold = threshold
            ?? Matcher.defaultThreshold(model: embedder.defaultThreshold, referenceCount: references.count)

        // ③ ④ Enumerate and scan. A faces folder inside the source isn't searched: its crops would match themselves.
        let items = try FolderEnumerator.enumerate(root: sourceURL).items
            .filter { !FolderEnumerator.isSameOrInside($0.url, facesURL) }
        CLI.log(String(format: "%d reference faces, threshold %.3f (%@); scanning %d photos",
                       references.count, threshold, embedder.displayName, items.count))
        var results: [PhotoResult] = []
        let start = Date()
        for await result in ScanEngine.run(items: items, references: referenceSet, pipeline: pipeline) {
            results.append(result)
            if let error = result.error {
                CLI.endProgress()
                CLI.log("\(result.item.relativePath): \(error)")
            }
            CLI.progress(String(format: "Scanning %d/%d  %.1f photos/s", results.count, items.count,
                                Double(results.count) / max(0.001, Date().timeIntervalSince(start))))
        }
        CLI.endProgress()

        // ⑤ Review: the app's default selection at this threshold.
        let matcher = Matcher(threshold: threshold)
        let (matches, nearMisses, _) = matcher.partition(results)
        let selected = matches.sorted { $0.item.relativePath.localizedStandardCompare($1.item.relativePath) == .orderedAscending }
        for r in selected {
            let reference = r.bestFace.map { references[$0.referenceIndex].file } ?? ""
            print(String(format: "%.3f\t%@\t%@", r.bestScore, r.item.relativePath, reference))
        }
        let unreadable = results.filter { $0.error != nil }.count
        CLI.log(String(format: "%d of %d photos match in %.1fs", selected.count, results.count, Date().timeIntervalSince(start))
                + (unreadable > 0 ? "; \(unreadable) unreadable" : "")
                + (nearMisses.isEmpty ? "" : String(format: "; %d more score within %.2f of the threshold (lower --threshold to include them)",
                                                    nearMisses.count, Matcher.nearMissMargin)))
        guard !dryRun, !selected.isEmpty else { return }

        // ⑥ Export.
        let operations = try ExportPlanner.plan(items: selected.map(\.item), source: sourceURL, destination: outputURL,
                                                includeSidecars: !noSidecars)
        let summary = await ExportService.execute(operations) { done, total in
            CLI.progress("Copying \(done)/\(total)")
        }
        CLI.endProgress()
        for failure in summary.failures { CLI.log("\(failure.path): \(failure.message)") }
        CLI.log("Copied \(summary.copied) files to \(outputURL.path)"
                + (summary.skippedIdentical > 0 ? "; \(summary.skippedIdentical) already there" : "")
                + (summary.renamed > 0 ? "; \(summary.renamed) renamed to avoid overwriting" : "")
                + (summary.failures.isEmpty ? "" : "; \(summary.failures.count) failed"))
        if !summary.failures.isEmpty { throw ExitCode.failure }
    }
}
