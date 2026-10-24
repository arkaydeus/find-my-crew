# fmc — command-line tool

`fmc` is Find My Crew without the window: the same `FindMyCrew/Core` code (Vision detection, the SFace model,
matching thresholds, copying) behind two subcommands.

```sh
mise run cli:build                  # → build/DerivedData/Build/Products/Release/fmc (+ SFace.mlmodelc beside it)
mise run fmc -- --help              # build and run in one go
```

To put it on your `PATH`, symlink the binary (it finds the model through the link):

```sh
ln -s "$PWD/build/DerivedData/Build/Products/Release/fmc" ~/.local/bin/fmc
```

## Extract faces

```sh
fmc extract ~/Pictures/Party IMG_0042.HEIC -o ~/Desktop/faces            # WebP by default
fmc extract ~/Pictures/Party -o ~/Desktop/faces -f jpeg --quality 85 --size 256
```

Each face becomes its own square image with some margin (`--padding`, default 0.4 of the face size), mirroring
sub-folders: `Party/2024/IMG_1.HEIC` → `faces/2024/IMG_1_face1.webp`, faces numbered left to right. Formats:
`webp` (default), `jpeg`, `png`, `heic`, `tiff`. Existing files get a numbered copy unless `--overwrite`.
Repeated inputs (including symlink aliases and overlapping file/folder arguments) are processed once. A RAW
and JPEG with the same stem in the same folder produce one set of crops, using the JPEG. Distinct photos whose
crop names collide get separate numbered paths, including with `--overwrite`; that flag replaces an existing
base file only once per run and preserves existing numbered copies. The output folder can't be inside an input folder.

## Filter photos by face

```sh
fmc filter --faces ~/Desktop/crew --source ~/Pictures/Party --output ~/Desktop/matches
fmc filter --faces ~/Desktop/crew -s ~/Pictures/Party -o ~/Desktop/matches --dry-run
```

Each image in `--faces` contributes one reference face (its only face, or the largest one) — the crops from
`fmc extract` are ideal; delete the ones of people you aren't looking for. Every photo under `--source` is scanned
and photos where any face matches any reference are copied to `--output` the way the app exports: sub-folders,
dates and sidecars (RAW+JPEG pairs, `.xmp`, `.aae`; `--no-sidecars` to skip), never overwriting. The output folder must also be outside the reference faces folder.

Matches are printed to stdout as `score<TAB>path<TAB>reference`; progress and the summary go to stderr. The
threshold defaults to the app's (the model's, raised slightly as references are added); the summary says how many
photos fell just below it, and `--threshold` changes it. `--model` uses another Core ML face model.

Both commands take `--resolution` (detection size, default 2048 px long edge) and `--min-face-size` (default 20 px).
Exit status: 0 on success, 1 if any file failed, 64 for bad arguments. Filter still lists and copies any successful
matches when reference images or source photos fail, then exits 1; this also applies to dry runs and no-match scans.
