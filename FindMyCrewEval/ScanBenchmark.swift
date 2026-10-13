import CoreGraphics
import Foundation
import ImageIO

// fmc-eval scan — end-to-end check of the app's scan → review → export path on a labelled folder.
//
//   fmc-eval scan --model <model> --references <dir> --source <dir> --labels <labels.tsv>
//                 [--export <dest>] [--threshold T] [--report <results.csv>]
//
// <references>/<Person>/*.jpg   sample photos per person (the largest face in each is used, as a user
//                               would tick it); <labels.tsv> has `path<TAB>identity` rows relative to <source>
//                               (identity empty = nobody we search for). A photo is a true match when its
//                               label is one of the reference people (rule: any tagged person).

enum ScanBenchmark {
    struct Options {
        var model: URL
        var references: URL
        var source: URL
        var labels: URL
        var export: URL?
        var threshold: Float?
        var report: URL?
        var referenceCrops: URL?
        var maxRefs: Int?
    }

    static func parse(_ args: [String]) -> Options {
        func value(_ flag: String) -> String? {
            args.firstIndex(of: flag).flatMap { $0 + 1 < args.count ? args[$0 + 1] : nil }
        }
        guard let model = value("--model"), let refs = value("--references"), let source = value("--source"),
              let labels = value("--labels")
        else {
            FileHandle.standardError.write(Data("usage: fmc-eval scan --model M --references DIR --source DIR --labels TSV [--export DEST] [--threshold T] [--report TSV] [--reference-crops DIR]\n".utf8))
            exit(2)
        }
        return Options(model: URL(filePath: model), references: URL(filePath: refs, directoryHint: .isDirectory),
                       source: URL(filePath: source, directoryHint: .isDirectory), labels: URL(filePath: labels),
                       export: value("--export").map { URL(filePath: $0, directoryHint: .isDirectory) },
                       threshold: value("--threshold").flatMap(Float.init), report: value("--report").map { URL(filePath: $0) },
                       referenceCrops: value("--reference-crops").map { URL(filePath: $0, directoryHint: .isDirectory) },
                       maxRefs: value("--max-refs").flatMap(Int.init))
    }

    static func run(_ o: Options) async throws -> Bool {
        let embedder = try await FaceEmbedder.load(modelAt: o.model, displayName: o.model.lastPathComponent)
        let pipeline = FacePipeline(embedder: embedder)
        var ok = true

        // ① ② References, as a user would accept them in the app: a photo with one face is "Yes" by default; in a
        // photo with several faces the user ticks the person, simulated by the face most similar to that person's
        // single-face references. Chosen faces can be dumped (--reference-crops) to check them by eye.
        var refEmbeddings: [[Float]] = [], refPerson: [String] = [], refFile: [String] = []
        let people = try FileManager.default.contentsOfDirectory(at: o.references, includingPropertiesForKeys: nil)
            .filter(\.hasDirectoryPath).sorted { $0.lastPathComponent < $1.lastPathComponent }
        print("References")
        for person in people {
            let name = person.lastPathComponent.replacingOccurrences(of: "_", with: " ")
            var photos: [(url: URL, image: CGImage, faces: [DetectedFace])] = []
            for url in try FileManager.default.contentsOfDirectory(at: person, includingPropertiesForKeys: nil)
            where ImageLoader.isSupported(url) {
                let (image, faces) = try await pipeline.process(url: url)
                photos.append((url, image, faces))
            }
            let anchors = photos.filter { $0.faces.count == 1 }.map { $0.faces[0].embedding }
            var notes: [String] = []
            for photo in photos.sorted(by: { $0.url.lastPathComponent < $1.url.lastPathComponent })
                .prefix(o.maxRefs ?? .max) {
                let face: DetectedFace?
                switch photo.faces.count {
                case 0: face = nil; notes.append("\(photo.url.lastPathComponent.prefix(40)): no face")
                case 1: face = photo.faces[0]
                default:
                    // The user ticks the face that is the person; if none looks like them, nothing is ticked.
                    func likeness(_ f: DetectedFace) -> Float {
                        anchors.map { Vector.dot($0, f.embedding) }.reduce(0, +) / Float(max(1, anchors.count))
                    }
                    let best = anchors.isEmpty ? photo.faces.max { $0.pixelSize < $1.pixelSize }
                        : photo.faces.max { likeness($0) < likeness($1) }
                    if let best, anchors.isEmpty || likeness(best) >= embedder.defaultThreshold {
                        face = best
                        notes.append("\(photo.url.lastPathComponent.prefix(40)): picked 1 of \(photo.faces.count) faces")
                    } else {
                        face = nil
                        notes.append("\(photo.url.lastPathComponent.prefix(40)): none of \(photo.faces.count) faces is the person")
                    }
                }
                guard let face else { continue }
                if let w = face.qualityWarning { notes.append("\(photo.url.lastPathComponent.prefix(40)): \(w)") }
                refEmbeddings.append(face.embedding); refPerson.append(name); refFile.append(photo.url.lastPathComponent)
                if let dir = o.referenceCrops {
                    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                    let b = face.boundingBox
                    if let crop = ImageUtils.crop(photo.image, to: b.insetBy(dx: -b.width * 0.3, dy: -b.height * 0.3), maxSide: 256) {
                        try writeJPEG(crop, to: dir.appending(path: "\(name) - \(refFile.count).jpg"))
                    }
                }
            }
            print("  \(name): \(refPerson.filter { $0 == name }.count) faces from \(photos.count) photos"
                  + (notes.isEmpty ? "" : "\n    " + notes.joined(separator: "\n    ")))
        }
        let references = ReferenceSet(embeddings: refEmbeddings)
        let appDefault = Matcher.defaultThreshold(model: embedder.defaultThreshold, referenceCount: refEmbeddings.count)
        let threshold = o.threshold ?? appDefault
        let targets = Set(refPerson)

        // Labels.
        var labels: [String: String] = [:]
        for line in try String(contentsOf: o.labels, encoding: .utf8).split(whereSeparator: \.isNewline).dropFirst() {
            let f = line.split(separator: "\t", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
            labels[f[0]] = f.count > 1 ? f[1] : ""
        }

        let expectationsURL = o.labels.deletingLastPathComponent().appending(path: "expectations.json")
        let expectations = FileManager.default.fileExists(atPath: expectationsURL.path)
            ? try JSONDecoder().decode(ScenarioValidation.Expectations.self, from: Data(contentsOf: expectationsURL))
            : ScenarioValidation.Expectations()

        // ③ Enumerate.
        var t0 = Date()
        let enumeration = try FolderEnumerator.enumerate(root: o.source)
        let items = enumeration.items
        print(String(format: "\nEnumerated %d images in %d folders (%.2fs); skipped packages: %@",
                     items.count, enumeration.folderCount + 1, Date().timeIntervalSince(t0),
                     enumeration.skippedPackages.joined(separator: ", ")))
        let unlabeled = items.filter { labels[$0.relativePath] == nil }
        let missing = Set(labels.keys).subtracting(items.map(\.relativePath))
        if !unlabeled.isEmpty { print("  ! \(unlabeled.count) enumerated files have no label, e.g. \(unlabeled[0].relativePath)") }
        if !missing.isEmpty { print("  \(missing.count) labelled files were not enumerated (expected for hidden/package/non-image)") }

        // ④ Scan.
        let baseline = footprint()
        var peak = baseline
        var results: [PhotoResult] = []
        t0 = Date()
        for await r in ScanEngine.run(items: items, references: references, pipeline: pipeline) {
            results.append(r)
            if results.count % 100 == 0 {
                peak = max(peak, footprint())
                print(String(format: "  scanned %d/%d  %.1f photos/s  footprint %d MB", results.count, items.count,
                             Double(results.count) / Date().timeIntervalSince(t0), footprint() >> 20))
            }
        }
        let scanTime = Date().timeIntervalSince(t0)
        peak = max(peak, footprint())
        results.sort { $0.bestScore > $1.bestScore }
        let failed = results.filter { $0.error != nil }
        print(String(format: "\nScan: %d photos in %.1fs = %.1f photos/s; %d faces; memory +%d MB (peak footprint %d MB)",
                     results.count, scanTime, Double(results.count) / scanTime, results.reduce(0) { $0 + $1.faces.count },
                     (peak - baseline) >> 20, peak >> 20))
        print("Skipped (unreadable): \(failed.count)")
        for r in failed { print("  \(r.item.relativePath): \(r.error ?? "")") }

        let scanProblems = ScenarioValidation.scanProblems(items: items, results: results, labels: labels,
                                                            expectations: expectations)
        if !scanProblems.isEmpty { print("SCAN PROBLEMS:\n  " + scanProblems.joined(separator: "\n  ")) }
        ok = ok && scanProblems.isEmpty

        // ⑤ Review: accuracy at the default threshold and a sweep.
        func person(_ r: PhotoResult, at t: Float) -> Set<String> {
            Set(r.faces.filter { $0.score >= t && $0.referenceIndex >= 0 }.map { refPerson[$0.referenceIndex] })
        }
        func truth(_ r: PhotoResult) -> String { labels[r.item.relativePath] ?? "" }
        // Only explicitly expected corrupt/truncated labels are excluded; unexpected errors remain misses.
        let scored = results.filter { !ScenarioValidation.excludedFromAccuracy(truth($0)) }

        print(String(format: "\nAccuracy at threshold %.3f (app default for %d references %.3f; model %.3f)",
                     threshold, refEmbeddings.count, appDefault, embedder.defaultThreshold))
        print("  person              photos  found  missed  false+  precision  recall")
        for name in targets.sorted() {
            let positiveCount = labels.values.filter { $0 == name }.count
            let predicted = scored.filter { $0.error == nil && person($0, at: threshold).contains(name) }
            let tp = predicted.filter { truth($0) == name }.count
            print(String(format: "  %-18@ %6d %6d %7d %7d %9.1f%% %6.1f%%", name as NSString, positiveCount, tp,
                         positiveCount - tp, predicted.count - tp,
                         predicted.isEmpty ? 100 : 100 * Double(tp) / Double(predicted.count),
                         positiveCount == 0 ? 100 : 100 * Double(tp) / Double(positiveCount)))
        }
        func anyTagged(_ t: Float) -> (tp: Int, fp: Int, fn: Int, nearMiss: Int) {
            ScenarioValidation.accuracy(results, labels: labels, targets: targets, threshold: t)
        }
        let a = anyTagged(threshold)
        let precision = Double(a.tp) / Double(max(1, a.tp + a.fp)), recall = Double(a.tp) / Double(max(1, a.tp + a.fn))
        print(String(format: "  ANY TAGGED PERSON: %d matches, %d true, %d false positives, %d missed (%d of them in near misses)",
                     a.tp + a.fp, a.tp, a.fp, a.fn, a.nearMiss))
        print(String(format: "  precision %.1f%%  recall %.1f%%  (recall incl. near-miss rescue %.1f%%)",
                     precision * 100, recall * 100, 100 * Double(a.tp + a.nearMiss) / Double(max(1, a.tp + a.fn))))
        print("\n  threshold  matches  precision  recall")
        for t in stride(from: threshold - 0.12, through: threshold + 0.12, by: 0.04) {
            let s = anyTagged(t)
            print(String(format: "  %9.3f %8d %9.1f%% %6.1f%%", t, s.tp + s.fp,
                         100 * Double(s.tp) / Double(max(1, s.tp + s.fp)), 100 * Double(s.tp) / Double(max(1, s.tp + s.fn))))
        }

        // Re-filter speed (FR-5.2).
        var matcher = Matcher(threshold: threshold)
        t0 = Date()
        for t in stride(from: threshold - 0.1, through: threshold + 0.1, by: 0.01) { matcher.threshold = t; _ = matcher.partition(results) }
        print(String(format: "\nThreshold re-filter: %.2f ms per slider move over %d results", Date().timeIntervalSince(t0) * 1000 / 21, results.count))

        if let report = o.report {
            var csv = "path\tlabel\tbest_score\tbest_person\tbest_reference\tfaces\tmatched\terror\tbox\n"
            for r in results {
                let i = r.bestFace?.referenceIndex ?? -1
                let p = i >= 0 ? refPerson[i] : "", f = i >= 0 ? refFile[i] : ""
                csv += [r.item.relativePath, truth(r), String(format: "%.4f", r.bestScore), p, f, "\(r.faces.count)",
                        "\(r.bestScore >= threshold)", r.error ?? "",
                        r.bestFace.map { String(format: "%.4f,%.4f,%.4f,%.4f", $0.box.minX, $0.box.minY, $0.box.width, $0.box.height) } ?? ""
                ].joined(separator: "\t") + "\n"
            }
            try csv.write(to: report, atomically: true, encoding: .utf8)
            print("Per-photo results: \(report.path)")
        }

        // ⑥ Export the selection and verify it.
        if let dest = o.export {
            matcher.threshold = threshold
            let selected = matcher.selected(results)
            let ops = try ExportPlanner.plan(items: selected.map(\.item), source: o.source, destination: dest, includeSidecars: true)
            let before = try Dictionary(uniqueKeysWithValues: ops.map { ($0.from, try digest($0.from)) })
            t0 = Date()
            let summary = await ExportService.execute(ops) { _, _ in }
            print(String(format: "\nExport: %d operations (%d sidecars) → copied %d, skipped identical %d, renamed %d, failed %d in %.1fs",
                         ops.count, ops.filter(\.isSidecar).count, summary.copied, summary.skippedIdentical, summary.renamed,
                         summary.failures.count, Date().timeIntervalSince(t0)))
            var problems = ScenarioValidation.exportProblems(operations: ops, summary: summary, before: before)
            problems += ScenarioValidation.sidecarProblems(selected: selected.map(\.item), operations: ops,
                                                           source: o.source, expectations: expectations)
            print(problems.isEmpty ? "Export verified: every file present, byte-identical, dates kept, structure mirrored, sources untouched"
                                   : "EXPORT PROBLEMS:\n  " + problems.prefix(20).joined(separator: "\n  "))
            ok = ok && problems.isEmpty
        }
        return ok
    }

    static func writeJPEG(_ image: CGImage, to url: URL) throws {
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, "public.jpeg" as CFString, 1, nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
        CGImageDestinationAddImage(dest, image, nil)
        guard CGImageDestinationFinalize(dest) else { throw CocoaError(.fileWriteUnknown) }
    }

    static func digest(_ url: URL) throws -> Data {
        try ScenarioValidation.digest(url)
    }

    static func footprint() -> Int {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return kr == KERN_SUCCESS ? Int(info.phys_footprint) : 0
    }
}
