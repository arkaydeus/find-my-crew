"""Shared helpers for FindMyCrew face-embedding model conversion.

Pipeline: ONNX -> PyTorch (onnx2torch) -> traced TorchScript -> Core ML ML Program.

Every converted model exposes the same interface so the app can treat the
bundled SFace model and user-converted custom models identically:

  input  "image"     : Core ML Image (RGB/BGR per model), 112x112 (configurable)
                       Core ML applies `scale * pixel + bias` per channel before
                       the network sees it, so the app just hands over pixels.
  output "embedding" : Float32 MultiArray (1, D). NOT L2-normalised; the app
                       must L2-normalise before computing cosine similarity.

  user_defined_metadata:
    fmc.inputSize        e.g. "112"
    fmc.embeddingDim     e.g. "128"
    fmc.alignment        "arcface5" (5-point similarity transform onto the
                         standard ArcFace 112x112 template)
    fmc.defaultThreshold cosine similarity threshold for "same person"
"""

from __future__ import annotations

import hashlib
import os
import urllib.request
from dataclasses import dataclass, field
from pathlib import Path
from typing import Sequence

import numpy as np

REPO_ROOT = Path(__file__).resolve().parents[2]
MODELS_CACHE = REPO_ROOT / "models-cache"

INPUT_NAME = "image"
OUTPUT_NAME = "embedding"
PARITY_MIN_COSINE = 0.999

# Public-domain-ish standard test image shipped in OpenCV's samples; the crop
# box is a loose face crop used only for numerical parity, not accuracy.
SAMPLE_FACE_URL = "https://raw.githubusercontent.com/opencv/opencv/4.x/samples/data/lena.jpg"
SAMPLE_FACE_BOX = (200, 180, 380, 400)


# --------------------------------------------------------------------------
# Download helpers
# --------------------------------------------------------------------------

def sha256_of(path: Path) -> str:
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def download(url: str, dest: Path, expected_sha256: str | None = None) -> Path:
    dest.parent.mkdir(parents=True, exist_ok=True)
    if not dest.exists():
        print(f"Downloading {url}\n  -> {dest}")
        tmp = dest.with_suffix(dest.suffix + ".part")
        urllib.request.urlretrieve(url, tmp)
        os.replace(tmp, dest)
    digest = sha256_of(dest)
    print(f"sha256({dest.name}) = {digest}")
    if expected_sha256 and digest != expected_sha256:
        raise SystemExit(
            f"SHA-256 mismatch for {dest}:\n  expected {expected_sha256}\n  got      {digest}\n"
            "Delete the file and re-run, or update the pinned hash if upstream changed intentionally."
        )
    return dest


# --------------------------------------------------------------------------
# ONNX loading / conversion
# --------------------------------------------------------------------------

def load_clean_onnx(onnx_path: Path):
    """Load an ONNX model and drop initializers that are also listed as graph
    inputs (old IR<4 exporters such as MXNet->ONNX, which SFace uses, list every
    weight as a graph input; onnx2torch would otherwise treat them as inputs)."""
    import onnx

    model = onnx.load(str(onnx_path))
    init_names = {i.name for i in model.graph.initializer}
    real_inputs = [i for i in model.graph.input if i.name not in init_names]
    if len(real_inputs) != len(model.graph.input):
        del model.graph.input[:]
        model.graph.input.extend(real_inputs)
    if len(real_inputs) != 1:
        raise SystemExit(f"Expected exactly one image input, found {[i.name for i in real_inputs]}")
    if len(model.graph.output) != 1:
        raise SystemExit(f"Expected exactly one output, found {[o.name for o in model.graph.output]}")
    onnx.checker.check_model(model)
    return model


def onnx_io_info(model) -> tuple[str, list, str, list]:
    def dims(vi):
        return [d.dim_value if d.HasField("dim_value") else (d.dim_param or None)
                for d in vi.type.tensor_type.shape.dim]

    i, o = model.graph.input[0], model.graph.output[0]
    return i.name, dims(i), o.name, dims(o)


def onnx_to_traced_torch(onnx_model, input_size: int):
    import torch
    from onnx2torch import convert

    torch_model = convert(onnx_model).eval()
    example = torch.rand(1, 3, input_size, input_size) * 255.0
    import warnings
    with torch.no_grad(), warnings.catch_warnings():
        # onnx2torch's PReLU checks the slope shape in Python; harmless with a fixed
        # input shape (traced output is verified against ONNX Runtime afterwards).
        warnings.simplefilter("ignore", torch.jit.TracerWarning)
        traced = torch.jit.trace(torch_model, example)
    return torch_model, traced


def torch_to_coreml(traced, *, input_size: int, scale: float, bias: Sequence[float],
                    color: str, precision: str):
    import coremltools as ct

    layout = ct.colorlayout.RGB if color.upper() == "RGB" else ct.colorlayout.BGR
    image_input = ct.ImageType(
        name=INPUT_NAME,
        shape=(1, 3, input_size, input_size),
        color_layout=layout,
        scale=float(scale),
        bias=[float(b) for b in bias],
    )
    return ct.convert(
        traced,
        inputs=[image_input],
        outputs=[ct.TensorType(name=OUTPUT_NAME, dtype=np.float32)],  # Float32 even in fp16 models
        convert_to="mlprogram",
        minimum_deployment_target=ct.target.macOS15,
        compute_precision=ct.precision.FLOAT16 if precision == "float16" else ct.precision.FLOAT32,
    )


@dataclass
class Metadata:
    author: str
    license: str
    short_description: str
    version: str
    input_size: int
    embedding_dim: int
    threshold: float
    alignment: str = "arcface5"
    extra: dict = field(default_factory=dict)


def apply_metadata(mlmodel, md: Metadata, *, color: str, scale: float, bias: Sequence[float]):
    mlmodel.author = md.author
    mlmodel.license = md.license
    mlmodel.short_description = md.short_description
    mlmodel.version = md.version
    mlmodel.input_description[INPUT_NAME] = (
        f"{md.input_size}x{md.input_size} {color.upper()} face crop aligned with the 5-point ArcFace "
        f"template. Core ML applies pixel*{scale:g} + {list(bias)} internally."
    )
    mlmodel.output_description[OUTPUT_NAME] = (
        f"Raw (un-normalised) {md.embedding_dim}-d face embedding. L2-normalise, then compare "
        f"with cosine similarity; >= {md.threshold} means same person."
    )
    meta = {
        "fmc.inputSize": str(md.input_size),
        "fmc.embeddingDim": str(md.embedding_dim),
        "fmc.alignment": md.alignment,
        "fmc.defaultThreshold": f"{md.threshold:g}",
    }
    meta.update(md.extra)
    mlmodel.user_defined_metadata.update(meta)


# --------------------------------------------------------------------------
# Parity checking
# --------------------------------------------------------------------------

def test_images(input_size: int, n_random: int = 4, face_images: Sequence[Path] = (),
                seed: int = 0, fetch_sample_face: bool = True):
    """Return list of (label, PIL RGB image of size input_size x input_size)."""
    from PIL import Image

    rng = np.random.default_rng(seed)
    imgs = []
    for k in range(n_random):
        arr = rng.integers(0, 256, size=(input_size, input_size, 3), dtype=np.uint8)
        imgs.append((f"random#{k}", Image.fromarray(arr, "RGB")))
    # Smooth gradient image (less adversarial than uniform noise).
    yy, xx = np.mgrid[0:input_size, 0:input_size]
    grad = np.stack([xx * 255 // (input_size - 1), yy * 255 // (input_size - 1),
                     (xx + yy) * 255 // (2 * input_size - 2)], -1).astype(np.uint8)
    imgs.append(("gradient", Image.fromarray(grad, "RGB")))

    faces = list(face_images)
    if fetch_sample_face and not faces:
        try:
            p = download(SAMPLE_FACE_URL, MODELS_CACHE / "test-images" / "lena.jpg")
            img = Image.open(p).convert("RGB").crop(SAMPLE_FACE_BOX)
            imgs.append(("face:lena-crop", img.resize((input_size, input_size), Image.BICUBIC)))
        except Exception as e:  # network optional
            print(f"WARNING: could not fetch sample face image ({e}); random images only.")
    for p in faces:
        img = Image.open(p).convert("RGB")
        imgs.append((f"face:{Path(p).name}", img.resize((input_size, input_size), Image.BICUBIC)))
    return imgs


def reference_blob(img, *, scale: float, bias: Sequence[float], color: str) -> np.ndarray:
    """Build the NCHW float32 tensor the ONNX model should receive for `img`
    (a PIL RGB image), i.e. exactly what Core ML's ImageType produces."""
    arr = np.asarray(img, dtype=np.float32)  # HWC, RGB
    if color.upper() == "BGR":
        arr = arr[..., ::-1]
    arr = arr * np.float32(scale) + np.asarray(bias, dtype=np.float32)
    return np.ascontiguousarray(arr.transpose(2, 0, 1)[None])


def ort_session(onnx_path: Path):
    """ONNX Runtime session on the *original* ONNX file (reference implementation).
    Log level 3 silences the 'initializer appears in graph inputs' warnings."""
    import onnxruntime as ort

    so = ort.SessionOptions()
    so.log_severity_level = 3
    return ort.InferenceSession(str(onnx_path), sess_options=so, providers=["CPUExecutionProvider"])


def l2n(v: np.ndarray) -> np.ndarray:
    v = v.reshape(-1).astype(np.float64)
    return v / max(np.linalg.norm(v), 1e-12)


def parity_check(onnx_path: Path, mlmodel_path: Path, images, *, scale: float,
                 bias: Sequence[float], color: str, compute_units: Sequence[str] = ("CPU_ONLY", "ALL"),
                 extra_reference=None) -> dict:
    """Compare ONNX Runtime vs Core ML embeddings. Returns {compute_unit: min_cosine}.

    `extra_reference`: optional callable(img) -> np.ndarray blob to use instead of
    reference_blob (used to feed an independently-built OpenCV-style blob)."""
    import coremltools as ct

    sess = ort_session(onnx_path)
    in_name = sess.get_inputs()[0].name
    ref = {}
    for label, img in images:
        blob = extra_reference(img) if extra_reference else reference_blob(img, scale=scale, bias=bias, color=color)
        ref[label] = sess.run(None, {in_name: blob})[0]

    results = {}
    for cu in compute_units:
        ml = ct.models.MLModel(str(mlmodel_path), compute_units=getattr(ct.ComputeUnit, cu))
        cosines = []
        for label, img in images:
            out = ml.predict({INPUT_NAME: img})[OUTPUT_NAME]
            c = float(np.dot(l2n(out), l2n(ref[label])))
            cosines.append(c)
            print(f"  [{cu:8s}] {label:20s} cosine={c:.6f}  "
                  f"shape={tuple(np.asarray(out).shape)}  |onnx|={np.linalg.norm(ref[label]):.3f}  "
                  f"|coreml|={np.linalg.norm(out):.3f}")
        results[cu] = min(cosines)
    return results


def convert_with_fallback(onnx_path: Path, out_path: Path, *, input_size: int, scale: float,
                          bias: Sequence[float], color: str, md_factory, images,
                          precision: str = "auto", extra_reference=None) -> tuple[str, dict]:
    """Convert, attach metadata, save, parity-check. Tries FLOAT16 first when
    precision == 'auto' and falls back to FLOAT32 if parity < PARITY_MIN_COSINE."""
    import shutil

    onnx_model = load_clean_onnx(onnx_path)
    in_name, in_dims, out_name, out_dims = onnx_io_info(onnx_model)
    print(f"ONNX input  {in_name}: {in_dims}\nONNX output {out_name}: {out_dims}")

    torch_model, traced = onnx_to_traced_torch(onnx_model, input_size)

    # Torch-vs-ONNX sanity check (catches onnx2torch mistakes before Core ML).
    import torch
    sess = ort_session(onnx_path)
    blob = reference_blob(images[0][1], scale=scale, bias=bias, color=color)
    with torch.no_grad():
        t_out = traced(torch.from_numpy(blob)).numpy()
    o_out = sess.run(None, {sess.get_inputs()[0].name: blob})[0]
    tc = float(np.dot(l2n(t_out), l2n(o_out)))
    print(f"TorchScript vs ONNX cosine: {tc:.7f}")
    if tc < 0.99999:
        raise SystemExit("onnx2torch conversion does not match ONNX Runtime")
    embedding_dim = int(np.prod(o_out.shape[1:]))

    order = ["float16", "float32"] if precision == "auto" else [precision]
    last = None
    for prec in order:
        print(f"\n=== Converting to Core ML ({prec}) ===")
        mlmodel = torch_to_coreml(traced, input_size=input_size, scale=scale, bias=bias,
                                  color=color, precision=prec)
        apply_metadata(mlmodel, md_factory(embedding_dim, prec), color=color, scale=scale, bias=bias)
        if out_path.exists():
            shutil.rmtree(out_path)
        out_path.parent.mkdir(parents=True, exist_ok=True)
        mlmodel.save(str(out_path))
        print(f"Saved {out_path}")
        print("Parity (L2-normalised cosine, Core ML vs ONNX Runtime):")
        res = parity_check(onnx_path, out_path, images, scale=scale, bias=bias, color=color,
                           extra_reference=extra_reference)
        last = (prec, res)
        worst = min(res.values())
        if worst > PARITY_MIN_COSINE:
            print(f"Parity OK with {prec}: worst cosine {worst:.6f} > {PARITY_MIN_COSINE}")
            return prec, res
        print(f"Parity FAILED with {prec}: worst cosine {worst:.6f}")
    raise SystemExit(f"Parity check failed for all precisions: {last}")


def dir_size(path: Path) -> int:
    return sum(p.stat().st_size for p in Path(path).rglob("*") if p.is_file())


def print_spec_summary(path: Path):
    import coremltools as ct

    m = ct.models.MLModel(str(path), skip_model_load=True)
    spec = m.get_spec()
    print("\n=== Core ML model summary ===")
    print(f"specificationVersion: {spec.specificationVersion}")
    for f in spec.description.input:
        print(f"input  {f.name}: {f.type.WhichOneof('Type')} "
              f"{f.type.imageType.width}x{f.type.imageType.height} "
              f"colorSpace={f.type.imageType.ColorSpace.Name(f.type.imageType.colorSpace)}")
    for f in spec.description.output:
        arr = f.type.multiArrayType
        print(f"output {f.name}: multiArray shape={list(arr.shape)} "
              f"dtype={arr.ArrayDataType.Name(arr.dataType)}")
    print(f"author: {m.author}\nlicense: {m.license}\ndescription: {m.short_description}")
    for k, v in sorted(m.user_defined_metadata.items()):
        if k.startswith("fmc."):
            print(f"  {k} = {v}")
    size = dir_size(path)
    print(f"size on disk: {size} bytes ({size / 1e6:.2f} MB)")
