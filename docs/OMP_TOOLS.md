# OMP tools and GUI icons

Verified on 2026-10-12 against installed OMP 18.3.2 and upstream OMP 18.10.1
([source revision 7967984](https://github.com/can1357/oh-my-pi/tree/7967984760906fd35cfefcaa280193edaa0c3241)).
This is the recorded upstream inventory, not a current-process capability probe.
The tables also map the exact identifiers retained by the GUI; dynamic/native
availability is described in [OMP integration](OMP_INTEGRATION.md).
Both versions declare the same 30 built-in identifiers and three hidden identifiers.
Their availability depends on OMP settings, model capabilities and session restrictions.
The GUI displays calls; OMP remains responsible for enabling and executing tools.

## Global tool catalogue

Settings → **Tools** shows a fixed catalogue of OMP tools, contextual action
devices, the two GUI host tools and four eval capabilities. Entries are grouped
by purpose. Each entry is one line: its exact identifier, two calling-method/status
tags immediately after the name, and horizontal controls at the trailing edge.
Descriptions are not displayed in rows; their metadata remains searchable.
Long identifiers truncate in the middle and show their full content on hover.
Status tags use enabled, disabled, automatic, unknown, built-in, GUI-provided or
on-demand labels. Search matches
identifiers, purposes, groups, tags, controls and config keys in English or the app language.

[OMPToolCatalogue](../OMPGUI/Core/Models/OMPToolCatalogue.swift) supplies the list
independently of conversations. The page reads only allowlisted switches from
OMP's public `config list --json` in a neutral directory, excluding project and
chat overlays, when opened or the application becomes active. Memory tags use
the GUI's global memory switch, which overrides the external native backend.
Missing or unreadable config stays unknown; enabled means the configuration
gate is open. Model, installation and mode requirements appear in status hover text.

Tools with native switches can be enabled or disabled on the row. Shared
settings have one control on their first visible member, with hover text
listing affected tools: checkpoint/rewind, context notes/new
context, and automatic learning/skill management. Search
keeps that control visible even when its other members are filtered out.
JavaScript and Python eval backends have independent switches; `find` retains
automatic/on/off, and delegation offers off, depth and unlimited choices while
preserving an existing custom depth. A prelude or learning switch changes its
own gate only; disabled eval or memory dependencies are explained in status hover text.

Edits use OMP's public `config set`, then read back the effective result; a saved
value shadowed by another source is reported instead of showing false success. The shared settings
service fences profile changes and external file edits before writing, and
serializes saves without opening RPC or discovering models for tool changes.
Memory and image activation are managed only in their existing settings pages.
Their catalogue rows reflect the current state and have no duplicate controls;
status hover text identifies the owning page. The catalogue writer also rejects
edits to these settings. Core tools and mode/workflow-owned helpers without an
independent native setting remain read-only. OMP owns config watching and applying tool changes; project settings,
runtime overrides and session restrictions can still take precedence.

Calling tags follow OMP 18.11.2's ordinary unrestricted tool presentation:
essential/pinned tools stay direct, discoverable tools follow `tools.xdev`,
action devices use `write xd://`, and the four preludes run inside `eval`.
Command-owned helpers are marked as workflow calls. Hover a tag for the call
example or source config keys. Session restrictions can change presentation.
No session is connected or probed; runtime readiness and dynamically installed
MCP/extension tools remain outside this reference. The earlier
[session capture](archive/tool-inventory-settings-2026-10-21.md)
is retained as historical evidence.

[OMPGUI/Core/Models/OMPTool.swift](../OMPGUI/Core/Models/OMPTool.swift) identifies native tools by exact ID.
[OMPToolSymbols.swift](../OMPGUI/UI/Common/OMPToolSymbols.swift) assigns the SF Symbol for every known ID and owns the exact identity/category fallbacks shared by transcript rows, Hydra steps, session history and progress. The native-tool switch is exhaustive; related tools may share a glyph.

System and custom symbols are explicit `SFSymbolResource` values. The custom
[`tool-find-folder`](../OMPGUI/Resources/Assets.xcassets/tool-find-folder.symbolset)
and [`tool-glob-folder`](../OMPGUI/Resources/Assets.xcassets/tool-glob-folder.symbolset)
Symbol Image Sets combine outline `folder` with upper-right
`magnifyingglass.circle.fill` / `asterisk.circle.fill` badges, enlarged 30% from
the native folder-badge reference. The custom
[`tool-analyze-files`](../OMPGUI/Resources/Assets.xcassets/tool-analyze-files.symbolset)
combines `text.menu` with the same magnifying-glass badge at the lower right.
They load by asset name and share the 12 pt symbol font / 16 pt slot, semantic
tint and font scaling with system glyphs; read uses native `text.menu`.
Source and editing notes are in the
[artwork guide](../design/icons/README.md#custom-tool-sf-symbols).

## Registered built-in tools (30)

Primary source: [builtin-names.ts](https://github.com/can1357/oh-my-pi/blob/7967984760906fd35cfefcaa280193edaa0c3241/packages/coding-agent/src/tools/builtin-names.ts)
and [tool factories](https://github.com/can1357/oh-my-pi/blob/7967984760906fd35cfefcaa280193edaa0c3241/packages/coding-agent/src/tools/index.ts).

| Exact tool ID | Purpose | SF Symbol |
| --- | --- | --- |
| read | Read files and resources | text.menu |
| bash | Execute shell commands | terminal |
| edit | Edit file contents | highlighter |
| ast_grep | Search syntax trees | point.3.connected.trianglepath.dotted |
| ast_edit | Edit syntax trees | point.3.filled.connected.trianglepath.dotted |
| ask | Ask the user a question | questionmark.message |
| debug | Debug programs | ladybug |
| ida | Inspect binaries through IDA | cpu |
| eval | Execute JavaScript or Python | curlybraces |
| github | Work with GitHub | point.bottomleft.forward.to.point.topright.scurvepath |
| glob | Match file paths | tool-glob-folder (custom SF Symbol) |
| grep | Search text | magnifyingglass |
| find | Search code by meaning | tool-find-folder (custom SF Symbol) |
| lsp | Language server operations | chevron.left.forwardslash.chevron.right |
| checkpoint | Save a session checkpoint | flag |
| rewind | Return to a checkpoint | arrowshape.turn.up.backward.2 |
| context_notes | Maintain context notes | note.text |
| new_context | Start a fresh context | arrow.trianglehead.2.clockwise.rotate.90 |
| security_scan | Run security analysis | viewfinder.trianglebadge.exclamationmark |
| task | Delegate to native subagents | person.2 |
| wait | Wait for native background work | timelapse |
| todo | Maintain task steps | checklist |
| web_search | Search the web | safari |
| write | Write files and resources | pencil.tip.crop.circle.badge.plus |
| memory_edit | Edit native memory | brain.head.profile |
| retain | Store memories | tray.and.arrow.down |
| recall | Retrieve memories | tray.and.arrow.up |
| reflect | Reflect on memories | ring.light (lightbulb on macOS 26) |
| learn | Save reusable learning | apple.intelligence |
| manage_skill | Manage native skills | books.vertical |

The task row retains the existing Hydra persona glyph when displaying a delegation.
An image read retains its photo preview glyph. The catalog symbols remain available
in tool summaries and Hydra progress.

## Hidden and conditionally exposed tools (3)

These are declared in OMP's HIDDEN_TOOL_NAMES, rather than the normal built-in list.

| Exact tool ID | Purpose | SF Symbol |
| --- | --- | --- |
| yield | Finish or yield a native subagent turn | arrow.turn.up.right |
| goal | Manage native goal execution | target |
| think | External thinking | brain.head.profile |

## Additional native session and workflow tools (9)

These are OMP-owned registrations outside the built-in list. Sources:
[SDK](https://github.com/can1357/oh-my-pi/blob/7967984760906fd35cfefcaa280193edaa0c3241/packages/coding-agent/src/sdk.ts),
[advisor](https://github.com/can1357/oh-my-pi/blob/7967984760906fd35cfefcaa280193edaa0c3241/packages/coding-agent/src/advisor/advise-tool.ts),
[security publication](https://github.com/can1357/oh-my-pi/blob/7967984760906fd35cfefcaa280193edaa0c3241/packages/coding-agent/src/security/publication.ts),
and [vibe tools](https://github.com/can1357/oh-my-pi/blob/7967984760906fd35cfefcaa280193edaa0c3241/packages/coding-agent/src/tools/vibe.ts).

| Exact tool ID | Purpose | SF Symbol |
| --- | --- | --- |
| advise | Consult a native advisor | bubble.left.and.bubble.right |
| security_publish | Publish a native security analysis result | shield.lefthalf.filled |
| generate_image | Generate images | photo.badge.plus |
| tts | Generate speech | waveform |
| vibe_spawn | Start a native vibe session | plus.message |
| vibe_send | Send input to a vibe session | paperplane |
| vibe_wait | Wait for a vibe session | clock |
| vibe_kill | Stop a vibe session | stop.circle |
| vibe_list | List vibe sessions | list.bullet.rectangle |

## Native command helper tools (17)

OMP also defines fixed tool sets for its own specialized command agents. These
receive explicit symbols if their calls appear in a native event stream. Sources:
[commit tools](https://github.com/can1357/oh-my-pi/tree/7967984760906fd35cfefcaa280193edaa0c3241/packages/coding-agent/src/commit/agentic/tools),
[changelog generation](https://github.com/can1357/oh-my-pi/blob/7967984760906fd35cfefcaa280193edaa0c3241/packages/coding-agent/src/commit/changelog/generate.ts),
[autoresearch tools](https://github.com/can1357/oh-my-pi/tree/7967984760906fd35cfefcaa280193edaa0c3241/packages/coding-agent/src/autoresearch/tools),
[compression](https://github.com/can1357/oh-my-pi/blob/7967984760906fd35cfefcaa280193edaa0c3241/packages/coding-agent/src/compress/protocol.ts),
and [sharpshooter](https://github.com/can1357/oh-my-pi/tree/7967984760906fd35cfefcaa280193edaa0c3241/packages/coding-agent/src/sharpshooter).

| Exact tool ID | Purpose | SF Symbol |
| --- | --- | --- |
| propose_commit | Propose a commit | checkmark.seal |
| split_commit | Split a proposed commit | arrow.triangle.branch |
| git_overview | Inspect the Git state | checkmark.rectangle.stack |
| analyze_files | Analyze changed files | tool-analyze-files (custom SF Symbol) |
| git_file_diff | Inspect a file diff | plus.forwardslash.minus |
| recent_commits | Inspect recent commits | clock.badge.checkmark |
| propose_changelog | Propose changelog entries | text.pad.header |
| git_hunk | Inspect a diff hunk | square.grid.3x3.square |
| create_changelog_entries | Generate changelog entries | text.badge.plus |
| init_experiment | Initialize a research experiment | flask |
| run_experiment | Run a research experiment | play.rectangle |
| log_experiment | Record an experiment result | chart.xyaxis.line |
| update_notes | Update research notes | text.pad.header |
| rewrite | Rewrite context during native compression | arrow.trianglehead.2.clockwise.rotate.90 |
| approve | Approve a native context rewrite | hand.thumbsup |
| record_deltas | Record memory changes | square.stack.3d.up |
| replace_memory_files | Replace consolidated memory files | arrow.left.arrow.right.square |

## Native xd:// action devices (4)

These are native action devices invoked through write, rather than separate
entries in BUILTIN_TOOL_NAMES. Sources:
[resolution devices](https://github.com/can1357/oh-my-pi/blob/7967984760906fd35cfefcaa280193edaa0c3241/packages/coding-agent/src/tools/resolve.ts)
and [issue reporting](https://github.com/can1357/oh-my-pi/blob/7967984760906fd35cfefcaa280193edaa0c3241/packages/coding-agent/src/tools/report-tool-issue.ts).

| Exact device ID | Purpose | SF Symbol |
| --- | --- | --- |
| resolve | Apply a staged action | checkmark.circle |
| reject | Discard a staged action | xmark.circle |
| propose | Submit a native plan for approval | doc.badge.clock |
| report_issue | Report a native tool issue | exclamationmark.message |

## Identity, transport and compatibility

- The catalog covers 59 named tools and four action devices with 60 distinct
  SF Symbols. Related memory, context and changelog tools intentionally share glyphs.
- OMP's exact legacy alias search maps to grep. There are no substring, regular
  expression or title-based guesses for native tool identity.
- A write to xd://ast_grep, for example, uses the ast_grep symbol and search
  category. The scheme follows OMP's parseXdUrl; the complete device ID remains
  exact. A read of the same URL displays the read symbol because it reads docs.
- Mounted tools' native JSON arguments supply their command, file or pattern.
  Writes of empty content, ? or help to normal tools read their help rather than
  appearing as execution or delegation. Native wrapped result details supply
  exit codes and file diffs.
- The raw RPC toolName and any invoked toolDevice are saved independently of
  the row's command, path or pattern. For older OMP chats missing these fields,
  history loading restores identities from the associated native session JSONL
  using the exact call ID and GUI namespace. This applies to recent, complete and
  separately loaded older turns. Existing identities remain authoritative.
  Unavailable or ambiguous native identities retain the category symbol; titles
  and output text are never used to guess a tool name. Decode-only legacy
  providers are excluded from recovery.
- Tool, thinking, notice and plan rows use native SF Symbols with a shared 12 pt
  symbol font in a 16 pt slot. The symbol follows the conversation text-size
  setting. Failed calls tint the same glyph red without an error corner badge
  or trailing exit-code label; refusal retains its warning badge. Existing MCP
  artwork and Hydra delegation avatars retain their overrides. Image reads use
  photo, and unresolved delegations use person.2. Hydra detail steps and native
  tool records in session history share this sizing and mapping. Progress,
  controls, menus and disclosure/status glyphs retain their own sizing.
- Browser and computer use are native eval preludes in these OMP versions, not
  additional built-in tool IDs. Calls reported as eval keep the eval symbol.
- MCP tools and user extensions are dynamic OMP-owned registrations. Native
  mcp__ names use powerplug; unknown extension names use wrench.and.screwdriver.
  Older rows without a native identity use the corresponding SF category symbol. They are never guessed
  from their names or title text. The inherited
  MCP server badges remain available only for archives without native identity.

The former Tabler artwork remains preserved and inactive in the asset catalog.
The [artwork guide](../design/icons/README.md#tool-row-tabler-artwork) and
[third-party notices](../THIRD_PARTY_NOTICES.md#tabler-icons) retain its provenance
and licensing. Active rows require no external icon package or SVG parser.

## Companion timeline rows

[TimelineRowIcon.swift](../OMPGUI/UI/Common/TimelineRowIcon.swift) applies the same
12 pt SF Symbol font and 16 pt slot to leading content icons in related timeline rows:

| Row | SF Symbol |
| --- | --- |
| System/information notice | info.circle |
| Warning notice | exclamationmark.triangle |
| Error notice | exclamationmark.square |
| Plan | list.bullet.clipboard |

Information, warning and error notices retain their semantic colours, selectable
content and bounded system-notice disclosure. Plans retain their existing draft
spinner and approval controls. These are presentation roles, not additional OMP
tool IDs. Disclosure arrows and other controls keep their SF Symbols.

When updating OMP compatibility, compare its built-in and hidden name lists and
native registrations with this catalog, add exact identifiers and SF mappings,
and verify native symbol availability through make verify AREAS="icons" after make build.
