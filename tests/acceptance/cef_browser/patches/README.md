# Prototype dependency repairs

These are local, reviewable repairs for the standalone acceptance host. They are
not upstream releases, a global OMP installation, or a production GUI dependency.
The runner copies sources into `build.noindex/cef-prototype/dependencies/`, keeps
the installed OMP dependencies read-only through a symlink, and uses the repaired
SDK's real Eval/Browser implementation. No browser API is mocked or replaced.

`sources.json` pins CefSwift to
`ba6ebff9e232529289662a84704ade1240563031`, OMP to 18.13.3, and the original SHA-256
of every patched input. The preparation helper rejects a version/input mismatch,
checks patch application, and records patch hashes. A changed upstream version
requires reviewing the patches and updating this manifest, not bypassing guards.
The copied sources retain their upstream licenses and attribution.

- [CefSwift repair](cefswift-cdp-dialogs.patch): explicit
  `useCDPJavaScriptDialogs` mode retains real CEF callbacks without entering an
  AppKit modal loop. CEF close/reset releases the extra reference on a later
  main-queue turn. Force close settles a pending callback before destroying the
  view. `CefBrowser.isClosed` reports actual CEF `on_before_close`, which the host
  waits for before termination.
- [OMP repair](omp-browser-repairs.patch): frame screenshots combine the
  top-viewport bounding box with the top-document scroll offset before calling
  `Page.screenshot`. Reopening an existing worker with an explicit dialog policy
  settles its dialog before old page-hook disposal can block worker recycling.

CDP dialog mode is exclusive to an automation-controlled host. Without a Page
client, a prompt waits for an answer until reset/force-close; this mode does not
provide the final product's human-facing native dialog UI. It does not override
`window.alert`, `confirm`, `prompt` or `onbeforeunload` in page JavaScript.

CefSwift is copyright 2026 Rajaniraiyn, under the [MIT license](LICENSE-CefSwift.txt).
OMP carries copyright Mario Zechner, Can Bölük and Stencil Labs, Inc., under its
[MIT license](LICENSE-OMP.txt). Original contexts and attribution remain intact.
CEF/Chromium distribution notices are unchanged.

See the [repair evidence](../../../../docs/archive/cef-browser-repairs-2026-10-27.md)
for measured behavior and remaining acceptance boundaries.
