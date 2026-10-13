#!/usr/bin/env bash
# Create .venv-models (Python 3.12) at the repo root and install the pinned
# model-conversion tooling from scripts/models/requirements.txt.
#
# Usage: scripts/models/setup_venv.sh            # creates/updates ./.venv-models
#        VENV_DIR=/tmp/venv scripts/models/setup_venv.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
VENV_DIR="${VENV_DIR:-$REPO_ROOT/.venv-models}"
PY_VERSION="3.12"

if command -v mise >/dev/null 2>&1; then
  mise install "python@$PY_VERSION" >/dev/null
  PYTHON=(mise exec "python@$PY_VERSION" -- python)
elif command -v "python$PY_VERSION" >/dev/null 2>&1; then
  PYTHON=("python$PY_VERSION")
else
  echo "error: Python $PY_VERSION not found. Install mise (https://mise.jdx.dev) or python$PY_VERSION." >&2
  exit 1
fi

if [[ ! -x "$VENV_DIR/bin/python" ]]; then
  echo "Creating $VENV_DIR with $("${PYTHON[@]}" --version)"
  "${PYTHON[@]}" -m venv "$VENV_DIR"
fi

"$VENV_DIR/bin/python" -m pip install --upgrade pip
"$VENV_DIR/bin/python" -m pip install -r "$SCRIPT_DIR/requirements.txt"
"$VENV_DIR/bin/python" -c "import coremltools, torch, onnx, onnx2torch, onnxruntime, numpy, PIL; \
print('OK: coremltools', coremltools.__version__, '| torch', torch.__version__, '| onnx', onnx.__version__, \
'| onnxruntime', onnxruntime.__version__, '| numpy', numpy.__version__)"
echo "Done. Run e.g.: $VENV_DIR/bin/python scripts/models/convert_sface.py"
