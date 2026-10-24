# Review regression validation

Run the Swift suite (Core, drop providers, AppModel, custom-model fixtures and benchmark checks):

```sh
DERIVED=~/Library/Developer/Xcode/DerivedData/FindMyCrew mise run test
DERIVED=~/Library/Developer/Xcode/DerivedData/FindMyCrew mise run eval:build
mise run test:py
```

`mise run test` keeps xcodebuild diagnostics and its normal `.xcresult` bundle
under the chosen DerivedData directory. Isolate model import with diagnostics:

```sh
xcodebuild -project FindMyCrew.xcodeproj -scheme FindMyCrew \
  -derivedDataPath build/DerivedData test -only-testing:FindMyCrewTests/ModelImportTests
```

Use the suite filter for Swift Testing; a method filter without `()` can silently
select zero tests on this toolchain. Confirm the output actually names and runs
the desired test.

`DroppedItems` lives in Core and is compiled by the hostless test target.
`DroppedItemsTests` uses real `NSItemProvider` registrations to check URL preference,
inaccessible-URL fallback, skipped SVG and failing JPEG representations before PNG,
delayed delivery, mixed and complete failures, wrong Folder inputs, directory URL
normalization, untrusted filenames and declared-type extensions. Ownership tests
check failed/rejected copies, overlapping readers and stale-copy purging while a
live copy remains locked. `AppModelTests` covers repeated copied content, removal
and redrop during processing, ownership through re-embedding, and feedback retained
after navigation. Existing security-scope tests cover balanced grant lifetimes.

`mise run test:py` depends on `venv`; it creates `.venv-models` when absent.
The Python test substitutes tiny local download/build stages and places a failing
`python3` ahead of the prepared environment on PATH. It performs no downloads.
Regenerate the tiny Core ML contract fixtures, when needed, with
`.venv-models/bin/python scripts/models/build_contract_fixtures.py`.

`ScenarioValidationTests` checks unexpected unreadable positives (50% recall for
one failure among two positives), required skips, forbidden enumeration, missing
labels/results, selected sidecars and RAW pairs, and per-output verification when
one collision is renamed and an unrelated equal-size destination has bad bytes.
The benchmark reads `expectations.json` next to its labels file when present.
Only explicitly labelled `#unreadable` and `#truncated` cases are excluded from
accuracy. Unexpected unreadable inputs fail scenario status.

## Sandboxed Finder and Photos drop check

Headless tests check access acquisition/release and background-task lifetime, but
cannot prove Finder delivers sandbox grants. Run this check on the signed app
built by `mise run build`; keep App Sandbox and user-selected read/write entitlements
enabled. Place test files outside the app container. Do not use open panels to
grant these locations before dropping them.

1. Start a fresh app instance. In Finder, drag a reference JPEG (e.g.
   `FindMyCrewTests/Fixtures/harris_2021.jpg`) onto People. Confirm the image and
   detected face appear, with the single face accepted.
2. Drag a folder containing copies of that portrait onto Folder. Confirm the
   image count appears. Scan it and confirm the photos reach Review with no
   access/decode failures and their thumbnails load.
3. Copy the selected photos to a folder chosen in the destination panel. Confirm
   the files are copied and the source bytes stay unchanged.
4. Drag a JPEG onto Folder. Confirm it reports “Drop a folder from Finder”,
   changes no source selection and creates no temporary copy. An image-only
   provider should not activate the Folder target at all. Drop the actual Finder
   folder again and confirm its directory status survives provider delivery.
5. Use a disposable Photos library containing only the public-domain test
   portraits. Drag one portrait onto People. Confirm its face appears from a
   readable app-owned copy; drag it again and confirm only one reference remains.
   Drop several portraits together and verify each usable photo imports once.
6. Observe the sandbox's temporary `Dropped Photos` directory. Copied items use
   UUID subdirectories and a `.lease` file. Rejected duplicate copies disappear
   immediately; removing a reference deletes its copy after its last background
   reader finishes. In-place Finder originals must remain untouched. Change
   pipeline options while a copy is referenced and confirm it remains readable.
7. Remove a dropped reference while it is processing, replace the source while
   enumeration is running, and stop/restart a scan. Confirm no stale results
   appear and background jobs finish without revoked-access failures. Repeat
   drops/removals to check grants are balanced rather than retained indefinitely.
   Drop another item before a delayed provider finishes and navigate between
   People and Folder; failures should still appear at the main window.
8. Use a failing provider alongside a working one (or revoke access to one source
   before delivery). Confirm successful items import and the alert identifies the
   failed items with a Finder/export retry action. A wholly failed drop must also
   show feedback. The automated provider tests exercise delayed and failing
   registrations without relying on external-app timing.
9. Quit the test instance and start it again. Abandoned UUID directories older
   than one minute are purged; a copy locked by another running instance and
   unrelated directories are preserved. The age guard avoids racing a copy whose
   lock is still being created.

## Review and cancellation UI check

- Rescue a near miss, raise the threshold beyond the near-miss band and collapse
  Near misses. The photo must stay in Manually included, support Quick Look and
  keyboard navigation, and be untickable. Lowering the threshold must not render
  duplicate tiles.
- Stop a scan with buffered results, both directly and after pause/resume. Allow
  the tail to drain. Elapsed time must stay frozen and throughput must equal the
  final processed count divided by that duration. Restart immediately and confirm
  the old scan contributes no results to the new one.
- Cancel a multi-file copy after the first file. The summary must say Copy stopped
  and show the partial count. Copy again to continue; a completed copy says Done.

## Validation on 2026-10-13

The full Swift suite passed 73 test cases (107 runs including parameters), and
the isolated testset-interpreter regression passed with the prepared Python 3.12.
The existing 1,337-photo labelled scenario passed scan expectations and exported
232 files (16 sidecars); every output's bytes, modification date and folder
structure were verified. A native Finder-drop check was attempted but could not
run because macOS Accessibility and Screen Recording permissions were pending.
That runtime check remains outstanding; headless lifetime tests are not a
substitute for it.

## Validation on 2026-10-14

- The initial isolated `ModelImportTests` run reproduced the contract test failure
  with its assertion: Core ML could not find the manifest's weights entry.
  `NoImageInput.mlpackage` uses inline constants, but its manifest still requires
  an empty weights directory. A committed `.gitkeep` restores the directory in
  clean checkouts. All three isolated import tests then passed.
- The full Swift suite passed 88 test cases, including the drop-provider and
  AppModel regressions. The prior failing nonquiet provider run printed assertion
  locations and values, confirming that the test command retains diagnostics.
- `mise run test:py` passed both with the existing environment and in an isolated
  checkout with no `.venv-models`; the latter created Python 3.12's environment,
  installed the pinned dependencies, then ran the test successfully.
- `mise run eval:build` passed with the shared Core drop resolver compiled into
  the evaluation tool.
- The ad-hoc signed app built with App Sandbox and user-selected read/write
  entitlements enabled and launched with the built-in model. Native automation
  could inspect the app and select the disposable public-domain Finder fixture.
  Its cross-window drag did not deliver a drop: People remained empty, without an
  import or error alert. The native automation connection subsequently closed.
  This proves neither sandbox drag grants nor Photos interoperability. The real Finder/Photos sequence above remains unverified;
  automated provider and ownership tests do not replace that runtime check.

## CLI review regressions

The hostless test target also compiles the CLI helpers and writers, and builds `fmc` for subprocess tests.
Run them with the normal `mise run test`; to isolate them, use the suite filters
`CLIHelpersTests`, `ExtractTests`, `ImageWriterTests`, and `CLICommandTests` on `FindMyCrewTests`.

- Extraction tests hold concurrent writes until all colliding jobs have claimed a path. They verify distinct
  crops from two roots and a same-stem pair, existing files and numbered copies, overwrite semantics, mirrored
  paths, partial write failures and summary counts. Subprocess tests check overlapping inputs, RAW/JPEG
  preference, extraction-to-filter reference count, no-face photos and failure exits.
- Filter subprocess tests cover sorted reference indexes, largest-face selection, reference-folder exclusion,
  model-adjusted thresholds, TSV output, dry runs, copies, sidecars and repeat runs. Corrupt references and
  sources must exit 1 in dry-run, no-match and export modes while preserving valid matches. Valid no-match runs
  exit 0. Output inside references is rejected before model loading, including new paths under symlinks.
- Writer tests round-trip all five formats and check type, dimensions, upright pixels, unavailable destination
  errors and lossy quality. WebP decoding checks straight RGB and alpha for opaque and translucent regions and
  exercises an encoder failure. Helper tests cover path expansion, enumeration, input aliases, bounded
  concurrency, model lookup through a symlinked executable, and valid/invalid custom model contract fixtures.

Validation on 2026-10-25: all 117 Swift tests passed, including these regressions and the existing 1,000-image
scan check. Release builds of both `fmc` and `fmc-eval` passed. Test diagnostics and `.xcresult` bundles remain
under `build/DerivedData/Logs/Test`.
