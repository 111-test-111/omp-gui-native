"""Sequential shared-MathJax attachment research; no OMP or application launch.

Fresh helper processes isolate cold starts and memory. WebKit ownership comes
from the helper's launchd PID domain, never from global process-name/time diffs.
All native body layout/drawing runs in AppKit TextKit 1. This is not a live GUI
frame-rate, total-app memory, or power measurement.
"""
import argparse
import hashlib
from datetime import datetime
import json
import os
from pathlib import Path
import runpy
import select
import statistics
import subprocess
import sys
import time
from zoneinfo import ZoneInfo

from support import resource_ledger

REPO = Path(__file__).resolve().parents[3]
ROUTES = ("native", "pdf", "png")


def save(path, data):
    path.write_text(json.dumps(data, ensure_ascii=False, indent=2) + "\n")


def read_line(process, limit):
    deadline = time.monotonic() + limit
    while time.monotonic() < deadline:
        if select.select([process.stdout], [], [], .2)[0]:
            line = process.stdout.readline()
            if line:
                return json.loads(line)
        if process.poll() is not None:
            raise RuntimeError(f"Helper exited {process.returncode}; inspect stderr")
    raise TimeoutError("Helper did not report its phase")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--executable", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--phase", choices=("all", "compat", "cold", "performance", "stream", "memory", "visual"), default="all")
    parser.add_argument("--routes", nargs="+", choices=ROUTES, default=list(ROUTES), help="Scope recovery to affected routes")
    args = parser.parse_args()
    output, executable = args.output.resolve(), args.executable.resolve()
    if not output.is_relative_to(REPO / "build.noindex/verification/runs"):
        parser.error("Require this worktree's isolated verification output")
    corpus = runpy.run_path(str(REPO / "tests/benchmarks/math_renderers/corpus.py"))["fixtures"]()
    save(output / "corpus.json", corpus)
    save(output / "environment.json", {
        "date": datetime.now(ZoneInfo("Asia/Hong_Kong")).isoformat(),
        "base_commit": subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=REPO, text=True).strip(),
        "hardware": subprocess.check_output(["sysctl", "-n", "machdep.cpu.brand_string"], text=True).strip(),
        "memory_bytes": int(subprocess.check_output(["sysctl", "-n", "hw.memsize"], text=True)),
        "system": subprocess.check_output(["sw_vers"], text=True),
        "swift": subprocess.check_output(["swift", "--version"], text=True, stderr=subprocess.STDOUT),
        "executable": str(executable), "methodology": __doc__,
        "settings": {"point_size": 15, "png_scale": 2, "atlas_batch_size": 8,
                     "atlas_pixels": 16_000_000, "cache_entries": 256, "cache_cost_bytes": 16*1024*1024},
    })
    provenance = output / "phase-evidence.json"
    history = json.loads(provenance.read_text()) if provenance.exists() else []
    source_paths = [*sorted((REPO / "tests/benchmarks/mathjax_attachments").glob("*.swift")),
                    REPO / "tests/benchmarks/mathjax_attachments/browser.js",
                    *[REPO / f"OMPGUI/UI/Markdown/{name}.swift" for name in
                      ("MathRendering", "MarkdownMath", "MarkdownInline", "StreamMend")],
                    REPO / "OMPGUI/UI/Preview/FilePreviewMarkdown.swift",
                    REPO / "OMPGUI/Resources/MarkdownPreview/vendor-manifest.json"]
    evidence = {"phase": args.phase, "routes": args.routes, "status": "incomplete",
                "date": datetime.now(ZoneInfo("Asia/Hong_Kong")).isoformat(),
                "executable_sha256": hashlib.sha256(executable.read_bytes()).hexdigest(),
                "sources": {str(path.relative_to(REPO)): hashlib.sha256(path.read_bytes()).hexdigest() for path in source_paths}}
    history.append(evidence)
    save(provenance, history)

    def command(phase, route, *extra):
        return [str(executable), phase, route, str(REPO), str(output), *map(str, extra)]

    def run(phase, route, *extra):
        result = subprocess.run(command(phase, route, *extra), capture_output=True, text=True, timeout=180)
        suffix = "-" + "-".join(map(str, extra)) if extra else ""
        (output / f"{phase}-{route}{suffix}.log").write_text(result.stderr)
        if result.returncode:
            raise RuntimeError(f"{phase}/{route}: {result.stderr[-4000:]}")
        lines = [line for line in result.stdout.splitlines() if line.startswith("{")]
        if len(lines) != 1:
            raise RuntimeError(f"Unexpected output from {phase}/{route}: {result.stdout[-2000:]}")
        return json.loads(lines[0])

    if args.phase in ("all", "compat"):
        results = {route: json.loads((output / f"compat-{route}.json").read_text()) for route in ROUTES
                   if (output / f"compat-{route}.json").exists()}
        for route in args.routes:
            result = run("compat", route)
            save(output / f"compat-{route}.json", result)
            results[route] = result
            if route == "native":
                save(output / "common_ids.json", result["common_core_ids"])
            else:
                bad = [row for row in result["rows"] if row["ok"] != row["valid"]]
                if bad:
                    raise RuntimeError(f"Compatibility mismatch {route}: {bad}")
            print(f"{route}: {sum(r['ok'] and r['valid'] for r in result['rows'])}/68 valid formulas", flush=True)
        save(output / "compat.json", results)
    if args.phase in ("all", "cold"):
        previous = json.loads((output / "cold.json").read_text()) if (output / "cold.json").exists() else []
        results = [row for row in previous if row["route"] not in args.routes]
        for repetition in range(5):
            for route in (args.routes if repetition % 2 == 0 else tuple(reversed(args.routes))):
                results.append({"repetition": repetition, **run("cold", route)})
        save(output / "cold.json", results)
        print("Five fresh-process cold samples per route complete", flush=True)
    if args.phase in ("all", "performance"):
        for route in args.routes:
            result = run("performance", route)
            save(output / f"performance-{route}.json", result)
            print(f"{route}: warm batches/cache/drawing complete", flush=True)
    if args.phase in ("all", "stream"):
        for route in args.routes:
            results = []
            for rate in (16, 4):
                for repetition in range(3):
                    results.append({"repetition": repetition, **run("stream", route, rate)})
            save(output / f"stream-{route}.json", results)
            print(f"{route}: six native-prose streaming replays complete", flush=True)
    if args.phase in ("all", "memory"):
        for route in args.routes:
            repetitions = []
            for repetition in range(3):
                phases = []
                with (output / f"memory-{route}-{repetition}.log").open("w") as errors:
                    proc = subprocess.Popen(command("memory", route), stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                            stderr=errors, text=True)
                    ledger = resource_ledger.Ledger({proc.pid: "helper"})
                    try:
                        for _ in range(6):
                            phase = read_line(proc, 90)
                            samples = []
                            ownership = resource_ledger.webkit_processes(proc.pid)
                            for process in ownership["roots"]:
                                ledger.attach(process["pid"], "webkit")
                            for _ in range(9):
                                samples.append(ledger.sample())
                                time.sleep(.2)
                            values = [sample["physical_bytes"] for sample in samples]
                            if any(value is None for value in values):
                                raise RuntimeError("Unreadable process footprint; do not substitute zero")
                            if route != "native" and phase["phase"] in ("worker_ready", "visible_100", "churn_1000"):
                                if not ownership["complete"] or not ownership["roots"]:
                                    raise RuntimeError("Cannot prove the shared worker's WebKit process ownership")
                            phase.update(samples=samples, ownership=ownership,
                                         settled_mib=statistics.median(values[-3:])/1048576,
                                         peak_observed_mib=max(values)/1048576)
                            phases.append(phase)
                            proc.stdin.write("\n"); proc.stdin.flush()
                        if proc.wait(timeout=10):
                            raise RuntimeError(f"Memory helper failed: {route}")
                    finally:
                        if proc.poll() is None:
                            proc.kill(); proc.wait()
                repetitions.append({"repetition": repetition, "phases": phases})
                save(output / f"memory-{route}.json", repetitions)
            print(f"{route}: three process ledgers and teardown samples complete", flush=True)
    if args.phase in ("all", "visual"):
        for route in args.routes:
            save(output / f"visual-{route}.json", run("visual", route))
        print("Light/dark, 696/280 pt and 4x drawing samples saved", flush=True)
    evidence["status"] = "passed"
    save(provenance, history)
    print(f"Evidence: {output}", flush=True)


if __name__ == "__main__":
    main()
