# FindMyCrew face-embedding models

Scripts that produce the Core ML face-embedding models used by FindMyCrew.

| File | Purpose |
| --- | --- |
| `setup_venv.sh` | Creates `.venv-models/` (Python 3.12 via mise) and installs `requirements.txt` |
| `requirements.txt` | Pinned, verified-compatible versions (coremltools 9.0 + torch 2.7.0, ...) |
| `convert_sface.py` | Downloads OpenCV Zoo SFace and builds the bundled `FindMyCrew/Resources/Models/SFace.mlpackage` |
| `convert_onnx_embedder.py` | Converts a user-supplied ArcFace-style ONNX model (such as InsightFace `w600k_r50.onnx`) into an `.mlpackage` the app can load as a custom model |
| `fmc_coreml.py` | Shared conversion, metadata, and parity-check code |

## Regenerating the bundled model

```sh
scripts/models/setup_venv.sh
.venv-models/bin/python scripts/models/convert_sface.py
```

Downloads go to `models-cache/`, which git ignores. The SFace ONNX file is pinned by SHA-256
(`0ba9fbfa01b5270c96627c4ef784da859931e02f04419c829e83484087c34e79`).
Pipeline: ONNX, then PyTorch (`onnx2torch`), then traced TorchScript, then a Core ML ML Program
(`minimum_deployment_target = macOS15`). The script tries FLOAT16 first and falls back to FLOAT32
if the parity check fails. Use `--precision float32` to force FP32.

Parity check: ONNX Runtime on the original ONNX file and Core ML (`CPU_ONLY` and `ALL` compute
units) run on 4 random images, a gradient image, and a sample face crop. They must agree with
cosine > 0.999 after L2 normalization. When `opencv-python` is installed, the script also compares
the Core ML output with the real `cv2.FaceRecognizerSF.feature()`. Use `--face-image PATH` to add
your own crops.

## Model interface (shared by all FindMyCrew models)

| | |
| --- | --- |
| Input `image` | Core ML Image, `fmc.inputSize` x `fmc.inputSize` (112x112). Pass a face crop aligned to the 5-point ArcFace template (`fmc.alignment = arcface5`). The model handles channel order and `scale`/`bias` itself, so pass plain pixels. |
| Output `embedding` | Float32 MultiArray `(1, fmc.embeddingDim)`. This is the raw output and is **not L2-normalized**. Normalize it before computing cosine similarity. |
| `fmc.defaultThreshold` | Cosine-similarity threshold for "same person" |

ArcFace 112x112 template (x, y): left eye (38.2946, 51.6963), right eye (73.5318, 51.5014),
nose (56.0252, 71.7366), left mouth corner (41.5493, 92.3655), right mouth corner (70.7299, 92.2041).

### SFace preprocessing (verified from OpenCV source)

`FaceRecognizerSFImpl::feature` in `modules/objdetect/src/face_recognize.cpp` is the same in 4.x and 5.x:

```cpp
blobFromImage(aligned_img, 1, Size(112,112), Scalar(0,0,0), /*swapRB*/true, /*crop*/false);
```

OpenCV feeds the network an RGB float32 NCHW tensor with values 0..255 and does no scaling. The
normalization `(x - 127.5) * 0.0078125` is built into the ONNX graph as its first two nodes, so the
conversion keeps it. The Core ML input is therefore `RGB, scale=1, bias=0`. Threshold: cosine >= 0.363,
from OpenCV's documentation (`samples/dnn/face_detect.cpp`, opencv_zoo `sface.py`).

## Converting your own ArcFace model

```sh
.venv-models/bin/python scripts/models/convert_onnx_embedder.py \
    --onnx /path/to/w600k_r50.onnx --out ~/Desktop/ArcFaceR50.mlpackage \
    --name "ArcFace R50 (InsightFace w600k)" --threshold 0.30
```

| Option | Default | Meaning |
| --- | --- | --- |
| `--input-size` | 112 | Square input size |
| `--scale` | `1/127.5` | Multiplier for 0..255 pixels. Fractions such as `1/127.5` are accepted. |
| `--bias` | `-1` | Added after scaling. Takes one value or `r,g,b`. |
| `--color` | `RGB` | Channel order the ONNX network expects (`RGB` or `BGR`) |
| `--threshold` | 0.30 | Written to `fmc.defaultThreshold` |
| `--name`, `--author`, `--license` | | Model metadata |
| `--precision` | `auto` | `auto` tries float16 and falls back to float32, or set `float16` / `float32` |

The InsightFace defaults (`RGB`, `(x - 127.5) / 127.5`) match the InsightFace `ArcFaceONNX` preprocessing.
If the ONNX graph starts with `Sub`/`Mul` nodes, it normalizes internally, so pass `--scale 1 --bias 0`.
This is the same check InsightFace uses, and the script prints a warning when your settings don't match it.
Settings for SFace through this generic script: `--scale 1 --bias 0 --color RGB --threshold 0.363`.
The embedding dimension, for example 512 for w600k_r50, is read from the model.

## Licensing

- **SFace** (OpenCV Zoo, `face_recognition_sface_2021dec.onnx`) is **Apache-2.0**. The converted
  `SFace.mlpackage` ships in the app, and its Core ML metadata records the license.
- **InsightFace / ArcFace pretrained weights** (`buffalo_l`, `w600k_r50`, `antelopev2`, ...) are licensed
  for **non-commercial research use only**. FindMyCrew never downloads, bundles, or redistributes them.
  Users who want them must get the weights themselves and convert them with
  `convert_onnx_embedder.py` for personal use, at their own discretion and under the upstream license terms.
- The sample image used for parity testing (`lena.jpg` from OpenCV `samples/data`) is downloaded to
  `models-cache/` and is never committed.
