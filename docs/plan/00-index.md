# Implementation Plan — Index

Source of truth for requirements: [`../PRD.md`](../PRD.md).

| # | Feature | Depends on | PRD refs |
|---|---|---|---|
| 01 | [Project scaffold](01-project-scaffold.md) | — | §6 Security, Distribution |
| 02 | [Face models (Core ML conversion)](02-face-models.md) | — | FR‑7, §7.1–7.2 |
| 03 | [Image loading](03-image-loading.md) | 01 | FR‑2.2, FR‑3.2 |
| 04 | [Face pipeline: detect → align → embed](04-face-pipeline.md) | 02, 03 | FR‑3, FR‑4 |
| 05 | [Reference faces (step ①–②)](05-reference-faces.md) | 04 | FR‑1 |
| 06 | [Folder scan (step ③–④)](06-folder-scan.md) | 04 | FR‑2, FR‑3, NFR performance |
| 07 | [Matching & review (step ⑤)](07-matching-review.md) | 05, 06 | FR‑4.3–4.4, FR‑5 |
| 08 | [Export / copy (step ⑥)](08-export-copy.md) | 07 | FR‑6 |
| 09 | [Settings & custom model](09-settings-custom-model.md) | 02, 04 | FR‑7.2 |
| 10 | [Evaluation & tests](10-evaluation-tests.md) | 04 | NFR accuracy |

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
