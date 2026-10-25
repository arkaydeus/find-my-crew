"""Command boundary fixtures for test_lifecycle.py; never invoke network/signing tools."""

import json
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import sys
import time


name, args = Path(sys.argv[0]).name, sys.argv[1:]
env = os.environ
with open(env["COMMAND_LOG"], "a") as log:
    log.write(json.dumps([name, *args]) + "\n")


def fail_if(key):
    if env.get(key):
        sys.exit(1)


def barrier():
    Path(env["BARRIER_READY"]).touch()
    deadline = time.monotonic() + 15
    while not Path(env["BARRIER_RELEASE"]).exists():
        if time.monotonic() > deadline:
            sys.exit("timed out waiting for test barrier")
        time.sleep(0.02)


if name == "uname":
    print(env.get("OS_NAME", "Darwin"))
elif name == "sw_vers":
    print(env.get("OS_VERSION", "15.0"))
elif name == "pgrep":
    sys.exit(0 if env.get("APP_RUNNING") else 1)
elif name == "curl":
    fail_if("DOWNLOAD_FAIL")
    target = Path(args[args.index("-o") + 1])
    shutil.copyfile(Path(env["DOWNLOADS"]) / args[-1].rsplit("/", 1)[-1], target)
elif name == "codesign":
    if "--verify" in args:
        fail_if("SIGNATURE_FAIL")
        if any(a.startswith("-R=") for a in args):
            fail_if("TEAM_FAIL")
    elif "--entitlements" in args:
        print("<plist><dict>" + ("<key>get-task-allow</key><true/>" if env.get("DEBUG_ENTITLEMENT") else "") + "</dict></plist>")
    else:
        lines = ["TeamIdentifier=" + env.get("SIGNED_TEAM", "QWD87G9T3P")]
        if not env.get("NO_TIMESTAMP"):
            lines.append("Timestamp=Oct 25, 2026")
        lines.append("flags=0x10000(runtime)" if not env.get("NO_RUNTIME") else "flags=0x0(none)")
        print("\n".join(lines), file=sys.stderr)
elif name == "spctl":
    fail_if("GATEKEEPER_FAIL")
elif name == "ditto":
    staging = len(args) == 2 and ".installing." in args[-1]
    if staging:
        fail_if("COPY_FAIL")
        if env.get("PAUSE_COPY"):
            barrier()
    os.execv("/usr/bin/ditto", ["ditto", *args])
elif name == "mv":
    if env.get("SWAP_FAIL") and ".installing." in args[0] and args[0].endswith("Find My Crew.app"):
        sys.exit(1)
    if env.get("RESTORE_FAIL") and args[0].endswith("previous.app"):
        sys.exit(1)
    if env.get("PAUSE_SWAP") and ".installing." in args[0] and args[0].endswith("Find My Crew.app"):
        subprocess.run(["/bin/mv", *args], check=True)
        barrier()
        sys.exit(0)
    os.execv("/bin/mv", ["mv", *args])
elif name == "security":
    if not env.get("NO_IDENTITY"):
        print('1) ABCDEF "Developer ID Application: Test (QWD87G9T3P)"')
elif name == "xcodegen":
    pass
elif name == "xcodebuild":
    fail_if("BUILD_FAIL")
    derived = Path(args[args.index("-derivedDataPath") + 1])
    app = derived / "Build/Products/Release/Find My Crew.app"
    shutil.copytree(env["BUILD_APP"], app)
    version = next((a.split("=", 1)[1] for a in args if a.startswith("MARKETING_VERSION=")), "1.0")
    info = app / "Contents/Info.plist"
    data = plistlib.loads(info.read_bytes())
    data["CFBundleShortVersionString"] = version
    info.write_bytes(plistlib.dumps(data))
    fmc = app / "Contents/Helpers/fmc"
    fmc.write_text("#!/bin/sh\nprintf '%s\\n' '" + env.get("BUILT_CLI_VERSION", version) + "'\n")
    fmc.chmod(0o755)
    if env.get("NO_MODEL"):
        shutil.rmtree(app / "Contents/Resources/SFace.mlmodelc")
elif name == "lipo":
    print(env.get("BINARY_ARCHS", "x86_64 arm64"))
elif name == "xcrun":
    if args[0] == "notarytool":
        print(env.get("NOTARY_RESULT", '{"status":"Accepted","id":"submission-123"}'))
        fail_if("NOTARY_FAIL")
    elif args[0:2] == ["stapler", "staple"]:
        fail_if("STAPLE_FAIL")
    elif args[0:2] == ["stapler", "validate"]:
        fail_if("TICKET_FAIL")
    else:
        sys.exit("unexpected xcrun: " + repr(args))
elif name == "git":
    if args[0] == "-C":
        args = args[2:]
    if args == ["status", "--porcelain"]:
        print(" M changed" if env.get("DIRTY") else "", end="")
    elif args == ["rev-parse", "--abbrev-ref", "HEAD"]:
        print(env.get("BRANCH", "main"))
    elif "refs/tags/" in " ".join(args):
        sys.exit(0 if env.get("DUPLICATE_TAG") else 1)
    elif args == ["rev-parse", "origin/main"]:
        print("different" if env.get("UNSYNCED") else "commit-123")
    elif args == ["rev-parse", "HEAD"]:
        print("commit-123")
    elif args == ["rev-list", "--count", "HEAD"]:
        print("42")
    elif args[0] == "fetch":
        fail_if("FETCH_FAIL")
    else:
        sys.exit("unexpected git: " + repr(args))
elif name == "gh":
    if args[:2] == ["auth", "status"]:
        fail_if("AUTH_FAIL")
    elif args[:2] == ["release", "create"]:
        # Assert actual build outputs are passed as assets, not just plausible path strings.
        for asset in args[3:5]:
            if not Path(asset).is_file():
                sys.exit("missing release asset: " + asset)
        fail_if("UPLOAD_FAIL")
        Path(env["DRAFT"]).touch()
    elif args[:2] == ["release", "edit"]:
        if not Path(env["DRAFT"]).exists():
            sys.exit("release was not staged")
        fail_if("PUBLISH_FAIL")
        Path(env["DRAFT"]).unlink()
    else:
        sys.exit("unexpected gh: " + repr(args))
elif name == "mise":
    fail_if("TEST_FAIL")
else:
    sys.exit("unexpected stub: " + name)
