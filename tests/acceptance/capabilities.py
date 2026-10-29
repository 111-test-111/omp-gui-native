#!/usr/bin/env python3
"""Explicitly requested P3/P4 native GUI acceptance in fresh isolated storage."""
import argparse
from datetime import datetime
import hashlib
import json
import os
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
    parser.add_argument("--model", default="kimi-code/k3")
    parser.add_argument("--p4-only", action="store_true", help="Run P4 separately after P3 has already passed")
    args = parser.parse_args()
    repo = Path(__file__).resolve().parents[2]
    try:
        verify(repo)
    except ValueError as error:
        parser.error(str(error))
    app = repo / "build.noindex/development/Build/Products/Debug/OMP GUI Dev.app"
    if not args.omp or not app.exists():
        parser.error("Require installed OMP and make build")
    output = repo / "build.noindex/omp-capability-live" / (datetime.now(ZoneInfo("Asia/Hong_Kong")).strftime("%Y%m%d-%H%M%S-") + uuid.uuid4().hex[:8])
    profile = output / "native-config/agent"
    profile.mkdir(parents=True)
    (output / "results").mkdir()
    (profile / "config.yml").write_text("modelRoles:\n  default: omp-gui-bootstrap/acceptance\n  future-role: preserve/me\ntask:\n  agentModelOverrides:\n    acceptance: omp-gui-bootstrap/acceptance\n  disabledAgents: [disabled-acceptance]\nfutureAcceptance: preserved\n")
    plugin = output / "local-plugin"
    plugin.mkdir()
    (plugin / "package.json").write_text(json.dumps({"name": "omp-gui-local-acceptance", "version": "1.0.0", "omp": {"extensions": ["extension.ts"]}}))
    shutil.copyfile(repo / "tests/fixtures/omp/capability_extension.ts", plugin / "extension.ts")
    workspace = output / "workspace"
    workspace.mkdir()
    (workspace / "Source.txt").write_text("first line\n原生上下文🙂 P4_SELECTED_FACT\nlast line\n")
    subprocess.run(["git", "init", "-q", str(workspace)], check=True)
    subprocess.run(["git", "-C", str(workspace), "add", "Source.txt"], check=True)
    subprocess.run(["git", "-C", str(workspace), "-c", "user.name=OMP Acceptance", "-c", "user.email=acceptance@localhost", "commit", "-qm", "Synthetic acceptance baseline"], check=True)
    linked = output / "linked-source"
    subprocess.run(["git", "-C", str(workspace), "worktree", "add", "-q", "--detach", str(linked), "HEAD"], check=True)
    agents = workspace / ".omp/agents"
    agents.mkdir(parents=True)
    (agents / "acceptance.md").write_text("---\nname: acceptance\ndescription: Local read-only OMP GUI acceptance worker\nmodel: " + args.model + "\nthinkingLevel: off\ntools: [read, bash]\nspawns: none\nprewalk: false\n---\nThis is an isolated synthetic acceptance. Follow the task exactly. Never modify files or delegate.\n")
    native = shlex.quote(str(Path(args.omp).resolve()))
    p3 = output / "omp-p3.sh"
    # OMP's plugin config directory is HOME-relative; its agent directory is absolute.
    p3.write_text("#!/bin/sh\nexport PI_CONFIG_DIR=" + shlex.quote(os.path.relpath(profile.parent, Path.home())) + "\nexport PI_CODING_AGENT_DIR=" + shlex.quote(str(profile)) + "\nexport OMP_PROFILE=default PI_PROFILE=default\nexport OMP_GUI_ACCEPTANCE_RESULTS=" + shlex.quote(str(output / "results")) + "\nunset PI_CONFIG_FILES\nexec " + native + ' --no-skills --no-rules --no-lsp --no-pty "$@"\n')
    config = output / "p4-overlay.yml"
    config.write_text("task:\n  isolation:\n    enabled: true\n    apply: false\n  batch: false\n  eager: default\n  maxRecursionDepth: 1\n  disabledAgents: []\n")
    p4 = output / "omp-p4.sh"
    p4.write_text('#!/bin/sh\nexport PI_CONFIG_FILES="${PI_CONFIG_FILES:+${PI_CONFIG_FILES}:}"' + shlex.quote(str(config)) + "\nexport OMP_WORKTREE_DIR=" + shlex.quote(str(output / "native-worktrees")) + "\nexec " + native + ' --no-extensions --no-skills --no-rules --no-lsp --no-pty "$@"\n')
    for wrapper in [p3, p4]:
        wrapper.chmod(0o700)
    metadata = {"date": datetime.now(ZoneInfo("Asia/Hong_Kong")).isoformat(), "native_version": subprocess.check_output([args.omp, "--version"], text=True).strip(), "model": args.model, "p4_only": args.p4_only,
                "scope": "P3 local self-authored plugin and synthetic OAuth in an isolated native profile; P4 actual existing provider authentication read by OMP, with scratch checkout and separate GUI storage.",
                "dylib_sha256": hashlib.sha256((app / "Contents/MacOS/OMP GUI Dev.debug.dylib").read_bytes()).hexdigest()}
    (output / "run.json").write_text(json.dumps(metadata, ensure_ascii=False, indent=2) + "\n")
    subprocess.run(["open", "-n", "-a", str(app), "--stdout", str(output / "stdout.log"), "--stderr", str(output / "stderr.log"), "--args", "-AppleLanguages", "(zh-Hans)", "--website-captures", str(output), "--omp-capability-acceptance", "--omp-p3", str(p3), "--omp-p4", str(p4), "--omp-model", args.model] + (["--p4-only"] if args.p4_only else []), check=True)
    print("Acceptance output:", output, flush=True)
    previous = None
    deadline = time.monotonic() + 3600
    while time.monotonic() < deadline:
        try:
            state = json.loads((output / "phase.json").read_text())
        except (FileNotFoundError, json.JSONDecodeError):
            time.sleep(0.25)
            continue
        if state != previous:
            print(json.dumps(state, ensure_ascii=False), flush=True)
            previous = state
        if state["phase"] in ("completed", "failed"):
            raise SystemExit(0 if state["phase"] == "completed" else 1)
        time.sleep(0.25)
    raise SystemExit("Acceptance timed out; no unrelated process was stopped")


if __name__ == "__main__":
    main()
