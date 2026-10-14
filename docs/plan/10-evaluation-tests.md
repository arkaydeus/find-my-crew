# 10 — Evaluation & tests

## Goal
Objective evidence that detection + recognition work, and regression protection.

## Design
- **Unit tests** (`FindMyCrewTests`): ImageLoader, FaceAligner maths, Matcher, ExportPlanner, ExportService (temp dirs), FolderEnumerator.
- **Integration test**: pipeline on small fixture faces (generated or public‑domain) checks detection count and embedding norm.
- **`fmc-eval` CLI**: `fmc-eval <dir> [--pairs N] [--model path]` where `<dir>` contains one sub‑folder per identity (LFW layout). Computes embeddings for all images (largest face), then genuine/impostor cosine distributions, ROC, TAR@FAR=1e‑2/1e‑3, best‑accuracy threshold, and throughput (images/s). Used to calibrate `fmc.defaultThreshold`.
- Eval data is downloaded locally by `scripts/eval/fetch_lfw.sh` (`mise run eval:fetch`, checksum‑verified) into `models-cache/eval/{lfw,pairs.txt}` and is never committed.
- `fmc-eval` ends with an `Acceptance:` line and exits non‑zero if either criterion below fails.
- **End‑to‑end test library** (`mise run testset`, ~2 GB): `scripts/eval/fetch_testset.py` downloads openly licensed photos, with the licence of each recorded in `manifest.csv`:
  - ten public figures (~80 photos each) from Wikimedia Commons;
  - official portraits of other people as hard negatives;
  - scenes and crowds;
  - full‑resolution originals for throughput;
  - CC0 camera‑RAW samples (CR2/CR3/NEF/ARW/RAF/ORF/RW2/PEF/SRW/DNG) from raw.pixls.us.

  `build_scenario.py` turns these into a messy library with ground truth (`labels.tsv`):
  - nested year/event folders with Unicode names;
  - mixed formats (HEIC/PNG/TIFF/WebP/GIF/BMP), EXIF‑rotated, grayscale and 640 px copies;
  - duplicates, RAW+JPEG pairs and .xmp/.aae sidecars;
  - corrupt files, hidden files and a `.photoslibrary` package.

  Reference photos are hand‑picked, as a user would choose them (`scenario_references.json`).
- **`fmc-eval scan`** (`mise run eval:scenario`) runs the app's Core path end to end on that library:
  - reference faces follow the app's Yes/No defaults; in multi‑face photos it picks the face that resembles the person;
  - folder enumeration and `ScanEngine` scan;
  - `Matcher` at the app default, with a threshold sweep;
  - `ExportPlanner` + `ExportService`, verified byte‑for‑byte (structure, dates, sidecars, sources untouched).

  It reports per‑person precision/recall, throughput and memory. Commons category labels are noisy (e.g. a minister in a general's photos), so false positives and misses should be audited visually before quoting accuracy.

## Acceptance criteria
- `mise run test` green.
- `mise run eval` prints TAR@FAR=1 % ≥ 97 % for the built‑in model on LFW subset and the measured threshold matches the shipped default within ±0.05.
