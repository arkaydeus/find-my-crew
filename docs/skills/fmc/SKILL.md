---
name: fmc
description: Use the Find My Crew `fmc` command-line tool on macOS to crop every face out of photos (`fmc extract`) or to find and copy the photos that show particular people (`fmc filter`). Use when asked to pull faces out of a photo library, find photos of someone in a folder, sort or filter photos by person, or script Find My Crew without its window.
---

# fmc — Find My Crew from the command line

`fmc` runs the Find My Crew app's own face pipeline (Apple Vision detection, the bundled SFace embedding model,
the app's matching thresholds and export/copy logic) without the UI. It never modifies or moves source photos.
macOS 15+ only.

## Setup

Check whether it's installed with `fmc --version`. If it isn't:

```sh
curl -fsSL https://raw.githubusercontent.com/arkaydeus/find-my-crew/main/scripts/install.sh | bash
```

This installs the app to `/Applications` and links `~/.local/bin/fmc` (make sure `~/.local/bin` is on `PATH`).
In a checkout of this repo you can build and run it instead: `mise run fmc -- <args>` (binary at
`build/DerivedData/Build/Products/Release/fmc`). Full details are in `docs/install.md` and `docs/cli.md`.

## The usual workflow

Finding photos of specific people takes three steps:

1. **Extract faces** from a few photos that show the people:
   ```sh
   fmc extract ~/Pictures/Party/IMG_0042.HEIC ~/Pictures/Party/IMG_0107.HEIC -o /tmp/crew
   ```
2. **Prune the references**: delete the crops in `/tmp/crew` of people you *aren't* looking for. Every image
   left counts as a person to find. If you can't see images yourself, ask the user which crops to keep, or
   which filenames show whom.
3. **Filter the library**. Do a dry run first, then the copy:
   ```sh
   fmc filter --faces /tmp/crew -s ~/Pictures/Party -o ~/Desktop/matches --dry-run
   fmc filter --faces /tmp/crew -s ~/Pictures/Party -o ~/Desktop/matches
   ```

A photo matches if **any** face in it matches **any** reference (OR, not AND).

## `fmc extract <inputs…> -o <dir>`

Writes each detected face to its own square image. Inputs are files and/or folders (searched recursively).

| Option | Default | |
| --- | --- | --- |
| `-o, --output DIR` | required | created if needed; must not be inside an input folder |
| `-f, --format` | `webp` | `webp`, `jpeg`, `png`, `heic`, `tiff` |
| `--quality N` | 90 | 0–100 (webp, jpeg, heic) |
| `--size PX` | 512 | max crop side; never upscales; ≥ 16 |
| `--padding F` | 0.4 | margin per side as a fraction of the face size, 0–2 |
| `--overwrite` | off | replace existing files instead of writing `name (1).ext` |

Output paths mirror the input's sub-folders: `Party/2024/IMG_1.HEIC` → `<out>/2024/IMG_1_face1.webp`, faces
numbered left to right. A RAW and a JPEG with the same name in the same folder produce one set of crops (from
the JPEG), and repeated or overlapping inputs are processed once.

## `fmc filter --faces <dir|image> -s <dir> -o <dir>`

| Option | Default | |
| --- | --- | --- |
| `--faces PATH` | required | folder (recursive) or single image of the people to find |
| `-s, --source DIR` | required | folder of photos to search (recursive) |
| `-o, --output DIR` | required | created if needed; must be outside `--source` and `--faces` |
| `--threshold T` | model default, adjusted | cosine similarity, -1…1; higher means stricter |
| `--dry-run` | off | list matches, copy nothing |
| `--no-sidecars` | off | don't copy RAW+JPEG partners, `.xmp`, `.aae` |
| `--model PATH` | built-in SFace | `.mlpackage`, `.mlmodel` or `.mlmodelc` |

Each reference image contributes **one** face: its only face, or the largest if there are several (logged on
stderr). Use tight single-person crops from `fmc extract`, not group photos. A `--faces` folder inside
`--source` is excluded from the scan.

Matching photos are copied the way the app exports: sub-folders and file dates are kept, sidecars come along,
and existing files are never overwritten (identical files are skipped, others are renamed).

### Threshold tuning

The default is the model's threshold (0.363 for SFace), raised slightly as references are added
(`+0.019 × ln(n/3)` beyond 3 references) to keep false matches around 1% of photos. The stderr summary reports
how many photos scored within 0.04 below the threshold. If the user expects more matches, re-run with
`--dry-run` and a lower `--threshold` (for example 0.30) and compare. If unrelated people match, raise it.
Dry runs are cheap to repeat compared with cleaning up a copied output folder.

## Options shared by both commands

| Option | Default | |
| --- | --- | --- |
| `--resolution PX` | 2048 | long edge photos are decoded to for detection; larger finds smaller faces but is slower; ≥ 256 |
| `--min-face-size PX` | 20 | ignore smaller faces (measured at the detection resolution) |

For crowd shots or distant faces, try `--resolution 4096 --min-face-size 12`.

## Output and exit codes (for scripting)

- `filter` stdout: one line per match, `score<TAB>relative/path<TAB>reference-file`, sorted by path. Parse
  this; everything else is on stderr.
- stderr: per-file errors as `relative/path: message`, then a one-line summary. The progress line only appears
  on a TTY, so redirected stderr stays clean.
- Exit `0` success; `64` for bad arguments (an out-of-range option, a missing path, no supported images, no
  faces in the references); `1` for everything else. That includes an output folder inside an input, an
  unloadable `--model`, and any photo or reference that failed. When files fail, filter still lists (and,
  unless `--dry-run`, copies) the matches it found, then exits 1.

```sh
fmc filter --faces /tmp/crew -s ~/Pictures -o /tmp/out --dry-run 2>/dev/null | cut -f2   # just the paths
```

## Gotchas

- Supported inputs are anything ImageIO decodes as a photo, including HEIC and camera RAW (CR2/CR3, NEF, ARW,
  DNG, RAF, ORF, RW2 and others). SVG, PDF and icon files are skipped.
- Large libraries take a while: the scan runs on all cores and the summary reports photos per second. Run
  big jobs in the background and keep stdout in a file.
- `Built-in face model not found` means the binary is separated from its `SFace.mlmodelc`. Use the installed
  link or `mise run fmc`, not a copied binary, or pass `--model`.
- `fmc help extract` and `fmc help filter` print the authoritative option list for the installed version.
