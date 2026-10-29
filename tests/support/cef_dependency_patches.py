"""Reproducible, version-guarded dependency repairs for the isolated CEF host."""
import hashlib
import json
import shutil
import subprocess


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def prepare(source, destination, patch, inputs, version):
    for relative in inputs:
        if digest(source / relative) != inputs[relative]["sha256"]:
            raise RuntimeError(f"Dependency input changed; review patch before use: {source / relative}")
    fingerprint = {"version": version, "patchSHA256": digest(patch), "source": str(source.resolve())}
    marker = destination / "omp-gui-patch.json"
    if marker.exists() and json.loads(marker.read_text()) == fingerprint:
        subprocess.run(["git", "apply", "--reverse", "--check", str(patch)], cwd=destination, check=True)
        return fingerprint
    if destination.exists():
        shutil.rmtree(destination)
    shutil.copytree(source, destination, symlinks=True,
                    ignore=shutil.ignore_patterns(".git", ".build", ".cef", "node_modules"))
    if (source / "node_modules").is_dir():
        (destination / "node_modules").symlink_to((source / "node_modules").resolve(), target_is_directory=True)
    subprocess.run(["git", "apply", "--check", str(patch)], cwd=destination, check=True)
    subprocess.run(["git", "apply", str(patch)], cwd=destination, check=True)
    marker.write_text(json.dumps(fingerprint, indent=2) + "\n")
    return fingerprint


def prepare_cef(root, patches):
    sources = json.loads((patches / "sources.json").read_text())
    source = root / "CefSwift"
    if not source.exists():
        subprocess.run(["git", "clone", "https://github.com/Rajaniraiyn/CefSwift.git", str(source)], check=True)
        subprocess.run(["git", "checkout", "--detach", sources["cefSwiftRevision"]], cwd=source, check=True)
    revision = subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=source, text=True).strip()
    if revision != sources["cefSwiftRevision"]:
        raise RuntimeError("CefSwift source checkout does not match the pinned revision")
    destination = root / "dependencies/CefSwift"
    fingerprint = prepare(source, destination, patches / "cefswift-cdp-dialogs.patch",
                          {k: v for k, v in sources["inputs"].items() if k.startswith("Sources/")}, revision)
    return destination, fingerprint


def prepare_omp(root, source, patches):
    sources = json.loads((patches / "sources.json").read_text())
    version = json.loads((source / "package.json").read_text())["version"]
    if version != sources["ompVersion"]:
        raise RuntimeError(f"The OMP repair is scoped to {sources['ompVersion']}; review it for this installed version")
    destination = root / "dependencies/omp-sdk"
    fingerprint = prepare(source, destination, patches / "omp-browser-repairs.patch",
                          {k: v for k, v in sources["inputs"].items() if k.startswith("src/")}, version)
    return destination, fingerprint
