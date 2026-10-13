# Review regression validation

Run the Swift suite (Core, AppModel, custom-model fixtures and benchmark checks):

```sh
make test DERIVED=~/Library/Developer/Xcode/DerivedData/FindMyCrew
make eval-build DERIVED=~/Library/Developer/Xcode/DerivedData/FindMyCrew
.venv-models/bin/python scripts/eval/test_make_testset.py
```

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

## Sandboxed Finder-drop check

Headless tests check access acquisition/release and background-task lifetime, but
cannot prove Finder delivers sandbox grants. Run this check on the signed app
built by `make build`; keep App Sandbox and user-selected read/write entitlements
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
4. Remove a dropped reference while it is processing, replace the source while
   enumeration is running, and stop/restart a scan. Confirm no stale results
   appear and background jobs finish without revoked-access failures. Repeat
   drops/removals to check grants are balanced rather than retained indefinitely.

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
