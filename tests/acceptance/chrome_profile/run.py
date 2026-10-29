#!/usr/bin/env python3
"""Manual Chrome/CEF migration research; --run authorizes isolated browser processes only."""
import argparse
from datetime import datetime
import os
from pathlib import Path
import plistlib
import shutil
import signal
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[3]
WORK = ROOT / "build.noindex/chrome-profile"

sys.path.insert(0, str(ROOT / "tests"))
from support.local_build import clear_generated_quarantine, swiftpm_environment


def prepare():
    # Uses the same reviewed wrapper and CEF distribution as the GUI. No app
    # target is rebuilt: production sources/resources are unchanged by this study.
    subprocess.run(["python3", str(ROOT / "scripts/browser_runtime.py"), "prepare"], check=True)
    package = WORK / "package"
    shutil.copytree(Path(__file__).parent / "Sources", package / "Sources", dirs_exist_ok=True)
    shutil.copy2(Path(__file__).parent / "Package.swift", package / "Package.swift")
    subprocess.run(["swift", "build", "--package-path", str(package), "--scratch-path", str(WORK / "build"),
                    "-c", "debug", "--product", "OMPChromeProfileProbe", "--arch", "arm64"], check=True,
                   env=dict(os.environ, **swiftpm_environment(ROOT, WORK / "tmp")))
    app = WORK / "OMP GUI Chrome Profile Probe.app"
    executable = "OMPChromeProfileProbe"
    (app / "Contents/MacOS").mkdir(parents=True, exist_ok=True)
    (app / "Contents/Resources").mkdir(exist_ok=True)
    shutil.copy2(WORK / "build/debug" / executable, app / "Contents/MacOS" / executable)
    info = {"CFBundleExecutable": executable, "CFBundleIdentifier": "dev.ompgui.mac.dev.chrome-profile-probe",
            "CFBundleName": "OMP GUI Chrome Profile Probe", "CFBundlePackageType": "APPL", "CFBundleVersion": "1",
            "CFBundleShortVersionString": "1", "LSUIElement": True, "LSMinimumSystemVersion": "26.0",
            "NSHighResolutionCapable": True, "LSEnvironment": {"MallocNanoZone": "0"}}
    (app / "Contents/Info.plist").write_bytes(plistlib.dumps(info))
    env = dict(os.environ, TARGET_BUILD_DIR=str(WORK), FULL_PRODUCT_NAME=app.name, EXECUTABLE_NAME=executable,
               PRODUCT_BUNDLE_IDENTIFIER=info["CFBundleIdentifier"], CODE_SIGNING_ALLOWED="NO")
    subprocess.run(["python3", str(ROOT / "scripts/browser_runtime.py"), "embed"], check=True, env=env)
    clear_generated_quarantine(ROOT, app)
    return app / "Contents/MacOS" / executable


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--run", action="store_true")
    parser.add_argument("--skip-build", action="store_true")
    parser.add_argument("--case", choices=("all", "transfer", "database"), default="all")
    parser.add_argument("--inspect-run", type=Path, help="Existing isolated transfer run, for the database-only diagnostic")
    parser.add_argument("--chrome", type=Path, default=Path("/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"))
    args = parser.parse_args()
    if (args.case == "database") != (args.inspect_run is not None):
        parser.error("Database inspection requires --case database --inspect-run <owned run>")
    binary = WORK / "OMP GUI Chrome Profile Probe.app/Contents/MacOS/OMPChromeProfileProbe" if args.skip_build else prepare()
    if not args.run:
        print(f"Prepared isolated probe: {binary}")
        return
    if not binary.is_file() or not args.chrome.is_file():
        parser.error("The prepared probe and installed Chrome executable are required")
    output = args.inspect_run.resolve() if args.inspect_run else WORK / "runs" / datetime.now().strftime("%Y%m%d-%H%M%S-%f")
    if not output.is_relative_to(WORK / "runs"):
        parser.error("Only this worktree's isolated runs may be inspected")
    output.mkdir(parents=True, exist_ok=args.case == "database")
    env = {k: v for k, v in os.environ.items() if not k.startswith(("OMP_", "PI_", "CEF_", "PROFILE_PROBE_"))}
    env["MallocNanoZone"] = "0"
    command = ["node", str(Path(__file__).with_name("migration_tests.mjs")), str(output), str(binary), str(args.chrome), args.case]
    process = subprocess.Popen(command, env=env, cwd=ROOT, start_new_session=True)
    try:
        code = process.wait(timeout=240)
    except (subprocess.TimeoutExpired, KeyboardInterrupt):
        os.killpg(process.pid, signal.SIGTERM)
        try:
            process.wait(timeout=5)
        except subprocess.TimeoutExpired:
            os.killpg(process.pid, signal.SIGKILL)
            process.wait()
        raise
    if code:
        raise SystemExit(code)
    print(f"Chrome profile evaluation: {output}")


if __name__ == "__main__":
    main()
