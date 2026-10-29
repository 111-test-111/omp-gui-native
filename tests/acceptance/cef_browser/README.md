# CefWebView + OMP CDP prototype

This is a standalone, visible acceptance app, not a browser feature in the
shipping OMP GUI target. Running it requires the owner's explicit GUI acceptance
authorization. It uses a version-guarded local copy of the installed OMP SDK,
its real Eval tool, browser prelude and Puppeteer CDP connection; it makes no
model-backed prompt. See the [dependency repairs](patches/README.md).

The prepared SwiftPM dependency is pinned to CefSwift commit
`ba6ebff9e232529289662a84704ade1240563031`, whose manifest pins CEF
154.0.34 / Chromium 154.0.8037.98. The first build downloads the upstream CEF
minimal arm64 distribution and verifies the manifest's SHA-1. The local acceptance
bundle, SwiftPM caches, browser profile, OMP profile, fixture server and evidence
stay under this worktree's `build.noindex/cef-prototype/`.
The source manifest and patch input hashes are in `patches/sources.json`; the
checked-in Swift package consumes the runner's repaired local dependency.

```sh
python3 tests/acceptance/cef_browser/run.py --omp /absolute/path/to/omp
# Reuse the already-built prototype for an affected acceptance path:
python3 tests/acceptance/cef_browser/run.py --omp /absolute/path/to/omp --skip-build --case closing
# Keep the successful prototype visible for inspection:
python3 tests/acceptance/cef_browser/run.py --omp /absolute/path/to/omp --skip-build --keep-open
# Extended browser capability acceptance (requires the same GUI authorization):
python3 tests/acceptance/cef_browser/run.py --omp /absolute/path/to/omp --case capabilities
# Rerun only affected groups after analyzing a failure:
python3 tests/acceptance/cef_browser/run.py --omp /absolute/path/to/omp --skip-build --case capabilities --groups selectors,frames
# Focused repair acceptance: pixels, real dialogs, cancellation and shutdown:
python3 tests/acceptance/cef_browser/run.py --omp /absolute/path/to/omp --case repairs
```

`--build-only` builds without launching. `--case closing|cancellation` narrows the
live workload; attaching both native targets remains a prerequisite. The runner
prints the unique run directory. With `--keep-open`, interrupt the driver after
inspection; its cleanup only exits the app instance it launched. Do not rebuild
the prototype while that instance is running.

`--case capabilities` covers navigation, selectors/ARIA/Shadow DOM, form controls,
pointer/scroll input, JavaScript/init scripts, same-origin/cross-site frames,
storage, network/HAR/routes, upload/download, screenshot change detection and
annotation, PDF, console/trace/profile diagnostics, emulation, optional feature
discovery, and dialogs. The driver records each group separately. A `partial`
result is an unsuccessful capability matrix, even when the measurement driver
exits successfully. Image files require visual review: file creation alone does
not establish that the correct pixels were captured. Dialogs run last because
a native modal failure can stall the renderer. Cleanup escalates only for the
fixture process this driver launched.

The host explicitly enables the CEF accessibility tree, and both native and OMP
download destinations stay inside this run. Scoped `observe` on an unnamed
container uses `includeAll: true` to retain its subtree through Puppeteer's AX
filtering. See the [dated capability results](../../../docs/archive/cef-browser-capabilities-2026-10-27.md)
for the original gaps, followed by the [repair evidence](../../../docs/archive/cef-browser-repairs-2026-10-27.md).

`--case repairs` selects `frames,dialogs,lifecycle,shutdown`; `--groups` narrows
that selection. Frame checks compare real image pixels for same-origin,
cross-site and nested cross-site targets at two DOM DPRs, including top/child
scrolling. An original Puppeteer screenshot on the same page remains a failing
control. Dialog checks use the real JavaScript/CEF/CDP callbacks, including
beforeunload, input in B while A waits, AbortSignal, native close/recreation and
quitting with a pending prompt. The read-only image helper uses AppKit to
respect the native colour profile. A clean host exit is required in addition
to passing browser assertions; `result.json` includes `hostShutdown`.

`--skip-build` rejects changed compiled-host inputs. `--keep-open` can retain a
failed measurement for diagnosis and preserves its failure status. The runner
starts the host in a separate process group, then exits only that owned instance
through the native control path. Interruption of the driver is not a GUI pass.

The host creates two Alloy `CefWebView` tabs, each with a native UUID and CEF
browser identifier injected through the owning Swift browser. The driver verifies
those values through OMP and independently asks the native owner to read back
form state. This distinguishes operation of the hosted page from a separate
Chromium page. Checks cover Chinese input, trusted keyboard events, clicks,
multiline input, background-tab isolation, real screenshots, AbortSignal
interruption, stale target rejection, attached-handle release, and native tab
close/recreation. Cancellation must report interruption; a selector timeout does
not count. Screenshots explicitly request PNG because OMP can otherwise save
an optimized WebP image.

Each tab retains its own native hosting view. Removing a SwiftUI collection row
must not dispose another tab's `CefWebView`. After native close/recreation, the
driver releases the borrowed OMP browser handles and reconnects to refresh CDP
target discovery; the remaining native tab and its form state survive this step.

Evidence includes `result.json`, `native-proofs.jsonl`, `native-controls.jsonl`,
`environment.json`, app/OMP logs and PNG screenshots. The fixture is deterministic
and loopback-only; it does not use real accounts, remote sites, an external model,
or the owner's GUI/OMP data. This does not certify model task quality, IME
composition, arbitrary sites, production signing, Chromium sandboxing, energy use
or full OMP GUI integration.

The prototype is an ad-hoc local development host with Chromium sandbox disabled
and mock key storage. It must not be distributed or used to browse untrusted
content. It does not change the repository's Developer ID/hardened-runtime
packaging contract. Its runtime lifecycle deliberately tears down native browser
views before requesting process termination, avoiding shutdown from inside CEF's
close callback in the pinned wrapper.

UI translations come from the single production
[string catalog](../../../OMPGUI/Resources/Localizable.xcstrings); the driver
derives local bundle strings from it. CefSwift is MIT licensed; its vendored CEF
headers and downloaded CEF distribution carry separate BSD and third-party
notices. See the pinned dependency's LICENSE and the CEF distribution notices.

See the [manual acceptance rules](../README.md) and
[verification guide](../../../docs/verification.md).
