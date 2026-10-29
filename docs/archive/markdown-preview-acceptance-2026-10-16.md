# Markdown document preview acceptance

> 历史记录：仅代表原文所列日期、版本及验收范围，不是当前操作指南。 当前已移除的收件箱、会话记录、独立 fork 和诊断入口不因本文的历史描述而恢复为功能。 当前入口见[文档索引](../README.md)和[功能状态与验收边界](../status.md)。

## Markdown migration validation (2026-10-16)

The standalone production host was checked on Apple M5 / arm64, macOS 27.2,
with a 720×900 point unshown viewport. The owner's local
`Attention-Is-All-You-Need.md` (42,285 UTF-8 bytes, SHA-256
`5ba3e3f1c33e87766cb8f12f2663316f19e070d5b0ea5c690b1092ff3c89d392`)
was read in place; the paper and figures are not redistributed in the repository.

- Paper: 126/126 formulas rendered; four footnotes each appeared once; the
  author table had nine rows including its header; all five local images
  decoded. Top, formula, figure and narrow/dark screenshots were inspected.
- Synthetic compatibility: 68/68 valid formulas from the existing math corpus
  rendered, including AMS environments, matrices, Unicode, mhchem, physics and
  mathtools. Six malformed formulas retained their complete original source,
  including unbalanced input that MathJax leaves unparsed rather than reporting
  as an error. Explicit bbm/bboldx/dsfont extensions loaded offline too.
- Parsing and interaction: frontmatter, references, footnotes, superscripts,
  task lists, table alignment, code fences, exact TeX selection export, local
  file links and native find passed. Document changes isolated macros/labels;
  resize/theme changes did not reparse. Refresh and immediate tab changes
  preserved scroll state; latest revision won; teardown released the host.
- Offline loading: 205 runtime files, 3,854,669 bytes (excluding HTML/CSS/notices
  and manifest), matched SHA-256 hashes in the source and built application.
  No missing dynamic assets or attempted HTTP(S) resource loads were observed.
  Plain Markdown did not load MathJax. Chat rendering was not changed.

The final `benchmark.py` run measured **413 ms cold wall time**, including
WebView creation and engine startup; JavaScript parsing/typesetting was 200 ms.
Ten warm replacements took **103, 60, 56, 56, 48, 48, 49, 47, 46, 47 ms**
(median **48.5 ms**). Resizing and theme changes use CSS without reparsing.

Physical footprint samples include the standalone helper plus newly created
WebKit WebContent/GPU/Networking services, not the entire OMP GUI application
or an app-wide incremental-memory measurement. Eleven samples at 200 ms
intervals recorded approximately **153 MiB settled after cold load**, **149 MiB
settled after ten warm replacements**, and **36 MiB after view teardown**.
Observed peaks were **234 MiB cold / 232 MiB after warm replacements**; these
samples do not promise a maximum for other documents or machines. A preceding
implementation recreated the output jax/font objects on every replacement and
reached 304 MiB in the same warm workload; retaining that output/font state
removed the extra allocations without sharing document macros.

The raw benchmark report, process identities, logs and PNGs are generated under
`build.noindex/markdown-preview-checks`. `make build`, Markdown checks, native
preview renderer checks and store lifecycle checks passed. The built Dev app
was not installed or launched; live GUI interactions remain unverified.

## Markdown layout and image follow-up (2026-10-16)

The same paper and unshown viewport now verify expanded metadata, three
separate quoted lines, natural-width table cells, and a single rule before the
footnotes. The reported positional-embedding cell fits on one line while the
table scrolls horizontally. Long-prose fixtures still wrap, nested quotes retain
line breaks, and ordinary paragraphs keep their standard soft breaks. Paper
formula/image checks and the compatibility corpus continue to pass. Additional
image fixtures verify JPEG pass-through, EXIF rotation, the 2,048-pixel bound and
static GIF first frames. Top, quote and table snapshots were inspected.

For an isolated native-image comparison, the previous handler from `26ddb96`
and the updated handler were compiled with the same benchmark helper and served
the same updated browser resources. Five batches of the paper's five images
(25 requests) took **194 ms before / 8 ms after**; transferred bytes were
4,933,980 / 4,344,655. This measures fetching compressed bytes through the native
handler, excluding WebKit pixel decoding. The paper's five PNG files now pass
through without allocating native pixel buffers or re-encoding them as PNG.

The updated run measured **456 ms cold wall time** (198 ms JavaScript) and warm
times of **104, 54, 52, 47, 47, 47, 51, 45, 45, 45 ms** (median **47 ms**).
Settled physical footprints were **153 MiB cold / 149 MiB warm / 153 MiB after
image requests / 36 MiB after teardown**, using the same standalone helper plus
WebKit attribution described above. These whole-render figures are close to
earlier runs; the demonstrated improvement is removal of repeated native image
processing, not a large reduction in steady WebKit memory. Raw comparison files
are `benchmark-before-images.json` and `benchmark-after-images.json` in the
verification output directory. The offline manifest contains 205 runtime files
totalling 3,854,890 bytes.
