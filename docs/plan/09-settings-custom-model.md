# 09 — Settings & custom model

## Goal
Allow advanced users to swap the bundled embedder for a higher‑accuracy model they converted themselves (e.g. ArcFace R50 for personal use), and tune performance options.

## Design
- `Settings` scene (⌘,):
  - **Recognition model**: "Built‑in (SFace, Apache‑2.0)" or "Custom…". Import accepts `.mlpackage`/`.mlmodel`/`.mlmodelc`; the app compiles (`MLModel.compileModel(at:)`) and copies the compiled model into `Application Support/FindMyCrew/Models/`. Validate the I/O contract (`image` 112×112 image input, `embedding` output) and show embedding dim + default threshold read from metadata. Licence reminder text.
  - **Detection resolution**: 1600 / 2048 (default) / 3072 px.
  - **Flip augmentation**: on (default) / off.
- Persisted with `@AppStorage`; `ModelStore` resolves the active `FaceEmbedder`. Switching model clears reference embeddings (re‑embedded automatically) and scan results.

## Acceptance criteria
- Importing a model that violates the contract shows a precise error.
- Switching back to Built‑in always works.
