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
    var item: ScanItem
    var faces: [FaceHit]
    var error: String?

    var id: URL { item.url }
    var bestScore: Float { faces.map(\.score).max() ?? -1 }
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
        guard paused else { return }
        await withCheckedContinuation { waiters.append($0) }
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
        gate: PauseGate = PauseGate()
    ) -> AsyncStream<PhotoResult> {
        AsyncStream(bufferingPolicy: .unbounded) { continuation in
            let task = Task.detached(priority: .userInitiated) {
                await withTaskGroup(of: PhotoResult.self) { group in
                    var iterator = items.makeIterator()
                    for _ in 0..<max(1, concurrency) {
                        guard let item = iterator.next() else { break }
                        group.addTask { await process(item, references: references, pipeline: pipeline) }
                    }
                    while let result = await group.next() {
                        continuation.yield(result)
                        await gate.waitIfPaused()
                        if Task.isCancelled { group.cancelAll(); break }
                        if let item = iterator.next() {
                            group.addTask { await process(item, references: references, pipeline: pipeline) }
                        }
                    }
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    static func process(_ item: ScanItem, references: ReferenceSet, pipeline: FacePipeline) async -> PhotoResult {
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
            return PhotoResult(item: item, faces: [], error: "Cancelled")
        } catch {
            return PhotoResult(item: item, faces: [], error: error.localizedDescription)
        }
    }
}
