#!/usr/bin/env python3
"""Run the P0 headless helper with a bounded resource sampler; never launch the GUI."""
from datetime import datetime
import hashlib
import json
import os
from pathlib import Path
import platform
import subprocess
import sys
import time
from zoneinfo import ZoneInfo
sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from support import resource_ledger as resources


def main():
    executable, output = map(Path, sys.argv[1:3])
    repo = Path(__file__).resolve().parents[2]
    fixture = repo / "tests/fixtures/omp/rpc.py"
    # Logs from previous runs must not alter deterministic assertions.
    old_log = output / "storage/requests.txt"
    old_log.unlink(missing_ok=True)
    environment = dict(os.environ, OMP_GUI_PERFORMANCE="1")
    command = [str(executable), "--benchmark", "--website-captures", str(output), "--fixture", str(fixture)]
    started = time.monotonic()
    with (output / "checks.log").open("w") as log:
        process = subprocess.Popen(command, env=environment, stdout=log, stderr=log)
        ledger = resources.Ledger({process.pid: "headless-helper"})
        samples = []
        try:
            while process.poll() is None:
                if time.monotonic() - started > 180:
                    raise TimeoutError("Headless P0 checks exceeded 180 seconds")
                samples.append(ledger.sample())
                time.sleep(0.2)
            samples.append(ledger.sample())
        finally:
            if process.poll() is None:
                process.terminate()
                try:
                    process.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    process.kill()
                    process.wait()
    elapsed = time.monotonic() - started
    if process.returncode:
        print((output / "checks.log").read_text(), file=sys.stderr)
        raise SystemExit(process.returncode or 1)
    checks = json.loads((output / "checks.json").read_text())
    # Fingerprint the actual uncommitted inputs, not only the parent commit.
    source_hash = hashlib.sha256()
    sources = sorted((repo / "OMPGUI").rglob("*.swift")) + [fixture, Path(__file__),
        repo / "tests/functional/omp/lifecycle_tests.swift", repo / "tests/support/resource_ledger.py"]
    for source in sources:
        if source.is_file():
            source_hash.update(str(source.relative_to(repo)).encode() + b"\0" + source.read_bytes() + b"\0")
    report = dict(schema=1, workload="omp-p0-v1", date=datetime.now(ZoneInfo("Asia/Hong_Kong")).isoformat(),
                  revision=subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=repo, text=True).strip(),
                  dirty=bool(subprocess.check_output(["git", "status", "--porcelain"], cwd=repo, text=True)),
                  machine=platform.machine(), os=platform.mac_ver()[0],
                  hardware=subprocess.check_output(["/usr/sbin/sysctl", "-n", "hw.model"], text=True).strip(),
                  memory_bytes=int(subprocess.check_output(["/usr/sbin/sysctl", "-n", "hw.memsize"], text=True)),
                  fixture_sha256=hashlib.sha256(fixture.read_bytes()).hexdigest(),
                  workload_sha256=hashlib.sha256((repo / "tests/functional/omp/lifecycle_tests.swift").read_bytes()).hexdigest(),
                  source_sha256=source_hash.hexdigest(),
                  dylib_sha256=hashlib.sha256((repo / "build.noindex/development/Build/Products/Debug/OMP GUI Dev.app/Contents/MacOS/OMP GUI Dev.debug.dylib").read_bytes()).hexdigest(),
                  swift=subprocess.check_output(["xcrun", "swiftc", "--version"], text=True).strip(),
                  build="Debug production dylib; headless check executable",
                  wall_seconds=elapsed, checks=checks,
                  resources=resources.summary(samples), samples=samples,
                  unmeasured=["GUI first frame and input latency", "GUI idle CPU", "actual OMP and MCP", "WebKit", "100 chat switches and 20 preview cycles"],
                  native_runtime="deterministic RPC fixture, no installed OMP or model request")
    (output / "baseline.json").write_text(json.dumps(report, ensure_ascii=False, indent=2) + "\n")
    print((output / "checks.log").read_text().strip())
    print("Headless baseline:", output / "baseline.json")


if __name__ == "__main__":
    main()
