PROJECT  := FindMyCrew.xcodeproj
SCHEME   := FindMyCrew
DERIVED  := build/DerivedData
APP      := $(DERIVED)/Build/Products/Debug/Find My Crew.app
EVAL_BIN := $(DERIVED)/Build/Products/Release/fmc-eval
LFW_DIR  := models-cache/eval/lfw

.PHONY: project build test run eval eval-build models fetch-eval clean

project:
	xcodegen generate

build: project
	xcodebuild -project $(PROJECT) -scheme $(SCHEME) -configuration Debug \
		-derivedDataPath $(DERIVED) build -quiet

test: project
	xcodebuild -project $(PROJECT) -scheme $(SCHEME) -derivedDataPath $(DERIVED) test -quiet

run: build
	open "$(APP)"

eval-build: project
	xcodebuild -project $(PROJECT) -scheme fmc-eval -configuration Release \
		-derivedDataPath $(DERIVED) build -quiet

# Verification accuracy on LFW (run `make fetch-eval` first).
eval: eval-build
	"$(EVAL_BIN)" "$(LFW_DIR)" --model FindMyCrew/Resources/Models/SFace.mlpackage

fetch-eval:
	scripts/eval/fetch_lfw.sh

# Regenerate the bundled Core ML model (needs Python 3.12 via mise).
models:
	scripts/models/setup_venv.sh
	.venv-models/bin/python scripts/models/convert_sface.py

clean:
	rm -rf build
