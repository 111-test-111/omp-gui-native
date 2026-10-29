# Third-party notices

OMP GUI is a modified fork of Tivano, based on Droppy Code by Jordy Spruit (Droppy), https://getdroppycode.app. OMP is the sole executable runtime. Notices for inherited and removed components remain for attribution; historical provider features and paths do not imply current runtime support. Complete original license texts below and in the resource notices are preserved.

## Droppy Code

Droppy Code itself is licensed under the GNU AGPL v3.0 with additional attribution terms (see LICENSE). The notices below are for what it builds on and are preserved as their licenses require.

## Git logo

Git logo artwork by Jason Long, used in the MCP Git icon at
`OMPGUI/Resources/Assets.xcassets/mcp-git.imageset/mcp-git.svg`.
Licensed under [Creative Commons Attribution 3.0 Unported](https://creativecommons.org/licenses/by/3.0/).
Source and attribution: [Git logos](https://git-scm.com/community/logos).
The artwork is packaged as an SVG application icon; its use does not imply endorsement.

## Maple

The Git sidebar's commit-lane, curved-edge and merge-ring presentation is adapted from
[Maple](https://github.com/poolcamacho/Maple), by Pool Camacho, reviewed at commit
9255de96fd57c7d28bb7876616a8a0ddb3b8aa5a. OMP GUI uses a modified row-local layout
with pending-parent pagination, its own bounded read-only Git services and native Chrome UI.

MIT License

Copyright (c) 2026 Pool Camacho

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.

## T3 Code

Droppy Code began as a native Swift rewrite of T3 Code by T3 Tools Inc. (https://github.com/pingdotgg/t3code),
in T3 Code's own repository. That upstream lineage is retained in this attribution, and `LICENSE` keeps
T3 Tools Inc.'s copyright notice beside Droppy Code's.

MIT License

Copyright (c) 2026 T3 Tools Inc.

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.

## Synara

The way Droppy Code keeps a chat responsive under load follows principles studied in Synara
by T3 Tools Inc. and Emanuele Di Pietro (https://github.com/Emanuele-web04/synara), a
TypeScript app whose architecture was read, not copied: nothing synchronous on the click
that opens a chat (its history decodes off the main thread and the selection paints first),
one write to the library for a click rather than one per thread, timeline blocks kept per
thread across switches so coming back to a chat reuses them, the chat column staying put
while only the transcript is swapped, sidebar rows reading their own thread rather than
the whole list, generous parse caches so scrolling back through a long thread never parses
again, and rows built lazily so a popover opens on what is visible. No Synara code is in
this repository; its license is reproduced here in acknowledgement.

MIT License

Copyright (c) 2026 T3 Tools Inc.
Copyright (c) 2026 Emanuele Di Pietro

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.

## SwiftTerm

The terminal under every thread is SwiftTerm by Miguel de Icaza, https://github.com/migueldeicaza/SwiftTerm,
fetched by Swift Package Manager and linked into the app.

Copyright (c) 2019-2026 Miguel de Icaza (https://github.com/migueldeicaza)
Copyright (c) 2017-2019, The xterm.js authors (https://github.com/xtermjs/xterm.js)
Copyright (c) 2014-2016, SourceLair Private Company (https://www.sourcelair.com)
Copyright (c) 2012-2013, Christopher Jeffrey (https://github.com/chjj/)

Permission is hereby granted, free of charge, to any person obtaining
a copy of this software and associated documentation files (the
"Software"), to deal in the Software without restriction, including
without limitation the rights to use, copy, modify, merge, publish,
distribute, sublicense, and/or sell copies of the Software, and to
permit persons to whom the Software is furnished to do so, subject to
the following conditions:

The above copyright notice and this permission notice shall be
included in all copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND,
EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF
MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND
NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE
LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION
OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION
WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.

## MonoCode

The removed Codex reset-credit feature in Tivano's usage popover (`Tivano/Services/Providers/CodexSession.swift`,
`Tivano/App/Views/Usage/UsageViews.swift`) follows MonoCode by hardbeat920, https://github.com/hardbeat920/monocode,
`src/lib/rateLimitsFetch.ts` and `src/chrome/UsageProviderChip.tsx`: the app-server's `account/rateLimitResetCredit/consume`
call sent with an idempotency key, the reset credits read beside the rate limits, the confirm step before a reset is spent,
and the four outcomes it can answer with. No MonoCode code is in this repository; its license is reproduced here in
acknowledgement.

MIT License

Copyright (c) 2026 Nick

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.

## Zeron

Tivano's working indicators (`OMPGUI/UI/Common/WorkingIndicators.swift`) are ported from Zeron,
https://github.com/zeronsh/zeron, `apps/ios/Zeron/Views/Loaders.swift`,
`apps/ios/Zeron/Theme/Motion.swift` and `crates/ui/src/markdown/veil.rs`
(`OMPGUI/UI/Markdown/StreamVeil.swift`).

MIT License

Copyright (c) 2026 Wing

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.

## Octicons

The Copilot provider icon (`OMPGUI/Resources/Assets.xcassets/provider-copilot.imageset/copilot.svg`) is
the `copilot` mark from GitHub's Octicons, https://github.com/primer/octicons, `icons/copilot-24.svg`,
with its artboard resized to match the other provider marks.

MIT License

Copyright (c) 2026 GitHub Inc.

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.

## TourKit

Earlier Tivano versions included a welcome tour ported from TourKit by Ram Patra,
https://github.com/rampatra/TourKit. The tour has been removed. Its original notice
is retained here for historical attribution.

MIT License

Copyright (c) 2026 Ram Patra

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.

## mugen-markdown

The streaming fade in `OMPGUI/UI/Markdown/StreamVeil.swift` derives from Zeron's
veil implementation, which credits mugen-markdown's `FadePainter`.
https://github.com/wingleeio/mugen

MIT License

Copyright (c) 2026 Wing Lee

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.

## Anti-slop guidance

Tivano's concise reply guidance is adapted from ideas in
https://github.com/miqdadbadjuber/anti-slop, revision
`743735248fbaefd76bb56619615687dfa8b3bc1e`. Tivano does not bundle or run its tooling.

MIT License

Copyright (c) 2026 Miqdad Badjuber

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.

## Tabler Icons

Tool and companion notice/plan row artwork (`OMPGUI/Resources/Assets.xcassets/tool-tabler-*.imageset`)
is from [Tabler Icons](https://github.com/tabler/tabler-icons), revision
`a4ce1404bc6d24d3c365afe7b258d6bf6f48d62d`, by Paweł Kuna. The selected Outline
SVGs retain their 24 × 24 geometry, 2-unit strokes and rounded joins/caps.
`currentColor` is normalized to black for native template compilation; the GUI
applies its semantic foreground colour. This selection is limited to tool rows
and related timeline notice/plan rows;
existing application, Hydra and MCP artwork and SF Symbols elsewhere are retained.

MIT License

Copyright (c) 2020-2026 Paweł Kuna

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.

## Provider names and marks

Codex, Claude, Cursor, OpenCode, Grok, DeepSeek, Meta, Devin, Antigravity, GitHub Copilot and Command
Code are the names and marks of their respective owners, retained here in inherited marks and archive/fixture identities. OMP GUI executes only OMP; those identifiers do not enable other runtime adapters.
OMP GUI and Tivano are not affiliated with or endorsed by those trademark owners.

## SwiftMath and Asana Math

Earlier native chat Markdown math used [SwiftMath 1.7.3](https://github.com/mgriebling/SwiftMath/tree/1.7.3) and its unmodified `Asana-Math` font. The application now uses the offline MathJax resources below; the pinned, unmodified SwiftMath package remains a dependency of historical comparison helpers only. Its attribution and original license texts are preserved.

SwiftMath is MIT licensed, Copyright (c) 2023 Computer Inspirations. Its bundled iosMath resources retain the MIT license, Copyright (c) 2013 MathChat. Their complete original license texts are shipped in `OMPGUI/Resources/MathLicenses/SwiftMath-MIT.txt` and `SwiftMath-iosMath-MIT.txt`.

Asana Math is Copyright (c) 2007–2019 Apostolos Syropoulos, (c) 2000 Young Ryu and (c) 1997, 1999 Claudio Beccari, licensed under the SIL Open Font License 1.1. The original copyright, reserved font names (Asana Math, pxfonts, gsmn1000) and complete license are extracted without modification from the font metadata into `OMPGUI/Resources/MathLicenses/Asana-Math-font-notices.txt` and shipped in the app.

SwiftMath's upstream resource bundle contains its original MIT, GUST and other font notices. The GUST text is additionally shipped in `OMPGUI/Resources/MathLicenses/GUST-FONT-LICENSE.txt`. Fonts are not modified or renamed.

## Offline Markdown document preview

The file preview bundles markdown-it 15.0.2, markdown-it-footnote 4.0.0,
markdown-it-texmath 1.0.0 (delimiter tokenization only), DOMPurify 3.4.17,
highlight.js 11.11.1, MathJax 4.1.3, MathJax New Computer Modern 4.1.3,
and MathJax mhchem/bbm/bboldx/dsfont font extensions 4.1.3.
The document preview uses these libraries; native chat formula attachments share
the MathJax CHTML configuration and font resources. The fonts are distributed
unchanged under their original names.

Complete upstream library licenses (including bundled transitive dependencies),
the original WOFF2 copyright/trademark notices and the GUST Font License are
shipped in `OMPGUI/Resources/MarkdownPreview/THIRD_PARTY_LICENSES.txt`. MathJax
JavaScript is Apache-2.0; its bundled New Computer Modern font files retain
their GUST notices. DOMPurify offers Apache-2.0 or MPL-2.0; the Apache-2.0
option is used here. The remaining MIT/BSD notices are retained in full.

The pinned dependency lockfile, rebuild sources and generated file hashes are
in `scripts/markdown-preview` and `OMPGUI/Resources/MarkdownPreview/vendor-manifest.json`.

## Code highlighting theme palettes

The selectable syntax families in `OMPGUI/UI/Theme/CodeHighlightTheme.swift`
take their foreground values and token mappings from these upstream projects.
No source code is copied; only palette colors and scope-to-token choices are.

- **GitHub** — [github-vscode-theme 6.3.5](https://github.com/primer/github-vscode-theme/tree/cd78e5e4e7bcf132a6f428ae0f32264bb1b729cf),
  `src/theme.js` and `src/colors.js`, over
  [@primer/primitives 7.10.0](https://www.npmjs.com/package/@primer/primitives/v/7.10.0)
  `prettylights.syntax`. Copyright (c) 2020 Primer and Copyright (c) 2018 GitHub Inc.
- **Atom One** — [one-light-syntax](https://github.com/atom/one-light-syntax/tree/d84579027410c576086dfca14d934c4bd74b0438)
  and [one-dark-syntax](https://github.com/atom/one-dark-syntax/tree/9c96f4454362267ac45322063e193ccf9d2debb1),
  `styles/colors.less` and `styles/syntax/_base.less`. Copyright (c) 2016 GitHub Inc.
- **Solarized** — [altercation/solarized](https://github.com/altercation/solarized/tree/62f656a02f93c5190a8753159e34b385588d5ff3),
  the canonical sixteen-color palette and `vim-colors-solarized`. Decorators follow
  the [official IntelliJ port](https://github.com/jkaving/intellij-colors-solarized)'s
  `PY.DECORATOR`. Copyright (c) 2011 Ethan Schoonover.
- **Catppuccin** — [palette 1.8.0](https://github.com/catppuccin/palette/tree/07d02aa110ef9eb7e7427afca5c73ba9cf7f8ebd)
  (Latte and Mocha) and [Catppuccin for VSCode 3.19.0](https://github.com/catppuccin/vscode/tree/befc9e6fc41980f4241408f7049755d47c06ff45)
  `tokenColors` (`text`, `overlay2`, `green`, `mauve`, `peach`, `yellow`).
  Copyright (c) 2021 Catppuccin.

MIT License

Copyright (c) 2020 Primer
Copyright (c) 2016 GitHub Inc.
Copyright (c) 2018 GitHub Inc.
Copyright (c) 2011 Ethan Schoonover
Copyright (c) 2021 Catppuccin

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.

## Lobe Icons

Provider logos from LobeHub Lobe Icons, @lobehub/icons-static-svg 1.101.0, revision aea0ecb0fe1439467219197c52ffaeb579dfe33f. Source: https://github.com/lobehub/lobe-icons. Original SVG paths are preserved; currentColor is normalized to black, intrinsic em dimensions use viewBox units, and browser-only root flex styling is omitted for native template rendering. Brand names and marks remain the property of their respective owners.

MIT License

Copyright (c) 2023 LobeHub

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.


## Embedded browser dependencies

OMP GUI embeds [CefSwift](https://github.com/Rajaniraiyn/CefSwift), pinned at `ba6ebff9e232529289662a84704ade1240563031`, under the MIT license (Copyright © 2026 Rajaniraiyn). Local modifications add the reviewed CDP dialog lifecycle repair and application event hooks; see [the dependency patch](config/browser/cefswift.patch). The unmodified upstream MIT text is copied into the app as `LICENSE-CefSwift.txt`.

The pinned Chromium Embedded Framework (CEF 154.0.34 / Chromium 154.0.8037.98) is distributed under its BSD-style license and Chromium's bundled third-party licenses. The CEF distribution's `LICENSE.txt` is copied as `LICENSE-CEF.txt`; framework resources retain their notices. Framework and helper binaries are generated into the task build directory and are not checked into this repository.

Native OMP remains an external runtime. The optional application-local compatibility copy of OMP 18.12.5 preserves that package's original MIT license and attribution. [The bounded repair specification](OMPGUI/Resources/OMPBrowserPatches.json) adapts iframe captures, dialog-policy ordering and exact native page attachment without modifying the globally installed package. The original OMP license is also retained with the [acceptance patch evidence](tests/acceptance/cef_browser/patches/LICENSE-OMP.txt).
