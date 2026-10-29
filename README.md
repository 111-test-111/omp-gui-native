# OMP GUI Native

English | [简体中文](README.zh-CN.md)

A native macOS desktop workspace for [Oh My Pi (OMP)](https://omp.sh), built with SwiftUI and AppKit. This is a **modified fork of [Tivano](https://github.com/elijah7x/tivano)**, with the Droppy Code / T3 Code lineage and required attribution preserved. It is independent of, and not endorsed by, those projects or OMP's authors.

**Source release:** early development. This repository publishes source code, not a signed or notarized installer. Automatic updates and inherited publishing scripts remain disabled. Historical upstream versions are not releases of this fork.

## What it does

- **Projects and conversations:** native project sidebar, conversation history, streaming responses, model selection, thinking controls, approvals and queued messages.
- **Native OMP integration:** independent session processes over the public NDJSON RPC interface, history resumption, native controls and capability-based optional operations.
- **Subagent visibility:** native worker progress, incremental detail loading and Hydra / Pi Crew interaction. OMP owns worker execution and scheduling; the GUI does not implement a second agent engine.
- **Workspace tools:** file browsing and previews, selected-file context, Markdown/math rendering, an embedded Chromium browser and SwiftTerm terminals.
- **Git and GitHub:** inspect repositories and changes, use an existing GitHub CLI login or a personal access token, and select repositories to clone. This fork does not bundle another application's GitHub OAuth identity.
- **Local dictation:** macOS speech recognition can add editable text to a draft after explicit language-asset and microphone permission setup. This is not a full-duplex agent voice-call feature.

Features depend on the installed OMP version, model provider, account capabilities and macOS permissions. See [current status and acceptance boundaries](docs/status.md), not historical screenshots alone, when assessing support.

## Requirements

- Apple Silicon and **macOS 26 or later**.
- Full Xcode with a compatible macOS SDK and Swift toolchain, Git and Python 3.
- OMP installed and authenticated separately. The reviewed integration baseline is **OMP 18.13.3**; SDK-backed configuration and browser integration also require **Bun 1.4.4 or later**. Follow OMP's own installation and authentication instructions.
- Network access for the first Swift package and pinned Chromium Embedded Framework downloads.

The external OMP runtime owns model providers, OAuth/API keys, model roles, MCP, skills, extensions, worker isolation and task execution. The GUI discovers `omp` from the login shell or an executable path in Settings.

## Build from source

```sh
git clone https://github.com/111-test-111/omp-gui-native.git
cd omp-gui-native
make build
```

`make build` produces an unsigned development app under `build.noindex/development/Build/Products/Debug/OMP GUI Dev.app`. It does **not** install, launch or replace a running application. The first build prepares the pinned browser runtime before building the checked-in Xcode project.

The build authority is `OMPGUI.xcodeproj`, scheme/target/module `OMPGUI`. The inherited `project.yml` is not a complete regeneration source; do not run XcodeGen over the checked-in project as routine setup.

Authenticate OMP with `omp login` before using a provider. For repository features, use `gh auth login` or connect a user-owned PAT in the app. Browser-based GitHub OAuth is unavailable unless the fork is configured with its own registered OAuth App; no upstream client identity is shipped.

See [local development](docs/local-development.md) for prerequisites and the worktree workflow, and [troubleshooting](docs/troubleshooting.md) for runtime discovery and configuration failures.

## Architecture and trust boundaries

```text
SwiftUI / AppKit
  → ThreadRuntime and OMPSession
  → OMPRPC / external OMP CLI
  → native model, tool and worker execution
```

The GUI projects native events into conversations, approvals and worker panels. Host tools bridge explicitly shared file context, preview locations and browser entry points. Optional capabilities are enabled only after native registration or process replies confirm them.

| Area | Entry point |
| --- | --- |
| Runtime and ownership | [OMP integration](docs/OMP_INTEGRATION.md) |
| Source layout | [Architecture](docs/architecture.md) |
| Chat, approvals and workers | [Interaction guide](docs/chat-workflows.md) |
| Browser and local data | [Browser](docs/browser.md), [storage/configuration](docs/shared-library.md) |
| Development checks | [Verification](docs/verification.md), [tests](tests/README.md) |
| Source publication and lineage | [Source-release notes](docs/source-release.md), [repository history](docs/repository-history.md) |

OMP's provider credentials remain in its active profile. The GUI separately handles its own GitHub connection token and browser/app state; it is not a credential-free process. Do not give a model or an untrusted workspace broader access than you intend.

## Development and verification

```sh
make verify                                    # List areas; runs no checks.
make verify-plan AREAS="rpc"                    # Inspect an affected area.
make verify TIER=static AREAS="documentation"   # Documentation checks only.
```

There is no Xcode test target or default full-suite run. Select the smallest relevant area, use isolated fixtures, and distinguish static, functional, native-runtime and manual GUI evidence. A passing source or documentation check is not a signed-package, real-account or platform acceptance result.

Read [AGENTS.md](AGENTS.md) before contributing. Work in a dedicated task worktree; do not modify another task's checkout or running application. The [packaging guide](docs/packaging.md) documents separate signing and installation prerequisites. No GitHub source publication grants an Apple signing identity, and this fork does not use Tivano's update feed or release endpoints.

## License and attribution

**Droppy Code by Jordy Spruit (Droppy), https://getdroppycode.app**

OMP GUI Native is a modified Tivano fork, descending from Droppy Code and T3 Code. The work is distributed under **GNU AGPL v3.0 with the additional attribution/origin terms in [LICENSE](LICENSE)**. Preserve the required README, About/credits and source notices. The license does not grant rights to Droppy names, icons or other marks; see [TRADEMARK.md](TRADEMARK.md).

[THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md) retains the T3 Tools Inc. MIT notice and the licenses and credits for inherited components, SwiftTerm, browser resources, fonts, icons and subsequent adaptations. Third-party marks identify their sources and do not imply endorsement.
