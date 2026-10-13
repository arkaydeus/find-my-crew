# 04 — Face pipeline: detect → align → embed

## Goal
Given a `CGImage`, return every face with bounding box, quality info and an L2‑normalised embedding.

## Design
```swift
struct DetectedFace: Sendable {
  var boundingBox: CGRect      // normalised, top‑left origin
  var landmarks5: [CGPoint]    // image pixel coords: lEye, rEye, nose, lMouth, rMouth
  var quality: Float?          // Vision capture quality 0…1
  var yaw, roll: Double?       // degrees
  var pixelSize: CGFloat       // face box long edge in working pixels
  var embedding: [Float]       // unit length
}
```
- **FaceDetector** — Vision Swift API: `DetectFaceRectanglesRequest` → `DetectFaceLandmarksRequest(inputFaceObservations:)` → `DetectFaceCaptureQualityRequest`. Landmark regions → 5 points: pupils (fallback eye centroid), nose tip (lowest nose‑crest point / nose centroid), outer‑lip extreme left/right points. Points are mapped into top‑left pixel space.
- **FaceAligner** — least‑squares similarity transform (Umeyama, 4 DoF) from the 5 points to the ArcFace template:
  `(38.2946,51.6963) (73.5318,51.5014) (56.0252,71.7366) (41.5493,92.3655) (70.7299,92.2041)`.
  Render 112×112 BGRA `CVPixelBuffer` via `CGContext` with the affine transform (high interpolation). Also produce the horizontally flipped crop for TTA.
- **FaceEmbedder** — wraps `MLModel` (compute units `.all`), reads I/O contract metadata, runs a batch prediction (`MLArrayBatchProvider`) for original + flipped crops, sums and L2‑normalises. One `MLModel` instance shared; Core ML prediction is thread‑safe.
- **FacePipeline** — composes the above; `process(cgImage) async throws -> [DetectedFace]`; skips faces whose box is < 20 px.

## Tasks
1. `FaceDetector.swift`, `FaceAligner.swift`, `FaceEmbedder.swift`, `FacePipeline.swift`, `Vector.swift` (Accelerate dot/normalise).
2. Unit tests: aligner maps template to itself (identity) and recovers a known similarity transform; embedder output length & unit norm; pipeline finds ≥1 face in a bundled test face image.

## Acceptance criteria
- Same person (two different photos) cosine > default threshold; different people < threshold (fixture test).
- Pipeline handles images with 0 and with many faces.
