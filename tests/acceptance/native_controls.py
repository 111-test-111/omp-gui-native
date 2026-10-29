#!/usr/bin/env python3
"""Owner-requested manual native-controls inspection; not an automated check."""
import argparse
from datetime import datetime
from http.server import ThreadingHTTPServer
import hashlib
import json
import math
import os
from pathlib import Path
import shlex
import subprocess
import sys
import threading
import time
import uuid
from zoneinfo import ZoneInfo

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from native.rpc_provider import Provider
from support.build_inputs import verify
from support.resource_ledger import Ledger, webkit_processes, summary


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--omp", required=True, type=Path, help="Explicit real OMP executable, not a provider fixture")
    parser.add_argument("--language", choices=["en", "zh-Hans"], default="zh-Hans")
    parser.add_argument("--width", type=float, default=1320, help="Content width in points; production minimum is 860")
    parser.add_argument("--chat-math", action="store_true", help="Focused real-chat math/scroll inspection with fixed-rate local SSE")
    parser.add_argument("--selection-only", action="store_true", help="With --chat-math, inspect only an actually visible native math selection")
    args = parser.parse_args()
    if args.selection_only and not args.chat_math:
        parser.error("--selection-only requires --chat-math")
    binary = args.omp.expanduser().resolve()
    if not binary.is_file() or not os.access(binary, os.X_OK):
        parser.error("Provide an executable native OMP path")
    if not math.isfinite(args.width) or args.width < 860:
        parser.error("--width must be finite and at least 860 points")
    repo = Path(__file__).resolve().parents[2]
    try:
        evidence = verify(repo)
    except ValueError as error:
        parser.error(str(error))
    app = repo / "build.noindex/development/Build/Products/Debug/OMP GUI Dev.app"
    executable = app / "Contents/MacOS/OMP GUI Dev"
    if not executable.is_file():
        parser.error("Run make build first")
    output = repo / "build.noindex/native-controls-live" / (
        datetime.now(ZoneInfo("Asia/Hong_Kong")).strftime("%Y%m%d-%H%M%S-") + uuid.uuid4().hex[:8])
    output.mkdir(parents=True)
    profile = output / "profile/agent"
    profile.mkdir(parents=True)
    for name in ("workspace", "home", "tmp"):
        (output / name).mkdir()
    workspace = output / "workspace"
    (workspace / "Acceptance.txt").write_text("Fresh native-controls acceptance workspace.\n")
    subprocess.run(["git", "init", "-q", "-b", "main", str(workspace)], check=True)
    subprocess.run(["git", "-C", str(workspace), "add", "Acceptance.txt"], check=True)
    subprocess.run(["git", "-C", str(workspace), "-c", "user.name=OMP Acceptance",
                    "-c", "user.email=acceptance@localhost", "commit", "-qm", "Isolated native-controls fixture"], check=True)
    if Path(subprocess.check_output(["git", "-C", str(workspace), "rev-parse", "--show-toplevel"], text=True).strip()).resolve() != workspace.resolve():
        raise RuntimeError("Acceptance Git root must be the fresh workspace")
    (output / "empty-native-config.json").write_text("{}\n")
    provider = Provider
    if args.chat_math:
        from chat_math_provider import Provider as MathProvider
        provider = MathProvider
    server = ThreadingHTTPServer(("127.0.0.1", 0), provider)
    server.log_path = output / "provider-requests.jsonl"
    server.record_lock = threading.Lock()
    threading.Thread(target=server.serve_forever, daemon=True).start()
    models = dict(providers={"p5-local": dict(api="openai-completions",
                  baseUrl=f"http://127.0.0.1:{server.server_port}/v1", auth="none",
                  models=[dict(id="forward", contextWindow=4000000, maxTokens=1000000)])})
    (profile / "models.yml").write_text(json.dumps(models))
    (profile / "config.yml").write_text(
        "modelRoles:\n  default: p5-local/forward\ngoal:\n  continuationModes: []\n"
        "task:\n  isolation:\n    enabled: false\n  batch: false\n  structured: false\n  maxRecursionDepth: 1\n")
    # Reset again at the native boundary: the GUI's login shell may reintroduce
    # PI_/OMP_ values after the launch environment was sanitized. No environment
    # dump or external account/credential data is written to the report.
    native_environment = {
        "HOME": str(output / "home"), "PATH": os.environ.get("PATH", "/usr/bin:/bin"),
        "TMPDIR": str(output / "tmp"), "LANG": "en_US.UTF-8",
        "PI_CONFIG_DIR": str(output / "profile"), "PI_CODING_AGENT_DIR": str(profile),
        "PI_CONFIG_FILES": str(output / "empty-native-config.json"),
        "OMP_PROFILE": "default", "PI_PROFILE": "default",
    }
    wrapper = output / "omp-isolated.sh"
    command = ["/usr/bin/env", "-i", *(f"{key}={value}" for key, value in native_environment.items()),
               str(binary), "--no-extensions", "--no-skills", "--no-rules", "--no-lsp", "--no-pty"]
    wrapper.write_text("#!/bin/sh\nexec " + " ".join(shlex.quote(part) for part in command) + ' "$@"\n')
    wrapper.chmod(0o700)
    metadata = {
        "date": datetime.now(ZoneInfo("Asia/Hong_Kong")).isoformat(),
        "native_executable": str(binary), "wrapper": str(wrapper),
        "native_sha256": hashlib.sha256(binary.read_bytes()).hexdigest(),
        "language": args.language, "requested_content_width": args.width, "app_build": evidence,
        "revision": subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=repo, text=True).strip(),
        "driver_sha256": hashlib.sha256(Path(__file__).read_bytes()).hexdigest(),
        "provider_source_sha256": hashlib.sha256((repo / "tests/native/rpc_provider.py").read_bytes()).hexdigest(),
        "scope": "Manual Goal/side-question/Usage inspection on one production lead. Fresh GUI library and reset capture defaults suite; isolated native HOME/profile and deterministic loopback HTTP provider. No external account or resource workload.",
        "manual_result_scope": "finish confirms operator completion, not an automatically verified cycle count or visual result.",
    }
    if args.chat_math:
        metadata["scope"] = "Focused real-chat math: actual native OMP, production timeline, independent fixed-rate loopback SSE. Fresh isolated storage/profile; no external account."
        metadata["manual_result_scope"] = "math-checks.json contains local assertions; visual captures require inspection. Main heartbeat and cell draw callbacks do not measure GPU presentation."
        metadata["provider_source_sha256"] = hashlib.sha256((repo / "tests/acceptance/chat_math_provider.py").read_bytes()).hexdigest()
    process = None
    outcome = "failed"
    failure = None
    try:
        metadata["native_version"] = subprocess.check_output([str(wrapper), "--version"], text=True, timeout=15).strip()
        environment = {key: value for key, value in os.environ.items()
                       if not key.startswith(("PI_", "OMP_"))}
        environment.update(PI_CONFIG_DIR=str(output / "profile"), PI_CODING_AGENT_DIR=str(profile),
                           PI_CONFIG_FILES=str(output / "empty-native-config.json"),
                           OMP_PROFILE="default", PI_PROFILE="default")
        with (output / "stdout.log").open("w") as stdout, (output / "stderr.log").open("w") as stderr:
            # Direct launch gives this driver an exact process identity and a
            # controlled environment, rather than targeting a shared bundle ID.
            process = subprocess.Popen([str(executable), "-AppleLanguages", f"({args.language})",
                "--website-captures", str(output), "--omp-native-controls-acceptance",
                "--omp-executable", str(wrapper), "--omp-native-executable", str(binary),
                "--omp-window-width", str(args.width), *(["--omp-chat-math-acceptance"] if args.chat_math else []),
                *(["--omp-chat-math-selection-only"] if args.chat_math and args.selection_only else [])], cwd=output / "workspace", env=environment,
                stdout=stdout, stderr=stderr)
            metadata["gui_pid"] = process.pid
            (output / "run.json").write_text(json.dumps(metadata, ensure_ascii=False, indent=2) + "\n")
            print("Native controls output:", output, flush=True)
            print("Window: OMP Native Controls Acceptance; wait for phase ready before inspection.", flush=True)
            if args.chat_math and args.selection_only:
                print("Focused visible-selection capture; this instance finishes automatically.", flush=True)
            elif args.chat_math:
                print("At math-state needs-user-scroll, scroll up with real wheel input and create math-scrolled. At needs-sidebar-width-check, toggle the sidebar twice and create math-sidebar-checked. Other checks and finish are automatic.", flush=True)
            else:
                print("Manually check Refresh / Not set translations and 20 sheet open/close cycles; write notes in this output directory.", flush=True)
                print("Create finish within 600 seconds after ready to stop this instance; abort records a failure. Do not run another capture instance concurrently.", flush=True)
            previous = None
            ledger = Ledger({process.pid: "gui"}) if args.chat_math else None
            samples = []
            webkit_complete = True
            next_sample = 0
            deadline = time.monotonic() + 720
            while time.monotonic() < deadline:
                if ledger and time.monotonic() >= next_sample:
                    domain = webkit_processes(process.pid)
                    webkit_complete = webkit_complete and domain["complete"]
                    for root in domain["roots"]:
                        ledger.attach(root["pid"], "webkit-" + root["service"].split(".")[-1])
                    sample = ledger.sample()
                    sample["webkit_pid_domain_complete"] = domain["complete"]
                    try:
                        sample["phase"] = json.loads((output / "math-state.json").read_text())["phase"]
                    except (OSError, ValueError, KeyError):
                        sample["phase"] = "bootstrap"
                    samples.append(sample)
                    next_sample = time.monotonic() + 0.5
                try:
                    state = json.loads((output / "phase.json").read_text())
                except (FileNotFoundError, json.JSONDecodeError):
                    state = None
                if state and state != previous:
                    print(json.dumps(state, ensure_ascii=False), flush=True)
                    previous = state
                    if ledger and state.get("omp_pid"):
                        ledger.attach(state["omp_pid"], "omp")
                if state and state.get("phase") in ("completed", "failed"):
                    outcome = state["phase"]
                    failure = state.get("error")
                    process.wait(timeout=15)
                    break
                if process.poll() is not None:
                    raise RuntimeError("This GUI exited before writing a terminal phase")
                time.sleep(0.25)
            else:
                raise RuntimeError("Launcher deadline exceeded before a terminal phase")
    except (OSError, subprocess.SubprocessError, RuntimeError, KeyboardInterrupt) as error:
        outcome = "failed"
        failure = str(error) or type(error).__name__
    finally:
        if args.chat_math and 'samples' in locals():
            (output / "math-resources.json").write_text(json.dumps(dict(
                webkit_pid_domain_complete=webkit_complete, summary=summary(samples), samples=samples), indent=2) + "\n")
        if process is not None and process.poll() is None:
            (output / "abort").write_text("Launcher requested explicit acceptance shutdown.\n")
            try:
                process.wait(timeout=10)
            except subprocess.TimeoutExpired:
                # Only the child created above is eligible for fallback cleanup.
                process.terminate()
                try:
                    process.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    failure = (failure or "") + " Own GUI did not exit after SIGTERM; process was not force-killed."
        server.shutdown()
        server.server_close()
        metadata.update(status=outcome, returncode=process.returncode if process else None,
                        provider_requests=sum(1 for _ in server.log_path.open()) if server.log_path.exists() else 0)
        if failure:
            metadata["error"] = failure
        (output / "run.json").write_text(json.dumps(metadata, ensure_ascii=False, indent=2) + "\n")
    print("Result:", output / "run.json", flush=True)
    raise SystemExit(0 if outcome == "completed" and failure is None and process is not None and process.returncode == 0 else 1)


if __name__ == "__main__":
    main()
