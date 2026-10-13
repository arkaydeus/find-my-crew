# 02 — Face models (Core ML conversion)

## Goal
Ship a redistributable, ANE‑friendly face‑embedding model and reproducible tooling to (re)generate it, plus a converter for user‑supplied ArcFace‑style models.

## Decisions
- **Detector:** Apple Vision (no model file needed). See PRD §7.1.
- **Embedder:** OpenCV Zoo SFace `face_recognition_sface_2021dec.onnx` (Apache‑2.0), 128‑D.
- Conversion path: ONNX → `onnx2torch` → TorchScript trace → `coremltools` ML Program (macOS 15 target). (coremltools no longer converts ONNX directly.)
- Normalisation baked into an `ImageType` input so Swift just supplies a 112×112 `CVPixelBuffer`.

## I/O contract (shared with custom models)
| Name | Kind | Shape | Notes |
|---|---|---|---|
| `image` | Image (RGB) | 112×112 | Aligned with ArcFace 5‑point template |
| `embedding` | MultiArray Float | `[1, D]` | Not normalised; app L2‑normalises |

Metadata keys: `fmc.inputSize`, `fmc.embeddingDim`, `fmc.alignment` (`arcface5`), `fmc.defaultThreshold`.

## Tasks
1. `scripts/models/setup_venv.sh` + pinned `requirements.txt` (Python 3.12).
2. `convert_sface.py` — download, verify OpenCV preprocessing, convert, parity check vs onnxruntime (cosine > 0.999), write `FindMyCrew/Resources/Models/SFace.mlpackage`.
3. `convert_onnx_embedder.py` — generic converter (scale/bias/colour/threshold flags) for personal‑use models; never downloads research‑licensed weights.
4. `scripts/models/README.md` with licensing notes.

## Acceptance criteria
- Running `make models` regenerates an identical‑contract model.
- Parity check passes and is printed.
- The app target compiles the `.mlpackage` (Xcode generates the `.mlmodelc`).
