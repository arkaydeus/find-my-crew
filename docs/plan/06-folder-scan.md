# 06 — Folder scan (steps ③ and ④)

## Goal
Recursively process every supported image under the chosen folder, quickly and cancellably, retaining per‑face similarity scores for instant re‑thresholding.

## Design
- **FolderEnumerator** — `FileManager.enumerator(at:includingPropertiesForKeys:[.isRegularFileKey,.fileSizeKey,.contentTypeKey], options:[.skipsHiddenFiles,.skipsPackageDescendants])`; yields `ScanItem { url, relativePath, size }`. Runs off the main actor; reports a running count.
- **ScanEngine** (actor):
  - Input: items, reference embeddings matrix (R×D), pipeline.
  - Bounded concurrency via `withThrowingTaskGroup` keeping `N = activeProcessorCount` tasks in flight (decode on CPU, Vision/Core ML on ANE/GPU).
  - For each image: load @2048 px → faces → for each face `bestScore = max_r cos(face, ref_r)`, `bestRef = argmax`. Store `PhotoResult { item, faces: [FaceHit{ box, score, refIndex }], error? }` — only faces' scores/boxes, not embeddings (memory: ~100 B per face).
  - Progress published via `AsyncStream<ScanProgress>` (processed, total, matchesAtDefault, photos/s, current file); UI throttled to ~10 Hz.
  - Pause (suspend via continuation gate) / cancel (task cancellation, checked between images).
- UI:
  - `SourceView`: choose folder button, path control, live "Found N images (M sub‑folders)", list of skipped packages.
  - `ScanView`: progress bar, counts, ETA, matches so far (thumbnail strip), Pause/Cancel; auto‑advance to Review when done.

## Acceptance criteria
- 1 000‑image synthetic folder scans with constant memory (no growth > 300 MB).
- Cancel stops within 1 s; partial results reviewable.
- Corrupt files counted under "Skipped" with reason.
