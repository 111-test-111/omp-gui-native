"""Run sequential macOS measurements; save all samples and process identities."""
import argparse
import ctypes
from datetime import datetime
import json
import os
import re
import select
import statistics
import subprocess
import time
from pathlib import Path
from zoneinfo import ZoneInfo

REPO = Path(__file__).resolve().parents[3]
ROOT = Path(os.environ.get("OMP_GUI_VERIFICATION_OUTPUT", REPO / "build.noindex/math-renderer-evaluation"))
EXE = ROOT / ".build/release/Benchmark"

class RusageV2(ctypes.Structure):
    _fields_ = [("uuid", ctypes.c_uint8 * 16)] + [(name, ctypes.c_uint64) for name in
        ["user_time", "system_time", "pkg_idle_wkups", "interrupt_wkups", "pageins", "wired_size",
         "resident_size", "phys_footprint", "proc_start_abstime", "proc_exit_abstime", "child_user_time",
         "child_system_time", "child_pkg_idle_wkups", "child_interrupt_wkups", "child_pageins",
         "child_elapsed_abstime", "diskio_bytesread", "diskio_byteswritten"]]

LIBPROC = ctypes.CDLL("/usr/lib/libproc.dylib")
LIBPROC.proc_pid_rusage.argtypes = [ctypes.c_int, ctypes.c_int, ctypes.c_void_p]
class Timebase(ctypes.Structure):
    _fields_ = [("numer", ctypes.c_uint32), ("denom", ctypes.c_uint32)]
TIMEBASE = Timebase()
ctypes.CDLL("/usr/lib/libSystem.B.dylib").mach_timebase_info(ctypes.byref(TIMEBASE))
TICK_SECONDS = TIMEBASE.numer / TIMEBASE.denom / 1e9

def usage(pid):
    info = RusageV2()
    if LIBPROC.proc_pid_rusage(pid, 2, ctypes.byref(info)):
        return {"phys_footprint_mib": None, "cpu_seconds": None}
    return {"phys_footprint_mib": info.phys_footprint / 1048576,
            "cpu_mach_ticks": info.user_time + info.system_time,
            "cpu_seconds": (info.user_time + info.system_time) * TICK_SECONDS}


def save(name, value):
    (ROOT / (name + ".json")).write_text(json.dumps(value, ensure_ascii=False, indent=2) + "\n")


def run(mode, *args, timeout=120):
    start = time.monotonic()
    proc = subprocess.run([str(EXE), mode, str(ROOT), *map(str, args)], capture_output=True, text=True, timeout=timeout)
    (ROOT / (mode + ("-" + "-".join(map(str, args)) if args else "") + ".log")).write_text(proc.stderr + proc.stdout)
    if proc.returncode:
        raise RuntimeError(f"{mode} failed ({proc.returncode}): {proc.stderr[-3000:]}")
    for line in reversed(proc.stdout.splitlines()):
        if line.startswith("{"):
            result = json.loads(line)
            result["process_wall_ms"] = (time.monotonic()-start)*1000
            return result
    raise RuntimeError(f"{mode}: no result: {proc.stdout[-1000:]}")


def processes():
    output = subprocess.check_output(["ps", "-axo", "pid=,ppid=,rss=,comm="], text=True)
    result = {}
    for line in output.splitlines():
        parts = line.strip().split(None, 3)
        if len(parts) == 4:
            pid, ppid, rss, command = parts
            result[int(pid)] = dict(pid=int(pid), ppid=int(ppid), rss_kib=int(rss), command=command)
    return result


def memory(engine, count, views):
    baseline = processes()
    command = [str(EXE), "memory", str(ROOT), engine, str(count), str(views)]
    proc = subprocess.Popen(command, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    try:
        deadline = time.monotonic()+90
        while time.monotonic() < deadline:
            ready, _, _ = select.select([proc.stdout], [], [], 1)
            if not ready:
                if proc.poll() is not None:
                    raise RuntimeError(proc.stderr.read())
                continue
            line = proc.stdout.readline()
            if line.startswith("{") and json.loads(line).get("phase") == "ready":
                break
        else:
            raise TimeoutError("memory phase")
        samples = []
        for _ in range(7):
            current = processes()
            selected = [p for pid, p in current.items() if pid == proc.pid or
                        (pid not in baseline and re.search(r"com\.apple\.WebKit\.(WebContent|GPU|Networking)", p["command"]))]
            for p in selected:
                p.update(usage(p["pid"]))
            footprints = [p["phys_footprint_mib"] for p in selected]
            cpus = [p["cpu_seconds"] for p in selected]
            samples.append(dict(total_rss_kib=sum(p["rss_kib"] for p in selected),
                                total_phys_footprint_mib=sum(footprints) if all(x is not None for x in footprints) else None,
                                total_cpu_seconds=sum(cpus) if all(x is not None for x in cpus) else None,
                                processes=selected))
            time.sleep(0.15)
        return dict(engine=engine, count=count, views=views, samples=samples,
                    median_rss_mib=statistics.median(s["total_rss_kib"] for s in samples)/1024,
                    median_phys_footprint_mib=statistics.median(s["total_phys_footprint_mib"] for s in samples) if all(s["total_phys_footprint_mib"] is not None for s in samples) else None,
                    baseline_webkit_pids=[pid for pid, p in baseline.items() if "com.apple.WebKit." in p["command"]])
    finally:
        try:
            proc.communicate("\n", timeout=10)
        except subprocess.TimeoutExpired:
            proc.kill()
            proc.communicate()
        time.sleep(0.3)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--phase", choices=["compat", "perf", "memory", "visual", "all"], default="all")
    phase = parser.parse_args().phase
    meta = dict(date=datetime.now(ZoneInfo("Asia/Hong_Kong")).isoformat(), base_commit=subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=REPO, text=True).strip(),
                mach_timebase_numer=TIMEBASE.numer, mach_timebase_denom=TIMEBASE.denom,
                hardware=subprocess.check_output(["sysctl", "-n", "machdep.cpu.brand_string"], text=True).strip(),
                memory_bytes=subprocess.check_output(["sysctl", "-n", "hw.memsize"], text=True).strip(),
                macos=subprocess.check_output(["sw_vers"], text=True),
                xcode=subprocess.check_output(["xcodebuild", "-version"], text=True),
                methodology="Fresh CLI process for cold tests. Release Swift, frozen fd7776e SwiftMath baseline. Offscreen WKWebView. RSS and proc_pid_rusage physical-footprint ledger include new WebKit XPC services, not pre-existing services; RSS shared pages are not deduplicated. Performance phases run sequentially. Raster captures are 720x900 points at 2x; native draws the visible glyph range.")
    save("environment", meta)
    if phase in ["compat", "all"]:
        native = run("native-compat"); save("native-compat", native)
        web = {}
        for font in ["local", "asana", "latin"]:
            value = run("web-compat", font)
            value["rows"] = json.loads(value.pop("rows_json"))
            value["meta"] = json.loads(value.pop("meta_json"))
            web[font] = value
            save("temml-compat-"+font, value)
        extended = run("web-compat", "local-extensions")
        extended["rows"] = json.loads(extended.pop("rows_json"))
        extended["meta"] = json.loads(extended.pop("meta_json"))
        save("temml-compat-local-extensions", extended)
        supported = {r["id"] for r in native["rows"] if r["ok"] and r["group"] == "core"}
        for value in web.values():
            supported &= {r["id"] for r in value["rows"] if r["ok"]}
        common = sorted(supported)
        save("common_ids", common)
        print(f"compatibility measured; {len(common)} common core fixtures", flush=True)
        jsc = run("jsc"); save("jsc", jsc)
        copied = run("web-copy", "local-copy")
        copied["copies"] = json.loads(copied.pop("copy_json"))
        save("temml-copy", copied)
    if phase in ["perf", "all"]:
        save("native-perf", run("native-perf"))
        print("native warm performance measured", flush=True)
        for font in ["local", "asana", "latin"]:
            save("temml-perf-"+font, run("web-perf", font))
            save("temml-attachment-perf-"+font, run("web-attachment-perf", font))
            save("temml-pdf-perf-"+font, run("web-pdf-perf", font))
            save("temml-atlas-perf-"+font, run("web-atlas-perf", font))
            print(f"Temml {font} warm performance measured", flush=True)
        cold = []
        for i in range(9):
            # Alternate order to reduce warm system and background-load bias.
            order = ["native", "webkit"] if i % 2 == 0 else ["webkit", "native"]
            for engine in order:
                value = run("native-cold" if engine == "native" else "web-cold", *([] if engine == "native" else ["local"]))
                cold.append(dict(engine=engine, repetition=i, **value))
        save("cold", cold)
        print("nine cold-process repetitions measured for each renderer", flush=True)
    if phase in ["memory", "all"]:
        results = []
        for engine in ["native", "webkit"]:
            for count, views in [(0,1), (1,1), (100,1), (500,1), (100,10), (100,50)]:
                for repeat in range(3):
                    value = memory(engine, count, views)
                    value["repetition"] = repeat
                    results.append(value)
                save("memory", results)
                recent = results[-3:]
                print(f"{engine} {count} formulas / {views} views: {statistics.median(x['median_rss_mib'] for x in recent):.1f} MiB RSS; {statistics.median(x['median_phys_footprint_mib'] for x in recent):.1f} MiB footprint", flush=True)
    if phase in ["visual", "all"]:
        save("native-visual", run("native-visual"))
        save("native-inline", run("native-inline"))
        for font in ["local", "asana", "latin"]:
            value = run("web-visual", font)
            value["geometry"] = json.loads(value.pop("geometry_json"))
            value["linebreaks"] = json.loads(value.pop("linebreaks_json"))
            save("temml-visual-"+font, value)
            inline = run("web-inline", font)
            inline["geometry"] = json.loads(inline.pop("geometry_json"))
            save("temml-inline-"+font, inline)
        print("light/dark 2x snapshots and line-break probes saved", flush=True)


if __name__ == "__main__":
    main()
