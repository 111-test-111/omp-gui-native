"""Measure the standalone production Markdown host, without launching OMP GUI.

Select TIER=benchmark AREAS="markdown-preview" PAPER=/path/to/paper.md.
Physical footprint is the helper plus WebKit processes absent from the baseline;
concurrent unrelated WebKit launches can affect attribution. Raw PIDs/samples
are retained; this is not a measurement of the whole app's incremental memory.
"""
import argparse
import importlib.util
import json
from pathlib import Path
import re
import select
import statistics
import subprocess
import time

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location('math_memory', ROOT / 'tests/benchmarks/math_renderers/run.py')
memory = importlib.util.module_from_spec(spec)
spec.loader.exec_module(memory)


def sample(pid, baseline):
    selected = [p for key, p in memory.processes().items() if key == pid or
                (key not in baseline and re.search(r'com\.apple\.WebKit\.(WebContent|GPU|Networking)', p['command']))]
    for process in selected:
        process.update(memory.usage(process['pid']))
    footprints = [p['phys_footprint_mib'] for p in selected]
    return {'processes': selected,
            'physical_mib': sum(footprints) if all(x is not None for x in footprints) else None}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('paper', type=Path)
    parser.add_argument('--executable', type=Path, required=True, help='Helper compiled by tests/run.py')
    parser.add_argument('--output', type=Path, required=True, help='Fresh output from tests/run.py')
    args = parser.parse_args()
    output = args.output.resolve()
    if not output.is_relative_to(ROOT / 'build.noindex/verification/runs'):
        parser.error('Require isolated runner output')
    baseline = memory.processes()
    command = [str(args.executable.resolve()), str(ROOT / 'OMPGUI/Resources/MarkdownPreview'), str(output), str(args.paper.resolve()), '--benchmark']
    report = {'method': __doc__, 'runs': [], 'baseline_webkit_pids': [pid for pid, p in baseline.items() if 'com.apple.WebKit.' in p['command']]}
    with (output / 'benchmark-stderr.log').open('w') as errors:
        proc = subprocess.Popen(command, stdout=subprocess.PIPE, stderr=errors, text=True)
        try:
            deadline = time.monotonic() + 60
            while time.monotonic() < deadline:
                if not select.select([proc.stdout], [], [], .5)[0]:
                    if proc.poll() is not None: break
                    continue
                line = proc.stdout.readline()
                if not line:
                    if proc.poll() is not None: break
                    continue
                if not line.startswith('{'): raise RuntimeError(line.strip())
                phase = json.loads(line)
                phase['samples'] = []
                for _ in range(11):
                    phase['samples'].append(sample(proc.pid, baseline))
                    time.sleep(.2)
                values = [s['physical_mib'] for s in phase['samples']]
                phase['median_physical_mib'] = statistics.median(values) if all(v is not None for v in values) else None
                phase['settled_physical_mib'] = statistics.median(values[-3:]) if all(v is not None for v in values) else None
                phase['peak_observed_physical_mib'] = max(values) if all(v is not None for v in values) else None
                report['runs'].append(phase)
                print(json.dumps({k: v for k, v in phase.items() if k != 'samples'}), flush=True)
            if proc.wait(timeout=5): raise RuntimeError('Benchmark helper failed; see benchmark-stderr.log')
        finally:
            if proc.poll() is None:
                proc.kill()
                proc.wait()
    (output / 'benchmark.json').write_text(json.dumps(report, ensure_ascii=False, indent=2) + '\n')


if __name__ == '__main__':
    main()
