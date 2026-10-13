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

    // ③ Source
    private(set) var sourceRoot: URL?
    private(set) var enumeration: EnumerationResult?
    private(set) var enumeratingCount: Int?
    private(set) var enumerationError: String?
    private var enumerationTask: Task<Void, Never>?

    // ④ Scan
    private(set) var scanStatus: ScanStatus = .idle
    private(set) var results: [PhotoResult] = []
    private(set) var scanStart: Date?
    private(set) var scanElapsed: TimeInterval = 0
    private(set) var lastScannedPath = ""
    /// Reference faces used for the current results; editing them makes results stale.
    private(set) var scannedReferenceIDs: Set<UUID> = []
    private var scanTask: Task<Void, Never>?
    private let pauseGate = PauseGate()

    // ⑤ Review
    var threshold: Float = 0.36
    var excluded: Set<URL> = []
    var forceIncluded: Set<URL> = []

    // ⑥ Export
    var destination: URL?
    var includeSidecars = true
    private(set) var exportProgress: (done: Int, total: Int)?
    private(set) var exportSummary: ExportSummary?
    private(set) var exportError: String?
    private var exportTask: Task<Void, Never>?

    init() {
        Task { await reloadModel() }
    }

    // MARK: Model

    func reloadModel() async {
        do {
            let embedder = try await ModelStore.loadEmbedder(customModelName: settings.customModelName)
            self.embedder = embedder
            modelError = nil
            threshold = embedder.defaultThreshold
        } catch {
            embedder = nil
            modelError = "Could not load the face recognition model: \(error.localizedDescription)"
        }
    }

    /// Called when the recognition model or pipeline options change: everything must be recomputed.
    func pipelineChanged() async {
        cancelScan()
        await reloadModel()
        results = []
        scanStatus = .idle
        let urls = referencePhotos.map(\.url)
        referencePhotos = []
        addReferencePhotos(urls)
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

    func addReferencePhotos(_ urls: [URL]) {
        let existing = Set(referencePhotos.map(\.url))
        let new = urls.filter { ImageLoader.isSupported($0) && !existing.contains($0) }
        guard let pipeline else {
            if embedder == nil { Task { await reloadModel(); if self.embedder != nil { addReferencePhotos(new) } } }
            return
        }
        for url in new {
            let photo = ReferencePhoto(url: url)
            referencePhotos.append(photo)
            let id = photo.id
            Task.detached(priority: .userInitiated) {
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
                await self.finishReference(id: id, outcome: outcome)
            }
        }
    }

    private func finishReference(id: UUID, outcome: Result<[ReferenceFace], Error>) {
        guard let i = referencePhotos.firstIndex(where: { $0.id == id }) else { return }
        switch outcome {
        case .success(let faces):
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

    func chooseSource(_ url: URL) {
        enumerationTask?.cancel()
        if url != sourceRoot { resetScan() }
        sourceRoot = url
        enumeration = nil
        enumerationError = nil
        enumeratingCount = 0
        enumerationTask = Task {
            let worker = Task.detached(priority: .userInitiated) { () -> Result<EnumerationResult, Error> in
                Result {
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
    var failedCount: Int { results.filter { $0.error != nil }.count }
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
        scanStatus = .running
        scanStart = Date()
        step = .scan

        let gate = pauseGate
        scanTask = Task {
            await gate.setPaused(false)
            var buffer: [PhotoResult] = []
            var lastFlush = Date()
            for await result in ScanEngine.run(items: items, references: references, pipeline: pipeline, gate: gate) {
                buffer.append(result)
                if Date().timeIntervalSince(lastFlush) > 0.15 {
                    flush(&buffer)
                    lastFlush = Date()
                }
            }
            flush(&buffer)
            finishScan(cancelled: Task.isCancelled)
        }
    }

    private func flush(_ buffer: inout [PhotoResult]) {
        guard !buffer.isEmpty else { return }
        results.append(contentsOf: buffer.filter { $0.error != "Cancelled" })
        lastScannedPath = buffer.last?.item.relativePath ?? lastScannedPath
        buffer.removeAll(keepingCapacity: true)
        if let scanStart, scanStatus == .running { scanElapsed = Date().timeIntervalSince(scanStart) }
    }

    private func finishScan(cancelled: Bool) {
        guard scanStatus == .running || scanStatus == .paused else { return }
        if let scanStart { scanElapsed = Date().timeIntervalSince(scanStart) }
        results.sort { $0.bestScore > $1.bestScore }
        scanStatus = cancelled ? .cancelled : .finished
        if !cancelled, step == .scan { step = .review }
    }

    func togglePause() {
        let pause = scanStatus == .running
        scanStatus = pause ? .paused : .running
        let gate = pauseGate
        Task { await gate.setPaused(pause) }
    }

    func cancelScan() {
        guard let scanTask else { return }
        let gate = pauseGate
        Task { await gate.setPaused(false) }
        scanTask.cancel()
        self.scanTask = nil
        if scanStatus == .running || scanStatus == .paused {
            results.sort { $0.bestScore > $1.bestScore }
            scanStatus = .cancelled
        }
    }

    private func resetScan() {
        results = []
        scanStatus = .idle
        scanElapsed = 0
        excluded = []
        forceIncluded = []
        exportSummary = nil
        exportError = nil
    }

    // MARK: ⑤ Review

    var thresholdRange: ClosedRange<Float> {
        let d = embedder?.defaultThreshold ?? 0.36
        return max(0.05, d - 0.15)...min(0.95, d + 0.25)
    }

    static let nearMissMargin: Float = 0.08

    /// Photos at or above the threshold, best first.
    var matches: [PhotoResult] {
        results.filter { $0.bestScore >= threshold }
    }

    /// Photos just below the threshold, worth a second look.
    var nearMisses: [PhotoResult] {
        results.filter { $0.bestScore < threshold && $0.bestScore >= threshold - Self.nearMissMargin }
    }

    func isIncluded(_ r: PhotoResult) -> Bool {
        if forceIncluded.contains(r.id) { return true }
        return r.bestScore >= threshold && !excluded.contains(r.id)
    }

    func setIncluded(_ include: Bool, for r: PhotoResult) {
        if r.bestScore >= threshold {
            if include { excluded.remove(r.id) } else { excluded.insert(r.id) }
        } else {
            if include { forceIncluded.insert(r.id) } else { forceIncluded.remove(r.id) }
        }
    }

    var selectedResults: [PhotoResult] {
        results.filter(isIncluded)
    }

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
        guard case .success(let ops)? = plannedOperations() else { return }
        exportSummary = nil
        exportError = nil
        exportProgress = (0, ops.count)
        exportTask = Task {
            let worker = Task.detached(priority: .userInitiated) {
                await ExportService.execute(ops) { done, total in
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
