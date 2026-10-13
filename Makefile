PROJECT  := FindMyCrew.xcodeproj
SCHEME   := FindMyCrew
# Override when the repo is on an external drive: test runners launched by Xcode may be denied
# access to removable volumes, e.g. `make test DERIVED=~/Library/Developer/Xcode/DerivedData/FindMyCrew`.
DERIVED  ?= build/DerivedData
APP      := $(DERIVED)/Build/Products/Debug/Find My Crew.app
EVAL_BIN := $(DERIVED)/Build/Products/Release/fmc-eval
LFW_DIR  := models-cache/eval/lfw

SCENARIO := models-cache/testset/scenario

.PHONY: project build test run eval eval-build models fetch-eval testset scenario-eval clean

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

# End-to-end test library from openly licensed photos (Wikimedia Commons + raw.pixls.us); ~2 GB, ~30 min.
testset:
	scripts/models/setup_venv.sh
	python3 scripts/eval/fetch_testset.py
	.venv-models/bin/python scripts/eval/build_scenario.py

# Scan → review → export on the test library, scored against its labels (run `make testset` first).
scenario-eval: eval-build
	rm -rf models-cache/testset/export
	"$(EVAL_BIN)" scan --model FindMyCrew/Resources/Models/SFace.mlpackage \
		--references $(SCENARIO)/references --source $(SCENARIO)/library --labels $(SCENARIO)/labels.tsv \
		--report $(SCENARIO)/results.tsv --export models-cache/testset/export

# Regenerate the bundled Core ML model (needs Python 3.12 via mise).
models:
	scripts/models/setup_venv.sh
	.venv-models/bin/python scripts/models/convert_sface.py

clean:
	rm -rf build
