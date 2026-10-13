#!/usr/bin/env python3
"""Turn the downloaded test corpus into a realistic, messy photo library with ground truth.

Reads models-cache/testset/manifest.csv (from fetch_testset.py) and writes models-cache/testset/scenario/:

  references/<Person>/            a few sample photos per target person (held out of the library)
  library/                        the folder to scan: nested year/event folders, renamed files, mixed formats
                                  (JPEG/HEIC/PNG/TIFF/WebP/GIF/BMP/RAW), EXIF-rotated, grayscale and
                                  low-resolution copies, duplicates, RAW+JPEG pairs, .xmp/.aae sidecars,
                                  corrupt files, non-images, hidden files and a .photoslibrary package
  labels.tsv                      path<TAB>identity for every image the app should enumerate
                                  ("" = nobody we search for, "#…" = excluded from accuracy, e.g. corrupt)
  expectations.json               things the run must satisfy (skipped files, sidecars to export, …)
  perf/                           full-resolution (≥ 12 MP) originals for the throughput test, + labels

Needs Pillow (use .venv-models/bin/python) and macOS `sips`.
"""

from __future__ import annotations

import argparse
import csv
import json
import random
import shutil
import subprocess
from pathlib import Path

from PIL import Image, ImageOps

REPO = Path(__file__).resolve().parents[2]
TESTSET = REPO / "models-cache" / "testset"
OUT = TESTSET / "scenario"

EVENTS = ["Christmas", "Été à Paris", "Birthday 🎂", "Work offsite", "Wedding – Sam & Alex", "Beach",
          "School play", "Hiking trip", "New Year", "Garden party", "Conference", "Random"]
DEEP = "Archive/Old phones/Pixel 3/DCIM/Camera/2019/Backup (copy)/really/deep/folder"


def load_manifest() -> list[dict]:
    """manifest.csv, or (while a download is still running) the same rows derived from the folder layout."""
    if (TESTSET / "manifest.csv").exists():
        return list(csv.DictReader(open(TESTSET / "manifest.csv")))
    rows = []
    for f in sorted((TESTSET / "download").rglob("*")):
        if f.is_file() and not f.name.startswith("."):
            group = str(f.parent.relative_to(TESTSET / "download"))
            identity = f.parent.name.replace("_", " ") if group.startswith(("people/", "originals/")) else ""
            rows.append(dict(file=str(f.relative_to(TESTSET)), group=group, identity=identity))
    print(f"(no manifest yet: derived {len(rows)} rows from the download folders)")
    return rows


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--targets", default="Kamala Harris,Antony Blinken,Christina Koch")
    ap.add_argument("--refs", type=int, default=5, help="reference photos per target person (random ones)")
    ap.add_argument("--pinned-refs", type=Path, default=Path(__file__).with_name("scenario_references.json"),
                    help="JSON {person: [file names]} of hand-picked reference photos, as a user would choose them; "
                         "people not listed get --refs random photos")
    ap.add_argument("--seed", type=int, default=7)
    ap.add_argument("--out", type=Path, default=OUT, help="scenario directory (default models-cache/testset/scenario)")
    args = ap.parse_args()
    rng = random.Random(args.seed)
    globals()["OUT"] = args.out.resolve()
    targets = [t.strip() for t in args.targets.split(",")]

    rows = load_manifest()
    if OUT.exists():
        shutil.rmtree(OUT)
    lib = OUT / "library"
    lib.mkdir(parents=True)
    labels: dict[str, str] = {}
    sources: dict[str, str] = {}   # library path → "group<TAB>download file" (for clean-negative analysis)
    expect: dict[str, list] = {"must_skip_unreadable": [], "must_not_enumerate": [], "sidecars": [],
                               "raw_pairs": [], "duplicates": []}
    counter = iter(range(1000, 100000))

    def place(src: Path, identity: str, *, ext: str | None = None, folder: str | None = None) -> Path:
        folder = folder or (f"{rng.randint(2019, 2025)}/{rng.choice(EVENTS)}" if rng.random() < 0.9 else DEEP)
        e = ext or src.suffix.lower()
        name = f"IMG_{next(counter)}{e.upper() if rng.random() < 0.5 else e}"
        dst = lib / folder / name
        dst.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(src, dst)
        labels[str(dst.relative_to(lib))] = identity
        try:
            rel = src.relative_to(TESTSET / "download")
            sources[str(dst.relative_to(lib))] = f"{rel.parent}\t{rel.name}"
        except ValueError:
            sources[str(dst.relative_to(lib))] = sources.get(str(src.relative_to(lib)), "derived\t")
        return dst

    # ① References: held-out photos of each target.
    by_person: dict[str, list[Path]] = {}
    for r in rows:
        if r["group"].startswith("people/"):
            by_person.setdefault(r["identity"], []).append(TESTSET / r["file"])
    for name in targets:
        photos = by_person[name]
        rng.shuffle(photos)
        pinned = set(json.loads(args.pinned_refs.read_text()).get(name, [])) if args.pinned_refs.exists() else set()
        if pinned:
            refs = [p for p in photos if p.name in pinned]
            by_person[name] = [p for p in photos if p.name not in pinned]
        else:
            refs, by_person[name] = photos[: args.refs], photos[args.refs:]
        d = OUT / "references" / name.replace(" ", "_")
        d.mkdir(parents=True)
        for p in refs:
            shutil.copy2(p, d / p.name)
    print("References: " + ", ".join(f"{n} ×{len(list((OUT / 'references' / n.replace(' ', '_')).iterdir()))}" for n in targets))

    # ② Library: every remaining person photo (targets and non-targets), negatives, scenes, RAW.
    placed: list[tuple[Path, str]] = []
    for name, photos in by_person.items():
        for p in photos:
            placed.append((place(p, name if name in targets else ""), name))
    for r in rows:
        if r["group"] in ("negatives", "scenes", "raw"):
            placed.append((place(TESTSET / r["file"], ""), ""))

    # ③ Variants of existing library photos (label kept).
    jpegs = [(p, n) for p, n in placed if p.suffix.lower() in (".jpg", ".jpeg")]
    rng.shuffle(jpegs)
    pick = iter(jpegs)

    def convert(fraction: float, ext: str, fn) -> int:
        n = max(2, int(len(jpegs) * fraction))
        for _ in range(n):
            p, name = next(pick)
            label = labels.pop(str(p.relative_to(lib)))
            source = sources.pop(str(p.relative_to(lib)))
            dst = p.with_suffix(ext)
            fn(p, dst)
            p.unlink()
            labels[str(dst.relative_to(lib))] = label
            sources[str(dst.relative_to(lib))] = source
        return n

    def sips(fmt: str):
        return lambda s, d: subprocess.run(["sips", "-s", "format", fmt, str(s), "--out", str(d)],
                                           check=True, capture_output=True)

    def pil(fmt: str, **kw):
        def f(s, d):
            with Image.open(s) as im:
                ImageOps.exif_transpose(im).convert("RGB").save(d, fmt, **kw)
        return f

    def rotated(orientation: int):
        # Store the pixels turned, with an EXIF tag that tells viewers how to turn them back upright.
        def f(s, d):
            with Image.open(s) as im:
                im = ImageOps.exif_transpose(im)
                stored = {6: im.transpose(Image.Transpose.ROTATE_90), 8: im.transpose(Image.Transpose.ROTATE_270),
                          3: im.transpose(Image.Transpose.ROTATE_180)}[orientation]
                exif = Image.Exif()
                exif[0x0112] = orientation
                stored.save(d, "JPEG", quality=92, exif=exif.tobytes())
        return f

    def small(s, d):
        with Image.open(s) as im:
            im = ImageOps.exif_transpose(im)
            im.thumbnail((640, 640))
            im.save(d, "JPEG", quality=85)

    def gray(s, d):
        with Image.open(s) as im:
            ImageOps.exif_transpose(im).convert("L").save(d, "JPEG", quality=90)

    variants = {
        "HEIC": convert(0.06, ".heic", sips("heic")),
        "PNG": convert(0.04, ".png", sips("png")),
        "TIFF": convert(0.03, ".tiff", sips("tiff")),
        "WebP": convert(0.02, ".webp", pil("WEBP", quality=85)),
        "GIF": convert(0.01, ".gif", sips("gif")),
        "BMP": convert(0.01, ".bmp", sips("bmp")),
        "EXIF orientation 6": convert(0.02, ".rot6.jpg", rotated(6)),
        "EXIF orientation 8": convert(0.02, ".rot8.jpg", rotated(8)),
        "EXIF orientation 3": convert(0.01, ".rot3.jpg", rotated(3)),
        "640 px": convert(0.03, ".small.jpg", small),
        "grayscale": convert(0.02, ".gray.jpg", gray),
    }
    print("Variants: " + ", ".join(f"{k} {v}" for k, v in variants.items()))

    target_photos = [p for p, n in placed if n in targets and p.exists() and p.suffix.lower() == ".jpg"]
    rng.shuffle(target_photos)

    # Duplicates: the same photo in a second folder.
    for p in target_photos[:5]:
        d = place(p, labels[str(p.relative_to(lib))], folder="Duplicates/From old laptop")
        expect["duplicates"].append(str(d.relative_to(lib)))

    # Sidecars next to target photos (must be exported with them).
    for p in target_photos[5:15]:
        for ext, body in ((".xmp", "<x:xmpmeta xmlns:x='adobe:ns:meta/'/>"), (".AAE", "<plist/>")):
            s = p.with_suffix(ext)
            s.write_text(body)
            expect["sidecars"].append(str(s.relative_to(lib)))
    # RAW+JPEG pairs: a RAW with the same base name as a target JPEG (scanned itself, and a sidecar).
    raws = [TESTSET / r["file"] for r in rows if r["group"] == "raw"]
    for p, raw in zip(target_photos[15:18], raws):
        s = p.with_suffix(raw.suffix.upper())
        shutil.copy2(raw, s)
        labels[str(s.relative_to(lib))] = ""
        expect["raw_pairs"].append(str(s.relative_to(lib)))

    # Unreadable / damaged files.
    junk = lib / "2023" / "Broken card"
    junk.mkdir(parents=True, exist_ok=True)
    (junk / "IMG_0000.JPG").write_bytes(b"")
    (junk / "IMG_0001.HEIC").write_bytes(bytes(rng.randrange(256) for _ in range(4096)))
    (junk / "notes-renamed.png").write_text("this is not an image\n" * 50)
    for name in ("IMG_0000.JPG", "IMG_0001.HEIC", "notes-renamed.png"):
        labels[f"2023/Broken card/{name}"] = "#unreadable"
        expect["must_skip_unreadable"].append(f"2023/Broken card/{name}")
    for i, p in enumerate(target_photos[18:21]):
        data = p.read_bytes()
        (junk / f"IMG_TRUNC{i}.jpg").write_bytes(data[: len(data) * 2 // 5])
        labels[f"2023/Broken card/IMG_TRUNC{i}.jpg"] = "#truncated"

    # Things that must never be scanned.
    hidden = target_photos[21:24]
    (lib / "2024").mkdir(exist_ok=True)
    for i, p in enumerate(hidden):
        shutil.copy2(p, lib / "2024" / f".hidden_{i}.jpg")
    pkg = lib / "Old Photos Library.photoslibrary" / "originals" / "A"
    pkg.mkdir(parents=True)
    for p in target_photos[24:27]:
        shutil.copy2(p, pkg / p.name)
    (lib / ".thumbnails").mkdir()
    shutil.copy2(target_photos[27], lib / ".thumbnails" / "t.jpg")
    expect["must_not_enumerate"] = [".hidden_", ".photoslibrary", ".thumbnails"]
    (lib / "2022").mkdir(exist_ok=True)
    (lib / "2022" / "Notes.txt").write_text("not a photo")
    (lib / "2022" / "clip.MOV").write_bytes(b"\x00\x00\x00\x18ftypqt  " + bytes(1000))
    (lib / "2022" / "vector.svg").write_text("<svg xmlns='http://www.w3.org/2000/svg'/>")

    with open(OUT / "labels.tsv", "w") as f:
        f.write("path\tidentity\n")
        for k in sorted(labels):
            f.write(f"{k}\t{labels[k]}\n")
    with open(OUT / "sources.tsv", "w") as f:
        f.write("path\tgroup\tfile\n")
        for k in sorted(sources):
            f.write(f"{k}\t{sources[k]}\n")
    (OUT / "expectations.json").write_text(json.dumps(expect, indent=2, ensure_ascii=False))

    # ④ Throughput set: full-resolution originals.
    perf = OUT / "perf"
    perf.mkdir()
    with open(OUT / "perf-labels.tsv", "w") as f:
        f.write("path\tidentity\n")
        for r in rows:
            if r["group"].startswith("originals/"):
                src = TESTSET / r["file"]
                shutil.copy2(src, perf / src.name)
                f.write(f"{src.name}\t{r['identity'] if r['identity'] in targets else ''}\n")

    positives = sum(1 for v in labels.values() if v in targets)
    print(f"Library: {len(labels)} labelled images ({positives} contain a target), "
          f"{sum(1 for _ in lib.rglob('*') if _.is_dir())} folders; perf set: {len(list(perf.iterdir()))} originals")


if __name__ == "__main__":
    main()
