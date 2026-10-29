#!/usr/bin/env python3
"""Read-only macOS process ledger. Explicit WebKit roots avoid cross-app attribution."""
import argparse
import ctypes
import json
import os
import re
from pathlib import Path
import subprocess
import time


class RusageV2(ctypes.Structure):
    _fields_ = [("uuid", ctypes.c_uint8 * 16)] + [(name, ctypes.c_uint64) for name in (
        "user_time", "system_time", "pkg_idle_wkups", "interrupt_wkups", "pageins", "wired_size",
        "resident_size", "phys_footprint", "proc_start_abstime", "proc_exit_abstime", "child_user_time",
        "child_system_time", "child_pkg_idle_wkups", "child_interrupt_wkups", "child_pageins",
        "child_elapsed_abstime", "diskio_bytesread", "diskio_byteswritten")]


class Timebase(ctypes.Structure):
    _fields_ = [("numer", ctypes.c_uint32), ("denom", ctypes.c_uint32)]


LIBPROC = ctypes.CDLL("/usr/lib/libproc.dylib")
LIBPROC.proc_pid_rusage.argtypes = [ctypes.c_int, ctypes.c_int, ctypes.c_void_p]
TIMEBASE = Timebase()
ctypes.CDLL("/usr/lib/libSystem.B.dylib").mach_timebase_info(ctypes.byref(TIMEBASE))
TICK_SECONDS = TIMEBASE.numer / TIMEBASE.denom / 1e9


def usage(pid):
    info = RusageV2()
    if LIBPROC.proc_pid_rusage(pid, 2, ctypes.byref(info)):
        return None
    return dict(start=info.proc_start_abstime, physical_bytes=info.phys_footprint,
                cpu_seconds=(info.user_time + info.system_time) * TICK_SECONDS,
                interrupt_wakeups=info.interrupt_wkups,
                read_bytes=info.diskio_bytesread, written_bytes=info.diskio_byteswritten)


def process_table():
    rows = subprocess.check_output(["/bin/ps", "-axo", "pid=,ppid=,comm="], text=True)
    result = {}
    for line in rows.splitlines():
        parts = line.strip().split(None, 2)
        if len(parts) == 3:
            pid, ppid, command = parts
            result[int(pid)] = dict(pid=int(pid), ppid=int(ppid), executable=Path(command).name)
    return result


def webkit_processes(gui_pid, *, read_domain=None, table=None):
    """Resolve instances declared in this GUI's launchd PID domain.

    Never infer ownership from launch timing or a process name. Retain only
    numeric PIDs and service labels: launchctl also prints inherited environment
    values, which must not enter benchmark logs or reports.
    """
    if gui_pid <= 0:
        raise ValueError("Require positive GUI PID")
    if read_domain is None:
        def read_domain(domain):
            return subprocess.check_output(["/bin/launchctl", "print", domain], text=True,
                                           stderr=subprocess.DEVNULL, timeout=2)
    if table is None:
        table = process_table()
    roots = []
    complete = True
    for kind in ("WebContent", "Networking", "GPU"):
        service = "com.apple.WebKit." + kind
        domain = f"pid/{gui_pid}/"
        try:
            text = read_domain(domain + service)
            if not text.startswith(domain + service + " = {") or f"\n\tdomain = pid/{gui_pid} [" not in text:
                complete = False
                continue
            instances = re.search(r"\n\tinstances = \{(.*?)\n\t\}", text, re.S)
            names = re.findall(re.escape(service) + r"\.[A-Fa-f0-9-]{36}(?=,|\s)", instances[1]) if instances else []
            declared = [line.strip().rstrip(",") for line in instances[1].splitlines() if line.strip()] if instances else []
            if declared != names:
                complete = False
            if re.search(r"\n\tpid = [1-9][0-9]*\n", text):
                # An unrecognized non-instanced service layout needs new evidence.
                complete = False
            for name in names:
                instance = read_domain(domain + name)
                if not instance.startswith(domain + name + " = {") or f"\n\tdomain = pid/{gui_pid} [" not in instance:
                    complete = False
                    continue
                pid = re.search(r"\n\tpid = ([1-9][0-9]*)\n", instance)
                if pid:
                    pid = int(pid[1])
                    if table.get(pid, {}).get("executable") == service:
                        roots.append(dict(pid=pid, service=service, instance=name,
                                          evidence="launchctl GUI PID-domain instance"))
                    else:
                        complete = False
        except (OSError, subprocess.SubprocessError):
            complete = False
    return dict(complete=complete, roots=roots)


class Ledger:
    def __init__(self, roots):
        # Freeze identities at attachment. Reused PIDs never become new roots.
        self.roots = {}
        self.members = {}
        self.missing_roots = []
        for pid, role in roots.items():
            self.attach(pid, role)

    def attach(self, pid, role):
        """Attach a newly verified root once; never follow reuse of an old PID."""
        if pid in self.roots:
            return
        if pid <= 0:
            raise ValueError("Require positive PID")
        self.roots[pid] = role
        info = usage(pid)
        if info is None:
            self.missing_roots.append(pid)
        else:
            self.members[pid] = (info["start"], role)

    def sample(self):
        table = process_table()
        live = {}
        unreadable = []
        for pid, (start, role) in self.members.items():
            info = usage(pid)
            if pid in table and info is None:
                unreadable.append(pid)
            if pid in table and info is not None and info["start"] == start:
                live[pid] = dict(**table[pid], role=role, **info)
        # Retain known descendants after reparenting, with the same start identity.
        changed = True
        while changed:
            changed = False
            for pid, row in table.items():
                if pid in live or pid in self.roots or row["ppid"] not in live or pid == os.getpid():
                    continue
                info = usage(pid)
                if info is None:
                    unreadable.append(pid)
                    continue
                parent_role = live[row["ppid"]]["role"]
                role = "omp-descendant" if parent_role in ("omp", "omp-descendant") else "unclassified-descendant"
                self.members[pid] = (info["start"], role)
                live[pid] = dict(**row, role=role, **info)
                changed = True
        groups = {}
        for row in live.values():
            group = groups.setdefault(row["role"], dict(process_count=0, physical_bytes=0))
            group["process_count"] += 1
            group["physical_bytes"] += row["physical_bytes"]
        return dict(monotonic=time.monotonic(), processes=list(live.values()), groups=groups,
                    physical_bytes=None if unreadable or self.missing_roots else sum(row["physical_bytes"] for row in live.values()),
                    unreadable_pids=sorted(set(unreadable)),
                    missing_roots=self.missing_roots,
                    absent_roots=[pid for pid in self.roots if pid not in live])


def summary(samples):
    peaks = {}
    for sample in samples:
        for role, group in sample["groups"].items():
            peaks[role] = max(peaks.get(role, 0), group["physical_bytes"])
    # CPU uses matched identities between consecutive samples. Short-lived or
    # unreadable processes are omitted and are not silently assigned zero CPU.
    cpu = {}
    for previous, current in zip(samples, samples[1:]):
        older = {(p["pid"], p["start"]): p for p in previous["processes"]}
        elapsed = current["monotonic"] - previous["monotonic"]
        for process in current["processes"]:
            old = older.get((process["pid"], process["start"]))
            if old is not None and elapsed > 0:
                values = cpu.setdefault(process["role"], dict(cpu_seconds=0.0, observed_process_seconds=0.0))
                values["cpu_seconds"] += max(0, process["cpu_seconds"] - old["cpu_seconds"])
                values["observed_process_seconds"] += elapsed
    return dict(sample_count=len(samples), incomplete_samples=sum(s["physical_bytes"] is None for s in samples),
                observed_peak_physical_bytes=max((s["physical_bytes"] for s in samples if s["physical_bytes"] is not None), default=None),
                observed_peak_by_role_bytes=peaks, cpu_observations=cpu,
                methodology="Summed proc_pid_rusage physical footprint, sampled peaks, PID plus start identity. CPU excludes child cumulative counters to avoid double counting. Short-lived/unreadable processes may be missed; explicit WebKit roots only.")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--pid", type=int, required=True, help="Existing GUI PID; this tool never launches an app")
    for role in ("omp", "mcp", "webkit"):
        parser.add_argument("--" + role + "-pid", type=int, action="append", default=[])
    parser.add_argument("--seconds", type=float, default=60)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    if args.pid <= 0 or not 0 < args.seconds <= 600:
        parser.error("Require positive PID and 0 < seconds <= 600")
    roots = {args.pid: "gui"}
    for role in ("omp", "mcp", "webkit"):
        for pid in getattr(args, role + "_pid"):
            if pid <= 0 or pid in roots:
                parser.error("Every explicit PID must be positive and unique")
            roots[pid] = role
    ledger = Ledger(roots)
    samples = []
    deadline = time.monotonic() + args.seconds
    while time.monotonic() < deadline:
        samples.append(ledger.sample())
        time.sleep(0.2)
    report = dict(schema=1, roots=roots, summary=summary(samples), samples=samples,
                  unmeasured_roles=[role for role in ("omp", "mcp", "webkit") if role not in roots.values()])
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(report, indent=2) + "\n")
    print(json.dumps(report["summary"]))


if __name__ == "__main__":
    main()
