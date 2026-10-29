#!/usr/bin/env python3
"""Explicit GUI verification launch. Requires owner authorization; never runs from make build."""
import argparse
from datetime import datetime
from zoneinfo import ZoneInfo
import hashlib
import json
from pathlib import Path
import platform
import re
import shutil
import statistics
import subprocess
import time
import uuid
import sys
sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from support import resource_ledger as resources
from support.build_inputs import verify


def summarize(samples):
    result = resources.summary(samples)
    gui = result["cpu_observations"].get("gui")
    result["gui_cpu_percent_of_one_core"] = 100 * gui["cpu_seconds"] / gui["observed_process_seconds"] if gui and gui["observed_process_seconds"] else None
    totals = [s["physical_bytes"] for s in samples if s["physical_bytes"] is not None]
    result["median_physical_bytes"] = statistics.median(totals) if totals else None
    result["median_gui_bytes"] = statistics.median(s["groups"]["gui"]["physical_bytes"] for s in samples if "gui" in s["groups"]) if any("gui" in s["groups"] for s in samples) else None
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--omp", default=shutil.which("omp"))
    parser.add_argument("--language", choices=["en", "zh-Hans"], default="zh-Hans")
    parser.add_argument("--p5-forward", action="store_true", help="Generate only fresh segmented history; leave all existing conversations untouched")
    parser.add_argument("--preview-smoke", action="store_true", help="Diagnose preview lifecycle without idle timing phases; not a resource benchmark")
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
    output = repo / ("build.noindex/omp-p5-live" if args.p5_forward else "build.noindex/omp-p0-live") / (datetime.now().strftime("%Y%m%d-%H%M%S-") + uuid.uuid4().hex[:8])
    output.mkdir(parents=True)
    if args.p5_forward:
        workspace = output / "workspace"
        workspace.mkdir()
        mcp = {"mcpServers": {"p5": {"command": shutil.which("python3"), "args": [str(repo / "tests/fixtures/omp/mcp.py"), str(output / "mcp-events.jsonl")], "enabled": True}}}
        (workspace / ".mcp.json").write_text(json.dumps(mcp))
        subprocess.run(["git", "init", "-q", "-b", "main", str(workspace)], check=True)
        subprocess.run(["git", "-C", str(workspace), "add", ".mcp.json"], check=True)
        subprocess.run(["git", "-C", str(workspace), "-c", "user.name=OMP Acceptance", "-c", "user.email=acceptance@localhost", "commit", "-qm", "Isolated synthetic resource fixture"], check=True)
    before_webkit = {pid for pid, row in resources.process_table().items() if row["executable"].startswith("com.apple.WebKit.")}
    subprocess.run(["/usr/bin/open", "-n", "-a", str(app), "--env", "OMP_GUI_PERFORMANCE=1",
                    "--stdout", str(output / "stdout.log"), "--stderr", str(output / "stderr.log"),
                    "--args", "-AppleLanguages", f"({args.language})", "--website-captures", str(output),
                    "--omp-performance-check", "--omp-executable", str(Path(args.omp).absolute())] + (["--omp-p5-forward"] if args.p5_forward else []) + (["--omp-preview-smoke"] if args.preview_smoke else []), check=True)
    print("Live verification:", output, flush=True)
    print("During inspection, create the run's finish file to complete verification and quit this instance.", flush=True)
    ledger = None
    phase = None
    samples = []
    metadata = []
    attempted_webkit = set()
    ownership = []
    ownership_checks = []
    deadline = time.monotonic() + 720
    while time.monotonic() < deadline:
        try:
            state = json.loads((output / "phase.json").read_text())
        except (FileNotFoundError, json.JSONDecodeError):
            time.sleep(0.2)
            continue
        if ledger is None:
            ledger = resources.Ledger({state["gui_pid"]: "gui"})
        if "omp_pid" in state:
            ledger.attach(state["omp_pid"], "omp")
        if args.p5_forward and (output / "mcp-events.jsonl").exists():
            for line in (output / "mcp-events.jsonl").read_text().splitlines():
                row = json.loads(line)
                if row.get("event") == "start":
                    ledger.attach(row["pid"], "mcp")
        if state["phase"] != phase:
            phase = state["phase"]
            metadata.append(state)
            print("Phase:", phase, flush=True)
        if args.p5_forward:
            verified = resources.webkit_processes(state["gui_pid"])
            ownership_checks.append(dict(phase=phase, complete=verified["complete"]))
            for row in verified["roots"]:
                if row["pid"] not in attempted_webkit:
                    attempted_webkit.add(row["pid"])
                    ownership.append(row)
                ledger.attach(row["pid"], "webkit")
        # Verify XPC ownership outside measured phases. A new WebKit process
        # alone is not evidence that it belongs to this application.
        if not args.p5_forward and phase in ("warm-settle", "after-settle", "inspection"):
            for pid, row in resources.process_table().items():
                if pid in before_webkit or pid in attempted_webkit or not row["executable"].startswith("com.apple.WebKit."):
                    continue
                attempted_webkit.add(pid)
                destination = output / f"webkit-owner-{pid}.txt"
                try:
                    subprocess.run(["/usr/bin/sample", str(pid), "1", "10", "-file", str(destination)], capture_output=True, timeout=8)
                    data = destination.read_text()
                except (OSError, subprocess.TimeoutExpired):
                    continue
                match = re.search(r"^Responsible:\s+.*\[(\d+)\]", data, re.MULTILINE)
                if match and int(match.group(1)) == state["gui_pid"]:
                    ledger.attach(pid, "webkit")
                    ownership.append(dict(pid=pid, method="sample Responsible PID", responsible_pid=int(match.group(1))))
        sample = ledger.sample()
        sample["phase"] = phase
        if args.p5_forward:
            sample["webkit_enumeration_complete"] = verified["complete"]
            if not verified["complete"]:
                sample["physical_bytes"] = None
        samples.append(sample)
        if phase in ("completed", "failed"):
            break
        if state["gui_pid"] in sample["absent_roots"]:
            # The app can write its terminal phase and exit between our read
            # and the process sample. Do not misreport a completed run as lost.
            latest = json.loads((output / "phase.json").read_text())
            if latest["phase"] in ("completed", "failed"):
                phase = latest["phase"]
                metadata.append(latest)
            else:
                print("GUI exited before completion", flush=True)
            break
        time.sleep(0.2)
    else:
        print("Verification budget expired; report is incomplete. The launcher does not kill an unverified PID.", flush=True)
    groups = {name: summarize([s for s in samples if s["phase"] == name]) for name in dict.fromkeys(s["phase"] for s in samples)}
    report = dict(schema=1, workload="omp-p5-preview-smoke" if args.preview_smoke else ("omp-p5-forward-v2" if args.p5_forward else "omp-p0-live-v2"), date=datetime.now(ZoneInfo("Asia/Hong_Kong")).isoformat(), os=platform.mac_ver()[0],
                  hardware=subprocess.check_output(["/usr/sbin/sysctl", "-n", "hw.model"], text=True).strip(),
                  revision=subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=repo, text=True).strip(),
                  dirty=bool(subprocess.check_output(["git", "status", "--porcelain"], cwd=repo, text=True)),
                  language=args.language, build="Debug GUI", phases=groups, phase_transitions=metadata,
                  webkit_ownership=ownership, samples=samples,
                  native_scope="Actual OMP with isolated profile and disconnected localhost model; read-only native RPC" + (" and one local synthetic MCP server" if args.p5_forward else "; no model request or configured MCP server"),
                  unmeasured=["paid model streaming", "configured MCP servers", "GPU first readable frame", "VoiceOver speech", "sleep/wake"])
    if args.p5_forward and (output / "mcp-events.jsonl").exists():
        report["mcp_events"] = [{k: v for k, v in json.loads(line).items() if k != "pid"} for line in (output / "mcp-events.jsonl").read_text().splitlines()]
        if any(row.get("event") == "tools/list" for row in report["mcp_events"]):
            report["unmeasured"].remove("configured MCP servers")
    report["webkit_attribution"] = "verified subset" if ownership else "unavailable"
    # Verifying one XPC process does not prove that every WebKit service was found.
    measured_phases = {"idle-before", "chat-switches", "preview-cycles", "idle-after"}
    measured_ownership = [row for row in ownership_checks if row["phase"] in measured_phases]
    measured_samples = [s for s in samples if s["phase"] in measured_phases]
    complete_webkit = args.p5_forward and measured_phases.issubset({row["phase"] for row in measured_ownership}) and all(row["complete"] for row in measured_ownership)
    complete_resources = complete_webkit and all(s["physical_bytes"] is not None for s in measured_samples)
    idle_samples = [s for s in samples if s["phase"] in ("idle-before", "idle-after")]
    complete_idle = args.p5_forward and {"idle-before", "idle-after"}.issubset({s["phase"] for s in idle_samples}) and all(
        s.get("webkit_enumeration_complete") and s["physical_bytes"] is not None for s in idle_samples)
    report["webkit_service_enumeration_complete"] = complete_webkit
    report["webkit_ownership_checks"] = ownership_checks
    report["full_application_resource_coverage"] = complete_resources
    report["steady_state_resource_coverage"] = complete_idle
    report["resource_scope"] = "GUI, native OMP and observed descendants, explicit MCP roots, and WebContent/Networking/GPU instances in this GUI's launchd PID domain; excludes shared OS services and sampling-interval peaks."
    if not complete_webkit:
        report["unmeasured"].append("complete WebKit/XPC process coverage")
    if complete_webkit and not complete_resources:
        report["unmeasured"].append("complete physical-footprint readings")
    if not ownership:
        report["unmeasured"].append("WebKit resource ownership could not be verified")
    dylib = app / "Contents/MacOS/OMP GUI Dev.debug.dylib"
    report["dylib_sha256"] = hashlib.sha256(dylib.read_bytes()).hexdigest()
    report["workload_sha256"] = hashlib.sha256((repo / "OMPGUI/App/Captures/OMPPerformanceRun.swift").read_bytes()).hexdigest()
    report["driver_sha256"] = hashlib.sha256(Path(__file__).read_bytes()).hexdigest()
    report["workspace_isolated_git_fixture"] = args.p5_forward
    report["window_visibility_scope"] = "Activity/visibility recorded at phase transitions only; this does not certify an uninterrupted foreground window"
    report["memory_bytes"] = int(subprocess.check_output(["/usr/sbin/sysctl", "-n", "hw.memsize"], text=True))
    if (output / "checks.json").exists():
        report["checks"] = json.loads((output / "checks.json").read_text())
    if "idle-before" in groups and "idle-after" in groups:
        initial, final = groups["idle-before"], groups["idle-after"]
        before, after = initial["median_physical_bytes"], final["median_physical_bytes"]
        if before is not None and after is not None:
            budget = max(before * 0.1, 20 * 1024 * 1024)
            report["memory_comparison"] = dict(before_bytes=before, after_bytes=after, delta_bytes=after-before,
                                               budget_bytes=budget, measured_scope_within_budget=after-before <= budget,
                                               full_application_within_budget=(after-before <= budget) if complete_idle else None,
                                               basis="Median observed simultaneous physical footprint during two 60-second idle phases")
    (output / "baseline.json").write_text(json.dumps(report, ensure_ascii=False, indent=2) + "\n")
    print("Baseline:", output / "baseline.json", flush=True)
    if phase != "completed":
        raise SystemExit(1)


if __name__ == "__main__":
    main()
