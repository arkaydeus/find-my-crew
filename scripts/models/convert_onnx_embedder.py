#!/usr/bin/env python3
"""Convert a user-supplied ArcFace-style ONNX face-embedding model to a Core ML
.mlpackage that FindMyCrew can load as a custom model.

Typical target: InsightFace `w600k_r50.onnx` (from the buffalo_l pack). Those weights
are licensed for NON-COMMERCIAL RESEARCH use only. This project never downloads or
bundles them; obtain them yourself and convert for personal use at your own discretion.

The converted model has the same interface as the bundled SFace model:
  input  "image"     : Core ML Image, <input-size>x<input-size>, RGB or BGR layout
  output "embedding" : Float32 MultiArray (1, D), raw / un-normalised
  metadata           : fmc.inputSize, fmc.embeddingDim, fmc.alignment=arcface5,
                       fmc.defaultThreshold

Preprocessing is baked into the Core ML ImageType: the network receives
    pixel * scale + bias        (pixel in 0..255, channels in --color order)
InsightFace ArcFace models (w600k_r50, glintr100, ...) expect
    (pixel - 127.5) / 127.5  in RGB  ->  --scale 0.0078431373 --bias -1 --color RGB  (defaults)
SFace (normalises inside the graph) -> --scale 1 --bias 0 --color RGB

Examples:
    .venv-models/bin/python scripts/models/convert_onnx_embedder.py \\
        --onnx ~/Downloads/buffalo_l/w600k_r50.onnx --out ~/Desktop/ArcFaceR50.mlpackage \\
        --name "ArcFace R50 (InsightFace w600k)" --threshold 0.30

Parity: the script runs ONNX Runtime on the original model and Core ML on the same
images (random + a sample face crop) and requires L2-normalised cosine > 0.999.
"""

from __future__ import annotations

import argparse
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import fmc_coreml as fmc  # noqa: E402


def parse_bias(text: str) -> tuple[float, float, float]:
    parts = [float(p) for p in text.split(",")]
    if len(parts) == 1:
        return (parts[0],) * 3
    if len(parts) == 3:
        return tuple(parts)  # type: ignore[return-value]
    raise argparse.ArgumentTypeError("--bias takes one value or three comma-separated values")


def parse_scale(text: str) -> float:
    # Accept fractions like "1/127.5" for convenience.
    if "/" in text:
        num, den = text.split("/", 1)
        return float(num) / float(den)
    return float(text)


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--onnx", type=Path, required=True, help="path to the ONNX embedding model")
    ap.add_argument("--out", type=Path, required=True, help="output path, e.g. MyModel.mlpackage")
    ap.add_argument("--input-size", type=int, default=112)
    ap.add_argument("--scale", type=parse_scale, default=1 / 127.5,
                    help="multiplier applied to 0..255 pixels (default 1/127.5; fractions allowed)")
    ap.add_argument("--bias", type=parse_bias, default=(-1.0, -1.0, -1.0),
                    help="added after scaling; one value or 'r,g,b' in --color order (default -1)")
    ap.add_argument("--color", choices=["RGB", "BGR"], default="RGB",
                    help="channel order the ONNX network expects")
    ap.add_argument("--threshold", type=float, default=0.30,
                    help="default cosine threshold for 'same person' (default 0.30)")
    ap.add_argument("--name", default=None, help="human-readable model name")
    ap.add_argument("--author", default="User-converted model")
    ap.add_argument("--license", default="See original model license (user-supplied weights)")
    ap.add_argument("--precision", choices=["auto", "float16", "float32"], default="auto",
                    help="auto = try float16, fall back to float32 if parity fails")
    ap.add_argument("--face-image", type=Path, action="append", default=[],
                    help="extra face image(s) for the parity check")
    ap.add_argument("--no-sample-face", action="store_true",
                    help="don't download the OpenCV sample face image for parity")
    args = ap.parse_args()

    if not args.onnx.is_file():
        raise SystemExit(f"ONNX file not found: {args.onnx}")
    if args.out.suffix != ".mlpackage":
        raise SystemExit("--out must end with .mlpackage")

    name = args.name or args.onnx.stem
    onnx_sha = fmc.sha256_of(args.onnx)
    print(f"sha256({args.onnx.name}) = {onnx_sha}")
    print(f"Preprocessing: {args.color} pixel*{args.scale:.10g} + {list(args.bias)}")

    # Mirror InsightFace's own heuristic: a graph starting with Sub/Mul normalises
    # internally and wants raw 0..255 pixels (scale 1, bias 0).
    first_ops = [n.op_type for n in fmc.load_clean_onnx(args.onnx).graph.node[:3]]
    internal_norm = "Sub" in first_ops or "Mul" in first_ops
    if internal_norm and (args.scale != 1.0 or any(b != 0.0 for b in args.bias)):
        print(f"WARNING: graph starts with {first_ops} -> it probably normalises internally; "
              "consider --scale 1 --bias 0.")
    elif not internal_norm and args.scale == 1.0 and all(b == 0.0 for b in args.bias):
        print("WARNING: graph has no leading Sub/Mul normalisation but --scale 1 --bias 0 was "
              "given; ArcFace models usually need --scale 1/127.5 --bias -1.")

    images = fmc.test_images(args.input_size, face_images=args.face_image,
                             fetch_sample_face=not args.no_sample_face)

    def md_factory(dim: int, precision: str) -> fmc.Metadata:
        return fmc.Metadata(
            author=args.author,
            license=args.license,
            short_description=(
                f"{name}: face embedding model converted from ONNX. Input: "
                f"{args.input_size}x{args.input_size} {args.color} face aligned to the 5-point ArcFace "
                f"template. Output: raw {dim}-d embedding; L2-normalise and compare by cosine "
                f"similarity (same person if >= {args.threshold:g})."
            ),
            version="1",
            input_size=args.input_size,
            embedding_dim=dim,
            threshold=args.threshold,
            extra={"fmc.name": name,
                   "fmc.source": args.onnx.name,
                   "fmc.sourceSha256": onnx_sha,
                   "fmc.computePrecision": precision},
        )

    precision, results = fmc.convert_with_fallback(
        args.onnx, args.out, input_size=args.input_size, scale=args.scale, bias=args.bias,
        color=args.color, md_factory=md_factory, images=images, precision=args.precision,
    )
    fmc.print_spec_summary(args.out)
    print(f"\nDone. precision={precision} worst-cosine per compute unit: "
          + ", ".join(f"{k}={v:.6f}" for k, v in results.items()))


if __name__ == "__main__":
    main()
