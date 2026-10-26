"""Run real shell entry points in a temporary HOME with deterministic external tool boundaries.

Uses the system ditto, shasum and PlistBuddy on macOS. No credentials, signing services,
installed applications or GitHub repositories are touched.
"""

import hashlib
import json
import os
from pathlib import Path
import plistlib
import signal
import shutil
import subprocess
import sys
import tempfile
import time
import unittest


ROOT = Path(__file__).resolve().parents[2]
APP = "Find My Crew.app"
STUBS = "uname sw_vers pgrep curl codesign spctl ditto mv security xcodegen xcodebuild lipo xcrun git gh mise".split()


@unittest.skipUnless(sys.platform == "darwin", "requires macOS ditto and PlistBuddy")
class LifecycleCase(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="fmc lifecycle '")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name).resolve()
        self.home = self.root / "home"
        self.bin = self.root / "bin"
        self.apps = self.root / "John's Applications"
        self.tools = self.root / "tools"
        self.tmp = self.root / "tmp"
        self.repo = self.root / "repo"
        self.state = self.home / "Library/Application Support/Find My Crew/installer"
        for path in (self.home, self.bin, self.apps, self.tools, self.tmp):
            path.mkdir()
        shutil.copytree(ROOT / "scripts/release", self.repo / "scripts/release")
        self.fixture = self.make_app(self.root / "source" / APP)
        stub = self.tools / "stub"
        stub.write_text(f"#!{sys.executable}\n" + (ROOT / "scripts/tests/command_stub.py").read_text())
        stub.chmod(0o755)
        for tool in STUBS:
            (self.tools / tool).symlink_to(stub)
        self.env = {
            **os.environ,
            "HOME": str(self.home),
            "PATH": f"{self.tools}:/usr/bin:/bin:/usr/sbin:/sbin",
            "TMPDIR": str(self.tmp),
            "COMMAND_LOG": str(self.root / "commands.jsonl"),
            "DOWNLOADS": str(self.root / "downloads"),
            "BUILD_APP": str(self.fixture),
            "DERIVED": str(self.root / "derived"),
            "OUT_DIR": str(self.root / "release"),
            "DRAFT": str(self.root / "draft"),
            "BARRIER_READY": str(self.root / "barrier-ready"),
            "BARRIER_RELEASE": str(self.root / "barrier-release"),
        }
        # Keep developer shell release settings from changing these isolated tests.
        for key in ("SIGNING", "SKIP_TESTS", "FIND_MY_CREW_DOWNLOAD_URL", "TEAM_ID", "NOTARY_PROFILE"):
            self.env.pop(key, None)

    def make_app(self, path, version="1.2.3", bundle_id="com.findmycrew.app"):
        (path / "Contents/Helpers").mkdir(parents=True)
        (path / "Contents/MacOS").mkdir()
        (path / "Contents/Resources/SFace.mlmodelc").mkdir(parents=True)
        (path / "Contents/Info.plist").write_bytes(plistlib.dumps({
            "CFBundleIdentifier": bundle_id,
            "CFBundleShortVersionString": version,
        }))
        (path / "Contents/MacOS/Find My Crew").write_text("fixture")
        fmc = path / "Contents/Helpers/fmc"
        fmc.write_text(f"#!/bin/sh\nprintf '%s\\n' '{version}'\n")
        fmc.chmod(0o755)
        return path

    def command(self, script, args=(), env=None):
        return ["/bin/bash", str(script), *map(str, args)], {**self.env, **(env or {})}

    def run_script(self, script, args=(), env=None, success=True):
        command, environment = self.command(script, args, env)
        result = subprocess.run(command, env=environment, cwd=self.root, text=True, capture_output=True, timeout=30)
        if success:
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        else:
            self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
        return result

    def install(self, args=(), env=None, success=True):
        return self.run_script(ROOT / "scripts/install.sh", ["--app-dir", self.apps, "--bin-dir", self.bin, *args], env, success)

    def local_install(self, **kwargs):
        return self.install(["--from", self.fixture], **kwargs)

    def release(self, script="build", env=None, success=True, version="1.2.3"):
        return self.run_script(self.repo / f"scripts/release/{script}.sh", [version], env, success)

    def commands(self, name=None):
        path = Path(self.env["COMMAND_LOG"])
        commands = [json.loads(line) for line in path.read_text().splitlines()] if path.exists() else []
        return [cmd for cmd in commands if name is None or cmd[0] == name]

    def clear_log(self):
        Path(self.env["COMMAND_LOG"]).write_text("")

    def assert_clean(self):
        self.assertFalse(list(self.apps.glob(".*install*")))
        self.assertFalse((self.state / "lock").exists())
        self.assertFalse(list(self.tmp.iterdir()))

    def assert_version(self, version="1.2.3"):
        result = subprocess.run([str(self.bin / "fmc"), "--version"], text=True, capture_output=True, timeout=5)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.strip(), version)

    def downloads(self):
        folder = Path(self.env["DOWNLOADS"])
        folder.mkdir(exist_ok=True)
        archive = folder / "FindMyCrew.zip"
        subprocess.run(["/usr/bin/ditto", "-c", "-k", "--keepParent", str(self.fixture), str(archive)], check=True)
        (folder / "FindMyCrew.zip.sha256").write_text(hashlib.sha256(archive.read_bytes()).hexdigest() + "  FindMyCrew.zip\n")
        self.env["FIND_MY_CREW_DOWNLOAD_URL"] = "https://fixture.invalid/download"
        return archive


class InstallerTests(LifecycleCase):
    def test_relative_paths_update_and_default_uninstall_remember_custom_directories(self):
        self.run_script(ROOT / "scripts/install.sh", ["--from", self.fixture, "--app-dir", "relative apps/", "--bin-dir", "relative bin/"])
        app = self.root / "relative apps" / APP
        link = self.root / "relative bin/fmc"
        self.assertEqual(link.readlink(), app / "Contents/Helpers/fmc")
        self.assertTrue(link.exists())
        self.run_script(ROOT / "scripts/install.sh", ["--from", self.fixture])
        self.run_script(ROOT / "scripts/install.sh", ["--uninstall"])
        self.assertFalse(app.exists())
        self.assertFalse(link.is_symlink())
        self.assert_clean()

    def test_relative_app_dir_with_absolute_bin_and_apostrophe_cleanup(self):
        self.run_script(ROOT / "scripts/install.sh", ["--from", self.fixture, "--app-dir", "John's apps", "--bin-dir", self.bin])
        self.assertEqual((self.bin / "fmc").readlink(), self.root / "John's apps" / APP / "Contents/Helpers/fmc")
        self.assert_version()
        self.assert_clean()

    def test_local_bundle_zip_update_and_link_tracks_new_version(self):
        archive = self.downloads()
        self.install(["--from", archive])
        self.assert_version()
        replacement = self.make_app(self.root / "new" / APP, "2.0")
        self.install(["--from", replacement])
        self.assert_version("2.0")
        self.assert_clean()

    def test_download_checksum_signature_team_and_gatekeeper(self):
        self.downloads()
        self.install(["--version", "v1.2.3"])
        self.assert_version()
        self.assertTrue(any("-R=" in " ".join(c) for c in self.commands("codesign")))
        self.assertTrue(self.commands("spctl"))
        self.assert_clean()

    def test_versioned_and_latest_download_urls(self):
        self.downloads()
        for version, suffix in (([], "latest/download"), (["--version", "v1.2.3"], "download/v1.2.3")):
            with self.subTest(version=version):
                self.clear_log()
                self.install(version, env={"FIND_MY_CREW_DOWNLOAD_URL": ""})
                self.assertEqual(self.commands("curl")[0][-1], f"https://github.com/arkaydeus/find-my-crew/releases/{suffix}/FindMyCrew.zip")

    def test_rejected_downloads_preserve_installed_app_and_cleanup(self):
        self.local_install()
        self.downloads()
        cases = [("DOWNLOAD_FAIL", "download failed"), ("SIGNATURE_FAIL", "signature is invalid"),
                 ("TEAM_FAIL", "isn't signed"), ("GATEKEEPER_FAIL", "Gatekeeper rejects")]
        for key, message in cases:
            with self.subTest(key=key):
                result = self.install(env={key: "1"}, success=False)
                self.assertIn(message, result.stderr)
                self.assert_version()
                self.assert_clean()
        (Path(self.env["DOWNLOADS"]) / "FindMyCrew.zip.sha256").write_text("0" * 64 + "  FindMyCrew.zip\n")
        self.assertIn("checksum mismatch", self.install(success=False).stderr)
        self.assert_version()
        self.assert_clean()

    def test_unrelated_live_dangling_and_other_installation_links_are_preserved(self):
        other = self.make_app(self.root / "other" / APP)
        for target in (self.root / "other-tool", self.root / "missing", other / "Contents/Helpers/fmc"):
            with self.subTest(target=target):
                if target.name == "other-tool":
                    target.write_text("unrelated")
                link = self.bin / "fmc"
                if link.is_symlink():
                    link.unlink()
                link.symlink_to(target)
                self.assertIn("leaving it alone", self.local_install().stderr)
                self.assertEqual(link.readlink(), target)
                self.install(["--uninstall"])
                self.assertEqual(link.readlink(), target)
        self.assert_clean()

    def test_regular_cli_file_and_unrelated_destination_are_preserved(self):
        link = self.bin / "fmc"
        link.write_text("unrelated")
        self.assertIn("leaving it alone", self.local_install().stderr)
        self.assertEqual(link.read_text(), "unrelated")
        self.install(["--uninstall"])
        wrong = self.make_app(self.apps / APP, bundle_id="org.other.app")
        for args in (["--from", self.fixture], ["--uninstall"]):
            self.assertIn("isn't Find My Crew", self.install(args, success=False).stderr)
            self.assertTrue(wrong.exists())
        self.assert_clean()

    def test_destination_symlinks_are_preserved_including_dangling(self):
        dest = self.apps / APP
        for target in (self.fixture, self.root / "missing"):
            dest.symlink_to(target)
            self.local_install(success=False)
            self.assertEqual(dest.readlink(), target)
            dest.unlink()
        self.assertTrue(self.fixture.exists())
        self.assert_clean()

    def test_running_app_and_invalid_local_bundle_refuse_replacement(self):
        self.local_install()
        self.assertIn("is running", self.local_install(env={"APP_RUNNING": "1"}, success=False).stderr)
        bad = self.make_app(self.root / "bad" / APP, bundle_id="org.other.app")
        self.install(["--from", bad], success=False)
        self.assert_version()
        self.assert_clean()

    def test_missing_failing_and_empty_cli_versions_fail_before_replacement(self):
        self.local_install()
        fmc = self.fixture / "Contents/Helpers/fmc"
        for body in ("#!/bin/sh\nexit 7\n", "#!/bin/sh\nexit 0\n", None):
            with self.subTest(body=body):
                if body is None:
                    fmc.unlink()
                else:
                    fmc.write_text(body)
                result = self.local_install(success=False)
                self.assertNotIn("Linked fmc", result.stdout)
                self.assert_version()
                self.assert_clean()

    def test_link_version_failure_is_reported_and_previous_app_restored(self):
        self.local_install()
        fmc = self.fixture / "Contents/Helpers/fmc"
        fmc.write_text("#!/bin/sh\ncase \"$0\" in *.installing.*) echo 2.0;; *) exit 7;; esac\n")
        result = self.local_install(success=False)
        self.assertIn("installed fmc --version failed", result.stderr)
        self.assertNotIn("Linked fmc", result.stdout)
        self.assert_version()
        self.assert_clean()

    def test_no_cli_install_is_remembered_and_uninstalled_by_default(self):
        self.install(["--from", self.fixture, "--no-cli"])
        self.assertFalse((self.bin / "fmc").exists())
        self.assertTrue((self.state / "app-dir").exists())
        self.run_script(ROOT / "scripts/install.sh", ["--uninstall"])
        self.assertFalse((self.apps / APP).exists())
        self.assertFalse((self.state / "app-dir").exists())
        self.assert_clean()

    def test_uninstall_missing_custom_app_preserves_unrelated_link(self):
        self.env["HOME"] = str(self.root / "empty-home")
        # An unrelated link is never sufficient evidence to remove it.
        (self.bin / "fmc").symlink_to(self.root / "missing")
        self.install(["--uninstall"])
        self.assertTrue((self.bin / "fmc").is_symlink())

    def test_copy_and_swap_failure_restore_previous_app_and_cleanup(self):
        self.local_install()
        for key in ("COPY_FAIL", "SWAP_FAIL"):
            with self.subTest(key=key):
                self.local_install(env={key: "1"}, success=False)
                self.assert_version()
                self.assert_clean()

    def test_failed_rollback_preserves_backup_and_reports_location(self):
        self.local_install()
        result = self.local_install(env={"SWAP_FAIL": "1", "RESTORE_FAIL": "1"}, success=False)
        self.assertIn("preserved at", result.stderr)
        backups = list(self.apps.glob(".*installing.*/previous.app"))
        self.assertEqual(len(backups), 1)
        self.assertTrue((backups[0] / "Contents/Helpers/fmc").exists())
        self.assertIn(str(backups[0]), result.stderr)
        self.assertFalse((self.state / "lock").exists())
        self.assertFalse(list(self.apps.glob("*install-lock")))

    def test_simultaneous_install_and_uninstall_cannot_remove_staging_or_destination(self):
        self.local_install()
        command, environment = self.command(ROOT / "scripts/install.sh", ["--from", self.fixture, "--app-dir", self.apps, "--bin-dir", self.bin], {"PAUSE_COPY": "1"})
        process = subprocess.Popen(command, env=environment, cwd=self.root, text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        try:
            deadline = time.monotonic() + 10
            while not Path(self.env["BARRIER_READY"]).exists():
                self.assertIsNone(process.poll(), "installer exited before test barrier")
                self.assertLess(time.monotonic(), deadline, "installer never reached test barrier")
                time.sleep(0.02)
            for args in (["--from", self.fixture], ["--uninstall"]):
                self.assertIn("lock:", self.install(args, success=False).stderr)
            # Different users still share the per-destination lock.
            self.install(["--uninstall"], env={"HOME": str(self.root / "second-home")}, success=False)
            Path(self.env["BARRIER_RELEASE"]).touch()
            out, err = process.communicate(timeout=15)
            self.assertEqual(process.returncode, 0, out + err)
        finally:
            if process.poll() is None:
                process.terminate()
                process.communicate(timeout=5)
        self.assert_version()
        self.assert_clean()

    def test_termination_immediately_after_swap_restores_previous_app(self):
        self.local_install()
        replacement = self.make_app(self.root / "replacement" / APP, "2.0")
        command, environment = self.command(ROOT / "scripts/install.sh", ["--from", replacement, "--app-dir", self.apps, "--bin-dir", self.bin], {"PAUSE_SWAP": "1"})
        process = subprocess.Popen(command, env=environment, cwd=self.root, text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        try:
            deadline = time.monotonic() + 10
            while not Path(self.env["BARRIER_READY"]).exists():
                self.assertIsNone(process.poll(), "installer exited before swap barrier")
                self.assertLess(time.monotonic(), deadline, "installer never reached swap barrier")
                time.sleep(0.02)
            self.assert_version("2.0")
            process.send_signal(signal.SIGTERM)
            Path(self.env["BARRIER_RELEASE"]).touch()
            out, err = process.communicate(timeout=15)
            self.assertEqual(process.returncode, 143, out + err)
        finally:
            if process.poll() is None:
                process.kill()
                process.communicate(timeout=5)
        self.assert_version()
        self.assert_clean()

    def test_option_conflicts_missing_values_unknown_and_platform_checks(self):
        cases = [(["--from", self.fixture, "--version", "1.0"], "either"),
                 (["--uninstall", "--from", self.fixture], "cannot be combined"),
                 (["--uninstall", "--version", "1.0"], "cannot be combined"),
                 (["--uninstall", "--no-cli"], "cannot be combined"),
                 (["--bogus"], "unknown option"), (["--app-dir", ""], "needs a folder")]
        for flag in ("--version", "--from", "--app-dir", "--bin-dir"):
            cases.append(([flag], "needs"))
        for args, message in cases:
            with self.subTest(args=args):
                self.assertIn(message, self.install(args, success=False).stderr)
        self.local_install(env={"OS_NAME": "Linux"}, success=False)
        self.local_install(env={"OS_VERSION": "14.0"}, success=False)
        self.assert_clean()


class ReleaseBuildTests(LifecycleCase):
    def test_developer_id_signing_notarization_stapling_and_checksum(self):
        self.release(env={"SIGNING": "developer-id"})
        build = self.commands("xcodebuild")[0]
        for setting in ("ONLY_ACTIVE_ARCH=NO", "MARKETING_VERSION=1.2.3", "CURRENT_PROJECT_VERSION=42",
                        "CODE_SIGN_IDENTITY=Developer ID Application", "DEVELOPMENT_TEAM=QWD87G9T3P",
                        "OTHER_CODE_SIGN_FLAGS=--timestamp", "CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO"):
            self.assertIn(setting, build)
        commands = self.commands("xcrun")
        self.assertEqual([c[1:3] for c in commands], [["notarytool", "submit"], ["stapler", "staple"], ["stapler", "validate"]])
        self.assertIn("orkestrator-notary", commands[0])
        self.assertIn("--wait", commands[0])
        self.assertTrue(self.commands("spctl"))
        folder = Path(self.env["OUT_DIR"])
        digest = (folder / "FindMyCrew.zip.sha256").read_text().split()[0]
        self.assertEqual(digest, hashlib.sha256((folder / "FindMyCrew.zip").read_bytes()).hexdigest())
        self.assertFalse((folder / "notarize.zip").exists())

    def test_developer_id_identity_team_timestamp_runtime_and_entitlement_failures(self):
        cases = {"NO_IDENTITY": "no Developer ID", "SIGNED_TEAM": "isn't signed", "NO_TIMESTAMP": "no secure timestamp",
                 "NO_RUNTIME": "hardened runtime", "DEBUG_ENTITLEMENT": "get-task-allow"}
        for key, message in cases.items():
            with self.subTest(key=key):
                self.clear_log()
                result = self.release(env={"SIGNING": "developer-id", key: "wrong" if key == "SIGNED_TEAM" else "1"}, success=False)
                self.assertIn(message, result.stderr)
                self.assertFalse(self.commands("xcrun"))
                self.assertFalse((Path(self.env["OUT_DIR"]) / "FindMyCrew.zip").exists())

    def test_notarization_invalid_malformed_and_failed_responses(self):
        cases = [({"NOTARY_RESULT": '{"status":"Invalid","id":"bad-123"}'}, "submission bad-123"),
                 ({"NOTARY_RESULT": "not json"}, "submission unknown"),
                 ({"NOTARY_RESULT": '{}'}, "submission unknown"),
                 ({"NOTARY_FAIL": "1"}, "notarytool submit failed")]
        for env, message in cases:
            with self.subTest(env=env):
                self.clear_log()
                result = self.release(env={"SIGNING": "developer-id", **env}, success=False)
                self.assertIn(message, result.stderr)
                self.assertFalse(any(c[1] == "stapler" for c in self.commands("xcrun")))
                self.assertFalse((Path(self.env["OUT_DIR"]) / "FindMyCrew.zip").exists())

    def test_stapling_validation_and_gatekeeper_failures_stop_packaging(self):
        for key, message in (("STAPLE_FAIL", "couldn't staple"), ("TICKET_FAIL", "doesn't validate"), ("GATEKEEPER_FAIL", "Gatekeeper rejects")):
            with self.subTest(key=key):
                self.assertIn(message, self.release(env={"SIGNING": "developer-id", key: "1"}, success=False).stderr)
                self.assertFalse((Path(self.env["OUT_DIR"]) / "FindMyCrew.zip").exists())

    def test_build_architecture_model_signature_and_version_assertions(self):
        for key in ("BUILD_FAIL", "NO_MODEL", "SIGNATURE_FAIL", "BUILT_CLI_VERSION", "BINARY_ARCHS"):
            with self.subTest(key=key):
                self.release(env={"SIGNING": "adhoc", key: "wrong"}, success=False)
                self.assertFalse((Path(self.env["OUT_DIR"]) / "FindMyCrew.zip").exists())

    def test_auto_signing_chooses_identity_or_adhoc_and_validates_options(self):
        for environment, notarizes in (({}, True), ({"NO_IDENTITY": "1"}, False), ({"SIGNING": "adhoc"}, False)):
            with self.subTest(environment=environment):
                self.clear_log()
                self.release(env=environment)
                self.assertEqual(bool(self.commands("xcrun")), notarizes)
        self.release(env={"SIGNING": "invalid"}, success=False)
        self.release(version="1.2.3-beta", success=False)


class PublishTests(LifecycleCase):
    def test_clean_synced_main_tests_build_draft_upload_and_publish(self):
        self.release("publish")
        self.assertEqual(self.commands("mise"), [["mise", "run", "test:scripts"], ["mise", "run", "test"]])
        create = next(c for c in self.commands("gh") if c[1:3] == ["release", "create"])
        self.assertIn("--draft", create)
        self.assertIn("--generate-notes", create)
        self.assertEqual(create[create.index("--target") + 1], "commit-123")
        self.assertEqual(create[3], "v1.2.3")
        self.assertEqual(self.commands("gh")[-1], ["gh", "release", "edit", "v1.2.3", "--draft=false"])
        self.assertFalse(Path(self.env["DRAFT"]).exists())
        self.assertIn("CODE_SIGN_IDENTITY=Developer ID Application", self.commands("xcodebuild")[0])

    def test_auth_clean_branch_sync_fetch_and_duplicate_tag_gates(self):
        cases = [("AUTH_FAIL", "isn't logged in"), ("DIRTY", "uncommitted"), ("BRANCH", "from main"),
                 ("UNSYNCED", "isn't in sync"), ("FETCH_FAIL", ""), ("DUPLICATE_TAG", "already exists")]
        for key, message in cases:
            with self.subTest(key=key):
                self.clear_log()
                self.assertIn(message, self.release("publish", env={key: "1"}, success=False).stderr)
                self.assertFalse(self.commands("xcodebuild"))
                self.assertFalse(self.commands("mise"))
                self.assertFalse(any(c[1] == "release" for c in self.commands("gh")))

    def test_test_and_build_failures_never_create_release(self):
        for key in ("TEST_FAIL", "BUILD_FAIL", "NOTARY_FAIL"):
            with self.subTest(key=key):
                self.clear_log()
                self.release("publish", env={key: "1"}, success=False)
                self.assertFalse(any(c[1] == "release" for c in self.commands("gh")))

    def test_upload_failure_never_publishes_and_reports_draft(self):
        result = self.release("publish", env={"UPLOAD_FAIL": "1", "SKIP_TESTS": "1"}, success=False)
        self.assertIn("asset upload failed", result.stderr)
        self.assertFalse(any(c[1:3] == ["release", "edit"] for c in self.commands("gh")))
        self.assertNotIn("Published", result.stdout)
        self.assertFalse(self.commands("mise"))

    def test_publish_failure_retains_draft_and_propagates_failure(self):
        result = self.release("publish", env={"PUBLISH_FAIL": "1"}, success=False)
        self.assertIn("remain a draft", result.stderr)
        self.assertTrue(Path(self.env["DRAFT"]).exists())
        self.assertNotIn("Published", result.stdout)


if __name__ == "__main__":
    unittest.main()
