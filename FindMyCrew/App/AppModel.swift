import AppKit
import CoreGraphics
import Foundation
import Observation

enum Step: Int, CaseIterable, Identifiable, Comparable {
    case references, source, scan, review, export

    var id: Int { rawValue }
    static func < (a: Step, b: Step) -> Bool { a.rawValue < b.rawValue }

    var title: String {
        switch self {
        case .references: "People"
        case .source: "Folder"
        case .scan: "Scan"
        case .review: "Review"
        case .export: "Copy"
        }
    }

    var systemImage: String {
        switch self {
        case .references: "person.crop.square.badge.camera"
        case .source: "folder"
        case .scan: "viewfinder"
        case .review: "checkmark.rectangle.stack"
        case .export: "square.and.arrow.down.on.square"
        }
    }
}

// MARK: - Reference faces

struct ReferenceFace: Identifiable {
    let id = UUID()
    var crop: CGImage?
    var face: DetectedFace
    var accepted: Bool
}

struct ReferencePhoto: Identifiable {
    enum State { case loading, done, failed(String) }
    let id = UUID()
    var url: URL
    var access: SecurityScopedAccess?
    var droppedFile: DroppedFile?
    var state: State = .loading
    var faces: [ReferenceFace] = []
}

// MARK: - Scan

enum ScanStatus: Equatable {
    case idle, running, paused, finished, cancelled
}

@MainActor
@Observable
final class AppModel {
    var step: Step = .references

    // Model
    private(set) var embedder: FaceEmbedder?
    private(set) var modelError: String?
    var settings = AppSettings()

    // ① ② References
    var referencePhotos: [ReferencePhoto] = []
    // Stored at the window level: a delayed provider failure remains visible after navigation.
    var dropFailures: [DropFailure] = []
    var dropFailureMessage: String? { DropResult(failures: dropFailures).failureMessage }

    func receiveDrop(_ result: DropResult, kind: DropKind) {
        dropFailures.append(contentsOf: result.failures)
        switch kind {
        case .images: addDroppedReferencePhotos(result.files)
        case .folders:
            if let folder = result.files.first { chooseSource(folder.url, access: folder.access) }
        }
    }

    // ③ Source
    private(set) var sourceRoot: URL?
    private var sourceAccess: SecurityScopedAccess?
    private(set) var enumeration: EnumerationResult?
    private(set) var enumeratingCount: Int?
    private(set) var enumerationError: String?
    private var enumerationTask: Task<Void, Never>?

    // ④ Scan
    private(set) var scanStatus: ScanStatus = .idle
    private(set) var results: [PhotoResult] = []
    /// Time spent actively scanning (pauses excluded).
    private(set) var scanElapsed: TimeInterval = 0
    private var activeSince: Date?
    private var elapsedBeforePause: TimeInterval = 0
    /// Identifies the current scan so a cancelled scan's late results are ignored.
    private var scanGeneration = UUID()
    private(set) var lastScannedPath = ""
    /// Reference faces used for the current results; editing them makes results stale.
    private(set) var scannedReferenceIDs: Set<UUID> = []
    private var scanTask: Task<Void, Never>?
    private var scanControl = ScanControl()
    var hasPendingScanWork: Bool { scanTask != nil }
    private var pauseGate = PauseGate()

    // ⑤ Review
    var matcher = Matcher(threshold: 0.36)

    // ⑥ Export
    var destination: URL? {
        didSet { destinationAccess = destination.map { SecurityScopedAccess($0) } }
    }
    private var destinationAccess: SecurityScopedAccess?
    var includeSidecars = true
    private(set) var exportProgress: (done: Int, total: Int)?
    private(set) var exportSummary: ExportSummary?
    private(set) var exportError: String?
    private var exportTask: Task<Void, Never>?

    typealias ScanRunner = @Sendable ([ScanItem], ReferenceSet, FacePipeline, PauseGate, ScanControl) -> AsyncStream<PhotoResult>
    typealias ExportRunner = @Sendable ([CopyOperation], @Sendable (Int, Int) -> Void) async -> ExportSummary
    private let scanRunner: ScanRunner
    private let exportRunner: ExportRunner
    private let scanFlushInterval: TimeInterval

    init(scanFlushInterval: TimeInterval = 0.1,
         scanRunner: @escaping ScanRunner = { items, refs, pipeline, gate, control in
             ScanEngine.run(items: items, references: refs, pipeline: pipeline, gate: gate, control: control)
         },
         exportRunner: @escaping ExportRunner = { ops, progress in await ExportService.execute(ops, progress: progress) }) {
        self.scanFlushInterval = scanFlushInterval
        self.scanRunner = scanRunner
        self.exportRunner = exportRunner
        Task { await reloadModel() }
    }

    // MARK: Model

    func reloadModel() async {
        do {
            let embedder = try await ModelStore.loadEmbedder(customModelName: settings.customModelName)
            self.embedder = embedder
            modelError = nil
            threshold = embedder.defaultThreshold
        } catch where !settings.customModelName.isEmpty {
            // A broken or missing custom model must never lock the user out: fall back to the built-in one.
            let name = (settings.customModelName as NSString).deletingPathExtension
            settings.customModelName = ""
            await reloadModel()
            if embedder != nil {
                modelError = "Custom model “\(name)” could not be loaded (\(error.localizedDescription)). Using the built-in model."
            }
        } catch {
            embedder = nil
            modelError = "Could not load the face recognition model: \(error.localizedDescription)"
        }
    }

    /// Called when the recognition model or pipeline options change: everything must be recomputed.
    func pipelineChanged() async {
        cancelScan()
        await reloadModel()
        resetScan()
        // Re-embed the reference photos with the new pipeline, keeping the user's Yes/No choices.
        let previous = referencePhotos
        referencePhotos = []
        addDroppedReferencePhotos(previous.map { $0.droppedFile ?? DroppedFile(url: $0.url, access: $0.access) }) { url, faces in
            let choices = previous.first { $0.url == url }?.faces ?? []
            for i in faces.indices {
                let box = faces[i].face.normalizedBox
                let match = choices
                    .map { ($0, FaceDetector.iou($0.face.normalizedBox, box)) }
                    .filter { $0.1 > 0.4 }
                    .max { $0.1 < $1.1 }
                if let (old, _) = match { faces[i].accepted = old.accepted }
            }
        }
        if step > .source { step = .source }
    }

    var pipeline: FacePipeline? {
        embedder.map { FacePipeline(embedder: $0, options: settings.pipelineOptions) }
    }

    // MARK: Navigation

    func canEnter(_ target: Step) -> Bool {
        switch target {
        case .references: true
        case .source: !acceptedFaces.isEmpty
        case .scan: canEnter(.source) && (enumeration?.items.isEmpty == false)
        case .review: canEnter(.scan) && !results.isEmpty && scanStatus != .running && scanStatus != .paused
        case .export: canEnter(.review) && !selectedResults.isEmpty
        }
    }

    var nextStep: Step? { Step(rawValue: step.rawValue + 1) }
    var previousStep: Step? { Step(rawValue: step.rawValue - 1) }

    // MARK: ① ② References

    var acceptedFaces: [ReferenceFace] {
        referencePhotos.flatMap(\.faces).filter(\.accepted)
    }

    var referencesAreStale: Bool {
        !results.isEmpty && Set(acceptedFaces.map(\.id)) != scannedReferenceIDs
    }

    var isProcessingReferences: Bool {
        referencePhotos.contains { if case .loading = $0.state { true } else { false } }
    }

    /// Detects and embeds faces in new reference photos. `adjust` may change the default
    /// Yes/No choices before they are shown.
    func addReferencePhotos(
        _ urls: [URL], adjust: (@MainActor (URL, inout [ReferenceFace]) -> Void)? = nil
    ) {
        addDroppedReferencePhotos(urls.map { DroppedFile(url: $0) }, adjust: adjust)
    }

    func addDroppedReferencePhotos(
        _ files: [DroppedFile], adjust: (@MainActor (URL, inout [ReferenceFace]) -> Void)? = nil
    ) {
        var seenURLs = Set(referencePhotos.map(\.url))
        var seenContent = Set(referencePhotos.compactMap { $0.droppedFile?.contentID })
        let new = files.filter { file in
            guard ImageLoader.isSupported(file.url), seenURLs.insert(file.url).inserted else { return false }
            return file.contentID.map { seenContent.insert($0).inserted } ?? true
        }
        guard !new.isEmpty else { return }
        guard let pipeline else {
            Task {
                await reloadModel()
                if self.embedder != nil { addDroppedReferencePhotos(new, adjust: adjust) }
            }
            return
        }
        for file in new {
            let url = file.url
            let photo = ReferencePhoto(url: url, access: file.access, droppedFile: file)
            referencePhotos.append(photo)
            let id = photo.id
            Task.detached(priority: .userInitiated) {
                defer { withExtendedLifetime(file) {} }
                let outcome: Result<[ReferenceFace], Error>
                do {
                    let (image, faces) = try await pipeline.process(url: url)
                    let accept = faces.count == 1
                    outcome = .success(faces.map { face in
                        let crop = ImageUtils.crop(image, to: face.boundingBox.insetBy(
                            dx: -face.boundingBox.width * 0.2, dy: -face.boundingBox.height * 0.2), maxSide: 256)
                        return ReferenceFace(crop: crop, face: face, accepted: accept)
                    })
                } catch {
                    outcome = .failure(error)
                }
                await self.finishReference(id: id, outcome: outcome, adjust: adjust)
            }
        }
    }

    private func finishReference(
        id: UUID, outcome: Result<[ReferenceFace], Error>,
        adjust: (@MainActor (URL, inout [ReferenceFace]) -> Void)?
    ) {
        guard let i = referencePhotos.firstIndex(where: { $0.id == id }) else { return }
        switch outcome {
        case .success(var faces):
            adjust?(referencePhotos[i].url, &faces)
            referencePhotos[i].faces = faces
            referencePhotos[i].state = .done
        case .failure(let error):
            referencePhotos[i].state = .failed(error.localizedDescription)
        }
    }

    func setAccepted(_ accepted: Bool, faceID: UUID) {
        for p in referencePhotos.indices {
            if let f = referencePhotos[p].faces.firstIndex(where: { $0.id == faceID }) {
                referencePhotos[p].faces[f].accepted = accepted
            }
        }
    }

    func setAllAccepted(_ accepted: Bool) {
        for p in referencePhotos.indices {
            for f in referencePhotos[p].faces.indices { referencePhotos[p].faces[f].accepted = accepted }
        }
    }

    func removeReferencePhoto(_ id: UUID) {
        referencePhotos.removeAll { $0.id == id }
    }

    // MARK: ③ Source

    func chooseSource(_ url: URL, access suppliedAccess: SecurityScopedAccess? = nil) {
        enumerationTask?.cancel()
        if url != sourceRoot { cancelScan(); resetScan() }
        let access = suppliedAccess ?? SecurityScopedAccess(url)
        sourceAccess = access
        sourceRoot = url
        enumeration = nil
        enumerationError = nil
        enumeratingCount = 0
        enumerationTask = Task {
            let worker = Task.detached(priority: .userInitiated) { () -> Result<EnumerationResult, Error> in
                defer { withExtendedLifetime(access) {} }
                return Result {
                    try FolderEnumerator.enumerate(root: url) { count in
                        Task { @MainActor in
                            if self.enumeratingCount != nil { self.enumeratingCount = count }
                        }
                    }
                }
            }
            let result = await withTaskCancellationHandler { await worker.value } onCancel: { worker.cancel() }
            guard !Task.isCancelled else { return }
            enumeratingCount = nil
            switch result {
            case .success(let e): enumeration = e
            case .failure(let error): enumerationError = error.localizedDescription
            }
        }
    }

    // MARK: ④ Scan

    var processedCount: Int { results.count }
    var totalCount: Int { enumeration?.items.count ?? 0 }
    var failedResults: [PhotoResult] { results.filter { $0.error != nil } }
    var failedCount: Int { failedResults.count }
    var facesFound: Int { results.reduce(0) { $0 + $1.faces.count } }
    var photosPerSecond: Double { scanElapsed > 0 ? Double(processedCount) / scanElapsed : 0 }

    func startScan() {
        guard let items = enumeration?.items, let pipeline else { return }
        let faces = acceptedFaces
        let references = ReferenceSet(embeddings: faces.map(\.face.embedding))
        guard !references.isEmpty else { return }

        cancelScan()
        resetScan()
        scannedReferenceIDs = Set(faces.map(\.id))
        matcher.threshold = defaultThreshold
        scanStatus = .running
        activeSince = Date()
        step = .scan

        scanControl = ScanControl()
        pauseGate = PauseGate()
        let control = scanControl
        let gate = pauseGate
        let generation = scanGeneration
        let access = sourceAccess
        scanTask = Task {
            defer { withExtendedLifetime(access) {} }
            await gate.setPaused(false)
            var buffer: [PhotoResult] = []
            var lastFlush = Date()
            for await result in scanRunner(items, references, pipeline, gate, control) {
                buffer.append(result)
                if Date().timeIntervalSince(lastFlush) > scanFlushInterval {
                    flush(&buffer, generation: generation)
                    lastFlush = Date()
                }
            }
            flush(&buffer, generation: generation)
            finishScan(cancelled: scanStatus == .cancelled || Task.isCancelled, generation: generation)
        }
    }

    private func updateElapsed() {
        scanElapsed = elapsedBeforePause + (activeSince.map { Date().timeIntervalSince($0) } ?? 0)
    }

    private func flush(_ buffer: inout [PhotoResult], generation: UUID) {
        guard !buffer.isEmpty, generation == scanGeneration else { return }
        results.append(contentsOf: buffer)
        lastScannedPath = buffer.last?.item.relativePath ?? lastScannedPath
        buffer.removeAll(keepingCapacity: true)
        updateElapsed()
        // Results that arrive after Stop are still valid; keep the reviewable list sorted.
        if scanStatus == .cancelled { sortResults() }
    }

    private func sortResults() {
        results.sort { $0.bestScore > $1.bestScore }
    }

    private func finishScan(cancelled: Bool, generation: UUID) {
        guard generation == scanGeneration else { return }
        scanTask = nil
        guard scanStatus == .running || scanStatus == .paused else { return }
        updateElapsed()
        activeSince = nil
        sortResults()
        scanStatus = cancelled ? .cancelled : .finished
        if !cancelled, step == .scan { step = .review }
    }

    func togglePause() {
        guard scanStatus == .running || scanStatus == .paused else { return }
        let pause = scanStatus == .running
        if pause {
            updateElapsed()
            elapsedBeforePause = scanElapsed
            activeSince = nil
        } else {
            activeSince = Date()
        }
        scanStatus = pause ? .paused : .running
        let gate = pauseGate
        Task { await gate.setPaused(pause) }
    }

    func cancelScan() {
        guard scanTask != nil else { return }
        scanControl.cancel()
        if scanStatus == .running || scanStatus == .paused {
            updateElapsed()
            elapsedBeforePause = scanElapsed
            activeSince = nil
            sortResults()
            scanStatus = .cancelled
        }
    }

    private func resetScan() {
        scanGeneration = UUID()
        results = []
        scanStatus = .idle
        scanElapsed = 0
        elapsedBeforePause = 0
        activeSince = nil
        lastScannedPath = ""
        scannedReferenceIDs = []
        matcher = Matcher(threshold: defaultThreshold)
        exportSummary = nil
        exportError = nil
    }

    // MARK: ⑤ Review

    var threshold: Float {
        get { matcher.threshold }
        set { matcher.threshold = newValue }
    }

    /// The model's calibrated threshold, adjusted for how many reference faces the scan compares against.
    var defaultThreshold: Float {
        Matcher.defaultThreshold(model: embedder?.defaultThreshold ?? FaceEmbedder.fallbackThreshold,
                                 referenceCount: scannedReferenceIDs.count)
    }

    var thresholdRange: ClosedRange<Float> { Matcher.thresholdRange(default: defaultThreshold) }

    func isIncluded(_ r: PhotoResult) -> Bool { matcher.isIncluded(r) }

    func setIncluded(_ include: Bool, for r: PhotoResult) { matcher.setIncluded(include, for: r) }

    var selectedResults: [PhotoResult] { matcher.selected(results) }

    // MARK: ⑥ Export

    func plannedOperations() -> Result<[CopyOperation], Error>? {
        guard let sourceRoot, let destination else { return nil }
        return Result {
            try ExportPlanner.plan(items: selectedResults.map(\.item), source: sourceRoot,
                                   destination: destination, includeSidecars: includeSidecars)
        }
    }

    var isExporting: Bool { exportTask != nil }

    func startExport() {
        guard !isExporting, case .success(let ops)? = plannedOperations() else { return }
        exportSummary = nil
        exportError = nil
        exportProgress = (0, ops.count)
        let exportRunner = exportRunner
        let accesses = [sourceAccess, destinationAccess]
        exportTask = Task {
            defer { withExtendedLifetime(accesses) {} }
            let worker = Task.detached(priority: .userInitiated) {
                await exportRunner(ops) { done, total in
                    Task { @MainActor in self.exportProgress = (done, total) }
                }
            }
            let summary = await withTaskCancellationHandler { await worker.value } onCancel: { worker.cancel() }
            exportSummary = summary
            exportTask = nil
        }
    }

    func cancelExport() {
        exportTask?.cancel()
    }

    // MARK: Utilities

    func reveal(_ url: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }
}
