#!/usr/bin/env python3
"""Check resource attribution with deterministic process identities, without a GUI."""
from pathlib import Path
from unittest.mock import patch
import sys
sys.path.insert(0, str(Path(__file__).resolve().parents[2]))
from support import resource_ledger as resources


def main():
    checks = 0

    def expect(value, message):
        nonlocal checks
        assert value, message
        checks += 1

    def info(start, size=10, cpu=0):
        return dict(start=start, physical_bytes=size, cpu_seconds=cpu)

    def row(pid, parent):
        return dict(pid=pid, ppid=parent, executable="fixture")

    table = {101: row(101, 1), 102: row(102, 101), 103: row(103, 102), 104: row(104, 1), 999: row(999, 1)}
    values = {pid: info(pid) for pid in table}
    with patch.object(resources, "usage", side_effect=lambda pid: values.get(pid)), \
         patch.object(resources, "process_table", side_effect=lambda: table):
        ledger = resources.Ledger({101: "gui", 102: "omp", 104: "webkit"})
        sample = ledger.sample()
        expect(sample["physical_bytes"] == 40, "Explicit roots plus descendants counted once")
        roles = {p["pid"]: p["role"] for p in sample["processes"]}
        expect(roles[103] == "omp-descendant", "Unknown OMP child is not silently called MCP")
        expect(roles[104] == "webkit" and 999 not in roles, "Unrelated XPC processes stay excluded")
        ledger.attach(103, "mcp")
        expect(next(p for p in ledger.sample()["processes"] if p["pid"] == 103)["role"] == "mcp", "Verified dynamic roots can refine descendant attribution")
        table[103]["ppid"] = 1
        expect(any(p["pid"] == 103 for p in ledger.sample()["processes"]), "Known reparented children retain identity")
        values[104] = info(1004, size=999)
        ledger.attach(104, "webkit")
        sample = ledger.sample()
        expect(104 in sample["absent_roots"] and sample["physical_bytes"] == 30, "Reused root PID is not reattached")
        values.pop(103)
        sample = ledger.sample()
        expect(sample["physical_bytes"] is None and 103 in sample["unreadable_pids"], "Unreadable process makes total unknown")
        missing = resources.Ledger({555: "gui"}).sample()
        expect(missing["physical_bytes"] is None and missing["missing_roots"] == [555], "Missing attachment is unknown, not zero")
        expect(resources.summary([missing])["observed_peak_physical_bytes"] is None, "No complete measurements produce no peak")

    def observation(at, pid, start, cpu, size):
        return dict(monotonic=at, processes=[dict(pid=pid, role="gui", **info(start, size, cpu))],
                    groups={"gui": dict(physical_bytes=size)}, physical_bytes=size)

    first = observation(0, 101, 1, 10, 100)
    second = observation(2, 101, 1, 11, 120)
    reused = observation(4, 101, 2, 30, 140)
    summary = resources.summary([first, second, reused])
    expect(summary["cpu_observations"]["gui"] == dict(cpu_seconds=1, observed_process_seconds=2), "CPU deltas never cross PID reuse")
    expect(summary["observed_peak_physical_bytes"] == 140, "Peak is a simultaneous sampled total")
    name = "com.apple.WebKit.WebContent.00000000-0000-4000-8000-000000000001"
    def domain_fixture(domain):
        if domain.endswith(name):
            return domain + " = {\n\tdomain = pid/101 [Fixture]\n\tpid = 777\n}"
        suffix = "\n\tinstances = {\n\t\t" + name + ",\n\t}" if domain.endswith("WebContent") else ""
        return domain + " = {\n\tdomain = pid/101 [Fixture]" + suffix + "\n}"
    web_table = {777: dict(executable="com.apple.WebKit.WebContent"), 999: dict(executable="com.apple.WebKit.WebContent")}
    verified = resources.webkit_processes(101, read_domain=domain_fixture, table=web_table)
    expect(verified["complete"] and [r["pid"] for r in verified["roots"]] == [777], "GUI PID-domain membership excludes identically named unrelated WebKit processes")
    foreign = lambda domain: domain_fixture(domain).replace("domain = pid/101", "domain = pid/999")
    expect(not resources.webkit_processes(101, read_domain=foreign, table=web_table)["complete"], "Foreign launchd domain cannot prove ownership")
    expect(not resources.webkit_processes(101, read_domain=domain_fixture, table={})["complete"], "An unverified or exited WebKit PID makes that enumeration incomplete")
    malformed = lambda domain: domain_fixture(domain).replace(name, "future-instance-format")
    expect(not resources.webkit_processes(101, read_domain=malformed, table=web_table)["complete"], "Future launchctl instance formats remain unknown")
    print(f"OMP resource ledger checks passed: {checks}")


if __name__ == "__main__":
    main()
