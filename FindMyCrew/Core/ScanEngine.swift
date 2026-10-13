import CoreGraphics
import Foundation

/// One face found during the scan, scored against the reference set.
struct FaceHit: Sendable, Hashable {
    /// Normalised 0…1, top-left origin.
    var box: CGRect
    /// Cosine similarity to the closest reference face.
    var score: Float
    var referenceIndex: Int
}

struct PhotoResult: Sendable, Identifiable {
    let item: ScanItem
    let faces: [FaceHit]
    let error: String?
    /// Highest face score in the photo (−1 when it has no faces). Stored because review
    /// re-filters every result on each threshold change.
    let bestScore: Float

    init(item: ScanItem, faces: [FaceHit], error: String? = nil) {
        self.item = item
        self.faces = faces
        self.error = error
        bestScore = faces.map(\.score).max() ?? -1
    }

    var id: URL { item.url }
    var bestFace: FaceHit? { faces.max { $0.score < $1.score } }
}

/// Lets a running scan be paused and resumed.
actor PauseGate {
    private var paused = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func setPaused(_ value: Bool) {
        paused = value
        if !value {
            waiters.forEach { $0.resume() }
            waiters.removeAll()
        }
    }

    func waitIfPaused() async {
        guard paused, !Task.isCancelled else { return }
        await withCheckedContinuation { waiters.append($0) }
    }
}

/// Stop the producer without cancelling the consumer, so completed results can still be drained.
final class ScanControl: @unchecked Sendable {
    private let lock = NSLock()
    private var task: Task<Void, Never>?
    private var cancelled = false

    func install(_ task: Task<Void, Never>) {
        lock.withLock {
            self.task = task
            if cancelled { task.cancel() }
        }
    }

    func cancel() {
        lock.withLock { cancelled = true; task?.cancel() }
    }
}

enum ScanEngine {
    /// Processes `items` with bounded concurrency and streams one result per photo (in completion order).
    /// Cancelling the consuming task cancels the scan.
    static func run(
        items: [ScanItem],
        references: ReferenceSet,
        pipeline: FacePipeline,
        concurrency: Int = ProcessInfo.processInfo.activeProcessorCount,
        gate: PauseGate = PauseGate(),
        control: ScanControl = ScanControl()
    ) -> AsyncStream<PhotoResult> {
        stream(items: items, concurrency: concurrency, gate: gate, control: control) { item in
            await process(item, references: references, pipeline: pipeline)
        }
    }

    /// Separate worker entry point allows deterministic cancellation coverage without model timing.
    static func stream(
        items: [ScanItem], concurrency: Int, gate: PauseGate = PauseGate(), control: ScanControl,
        process: @escaping @Sendable (ScanItem) async -> PhotoResult?
    ) -> AsyncStream<PhotoResult> {
        AsyncStream(bufferingPolicy: .unbounded) { continuation in
            let task = Task.detached(priority: .userInitiated) {
                await produce(items: items, concurrency: concurrency, gate: gate, process: process) {
                    continuation.yield($0)
                }
                continuation.finish()
            }
            control.install(task)
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    static func produce(
        items: [ScanItem], concurrency: Int, gate: PauseGate,
        process: @escaping @Sendable (ScanItem) async -> PhotoResult?,
        yield: @escaping @Sendable (PhotoResult) -> Void
    ) async {
        await withTaskCancellationHandler {
            await withTaskGroup(of: PhotoResult?.self) { group in
                var iterator = items.makeIterator()
                for _ in 0..<max(1, concurrency) {
                    guard !Task.isCancelled, let item = iterator.next() else { break }
                    group.addTask { await process(item) }
                }
                while let result = await group.next() {
                    if let result { yield(result) }
                    if !Task.isCancelled { await gate.waitIfPaused() }
                    if Task.isCancelled {
                        group.cancelAll()
                        // Keep draining: children that already completed still have valid results.
                        continue
                    }
                    if let item = iterator.next() {
                        group.addTask { await process(item) }
                    }
                }
            }
        } onCancel: {
            Task { await gate.setPaused(false) }
        }
    }

    /// Scores every face in one photo. Returns `nil` if the scan was cancelled before it finished.
    static func process(_ item: ScanItem, references: ReferenceSet, pipeline: FacePipeline) async -> PhotoResult? {
        do {
            try Task.checkCancellation()
            let image = try autoreleasepool {
                try ImageLoader.load(item.url, maxPixel: pipeline.options.workingResolution)
            }
            let faces = try await pipeline.process(image: image)
            let hits = faces.map { face in
                let (score, index) = references.bestMatch(for: face.embedding)
                return FaceHit(box: face.normalizedBox, score: score, referenceIndex: index)
            }
            return PhotoResult(item: item, faces: hits)
        } catch is CancellationError {
            return nil
        } catch {
            return PhotoResult(item: item, faces: [], error: error.localizedDescription)
        }
    }
}
