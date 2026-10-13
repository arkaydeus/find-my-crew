# 08 — Export / copy (step ⑥)

## Goal
Copy selected photos into a destination folder, mirroring the source sub‑folder structure, without ever modifying the source.

## Design
- **ExportPlanner** (pure, unit‑tested): given source root, destination root, selected items, options → `[CopyOperation { from, to }]`.
  - `to = destination / relativePath` (relative to source root).
  - Validates: destination ≠ source and not inside it.
  - Sidecars (option, default on): files in the same directory sharing basename with extension in `{xmp, aae, dng, cr2, cr3, nef, arw, raf, orf, rw2, jpg, jpeg, heic}` that were not themselves selected.
- **ExportService** (actor): creates intermediate directories, `FileManager.copyItem` (APFS clone where possible, preserves metadata). Collision policy: identical size → skip; otherwise suffix ` (n)`. Progress stream; cancellable; failures collected.
- UI `ExportView`: choose destination, options (include sidecars), preview "Will copy N files (X GB) into M folders", Copy button, progress, summary + Reveal in Finder.

## Acceptance criteria
- Unit test: nested structure `a/b/c.jpg` → `dest/a/b/c.jpg`.
- Destination inside source is rejected with a clear message.
- Collision handling produces `name (1).jpg` and skips identical files.
- Originals untouched (verified by test comparing mtimes/hashes).
