# 03 — Image loading

## Goal
Fast, memory‑bounded decoding of every supported image type, orientation‑corrected, at a working resolution suitable for face detection.

## Design
- `ImageLoader` (Core, `Sendable` struct).
  - `isSupported(url)` — `UTType(filenameExtension:)` conforms to `.image`, plus an explicit RAW extension allow‑list (some RAW UTTypes conform to `public.camera-raw-image`).
  - `load(url, maxPixel: Int = 2048) -> CGImage` using `CGImageSourceCreateThumbnailAtIndex` with `kCGImageSourceCreateThumbnailFromImageAlways`, `kCGImageSourceCreateThumbnailWithTransform` (applies EXIF orientation), `kCGImageSourceThumbnailMaxPixelSize`, and `kCGImageSourceShouldCacheImmediately`. `kCGImageSourceShouldCache = false` on the source so memory is released per image.
  - `thumbnail(url, maxPixel: 400)` for UI grids (same path, smaller size).
- Working resolution 2048 px long edge balances small‑face recall vs. speed (a 24 px face at 2048 ≈ 70 px at 6000 px originals).
- Errors: typed `ImageLoadError.unreadable(url)`.

## Tasks
1. `ImageLoader.swift` with supported‑type logic and decoding.
2. `ThumbnailCache` (actor, `NSCache`‑backed) for the UI.
3. Unit tests: orientation (generated EXIF‑rotated JPEG), unsupported file, max pixel bound.

## Acceptance criteria
- EXIF‑rotated images come back upright.
- Long edge never exceeds `maxPixel`.
- Non‑images (e.g. `.txt`, `.mov`) are rejected by `isSupported`.
