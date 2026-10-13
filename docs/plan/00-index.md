# Implementation Plan — Index

Source of truth for requirements: [`../PRD.md`](../PRD.md).

| # | Feature | Depends on | PRD refs | Status |
|---|---|---|---|---|
| 01 | [Project scaffold](01-project-scaffold.md) | — | §6 Security, Distribution | Done |
| 02 | [Face models (Core ML conversion)](02-face-models.md) | — | FR‑7, §7.1–7.2 | Done |
| 03 | [Image loading](03-image-loading.md) | 01 | FR‑2.2, FR‑3.2 | Done |
| 04 | [Face pipeline: detect → align → embed](04-face-pipeline.md) | 02, 03 | FR‑3, FR‑4 | Done |
| 05 | [Reference faces (step ①–②)](05-reference-faces.md) | 04 | FR‑1 | Done |
| 06 | [Folder scan (step ③–④)](06-folder-scan.md) | 04 | FR‑2, FR‑3, NFR performance | Done |
| 07 | [Matching & review (step ⑤)](07-matching-review.md) | 05, 06 | FR‑4.3–4.4, FR‑5 | Done |
| 08 | [Export / copy (step ⑥)](08-export-copy.md) | 07 | FR‑6 | Done |
| 09 | [Settings & custom model](09-settings-custom-model.md) | 02, 04 | FR‑7.2 | Done |
| 10 | [Evaluation & tests](10-evaluation-tests.md) | 04 | NFR accuracy | Done |

### Verification (2026‑10‑13, Apple M5 Pro, macOS 27)

- `make build`: zero warnings (Swift 6, strict concurrency).
- `make test`: 55 tests pass. Coverage:
  - detection, embedding and matching on public‑domain fixtures;
  - the small‑face landmark regression;
  - a 1,000‑image scan with < 300 MB memory growth (measured +56 MB);
  - cancel in < 1 s;
  - export collisions with originals untouched;
  - the `AppModel` wizard flow end to end (references → folder → scan → review → export, stop/rescan, pause, model fallback).
- `make models`: parity check passes (Core ML vs ONNX Runtime worst cosine 0.99991).
- `make eval` (LFW, 6,000‑pair protocol): TAR@FAR=1 % **99.40 %**, best‑accuracy threshold 0.345 vs shipped 0.363, no‑face rate 0 %, 217 images/s.
- `make scenario-eval` (1,337‑image test library, 3 people × 5 hand‑picked references, labels corrected by visual audit):
  - precision **93.9 %**, recall **93.9 %**;
  - false matches on 1.2 % of non‑target photos;
  - every format and variant decoded, 3/3 corrupt files skipped, hidden/package files never scanned, 16/16 sidecars exported, export verified byte‑for‑byte.
- GUI pass (real app, driven through accessibility):
  - every step on the test library: references with face picks, folder, scan with pause/resume, review (slider, exclude, near‑miss rescue), copy;
  - folder change, the inside‑source guard, a repeat copy, and Settings model import;
  - results match `fmc-eval scan`.
- Throughput: 96–109 photos/s on 12–45 MP originals. Memory plateaus at ~600 MB over 4,000 photos (peak 684 MB).

## Repository layout (target)

```
project.yml                     XcodeGen spec (generates FindMyCrew.xcodeproj)
Makefile                        project / build / test / run / models
FindMyCrew/
  App/                          App entry, AppModel (wizard state)
  Core/                         UI‑free logic (pipeline, scan, matching, export)
  Views/                        SwiftUI screens and components
  Resources/Models/SFace.mlpackage
  Resources/Assets.xcassets
FindMyCrewTests/                XCTest/Swift Testing unit + integration tests
FindMyCrewEval/                 CLI: verification accuracy on a labelled folder
scripts/models/                 Python conversion tooling (not shipped)
docs/
```

## Conventions

- Swift 6 language mode, strict concurrency. UI state is `@MainActor @Observable`; heavy work runs in actors / detached tasks.
- `Core/` must not import SwiftUI so it can be unit‑tested and reused by the eval CLI.
- Every feature doc lists **acceptance criteria**; a feature is done when they pass (`make test` + manual check where noted).
