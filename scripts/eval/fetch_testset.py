#!/usr/bin/env python3
"""Download an end-to-end test corpus of openly licensed photos into models-cache/testset/.

Sources
  * Wikimedia Commons — public-domain / CC0 / CC BY / CC BY-SA photos only (licence recorded per file):
      - identities: photos of well-documented public figures, taken from the "<Name> in <year>"
        categories (one label per photo: the person the category is about);
      - hard negatives: official portraits of other people (same studio style as the targets);
      - crowds and scenes without faces.
  * raw.pixls.us — CC0 camera RAW samples (one per format), for decoder coverage.

Output
  models-cache/testset/download/<group>/<file>   downloaded files (long edge ≤ 1920 px unless --originals)
  models-cache/testset/manifest.csv             file, group, identity, licence, author, source page

Nothing here is committed or bundled. Usage:
  python3 scripts/eval/fetch_testset.py [--per-identity 80] [--negatives 400] [--scenes 150] [--originals 40]
"""

from __future__ import annotations

import argparse
import csv
import html
import json
import re
import sys
import threading
import time
import urllib.parse
import urllib.request
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
OUT = REPO / "models-cache" / "testset"
API = "https://commons.wikimedia.org/w/api.php"
UA = "FindMyCrewTestset/1.0 (https://github.com/arkaydeus; arkaydeusdev@gmail.com) python-urllib"

IDENTITIES = [
    "Joe Biden", "Kamala Harris", "Barack Obama", "Antony Blinken", "Lloyd Austin",
    "Pete Buttigieg", "Christina Koch", "Jill Biden", "Mark A. Milley", "Sunita Williams",
]
NEGATIVE_CATEGORIES = [
    "Official portraits of members of the 117th United States Congress",
    "Official portraits of members of the 118th United States Congress",
]
SCENE_CATEGORIES = [
    "Quality images of landscapes", "Featured pictures of landscapes", "Quality images of animals",
    "Crowds in the United States", "Quality images of architecture", "Featured pictures of food",
]
# Subcategories that are about something other than the person appearing in the photo.
SKIP_SUBCATS = re.compile(r"\b(with people|with animals|family|videos?|audio|signatures?|speeches|documents|art\b|"
                          r"quotations|supporters|demonstrations|pronunciation|photographs by|home|vehicles|"
                          r"electoral|career|hands|childhood|in art|caricatures|cartoons|memes)\b", re.I)
OK_LICENCE = re.compile(r"^(public domain|pd\b|pd-|cc0|cc[ -]by(-sa)?[ -]?\d|cc by(-sa)? \d)", re.I)
RAW_MODELS = {  # make/model directory on raw.pixls.us → wanted extension
    "Canon/EOS 5D Mark III": "cr2", "Canon/Canon EOS R10": "cr3", "Nikon/D850": "nef",
    "Sony/ILCE-7M3": "arw", "FUJIFILM/X-T50": "raf", "Olympus/E-M1MarkII": "orf",
    "Panasonic/DC-GH5": "rw2", "Pentax/K-1": "pef", "Samsung/NX1": "srw", "Leica/M10": "dng",
}

_lock = threading.Lock()
_last_request = [0.0]


def get(url: str, *, binary: bool = False, tries: int = 5, data: bytes | None = None):
    for attempt in range(tries):
        with _lock:  # ≤ 10 requests/s overall, as Wikimedia asks of bots
            wait = _last_request[0] + 0.1 - time.time()
            if wait > 0:
                time.sleep(wait)
            _last_request[0] = time.time()
        try:
            req = urllib.request.Request(url, data=data, headers={"User-Agent": UA})
            with urllib.request.urlopen(req, timeout=60) as r:
                data = r.read()
            return data if binary else json.loads(data)
        except urllib.error.HTTPError as e:
            if e.code in (429, 500, 502, 503, 504) and attempt < tries - 1:
                time.sleep(2 ** attempt * 2)
                continue
            raise
        except (urllib.error.URLError, TimeoutError):
            if attempt < tries - 1:
                time.sleep(2 ** attempt)
                continue
            raise


def api(**params) -> dict:
    params |= {"format": "json", "formatversion": "2"}
    # POST: batches of long file titles overflow a GET URL (HTTP 414).
    return get(API, data=urllib.parse.urlencode(params).encode())


def members(category: str, kind: str) -> list[str]:
    out, cont = [], {}
    while True:
        d = api(action="query", list="categorymembers", cmtitle="Category:" + category, cmtype=kind,
                cmlimit="500", **cont)
        out += [m["title"] for m in d["query"]["categorymembers"]]
        if "continue" not in d:
            return out
        cont = {"cmcontinue": d["continue"]["cmcontinue"]}


def person_files(name: str, limit: int) -> list[str]:
    """Files from '<name> by year' → '<name> in <year>' (→ '<name> in <month> <year>' …)."""
    files: list[str] = []
    seen: set[str] = set()
    queue = [(c.removeprefix("Category:"), 0) for c in members(f"{name} by year", "subcat")]
    queue.sort(key=lambda c: c[0], reverse=True)  # newest years first, older ones give an ageing test
    while queue and len(files) < limit * 3:
        cat, depth = queue.pop(0)
        if cat in seen or name.split()[-1] not in cat or SKIP_SUBCATS.search(cat):
            continue
        seen.add(cat)
        files += [f for f in members(cat, "file") if f.lower().endswith((".jpg", ".jpeg"))]
        if depth < 2:
            queue += [(c.removeprefix("Category:"), depth + 1) for c in members(cat, "subcat")]
    # Spread across years rather than taking one event's burst of near-identical frames.
    files = list(dict.fromkeys(files))
    step = max(1, len(files) // (limit * 2))
    return files[::step]


def image_info(titles: list[str], width: int | None) -> list[dict]:
    out = []
    for i in range(0, len(titles), 40):
        params = dict(action="query", prop="imageinfo", titles="|".join(titles[i:i + 40]),
                      iiprop="url|size|mime|extmetadata")
        if width:
            params["iiurlwidth"] = str(width)
        for p in api(**params)["query"]["pages"]:
            if "imageinfo" not in p:
                continue
            ii = p["imageinfo"][0]
            meta = ii.get("extmetadata", {})
            licence = meta.get("LicenseShortName", {}).get("value", "")
            if ii.get("mime") != "image/jpeg" or not OK_LICENCE.search(licence):
                continue
            author = re.sub(r"<[^>]+>", "", html.unescape(meta.get("Artist", {}).get("value", ""))).strip()
            big = width and ii["width"] > width
            out.append(dict(title=p["title"], url=ii["thumburl"] if big else ii["url"],
                            page=ii["descriptionurl"], licence=licence, author=author[:120],
                            pixels=ii["width"] * ii["height"]))
    return out


def safe_name(title: str) -> str:
    name = title.removeprefix("File:")
    return re.sub(r'[/\\:*?"<>|]', "_", name)[-150:]


def download(entries: list[dict], group: str, identity: str, rows: list[dict]) -> None:
    folder = OUT / "download" / group
    folder.mkdir(parents=True, exist_ok=True)

    def one(e: dict):
        path = folder / safe_name(e["title"])
        if not path.exists() or path.stat().st_size == 0:
            try:
                tmp = path.with_name(path.name + ".part")
                tmp.write_bytes(get(e["url"], binary=True))
                tmp.rename(path)
            except Exception as err:  # noqa: BLE001 — one bad file must not stop the corpus
                print(f"  ! {e['title']}: {err}", file=sys.stderr)
                return None
        return dict(file=str(path.relative_to(OUT)), group=group, identity=identity,
                    licence=e["licence"], author=e["author"], source=e["page"])

    with ThreadPoolExecutor(4) as pool:
        rows += [r for r in pool.map(one, entries) if r]


def fetch_raw(rows: list[dict]) -> None:
    folder = OUT / "download" / "raw"
    folder.mkdir(parents=True, exist_ok=True)
    for model, ext in RAW_MODELS.items():
        base = "https://raw.pixls.us/data/" + urllib.parse.quote(model) + "/"
        try:
            listing = get(base, binary=True).decode("utf-8", "replace")
        except Exception as err:  # noqa: BLE001
            print(f"  ! raw {model}: {err}", file=sys.stderr)
            continue
        names = [urllib.parse.unquote(h) for h in re.findall(r'href="([^"?/][^"]*)"', listing)]
        names = [n for n in names if n.lower().endswith("." + ext)]
        if not names:
            print(f"  ! raw {model}: no .{ext} file", file=sys.stderr)
            continue
        name = names[0]
        path = folder / f"{model.split('/')[-1].replace(' ', '_')}_{name}"
        if not path.exists():
            path.write_bytes(get(base + urllib.parse.quote(name), binary=True))
        rows.append(dict(file=str(path.relative_to(OUT)), group="raw", identity="", licence="CC0",
                         author="raw.pixls.us contributors", source=base + urllib.parse.quote(name)))
        print(f"  raw {path.name} ({path.stat().st_size >> 20} MB)")


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--per-identity", type=int, default=80)
    ap.add_argument("--negatives", type=int, default=400)
    ap.add_argument("--scenes", type=int, default=150)
    ap.add_argument("--originals", type=int, default=40, help="full-resolution photos for the throughput test")
    ap.add_argument("--no-raw", action="store_true")
    ap.add_argument("--raw-only", action="store_true", help="only (re)fetch RAW samples and update the manifest")
    args = ap.parse_args()

    rows: list[dict] = []
    if args.raw_only:
        rows = [r for r in csv.DictReader(open(OUT / "manifest.csv")) if r["group"] != "raw"]
        fetch_raw(rows)
        write_manifest(rows)
        return
    for name in IDENTITIES:
        titles = person_files(name, args.per_identity)
        entries = image_info(titles, 1920)[: args.per_identity]
        print(f"{name}: {len(entries)} photos (from {len(titles)} candidates)")
        download(entries, "people/" + name.replace(" ", "_"), name, rows)

    surnames = [n.split()[-1].lower() for n in IDENTITIES]
    negatives: list[str] = []
    for cat in NEGATIVE_CATEGORIES:
        negatives += [t for t in members(cat, "file") if not any(s in t.lower() for s in surnames)]
    negatives = list(dict.fromkeys(negatives))[:: max(1, len(negatives) // args.negatives)][: args.negatives]
    entries = image_info(negatives, 1920)
    print(f"Hard negatives: {len(entries)} official portraits of other people")
    download(entries, "negatives", "", rows)

    scenes: list[str] = []
    for cat in SCENE_CATEGORIES:
        try:
            scenes += members(cat, "file")[: args.scenes // len(SCENE_CATEGORIES) * 2]
        except Exception as err:  # noqa: BLE001
            print(f"  ! {cat}: {err}", file=sys.stderr)
    entries = image_info([s for s in scenes if s.lower().endswith((".jpg", ".jpeg"))], 1920)[: args.scenes]
    print(f"Scenes/crowds: {len(entries)}")
    download(entries, "scenes", "", rows)

    if args.originals:
        # Full-size originals ≥ 12 MP for the PRD throughput target.
        per_person = max(1, args.originals // 4)
        for name in IDENTITIES[:4]:
            big = [e for e in image_info(person_files(name, 40), None) if e["pixels"] >= 12_000_000]
            print(f"Full-resolution originals of {name}: {len(big[:per_person])}")
            download(big[:per_person], "originals/" + name.replace(" ", "_"), name, rows)

    if not args.no_raw:
        fetch_raw(rows)

    write_manifest(rows)


def write_manifest(rows: list[dict]) -> None:
    rows.sort(key=lambda r: r["file"])
    with open(OUT / "manifest.csv", "w", newline="") as f:
        w = csv.DictWriter(f, fieldnames=["file", "group", "identity", "licence", "author", "source"])
        w.writeheader()
        w.writerows(rows)
    print(f"Wrote {len(rows)} files; manifest at {OUT / 'manifest.csv'}")


if __name__ == "__main__":
    main()
