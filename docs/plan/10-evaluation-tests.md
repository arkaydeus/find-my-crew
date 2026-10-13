# 10 — Evaluation & tests

## Goal
Objective evidence that detection + recognition work, and regression protection.

## Design
- **Unit tests** (`FindMyCrewTests`): ImageLoader, FaceAligner maths, Matcher, ExportPlanner, ExportService (temp dirs), FolderEnumerator.
- **Integration test**: pipeline on small fixture faces (generated or public‑domain) checks detection count and embedding norm.
- **`fmc-eval` CLI**: `fmc-eval <dir> [--pairs N] [--model path]` where `<dir>` contains one sub‑folder per identity (LFW layout). Computes embeddings for all images (largest face), then genuine/impostor cosine distributions, ROC, TAR@FAR=1e‑2/1e‑3, best‑accuracy threshold, and throughput (images/s). Used to calibrate `fmc.defaultThreshold`.
- Eval data is downloaded locally by `scripts/eval/fetch_lfw.sh` into `models-cache/` and is never committed.

## Acceptance criteria
- `make test` green.
- `make eval` prints TAR@FAR=1 % ≥ 97 % for the built‑in model on LFW subset and the measured threshold matches the shipped default within ±0.05.
