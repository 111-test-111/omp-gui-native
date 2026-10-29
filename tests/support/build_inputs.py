"""Record/verify the source and binary used by app-linked checks. Never builds."""
import argparse
import hashlib
import json
from pathlib import Path


PRODUCTS = Path("build.noindex/development/Build/Products/Debug")
LIBRARY = PRODUCTS / "OMP GUI Dev.app/Contents/MacOS/OMP GUI Dev.debug.dylib"
RECORD = Path("build.noindex/development/verification-inputs.json")


def digest_files(repo, paths):
    digest = hashlib.sha256()
    files = set()
    for path in paths:
        path = Path(path)
        if not path.is_absolute():
            path = repo / path
        if path.is_dir():
            files.update(p for p in path.rglob("*") if p.is_file() and "__pycache__" not in p.parts)
        elif path.is_file():
            files.add(path)
        else:
            raise ValueError(f"Missing verification input: {path}")
    for path in sorted(files):
        label = str(path.relative_to(repo)) if path.is_relative_to(repo) else str(path)
        digest.update(label.encode() + b"\0" + path.read_bytes() + b"\0")
    return digest.hexdigest()


def source_digest(repo):
    # Only inputs to the app build: test/docs changes do not invalidate it.
    paths = ["OMPGUI", "OMPGUI.entitlements", "config", "project.yml", "scripts/develop.sh", "scripts/browser_runtime.py",
             "tests/support/local_build.py", "OMPGUI.xcodeproj/project.pbxproj"]
    paths += [str(path.relative_to(repo)) for path in (repo / "OMPGUI.xcodeproj").rglob("*.xcscheme")
              if "xcuserdata" not in path.parts]
    paths += [str(path.relative_to(repo)) for path in (repo / "OMPGUI.xcodeproj").rglob("Package.resolved")]
    return digest_files(repo, paths)


def record(repo, expected_source):
    # Compare with the pre-build snapshot so concurrent edits cannot certify a
    # binary whose inputs changed while xcodebuild was reading them.
    actual = source_digest(repo)
    if actual != expected_source:
        raise ValueError("App inputs changed during build; run make build after edits settle.")
    payload = {"schema": 1, "source_sha256": actual, "binary_sha256": digest_files(repo, (LIBRARY,))}
    target = repo / RECORD
    target.parent.mkdir(parents=True, exist_ok=True)
    target.write_text(json.dumps(payload, indent=2) + "\n")
    return payload


def verify(repo):
    try:
        payload = json.loads((repo / RECORD).read_text())
        valid = (payload["schema"] == 1 and payload["source_sha256"] == source_digest(repo)
                 and payload["binary_sha256"] == digest_files(repo, (LIBRARY,)))
    except (OSError, ValueError, KeyError):
        valid = False
    if not valid:
        raise ValueError("Missing/stale Dev build evidence in this worktree. Run make build once before app-linked checks.")
    return payload


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--record", metavar="PRE_BUILD_SHA256")
    args = parser.parse_args()
    repo = Path(__file__).resolve().parents[2]
    if args.record:
        record(repo, args.record)
    else:
        print(source_digest(repo))


if __name__ == "__main__":
    main()
