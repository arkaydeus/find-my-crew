# Find My Crew — Product Requirements Document

| | |
|---|---|
| Status | Draft v1 |
| Date | 2026-10-11 |
| Platform | macOS 15+ (developed and tuned on macOS 27 / Apple M5 Pro) |
| Stack | Swift 6, SwiftUI, Vision, Core ML, ImageIO |

## 1. Problem

People accumulate huge photo folders (phone dumps, event shoots, family archives) spread across nested sub‑folders. Pulling out "every photo that has Mum, Sam or me in it" is a manual, hours‑long job. Cloud photo services can do it, but require uploading private photos and lock results inside their app.

## 2. Goal

A native Mac app that, given a few sample photos of the people you care about, finds **every** photo in a folder tree that contains any of those people — entirely on‑device — and copies the matches to a new folder while preserving the original folder structure.

### Non‑goals (v1)

- Video files (frame sampling) — out of scope.
- Naming/clustering every person in the library (Photos‑style "People" album).
- Editing, deleting or moving originals. The app is **read‑only** on the source folder.
- Cloud/hosted inference of any kind.
- Windows/Linux/iOS.

## 3. Users & context

- **Primary user:** a non‑technical Mac owner with a large local photo folder (10k–500k files, mixed JPEG/HEIC/RAW).
- Distributed free of charge (no paid tier) → **all bundled models must have licences that allow redistribution**.
- Runs on Apple silicon; target device is an M5‑class Mac, so the Neural Engine (ANE) and GPU should do the heavy lifting.

## 4. User flow

```
① Reference photos ─▶ ② Confirm faces ─▶ ③ Choose folder ─▶ ④ Scan ─▶ ⑤ Review ─▶ ⑥ Copy
```

1. **Add reference photos.** User drags in (or picks via Open panel) one or more photos of the people to find. 3–10 photos per person in varied conditions is recommended (shown as a hint).
2. **Confirm faces.** Every face detected in the reference photos is shown as a cropped tile. Each tile has a **Yes / No** toggle. Only "Yes" faces become search targets. Tiles show a quality warning for blurry, tiny or extreme‑angle faces.
3. **Choose source folder.** User picks a folder; the app shows a live count of image files found (recursively, all sub‑folders).
4. **Scan.** The app detects every face in every image, computes an embedding, and compares it to the target faces. Progress bar, throughput (photos/s), ETA, current file, pause/cancel.
5. **Review.** Grid of matched photos, sorted by best similarity, with the matched face highlighted. A **sensitivity slider** (similarity threshold) updates the result set instantly without re‑scanning. Each photo has an include checkbox (to drop false positives). A "near misses" section shows photos just below threshold so the user can rescue false negatives.
6. **Copy.** User chooses a destination folder. Included photos are copied, recreating the relative sub‑folder path from the source root. Progress, summary (copied / skipped / failed), and "Reveal in Finder".

## 5. Functional requirements

### FR‑1 Reference intake
- FR‑1.1 Accept images via drag‑and‑drop and `NSOpenPanel` (multiple selection).
- FR‑1.2 Detect all faces in each reference photo; show tiles with Yes/No (default **Yes** when a photo contains exactly one face, otherwise **No** so the user must choose).
- FR‑1.3 Remove a reference photo; "Select all / none".
- FR‑1.4 At least one "Yes" face is required to continue.
- FR‑1.5 Warn on low‑quality reference faces (capture quality score, size < 64 px, |yaw| > 45°).

### FR‑2 Source selection & enumeration
- FR‑2.1 Pick a folder; enumerate recursively, skipping hidden files and packages (e.g. `.photoslibrary`) with an explanatory note.
- FR‑2.2 Supported types: JPEG, PNG, HEIC/HEIF, TIFF, WebP, GIF (first frame), BMP and camera RAW (CR2, CR3, NEF, ARW, DNG, RAF, ORF, RW2, PEF, SRW) — anything ImageIO can decode that conforms to `public.image`.
- FR‑2.3 Unreadable/corrupt files are logged and skipped, never crash the scan.

### FR‑3 Face detection
- FR‑3.1 Detect faces down to ~24 px on a long edge of ≥ 1600 px working resolution.
- FR‑3.2 Respect EXIF orientation.
- FR‑3.3 Produce 5‑point landmarks (eyes, nose, mouth corners) for alignment, plus a quality score.

### FR‑4 Face recognition
- FR‑4.1 Align each face to the standard 112×112 ArcFace 5‑point template via a similarity transform.
- FR‑4.2 Compute an L2‑normalised embedding; use horizontal‑flip test‑time augmentation (sum of original + flipped embeddings) for robustness.
- FR‑4.3 A photo **matches** if any face in it has cosine similarity ≥ threshold to **any** accepted reference face (rule: *any tagged person*).
- FR‑4.4 Threshold defaults to the model's calibrated value; adjustable in Review.

### FR‑5 Review
- FR‑5.1 Thumbnails load lazily; grid stays responsive with 10k+ results.
- FR‑5.2 Threshold changes re‑filter in < 100 ms (no re‑inference — all per‑face scores are retained).
- FR‑5.3 Per‑photo include/exclude, Quick Look preview (space bar), Reveal in Finder.

### FR‑6 Copy / export
- FR‑6.1 Destination must not be inside the source folder (prevents recursion) — validated.
- FR‑6.2 Recreate `relative/path/from/source/root` under destination.
- FR‑6.3 Collisions: skip if an identical file (same size) already exists; otherwise append ` (1)`, ` (2)`…
- FR‑6.4 Preserve file metadata (creation/modification dates, EXIF — byte‑for‑byte copy).
- FR‑6.5 Optionally copy RAW+JPEG sidecars and `.xmp`/`.aae` sidecars that share a basename (on by default).

### FR‑7 Model management
- FR‑7.1 Bundled default embedding model with a redistribution‑friendly licence.
- FR‑7.2 Settings allow importing a custom Core ML embedding model (`.mlpackage`/`.mlmodel`) that follows the app's I/O contract (see §7). Changing model invalidates scan results.

## 6. Non‑functional requirements

| Area | Requirement |
|---|---|
| Privacy | 100 % on‑device. No network entitlement. No telemetry. |
| Performance | ≥ 25 photos/s for 12 MP JPEGs on M5 (ANE/GPU), scan never blocks UI. Memory < 2 GB regardless of folder size. |
| Accuracy | On LFW‑style verification, TAR ≥ 97 % at the default threshold with FAR ≤ 1 % (measured by eval tool). |
| Robustness | Corrupt files skipped; cancellation within 1 s; safe to quit mid‑scan. |
| Security | App Sandbox; only user‑selected read/write access. Source is never modified. |
| Accessibility | All controls labelled for VoiceOver; keyboard‑navigable grid. |
| Distribution | Developer‑ID signed + notarised build possible; all bundled assets redistributable. |

## 7. Technical approach

### 7.1 Model choice (state of the art vs. licence)

| Stage | Choice | Why |
|---|---|---|
| Detection + landmarks + quality | **Apple Vision** (`DetectFaceRectanglesRequest`, `DetectFaceLandmarksRequest`, `DetectFaceCaptureQualityRequest`) | Apple's current production face detector, ANE‑accelerated, ships with the OS → zero licence risk, no bundle size. Comparable recall to SCRFD/RetinaFace on consumer photos; SCRFD weights are research‑only. |
| Recognition (bundled) | **SFace** (OpenCV Zoo, Apache‑2.0) → Core ML ML Program | Best recognition model with an explicit redistribution‑friendly licence on the *weights*. LFW 99.4 %. |
| Recognition (optional, user‑supplied) | Any ArcFace‑style model, e.g. InsightFace `w600k_r50` / AdaFace | Higher accuracy (IJB‑C), but weights are non‑commercial/research‑only, so the app never ships or downloads them. A conversion script is provided for personal use. |

Accuracy boosters independent of model: multi‑reference matching (max over all references), flip TTA, quality‑aware filtering, and a user‑tunable threshold with near‑miss review.

### 7.2 Embedding model I/O contract

- Input `image`: 112×112 RGB image (`ImageType`; normalisation baked into the model).
- Output `embedding`: Float32/Float16 `[1, D]`.
- Metadata (`user_defined_metadata`): `fmc.inputSize`, `fmc.embeddingDim`, `fmc.alignment = arcface5`, `fmc.defaultThreshold`.

### 7.3 Architecture

```
SwiftUI Views ──▶ AppModel (@Observable, @MainActor, wizard state)
                      │
     ┌────────────────┼──────────────────────────┐
     ▼                ▼                          ▼
ReferenceService   ScanEngine (actor)        ExportService (actor)
     │                │  TaskGroup, bounded concurrency
     └──────┬─────────┘
            ▼
      FacePipeline: ImageLoader → FaceDetector → FaceAligner → FaceEmbedder
            ▼
      Matcher (pure, vectorised cosine via Accelerate)
```

## 8. Success metrics

- A user can go from launch to copied results in < 5 minutes of interaction for a 20k‑photo folder.
- ≤ 2 % false positives at the default threshold on a mixed personal test set; recall ≥ 95 % for frontal/near‑frontal faces.

## 9. Risks & mitigations

| Risk | Mitigation |
|---|---|
| Bundled permissive model is less accurate than research models | Pluggable model slot; multi‑reference + TTA; near‑miss review. |
| Children / ageing across years reduce recall | Encourage references spanning ages; threshold slider. |
| Huge RAW files are slow to decode | Use ImageIO thumbnail decoding at working size (embedded previews when large enough). |
| Sandbox access lost after relaunch | v1 keeps state per session; security‑scoped bookmarks for recent folders are a v2 item. |

## 10. Future (v2+)

Scan cache across sessions, person naming/grouping, video support, Photos library source, "find everyone" clustering, symlink‑instead‑of‑copy export.
