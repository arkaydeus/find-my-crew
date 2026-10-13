# 01 — Project scaffold

## Goal
A buildable, sandboxed macOS SwiftUI app with a test target and an eval CLI target, generated reproducibly.

## Design
- **XcodeGen** `project.yml` → `FindMyCrew.xcodeproj` (generated project is committed for convenience; regenerate with `make project`).
- Targets:
  - `FindMyCrew` (application, macOS 15.0+, Swift 6, bundle id `com.findmycrew.app`).
  - `FindMyCrewTests` (Swift Testing, **hostless**): compiles `FindMyCrew/Core/**`, the model and `FindMyCrewTests/Fixtures/` (public‑domain photos) directly, like `fmc-eval`. A sandboxed host app hangs XCTest's failure symbolication, and `Core/` is UI‑free by design, so no host is needed.
  - `fmc-eval` (command‑line tool) compiling `FindMyCrew/Core/**` + `FindMyCrewEval/**` and the model resource.
- Entitlements: `com.apple.security.app-sandbox`, `com.apple.security.files.user-selected.read-write`. **No** network entitlement.
- `Info.plist`: display name "Find My Crew", category `public.app-category.photography`.
- `Makefile`: `project`, `build`, `test`, `run`, `eval`, `fetch-eval`, `models`. `DERIVED=…` overrides the DerivedData path (needed when the repo lives on an external drive: Xcode‑launched test runners may be denied access to removable volumes and hang).
- App shell: single `WindowGroup` with a `NavigationSplitView`‑free wizard layout: step sidebar + content + bottom bar (Back / Next).

## Tasks
1. `project.yml`, entitlements, Info.plist keys, asset catalog with AppIcon + AccentColor.
2. `FindMyCrewApp.swift`, `AppModel` with `Step` enum (`references`, `source`, `scan`, `review`, `export`).
3. `Makefile`, `.gitignore`.

## Acceptance criteria
- `make build` succeeds with zero warnings under Swift 6 strict concurrency.
- `make test` runs (even if only a smoke test).
- Launching shows the wizard with step 1 active.
