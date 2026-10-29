# Offline Markdown preview resources

The application builds from the checked-in `OMPGUI/Resources/MarkdownPreview`
directory. It does not need Node, npm, a server or network access at runtime.

To intentionally update/rebuild the browser resources, from this directory:

```sh
npm ci --ignore-scripts --no-audit --no-fund
npm run build
```

The exact versions and integrity hashes are in `package-lock.json`.
`build.mjs` bundles the Markdown parser, footnotes, math delimiter tokenizer,
DOMPurify and the explicit offline syntax selection in `syntax-languages.js` into
`preview.js`. This extends the common grammars with LaTeX, CMake, Dockerfile and
other source formats, plus small lexical HCL/Zig/BibTeX grammars and filename
aliases. It does not enable language autodetection or remove the 64 KiB fence
budget; the document continues to render in the existing WebView. It copies
only MathJax's CHTML component, TeX extension files, safe extension and NewCM
CHTML dynamic metrics/WOFF2 fonts, including the small mhchem/bbm/bboldx/dsfont
TeX font extensions. All loader paths point to the local resource scheme. SVG output, speech dictionaries, developer
sources, source maps and alternate font families are not shipped. The generated
manifest records every vendor file and both generated entry points with their size and SHA-256.

`preview.js` and `chat-math.js` are the editable entry points. They import the same
`math-engine.js` configuration; the chat entry exports transparent formula atlases
to the single transient native worker. The resource `chat-math.html` has no prose
or selection UI. Chat enables the public `begingroupSandbox` extension to reuse
the input jax without leaking formula definitions, and narrows `\qquad` to 1 em.
The document reader retains standard TeX spacing. Rebuild both entries after changing the shared configuration; edit `preview.css` and `index.html`
directly in the resource directory. Original library notices and the unmodified
font name-table notices/GUST license from `Font-notices.txt` are bundled by the
build script. Updating the font package requires rechecking those notices.

The shared configuration supplies conventional `\ii`, `\ee`, `\bm`, `\argmin`,
`\argmax`, `\sgn` and `\diag` shorthands. It preloads `braket` to keep its
single-argument notation stable and registers lazy command/environment triggers
for the bundled mathtools, physics, bbm, dsfont, units, gensymb, upgreek and
centernot packages. See the [notation contract](../../docs/markdown-rendering.md)
for examples and macro isolation boundaries. New syntax coverage belongs in
`tests/support/math_compatibility.swift`, shared by the document and native-image
checks; each document case starts with a fresh TeX input jax so preceding cases
cannot mask a missing autoload trigger. Configuration changes also advance the
native image-cache namespace in `ChatMathCache.swift`.

## Verification

From the task worktree root, select only the affected area after one `make build`
for compiled source/resource changes:

```sh
make verify AREAS="markdown-math markdown-preview" PAPER=/path/to/Attention-Is-All-You-Need.md
make verify AREAS="preview-renderers"
```

The Markdown helper compiles the production host, uses an unshown window and
does not launch the OMP GUI application. The optional paper stays in its original
directory so relative images are tested without copying the paper into this
repository. Snapshots and temporary executables are in `build.noindex`.

The compatibility checks cover expanded YAML frontmatter, quote line breaks,
adjacent separators, shared reference definitions, multiline/repeated footnotes,
HTML superscripts, intrinsic table widths with bounded long prose, tasks, fenced code,
math delimiters/AMS environments, Unicode text, equation tags, macro isolation,
selection export, local-link routing, native WebKit find, narrow panes, theme
changes, refresh/reading state, superseded work, >128 formulas, lazy MathJax
loading, local dynamic font resources and host release. Image checks cover small
PNG/JPEG pass-through, orientation, large-image bounds and static GIF frames. The existing native
renderer checks continue to exercise the source reader and other preview types.

For a cold start, ten warm document switches, five batches of figure requests
and process memory samples:

```sh
make verify TIER=benchmark AREAS="markdown-preview" PAPER=/path/to/Attention-Is-All-You-Need.md
```

The runner compiles the helper for the selected workload; do not run the functional
check as a separate prerequisite. The benchmark saves timings, raw process
identities, physical footprints (observed peaks and settled samples) and stderr in
`build.noindex/verification/runs/<run>/benchmark/markdown-preview/`.
The image phase fetches compressed bytes through the native handler; its timing
excludes browser pixel decoding. Baseline and candidate comparisons must use the
same paper and verification helper.
It sums the standalone helper and WebKit services absent from its baseline;
concurrent unrelated WebKit launches can affect attribution. This is not the
whole app's incremental memory. The helper verifies that its host is released.
