# 05 — Reference faces (steps ① and ②)

## Goal
User adds sample photos, sees every detected face, and marks each Yes/No.

## Design
- Model: `ReferenceFace { id, sourceURL, crop: CGImage, face: DetectedFace, accepted: Bool }`, `ReferencePhoto { url, faces: [ReferenceFace], state: loading|done|failed }`.
- `AppModel.addReferencePhotos(urls)` → processes concurrently via `FacePipeline`, appends results as they arrive.
- Default acceptance: `true` if the photo has exactly one face, else `false`.
- Face crop for display: bounding box expanded 40 %, clamped, cropped from the working image.
- Quality badge: ⚠︎ if quality < 0.3, box < 64 px, or |yaw| > 45°.
- UI `ReferencesView`:
  - Empty state drop zone ("Drop photos of the people you want to find").
  - `LazyVGrid` of face tiles grouped by photo; tile = crop + Yes/No segmented toggle (green/red border); context menu "Remove photo".
  - Toolbar: Add Photos…, Accept all, Reject all; counter "N faces selected".
  - Next is enabled when ≥ 1 face accepted.

## Acceptance criteria
- Dropping 5 photos shows faces within seconds; the UI never freezes.
- Photos with no face show an inline "No faces found" note.
- Toggling updates the selected counter; Next gating works.
