# Shared MathJax native attachment prototype

An isolated research path that retains AppKit TextKit 1 prose and replaces only
formula attachments. It does not change the application's renderer or launch
OMP GUI. Run only when renderer performance/resource research is requested.

```sh
make verify-plan TIER=benchmark AREAS="mathjax-attachments"
make verify TIER=benchmark AREAS="mathjax-attachments"
```

The shared test compiler builds a Release helper with pinned SwiftMath 1.7.3 and
the production Markdown parser/preview host and frozen fd7776e SwiftMath baseline.
No app build, npm install or new web dependency is required. The helper loads
the checked-in MathJax CHTML/NewCM assets and production startup configuration
through the preview's local scheme, then uses public asynchronous MathJax
conversion and WebKit export APIs. All windows remain unshown.

## Routes and bounds

- `native` uses the historical SwiftMath baseline, including its geometry cache.
- `pdf` exports at most eight formulas into one shared PDF. Each native
  attachment clips and draws its region of that vector page.
- `png` captures the same CHTML geometry at 2x, then copies each cropped image
  so cached tiles do not retain a complete atlas.

Temporary atlases are limited to 16 million pixels and 16,384 pixels per edge.
The prototype attachment cache holds at most 256 keys and 16 MiB of estimated
cost: unique PDF encoded data or decoded PNG pixel bytes, plus key overhead.
That estimate does not bound the process heap, WebKit memory or live attachments
retained by native text. Theme and image scale participate in the cache key.

## Measurements and correctness

The existing 74-fixture corpus checks output/fallback, source-preserving copy,
Unicode, native links, unfinished formulas and macro isolation. Compatibility
success means non-error, nonempty output; visual quality is assessed separately.
Performance uses only the baseline's supported core fixtures, with a numeric
suffix to create new keys. Five alternating fresh-process cold samples and seven
warm samples at 1/20/100 formulas include native attachment assembly and layout;
paint samples add a 720x900 point 2x native draw. Eleven cached samples cover
assembly/layout and drawing without new MathJax exports.

Streaming replays 30 unique formulas, 12 Unicode characters per update, waiting
16 ms or 4 ms after each update, three repetitions each. Processing is part of
the actual interval; this is not an independently scheduled arrival stream. Production inline parsing
publishes text immediately. One asynchronous worker coalesces misses, and native
layout/drawing uses the latest text with ready attachments. The recorded latency
runs from the first observed closing delimiter through native drawing. An actual
in-flight export is superseded to check message-generation protection.

Memory runs use three fresh processes per route. Each retains 100 visible
attachments, processes 1,000 additional unique formulas, releases the page/cache,
and finally tears down the shared host. Nine samples per phase retain physical
footprints, CPU counters and PID/start identities. WebKit roots are proven by the
helper's launchd PID domain using the shared resource ledger; unrelated browser
services are never inferred from launch timing. Observed peaks are sampled,
not guaranteed maxima; footprint sums are not unique whole-system physical pages.

Light/dark samples at 696/280 pt use native Chinese/English prose. A 4x native
draw compares vector scaling with the same fixed 2x image attachments. PDF atlases
are retained for independent font/image inspection and Poppler rendering.

## Evidence and targeted recovery

Raw JSON, stderr, PNGs and PDFs are saved under this worktree's
`build.noindex/verification/runs/<run>/benchmark/mathjax-attachments/`.
The runner records source fingerprints, toolchain and environment. After reading
production/prototype code to explain a failure, rerun only the affected phase
against that output, using the helper executable printed in `checks.log`:

```sh
python3 tests/benchmarks/mathjax_attachments/run.py \
  --executable /absolute/path/to/Checks \
  --output /absolute/path/to/run/benchmark/mathjax-attachments \
  --phase stream
```

Add `--routes pdf png` to recover only affected routes. Each phase records its
helper/source hashes in `phase-evidence.json`; native baselines can remain valid
after a correction confined to WebKit. Do not reuse a result if its relevant
source, runtime or environment changed.

With Pillow, pypdf and Poppler installed, analyze existing data without measuring
again:

```sh
python3 tests/benchmarks/mathjax_attachments/summarize.py \
  --input /absolute/path/to/run/benchmark/mathjax-attachments \
  --output /absolute/path/to/published-evidence
```

The [2026-10-18 evaluation](../../../docs/archive/mathjax-attachment-evaluation-2026-10-18.md)
contains the integration recommendation, sample images and measured boundaries.

This helper does not reproduce the whole SwiftUI timeline, scrolling, streaming
veil or power consumption. Native attachment selection still needs foreground
recoloring; the research PDF/PNG assets are keyed by theme rather than recolored
at drawing time. Each job isolates TeX macros; message-wide macro definitions,
equation numbering and cross-formula references need a context design before
production integration. Attachments are atomic and cannot inherit browser inline
line breaking. These boundaries must remain visible in any integration decision.
