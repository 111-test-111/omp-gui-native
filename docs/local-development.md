# OMP GUI local development

Read [AGENTS.md](../AGENTS.md) first, then use the [source map](architecture.md) and [verification guide](verification.md). Local `main` is the integration branch. `upstream` is a read-only Tivano source reference.

Before delegating development, research or review, follow the subagent authorization rule in [AGENTS.md](../AGENTS.md): absent an explicit user request for subagents, obtain consent through `ask` before spawning them.

## Task worktree and integration

Inspect `git status --short --branch` and `git worktree list` before starting. Fetch `upstream` when configured, then create a `codex/` branch from local `main` in a dedicated task worktree. Keep changes and builds there; never edit the primary checkout or another task's tree.

```sh
# From the primary repository; substitute your own unused task name/path.
git fetch upstream
git worktree add -b codex/task /path/to/task-worktree main
```

When the task is ready, review its diff and the selected checks, then create one task commit. If `main` advanced, incorporate it in the task worktree and resolve conflicts there; repeat only checks whose relevant inputs changed. With a clean primary checkout, fast-forward it to that one-commit result. Keep the task worktree and its evidence until the owner requests cleanup. A running application must never be removed with its worktree without explicit authorization to quit that instance.

Do not push, create a PR, publish a release or update `upstream` without the owner's corresponding instruction. Changes integrated into a local dev branch include its version bump and an Unreleased entry; version files are described in [packaging](packaging.md). Documentation-only work on `main` does not require an app build.

## Build and cleanup

Requires Apple Silicon, macOS 26 or later, full Xcode with a compatible SDK/Swift toolchain, command-line tools selected via `xcode-select`, and Python 3 for build fingerprints. The first build resolves the pinned Swift packages and may need network access. XcodeGen and Node/npm are not needed for a normal app build.

```sh
make build
make clean
```

[Makefile](../Makefile) delegates to [scripts/develop.sh](../scripts/develop.sh). `make build` compiles the Debug Dev product with signing disabled; it does not install, launch or require a Developer ID certificate.

GUI-launched builds use the [scoped local-build policy](verification.md) for their own compiled products and SwiftPM manifest/plugin helpers. This prevents automatic quarantine attribution from turning local verification into system approval dialogs; downloaded inputs, installed apps and system security settings are unchanged.

The main app sets `LSFileQuarantineEnabled = false`: local terminal, package-manager and build outputs are not automatically treated as web downloads. Completed GUI browser downloads are marked explicitly, and browser helpers retain automatic quarantine. This does not disable Gatekeeper, code signing or the Chromium sandbox. A fresh launch of the updated app is required; previously flagged files are not bulk-cleared.

| Output | Location |
| --- | --- |
| Dev app | `build.noindex/development/Build/Products/Debug/OMP GUI Dev.app` |
| Build log | `build.noindex/development/build.log` |
| Source/binary evidence | `build.noindex/development/verification-inputs.json` |
| Verification reports | `build.noindex/verification/runs/<run>/report.json` |

`make build` refuses to overwrite its running product. `make clean` removes this worktree's entire `build.noindex`, including package checkouts, caches, reports and local packages; preserve needed reports first. It refuses cleanup while a process is running from that directory. Application data and external OMP configuration remain intact.

## Project files and dependencies

The build authority is the checked-in [OMPGUI.xcodeproj](../OMPGUI.xcodeproj/project.pbxproj), with shared scheme/target/module `OMPGUI`. It pins SwiftTerm 1.20.0; [Package.resolved](../OMPGUI.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved) also records transitive Swift Argument Parser.

The reviewed native integration uses npm OMP **18.13.3** with **Bun 1.4.4 or later**. OMP remains external and is discovered through the configured executable or login PATH; it is not bundled with the GUI. The browser SDK repair requires this exact reviewed OMP version and matching source hashes. See the [upgrade evidence](archive/omp-18-13-3-compatibility-2026-10-29.md) before changing that baseline.

The [embedded browser](browser.md) uses a pinned, patched CefSwift local package under `build.noindex/browser`. `make build` prepares its source, verified CEF distribution and helper before invoking Xcode. For direct Xcode use, first run `python3 scripts/browser_runtime.py prepare`. The Xcode embed phase copies CEF into the app and signs nested code only for signed builds. No browser or GUI is launched by preparation/building.

The inherited [project.yml](../project.yml) describes the basic target but currently omits the explicit folder-resource handling present in the Xcode project. It is **not** a faithful regeneration source. Do not run `xcodegen generate` over the working project as routine setup. A future generation change must reconcile packages, resource build phases, configuration files and scheme settings before regeneration and build verification.

The Xcode synchronized group keeps `Resources/MarkdownPreview` as an explicit folder; preserve its internal resource structure. Chrome Cookie import uses the system SQLite3, Security, CommonCrypto and CryptoKit modules, with no additional package, command-line decryption helper or bundled Chrome extension. Build-only verification never accesses Chrome data or requests Keychain permission.

Local dictation uses the macOS 26 Speech and AVFoundation frameworks, with no additional package or command-line dependency. Settings → Dictation owns language selection, explicit system-asset installation and microphone permission; unsupported devices/languages remain unavailable. A prepared microphone click records directly. Both configurations declare microphone usage and the audio-input entitlement while retaining hardened runtime. Build-only checks do not request microphone access or download speech assets; see [dictation](chat-workflows.md#本地听写).

Markdown document resources are checked in. Only an intentional vendor change needs the [npm rebuild workflow](../scripts/markdown-preview/README.md). Chat keeps native prose and uses shared offline MathJax image attachments; see [chat rendering](markdown-rendering.md).

## Scoped verification

There is no Xcode test target. Select the smallest relevant areas before execution:

```sh
make verify
make verify-plan AREAS="rpc"
make verify AREAS="rpc"
# Documentation/tooling work, without building the app:
make verify TIER=static AREAS="documentation harness syntax"
```

Use only the applicable static areas: plain prose/link edits select `documentation`; test-tooling changes also select `harness syntax`. Compiled source/resource changes use one incremental `make build` plus affected checks. The registry is [tests/catalog.py](../tests/catalog.py); the [verification guide](verification.md) owns area descriptions, native/benchmark selection, prerequisites and stopping rules.

App-linked checks require this worktree's current source/binary evidence. The runner never automatically builds or retries. A failure must be explained from production/test source before fixing and rerunning the affected case. Passing evidence remains reusable while relevant inputs and environment are unchanged.

## Explicitly requested runs and packages

Only when the owner requests a GUI run, use `make run`. If this exact build is already running, the command brings it forward without rebuilding; otherwise it builds and opens it. Quit only the authorized instance before rebuilding. Do not use another task's running application.

Signed packaging/installing uses [scripts/package_local.sh](../scripts/package_local.sh) and the [package contract](packaging.md). It has a separate signing preflight, currently requiring a Dev team configuration correction. It never quits or launches applications. Legacy `quick_run.sh` packages and relaunches an installed app, so it is not a normal development or verification entry point.

Native CLI/SDK checks use `TIER=native` with an explicit OMP path; performance uses `TIER=benchmark`. [Manual acceptance drivers](../tests/acceptance/README.md) launch a GUI and require authorization for that instance. These scopes are not routine follow-ups to a documentation change.

OMP's active profile is external and shared by both GUI editions. Use isolated fixtures for automated checks; do not import other products' data. See [storage/configuration](shared-library.md) and [troubleshooting](troubleshooting.md).
