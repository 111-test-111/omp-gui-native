#!/usr/bin/env python3
"""Prepare the pinned CEF source/binary and embed it before Xcode signs the app.

All generated files stay inside this checkout's build.noindex. This does not
launch, package or install an app. The upstream bundler's ad-hoc signing is not
used: signed builds retain Developer ID, hardened runtime and secure timestamps.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import plistlib
import re
import shutil
import subprocess
import urllib.parse
import sys

ROOT = Path(__file__).resolve().parents[1]
CACHE = ROOT / "build.noindex/browser"
CONFIG = ROOT / "config/browser"
PACKAGE = CACHE / "dependencies/CefSwift"
FRAMEWORK = "Chromium Embedded Framework.framework"

sys.path.insert(0, str(ROOT / "tests"))
from support.local_build import clear_generated_quarantine, swiftpm_environment


def run(*args, **kwargs):
    subprocess.run([str(a) for a in args], check=True, **kwargs)


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def prepare():
    CACHE.mkdir(parents=True, exist_ok=True)
    pin = json.loads((CONFIG / "sources.json").read_text())["cefSwiftRevision"]
    source = CACHE / "upstream"
    if not source.exists():
        run("git", "clone", "https://github.com/Rajaniraiyn/CefSwift.git", source)
        run("git", "checkout", "--detach", pin, cwd=source)
    revision = subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=source, text=True).strip()
    if revision != pin or subprocess.check_output(["git", "status", "--porcelain"], cwd=source).strip():
        raise RuntimeError("CEF source differs from the reviewed pin; restore the build cache first")
    patch = CONFIG / "cefswift.patch"
    fingerprint = pin + ":" + sha(patch)
    marker = PACKAGE / "omp-gui-source.json"
    patched_paths = re.findall(r"^\+\+\+ b/(.+)$", patch.read_text(), re.MULTILINE)
    try:
        record = json.loads(marker.read_text())
        valid = record["fingerprint"] == fingerprint and all(sha(PACKAGE / p) == record["files"][p] for p in patched_paths)
    except (OSError, ValueError, KeyError):
        valid = False
    if not valid:
        if PACKAGE.exists():
            shutil.rmtree(PACKAGE)
        shutil.copytree(source, PACKAGE, ignore=shutil.ignore_patterns(".git", ".build", ".cef"))
        # git apply inside a Git-ignored subtree can silently skip patch paths
        # relative to the parent repository. patch always uses this exact cwd.
        run("/usr/bin/patch", "--batch", "-p1", "-i", patch, cwd=PACKAGE)
        marker.write_text(json.dumps({"fingerprint": fingerprint, "files": {p: sha(PACKAGE / p) for p in patched_paths}}))
    manifest = json.loads((PACKAGE / "CEF_VERSION.json").read_text())
    artifact = manifest["platforms"]["macosarm64"]["minimal"]
    archive = CACHE / artifact["name"]
    dist = CACHE / "distribution"
    if not (dist / ".complete").exists() or (dist / ".complete").read_text() != artifact["sha1"]:
        if not archive.exists():
            url = "https://cef-builds.spotifycdn.com/" + urllib.parse.quote(artifact["name"])
            run("curl", "--fail", "--location", "--retry", "3", "--output", archive, url)
        if archive.stat().st_size != artifact["size"] or hashlib.sha1(archive.read_bytes()).hexdigest() != artifact["sha1"]:
            raise RuntimeError("CEF archive checksum mismatch; remove the corrupt archive and retry")
        if dist.exists():
            shutil.rmtree(dist)
        dist.mkdir()
        run("tar", "xjf", archive, "-C", dist, "--strip-components", "1")
        framework = dist / "Release" / FRAMEWORK
        version = framework / "Versions/A"
        version.mkdir(parents=True)
        for entry in ["Chromium Embedded Framework", "Libraries", "Resources"]:
            (framework / entry).rename(version / entry)
            (framework / entry).symlink_to("Versions/A/" + entry)
        (framework / "Versions/Current").symlink_to("A")
        (dist / ".complete").write_text(artifact["sha1"])
    # SwiftPM is incremental; the helper uses the same patched wrapper as Xcode.
    run("swift", "build", "--package-path", PACKAGE, "--scratch-path", CACHE / "helper",
        "--configuration", "release", "--product", "cef-helper", "--arch", "arm64",
        env=dict(os.environ, **swiftpm_environment(ROOT, CACHE / "tmp")))
    clear_generated_quarantine(ROOT, CACHE / "helper/release/cef-helper")


def embed():
    app = Path(os.environ["TARGET_BUILD_DIR"]) / os.environ["FULL_PRODUCT_NAME"]
    frameworks = app / "Contents/Frameworks"
    frameworks.mkdir(parents=True, exist_ok=True)
    source = CACHE / "distribution/Release" / FRAMEWORK
    helper_binary = CACHE / "helper/release/cef-helper"
    if not source.exists() or not helper_binary.exists():
        raise RuntimeError("Run python3 scripts/browser_runtime.py prepare before opening Xcode")
    target = frameworks / FRAMEWORK
    # rsync preserves symlinks and doesn't copy an unchanged 500 MB framework.
    run("rsync", "-a", "--delete", str(source) + "/", str(target) + "/")
    name = os.environ["EXECUTABLE_NAME"]
    identifier = os.environ["PRODUCT_BUNDLE_IDENTIFIER"]
    helpers = []
    for suffix in ["", "Alerts", "GPU", "Plugin", "Renderer"]:
        helper_name = name + " Helper" + (f" ({suffix})" if suffix else "")
        helper = frameworks / (helper_name + ".app")
        binary = helper / "Contents/MacOS" / helper_name
        binary.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(helper_binary, binary)
        info = {"CFBundleExecutable": helper_name, "CFBundleName": helper_name,
                "CFBundleIdentifier": identifier + ".helper" + ("." + suffix.lower() if suffix else ""),
                "CFBundlePackageType": "APPL", "CFBundleVersion": "1", "CFBundleShortVersionString": "1",
                "LSUIElement": True, "LSMinimumSystemVersion": "26.0", "NSHighResolutionCapable": True,
                "LSFileQuarantineEnabled": True}
        (helper / "Contents/Info.plist").write_bytes(plistlib.dumps(info))
        helpers.append(helper)
    resources = app / "Contents/Resources"
    shutil.copy2(PACKAGE / "LICENSE", resources / "LICENSE-CefSwift.txt")
    shutil.copy2(CACHE / "distribution/LICENSE.txt", resources / "LICENSE-CEF.txt")
    if os.environ.get("CODE_SIGNING_ALLOWED") != "NO":
        identity = os.environ.get("EXPANDED_CODE_SIGN_IDENTITY", "")
        if not identity or identity == "-":
            raise RuntimeError("Signed CEF builds require the project's Developer ID identity")
        def sign(path, entitlements=None):
            args = ["codesign", "--force", "--sign", identity, "--options", "runtime", "--timestamp"]
            if entitlements:
                args += ["--entitlements", entitlements]
            run(*args, path)
        for library in sorted((target / "Versions/A/Libraries").glob("*.dylib")):
            sign(library)
        sign(target)
        for helper in helpers:
            sign(helper, CONFIG / "helper.entitlements")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("action", choices=["prepare", "embed"])
    globals()[parser.parse_args().action]()
