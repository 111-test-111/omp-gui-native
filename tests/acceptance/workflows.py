#!/usr/bin/env python3
"""Owner-requested GUI/native-model acceptance. Never runs from make build."""
import argparse
import base64
from datetime import datetime
import hashlib
import json
from pathlib import Path
import shlex
import shutil
import subprocess
import time
import uuid
from zoneinfo import ZoneInfo
import sys
sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from support.build_inputs import verify


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--omp", default=shutil.which("omp"))
    parser.add_argument("--model", required=True)
    args = parser.parse_args()
    if not args.omp or not Path(args.omp).is_file():
        parser.error("Provide the installed OMP executable")
    repo = Path(__file__).resolve().parents[2]
    try:
        verify(repo)
    except ValueError as error:
        parser.error(str(error))
    app = repo / "build.noindex/development/Build/Products/Debug/OMP GUI Dev.app"
    if not app.exists():
        parser.error("Run make build first")
    output = repo / "build.noindex/omp-workflow-live" / (datetime.now(ZoneInfo("Asia/Hong_Kong")).strftime("%Y%m%d-%H%M%S-") + uuid.uuid4().hex[:8])
    workspace = output / "workspace"
    workspace.mkdir(parents=True)
    (workspace / "Acceptance.txt").write_text("native-original\n")
    subprocess.run(["git", "init", "-q", str(workspace)], check=True)
    subprocess.run(["git", "-C", str(workspace), "add", "Acceptance.txt"], check=True)
    subprocess.run(["git", "-C", str(workspace), "-c", "user.name=OMP Acceptance", "-c", "user.email=acceptance@localhost", "commit", "-qm", "Scratch acceptance baseline"], check=True)
    (output / "image.png").write_bytes(base64.b64decode("iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+j5WQAAAAASUVORK5CYII="))
    config = output / "native-test-config.yml"
    config.write_text("compaction:\n  keepRecentTokens: 128\n")
    wrapper = output / "omp-acceptance.sh"
    wrapper.write_text('#!/bin/sh\nexport PI_CONFIG_FILES="${PI_CONFIG_FILES:+${PI_CONFIG_FILES}:}"' + shlex.quote(str(config)) + "\nexec " + shlex.quote(str(Path(args.omp).resolve())) + ' --tools read,bash --no-extensions --no-skills --no-rules --no-lsp --no-pty "$@"\n')
    wrapper.chmod(0o700)
    metadata = dict(date=datetime.now(ZoneInfo("Asia/Hong_Kong")).isoformat(),
                    native_version=subprocess.check_output([args.omp, "--version"], text=True).strip(),
                    model=args.model, process_overrides={"compaction.keepRecentTokens": 128}, revision=subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=repo, text=True).strip(),
                    scope="Actual GUI and installed native model. Fresh GUI storage, defaults, session files and scratch Git checkout. OMP reads its active native authentication; the GUI does not copy credentials or change the profile.")
    (output / "run.json").write_text(json.dumps(metadata, ensure_ascii=False, indent=2) + "\n")
    subprocess.run(["/usr/bin/open", "-n", "-a", str(app), "--stdout", str(output / "stdout.log"), "--stderr", str(output / "stderr.log"),
                    "--args", "-AppleLanguages", "(zh-Hans)", "--website-captures", str(output),
                    "--omp-workflow-acceptance", "--omp-executable", str(wrapper), "--omp-model", args.model], check=True)
    print("Acceptance output:", output, flush=True)
    print("GUI inspection markers: continue then finish; only this isolated instance exits.", flush=True)
    previous = None
    deadline = time.monotonic() + 2400
    while time.monotonic() < deadline:
        try:
            state = json.loads((output / "phase.json").read_text())
        except (FileNotFoundError, json.JSONDecodeError):
            time.sleep(0.2)
            continue
        if state != previous:
            print(json.dumps(state, ensure_ascii=False), flush=True)
            previous = state
        if state["phase"] in ("completed", "failed"):
            dylib = app / "Contents/MacOS/OMP GUI Dev.debug.dylib"
            metadata["dylib_sha256"] = hashlib.sha256(dylib.read_bytes()).hexdigest()
            metadata["driver_sha256"] = hashlib.sha256(Path(__file__).read_bytes()).hexdigest()
            (output / "run.json").write_text(json.dumps(metadata, ensure_ascii=False, indent=2) + "\n")
            if state["phase"] == "failed":
                raise SystemExit(1)
            return
        time.sleep(0.25)
    raise SystemExit("Acceptance timed out; no unrelated process was stopped")


if __name__ == "__main__":
    main()
