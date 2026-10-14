#!/usr/bin/env python3
"""Check testset uses its prepared interpreter even with a different python3 on PATH."""
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest


class TestsetInterpreterTests(unittest.TestCase):
    def test_both_stages_use_prepared_python(self):
        repo = Path(__file__).resolve().parents[2]
        with tempfile.TemporaryDirectory(prefix="fmc-testset-mise-") as tmp:
            root = Path(tmp)
            shutil.copyfile(repo / "mise.toml", root / "mise.toml")
            (root / "scripts/models").mkdir(parents=True)
            (root / "scripts/eval").mkdir(parents=True)
            (root / ".venv-models/bin").mkdir(parents=True)
            setup = root / "scripts/models/setup_venv.sh"
            setup.write_text("#!/bin/sh\ntest -x .venv-models/bin/python\n")
            setup.chmod(0o755)
            # Use this test's interpreter as the prepared venv, with no downloads or environment mutation.
            (root / ".venv-models/bin/python").symlink_to(sys.executable)
            for stage in ["fetch_testset", "build_scenario"]:
                (root / f"scripts/eval/{stage}.py").write_text(
                    "import json, sys\nprint(json.dumps([sys.argv[0], sys.executable, list(sys.version_info[:2])]))\n"
                )
            trap = root / "other-python/bin"
            trap.mkdir(parents=True)
            other_python = trap / "python3"
            other_python.write_text("#!/bin/sh\necho 'wrong system python3 selected' >&2\nexit 97\n")
            other_python.chmod(0o755)
            # Trust the copied config, skip tool installs (no downloads) and keep task output unprefixed.
            env = dict(os.environ, PATH=f"{trap}:{os.environ['PATH']}", MISE_TRUSTED_CONFIG_PATHS=str(root),
                       MISE_TASK_RUN_AUTO_INSTALL="0", MISE_TASK_OUTPUT="interleave")
            result = subprocess.run(["mise", "run", "testset"], cwd=root, env=env,
                                    check=True, text=True, capture_output=True)
            calls = [json.loads(line) for line in result.stdout.splitlines() if line.startswith("[")]
            self.assertEqual([Path(call[0]).stem for call in calls], ["fetch_testset", "build_scenario"])
            self.assertTrue(all(Path(call[1]).resolve() == (root / ".venv-models/bin/python").resolve() for call in calls))
            self.assertTrue(all(call[2] == list(sys.version_info[:2]) for call in calls))


if __name__ == "__main__":
    unittest.main()
