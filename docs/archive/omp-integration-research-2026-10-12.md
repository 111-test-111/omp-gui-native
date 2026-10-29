# OMP native integration

> 历史记录：仅代表原文所列日期、版本及验收范围，不是当前操作指南。 当前已移除的收件箱、会话记录、独立 fork 和诊断入口不因本文的历史描述而恢复为功能。 当前入口见[文档索引](../README.md)和[功能状态与验收边界](../status.md)。

Research date: 2026-10-12. The fork preserves Tivano's four-layer architecture and UI vocabulary while replacing its execution backend with OMP.

## Chosen surface

OMP exposes an embedded TypeScript SDK, RPC over stdio, and ACP. A Swift process host can consume public RPC directly without embedding Bun or maintaining a second agent engine. `rpc-ui` additionally emits native tool and extension dialog requests, which the existing question UI answers.

`OMPRPC` owns request correlation, cancellation, process-exit failure, bounded protocol-v2 chunk reassembly and child shutdown. `OMPSession` owns one process per lead chat. Native `sessionFile` is its resume identity, supplied back through `--resume`. `--session-dir` places OMP's conversation files and artifacts under the GUI edition's `OMP GUI Native` / `OMP GUI Native Dev` library, with the active OMP credential/config profile left unchanged. These names deliberately avoid this host's existing OMP GUI data.

Prompt admission and completion are separate. The adapter correlates `prompt_result` to each prompt ID and uses `session_settled` for background work. It also displays `command_output`, command-catalog updates and model changes from native slash commands. Background `agent_start`/`agent_end` runs enter the existing timeline through the same event path.

## Models, auth and settings

`omp models --json` supplies the native authenticated model catalog, custom models and advertised thinking levels. An actual chat also asks `get_available_models` in its project context. A new chat leaves model selection to OMP unless the user has chosen or carried a model, so native default roles and project overrides remain authoritative.

OMP's `config path` resolves the active agent directory, including profiles and XDG configuration. `omp config list --json` is reduced immediately to an allowlist of non-secret settings. Writes use `omp config set`, with OMP's own parsing, validation and persistence. The settings UI displays native OAuth provider metadata through `get_login_providers`; login opens OMP's own CLI flow. There is no app-owned model API key storage or provider API client.

The app's permissions choices map to native `always-ask`, `write`, and `yolo`; `OMP default` leaves the choice to OMP. Native per-tool policies are retained. The app does not install an approval gate extension.

## Custom prompts

Provider settings edits the native shared config base's `APPEND_SYSTEM.md` (normally `~/.omp/agent/APPEND_SYSTEM.md`). Named profiles and `PI_CONFIG_DIR` select their native base; an arbitrary `PI_CODING_AGENT_DIR` override does not redirect this file, matching OMP's documented shared-config lookup. The editor preserves UTF-8 content, follows existing symlink targets, saves atomically with private permissions, and rejects saves if the original bytes or symlink destination changed. Missing files start empty; unreadable or invalid UTF-8 files remain untouched. Saved edits apply on the next native session launch, including resumed conversations.

The GUI no longer passes `--append-system-prompt`, which would suppress OMP's own file discovery. An edition-local, per-session `--extension` uses the public `before_agent_start` event and returns the existing system-prompt blocks followed by the GUI's anti-slop guidance. OMP retains ownership of append-file discovery, project-over-user precedence, profiles, custom base prompts, tools and generated context. This hook prepares guidance afresh for each user delivery without accumulating duplicate blocks. Its file is removed with the session's existing runtime overlay.

Verification on 2026-10-13: `make build` and fourteen temporary Swift file fixtures passed (UTF-8/line endings, private permissions, missing/empty files, external edit/create/delete conflicts, invalid/unreadable files, symlink preservation and retarget conflicts). Eight native OMP 18.3.2 request-preparation checks used an in-process mock provider across the built-in guidance switch, default/custom base prompts and consecutive turns. Each request contained exactly one user append and one GUI guidance block, preserving project context. No GUI or real model request was launched.

## File-write previews

The same per-session extension observes native `tool_call` and `tool_result` hooks to capture each local `write` before execution and attach its original/resulting text in `details.ompGUI.fileSnapshot`. These hooks are awaited inside OMP; a delayed GUI `tool_execution_start` notification is not a before-write barrier. Native diffs take precedence. The snapshot survives RPC delivery and the GUI stores the resulting per-call diff in the existing conversation record.

Each native session, including workers, binds a separate snapshot map. When OMP prepares several exclusive writes before running the batch, each completed write advances later writes to the same file's baseline. Snapshots read the actual resulting file, preserving native formatting, rather than treating the requested content as the final bytes. Reads are limited to 1 MB per file and pending baseline text to 8 MB; missing files have an empty baseline, while unreadable, binary and oversized text stays unavailable. Failed and virtual writes do not acquire successful snapshots. Native tools, approvals, scheduling and session state remain OMP-owned.

Run `make build` and `make verify TIER=native AREAS="fast-write" OMP=/absolute/path/to/omp`. The regression uses the installed OMP SDK's extension runner and native write tool without a model or GUI, including prepared batches, rapid create/overwrite operations, symlinked paths, Unicode/CRLF, unavailable text and failures. It delays every GUI event until all files have changed again, then verifies each original diff and its saved/reopened form.

## Queued message controls

Ordinary idle sends retain their admission record without showing the delivery tab; failed or uncertain submissions remain recoverable. Inputs queued behind existing work show the delivery tab. Recall and removal update the GUI only after OMP confirms that the exact queued input was removed; recall merges text and attachments into the current composer draft.

OMP 18.3.2 has no individual queue-removal RPC. For npm installations with the public SDK and Bun available, `OMPSDKHost.js` enters OMP's native `runRootCommand` with a `createAgentSession` dependency hook. Native startup still owns profiles, configuration, authentication, tools, extensions, history and worker dispatch. The per-session extension sends private commands over the ordinary native RPC prompt transport. Its in-process SDK hook retains queued object identities and uses the native agent's synchronous queue replacement interface to remove only the requested follow-up and its hidden attachment companions, preserving steering and every other queued input. No GUI worker scheduler or queue replay is involved.

Removal results are correlated before ordinary timeline events, with bounded tombstones for late confirmations and retries. A capability handshake gates the controls; a standalone installation without the SDK retains basic native RPC chat. Run `make verify AREAS="queue"` and, after `make build`, `make verify AREAS="workflows"` for model-free queue identity, recall/removal and consumption-race checks.

## MCP

OMP owns tool discovery, connections, HTTP/SSE/stdio transport, OAuth and credential storage. The GUI has no MCP hub, proxy, bridge, independently spawned server or provider-specific config synchronization.

Settings displays the active profile's `mcp.json` and each project's `.omp/mcp.json`. It preserves unknown fields and native environment/header/OAuth definitions when saving, checks the original bytes to refuse overwriting an externally changed file, writes atomically and uses private file permissions. Native disable/enable arrays are respected. It never writes Codex, Claude or other tools' config files; OMP's own discovery rules remain intact.

## Hydra

`set_subagent_subscription` with `events` enables `subagent_lifecycle`, `subagent_progress` and `subagent_event`. These frames create and update local view records, not additional agent processes. Each worker has its own event decoder, transcript namespace, usage and tool state.

Live controls are negotiated for every native process. Empty `cancel_subagent` and `steer_subagent` requests cannot address any worker; the native missing-`subagentId` validation reply establishes support. Unknown commands, unavailable registries and failed probes leave the corresponding control unavailable. Supported sessions expose individual cancellation and an additional-instructions composer. Older OMP sessions keep their transcripts and results available with localized update guidance. A cancellation must return `cancelled: true`; only OMP's lifecycle frame ends the worker record. Steering never aborts the head or parent, clears the draft only after native acceptance, and preserves the draft after rejection.

Hydra's switch is a delegation preference: on adds `task.eager: preferred`, off inherits OMP's configured policy. Each process has an edition-local, private `--config` overlay watched by OMP. Updating this preference rewrites only that overlay, without replacing the process or stopping its workers. Native worker controls and results stay visible when the preference is off. Isolation and applying completed work remain independent native settings.

Head results persist the actual reported model, thinking level, working directory, file changes, isolation/application facts and native output/patch/branch references. Missing information is shown as unreported, not inferred from the lead model or execution success. In particular, OMP 18.3.2 does not expose a structured `changesApplied` field in `SingleResult`; the GUI preserves its original tool/background-delivery report instead of parsing model prose into an application claim. Registered native transcripts supply the final reply, with generation checks preventing delayed reads from updating a reused worker id. Reported artifact paths can be copied or revealed; the GUI never applies or removes those artifacts itself.

The existing dragon marks, roster, panel, transcripts and report assets are reused. Native `task.maxConcurrency`, `task.isolation.enabled`, `task.isolation.apply`, native agent definitions and `task.agentModelOverrides` replace Tivano's worker scheduler and merge pipeline. The GUI never launches Hydra heads, copies their worktrees, injects prose delegation blocks, creates task merge commits or publishes their results.

## Capability boundaries

- OMP's current RPC surface does not expose native plan-mode entry/exit. The inherited GUI shortcut is removed rather than sending an unrecognized `/plan` to a model. Native planning tools and model roles are available.
- Live worker control depends on OMP retaining the worker in its own addressable roster. Historical transcripts stay in the GUI, but the app does not invent worker revival behavior beyond public RPC.
- MCP changes apply when native sessions discover the file again. The settings UI explicitly says that a new OMP session may be needed.
- Subscription-limit scraping, vendor-specific CLI installation/update flows and app-owned provider/MCP credentials are removed. Native token/context events continue to feed the existing usage UI.
- Model requests and app launches are outside the read-only integration checks performed during this task. They require the user's configured OMP account and an explicit app run request.

## Evidence and verification

The exact native tool catalog and per-tool GUI symbols are documented in
[OMP tools](../OMP_TOOLS.md), including conditionally exposed tools and xd:// actions.

Installed OMP: `omp/18.3.2`. A non-inference, ephemeral RPC session successfully answered `negotiate_protocol`, `get_state`, `get_available_commands`, `set_subagent_subscription`, `get_subagents` and `get_login_providers`. Native catalog and configuration CLI JSON were inspected without modifying the user's configuration. No model turn was sent and no app was installed or launched.

The Hydra control audit on 2026-10-13 confirmed that this installed version returns `Unknown command` for both `cancel_subagent` and `steer_subagent`. Their presence in current upstream documentation does not establish local support. Eighteen temporary Swift regression fixtures checked native validation replies, negative/malformed cancellation acknowledgements, unknown application state, sparse updates, recovery references and persisted result round trips. A model-free RPC session also confirmed that atomic overlay updates change the live native system prompt, restore it when the preference is removed, and retain the same process. No GUI or model task was launched; cancellation/steering with an actual running worker remains an integration check for a supporting OMP version.

Debug compilation passed with `-skipPackagePluginValidation CODE_SIGNING_ALLOWED=NO`: Xcode needed trust for the inherited SwiftTerm build plugin, and this host does not have the upstream Developer ID private key. This is a build-only check; package scripts still require Developer ID signing. A temporary persistent session also returned a native session file and model catalog, and `/stats` emitted `command_output` with `agentInvoked: false`. This does not imply an authenticated model/tool round trip has been exercised.

The independent project now uses the `OMPGUI` source module, Xcode project, target and shared scheme. `make build` completed a fresh Debug build with the unchanged `dev.ompgui.mac.dev` bundle identity. `make clean` removed its full repository-local build directory afterward. The `make run` recipe was inspected without launching or relaunching the GUI; it builds and opens the local Dev product, or brings an already running copy forward. Developer ID packaging remains separate from these local development commands.

## Primary sources

- [OMP RPC protocol](https://github.com/can1357/oh-my-pi/blob/main/docs/rpc.md)
- [SDK and embedding](https://github.com/can1357/oh-my-pi/blob/main/docs/sdk.md)
- [Models, auth sources and model roles](https://github.com/can1357/oh-my-pi/blob/main/docs/models.md)
- [Configuration discovery and profiles](https://github.com/can1357/oh-my-pi/blob/main/docs/config-usage.md)
- [Native MCP configuration](https://github.com/can1357/oh-my-pi/blob/main/docs/mcp-config.md)
- [Task agent discovery](https://github.com/can1357/oh-my-pi/blob/main/docs/task-agent-discovery.md)
- [Agent Hub lifecycle](https://github.com/can1357/oh-my-pi/blob/main/docs/agent-hub.md)

Retired runtime identifiers remain decode-only for preserved UI captures and explicit archive compatibility. They are absent from `allCases`, rejected by the runtime registry, and have no executable adapter.
