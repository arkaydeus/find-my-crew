#!/usr/bin/env python3
"""Convert OpenCV Zoo SFace (face_recognition_sface_2021dec.onnx) to Core ML.

Output: FindMyCrew/Resources/Models/SFace.mlpackage

Verified preprocessing (OpenCV source, modules/objdetect/src/face_recognize.cpp,
identical on the 4.x and 5.x branches, checked 2026-10-11):

    void FaceRecognizerSFImpl::alignCrop(...)
        // similarity transform of the 5 YuNet landmarks onto the ArcFace template
        //   {38.2946,51.6963} {73.5318,51.5014} {56.0252,71.7366}
        //   {41.5493,92.3655} {70.7299,92.2041}
        warpAffine(src, aligned, M, Size(112,112), INTER_LINEAR);

    void FaceRecognizerSFImpl::feature(InputArray _aligned_img, OutputArray _face_feature)
        Mat inputBolb = dnn::blobFromImage(_aligned_img, 1, Size(112, 112),
                                           Scalar(0, 0, 0), /*swapRB=*/true, /*crop=*/false);
        net.setInput(inputBolb);
        net.forward(_face_feature);

    match(): L2-normalise both features, cosine = dot product.
    Documented thresholds (opencv_zoo sface.py, samples/dnn/face_detect.cpp):
        cosine >= 0.363 -> same identity;  L2 <= 1.128 -> same identity.

So the aligned BGR crop (OpenCV images are BGR) is channel-swapped to RGB and fed as
float32 NCHW in the range 0..255 with NO scaling or mean subtraction in OpenCV.

The normalisation lives *inside* the ONNX graph: the first two nodes are
    Sub(data, scalar_op1=127.5) -> Mul(_, scalar_op2=0.0078125)
i.e. the network computes (x - 127.5) / 128 itself. Those nodes are carried through the
conversion, therefore the Core ML ImageType uses color_layout=RGB, scale=1.0, bias=0
and Core ML feeds exactly the tensor OpenCV would feed (RGB float 0..255).

Gotchas handled here:
  * The ONNX file is an old IR-6 MXNet export that lists every weight as a graph
    input; these are stripped before onnx2torch (see fmc_coreml.load_clean_onnx).
  * Output is the raw 128-d feature (OpenCV's feature() output); it is NOT
    L2-normalised. The app must normalise before cosine comparison.

Usage:
    .venv-models/bin/python scripts/models/convert_sface.py [--precision auto|float16|float32]
                                                            [--face-image PATH ...]
"""

from __future__ import annotations

import argparse
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import fmc_coreml as fmc  # noqa: E402

SFACE_URL = ("https://huggingface.co/opencv/opencv_zoo/resolve/main/models/"
             "face_recognition_sface/face_recognition_sface_2021dec.onnx")
SFACE_SHA256 = "0ba9fbfa01b5270c96627c4ef784da859931e02f04419c829e83484087c34e79"
OUT_PATH = fmc.REPO_ROOT / "FindMyCrew" / "Resources" / "Models" / "SFace.mlpackage"

INPUT_SIZE = 112
SCALE = 1.0               # network normalises internally: (x - 127.5) * 0.0078125
BIAS = (0.0, 0.0, 0.0)
COLOR = "RGB"             # blobFromImage(..., swapRB=true) on a BGR Mat -> RGB
THRESHOLD = 0.363         # OpenCV-documented SFace cosine threshold


def opencv_blob(img):
    """Independent re-implementation of OpenCV's feature() preprocessing for a
    PIL RGB image: emulate cv::imread (BGR), then blobFromImage(swapRB=true)."""
    import numpy as np

    bgr = np.asarray(img, dtype=np.uint8)[..., ::-1]           # what cv::imread gives
    rgb = bgr[..., ::-1].astype(np.float32)                     # swapRB=true, scale=1, mean=0
    return np.ascontiguousarray(rgb.transpose(2, 0, 1)[None])   # NCHW


def opencv_ground_truth(onnx_path: Path, mlpackage: Path, images) -> None:
    """If opencv-python is installed, compare Core ML against the real
    cv2.FaceRecognizerSF.feature() (the reference implementation)."""
    try:
        import cv2
    except ImportError:
        print("opencv-python not installed; skipping cv2.FaceRecognizerSF ground-truth check.")
        return
    import coremltools as ct
    import numpy as np

    print(f"\nGround truth vs cv2.FaceRecognizerSF.feature() (OpenCV {cv2.__version__}):")
    rec = cv2.FaceRecognizerSF.create(str(onnx_path), "")
    ml = ct.models.MLModel(str(mlpackage), compute_units=ct.ComputeUnit.ALL)
    worst = 1.0
    for label, img in images:
        bgr = np.ascontiguousarray(np.asarray(img, dtype=np.uint8)[..., ::-1])
        cv_feat = rec.feature(bgr)
        cm = ml.predict({fmc.INPUT_NAME: img})[fmc.OUTPUT_NAME]
        c = float(np.dot(fmc.l2n(cv_feat), fmc.l2n(cm)))
        # Also OpenCV's own match() on the raw features.
        cv_match = rec.match(cv_feat, np.asarray(cm, dtype=np.float32).reshape(1, -1),
                             cv2.FaceRecognizerSF_FR_COSINE)
        worst = min(worst, c)
        print(f"  {label:20s} cosine={c:.6f}  (cv2 match()={cv_match:.6f})")
    if worst <= fmc.PARITY_MIN_COSINE:
        raise SystemExit(f"Core ML disagrees with cv2.FaceRecognizerSF (worst cosine {worst:.6f})")


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--precision", choices=["auto", "float16", "float32"], default="auto",
                    help="auto = try float16, fall back to float32 if parity fails")
    ap.add_argument("--face-image", type=Path, action="append", default=[],
                    help="extra face image(s) for parity (resized to 112x112)")
    ap.add_argument("--out", type=Path, default=OUT_PATH)
    args = ap.parse_args()

    onnx_path = fmc.download(SFACE_URL, fmc.MODELS_CACHE / "face_recognition_sface_2021dec.onnx",
                             expected_sha256=SFACE_SHA256)
    images = fmc.test_images(INPUT_SIZE, face_images=args.face_image)

    def md_factory(dim: int, precision: str) -> fmc.Metadata:
        return fmc.Metadata(
            author="OpenCV Zoo (SFace, Apache-2.0)",
            license="Apache-2.0",
            short_description=(
                "SFace face-recognition embedding (MobileFaceNet backbone, OpenCV Zoo "
                "face_recognition_sface_2021dec). Input: 112x112 RGB face aligned to the "
                "5-point ArcFace template. Output: raw 128-d embedding; L2-normalise and "
                f"compare by cosine similarity (same person if >= {THRESHOLD})."
            ),
            version="2021dec",
            input_size=INPUT_SIZE,
            embedding_dim=dim,
            threshold=THRESHOLD,
            extra={"fmc.source": "opencv_zoo/face_recognition_sface_2021dec.onnx",
                   "fmc.sourceSha256": SFACE_SHA256,
                   "fmc.computePrecision": precision},
        )

    precision, results = fmc.convert_with_fallback(
        onnx_path, args.out, input_size=INPUT_SIZE, scale=SCALE, bias=BIAS, color=COLOR,
        md_factory=md_factory, images=images, precision=args.precision,
        extra_reference=opencv_blob,
    )
    opencv_ground_truth(onnx_path, args.out, images)
    fmc.print_spec_summary(args.out)
    print(f"\nDone. precision={precision} worst-cosine per compute unit: "
          + ", ".join(f"{k}={v:.6f}" for k, v in results.items()))


if __name__ == "__main__":
    main()
