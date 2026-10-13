# 07 — Matching & review (step ⑤)

## Goal
Let the user inspect matches, tune sensitivity live, and exclude false positives before copying.

## Design
- **Matcher** (pure): `photoScore = max(face.score)`; `isMatch = photoScore >= threshold`. Similarities computed with `vDSP` dot products on unit vectors (cosine). Reference matrix built once per scan.
- Threshold slider maps to a "Sensitivity" scale (Strict … Loose) but shows the raw value; default = model metadata `fmc.defaultThreshold`. Range [threshold − 0.15, threshold + 0.25].
- Results view model keeps all `PhotoResult`s sorted by score descending; filtering is an O(n) pass (fast for 100k).
- Per‑photo `excluded: Set<URL>` survives threshold changes.
- **Near misses**: photos with score in `[threshold − 0.08, threshold)`, collapsed section; clicking "Include" force‑includes them (`forcedIncluded: Set<URL>`).
- UI `ReviewView`: `LazyVGrid` tiles (async thumbnail, matched face box overlay, score badge, relative path tooltip, checkbox). Space = Quick Look (`QLPreviewPanel` via `NSViewRepresentable` or `quickLookPreview` modifier). Context menu: Reveal in Finder, Open.
- Summary bar: "N photos selected (M excluded) of K scanned".

## Acceptance criteria
- Moving the slider updates the grid immediately with 10k results.
- Exclusions persist across slider moves.
- Near‑miss rescue includes the photo in export.
