"""The single registry of automated checks. Names describe behavior, not milestones."""
from dataclasses import dataclass


TIERS = ("static", "functional", "native", "benchmark")


@dataclass(frozen=True)
class Check:
    area: str
    description: str
    tier: str = "functional"
    sources: tuple[str, ...] = ()
    app: bool = False
    prepare: str = ""
    recipe: str = "swift"
    inputs: tuple[str, ...] = ()
    tools: tuple[str, ...] = ()
    dependencies: tuple[str, ...] = ()
    timeout: int = 120

    @property
    def id(self):
        return f"{self.tier}:{self.area}"


def app_source(name):
    return (f"tests/{name}_tests.swift",)


def omp_fixture(name):
    return (f"tests/fixtures/omp/{name}.py",)


MARKDOWN = "OMPGUI/UI/Markdown/"
FILES = "OMPGUI/Services/Files/"
PREVIEW = "OMPGUI/UI/Preview/"
MODEL = "OMPGUI/Core/Models/"
SUPPORT = "OMPGUI/Core/Support/"
INLINE = tuple(MARKDOWN + name + ".swift" for name in ("MarkdownInline", "MarkdownMath", "StreamMend"))
FILE_READER = (
    MODEL + "FilePreview.swift", FILES + "FilePreviewError.swift", FILES + "FilePreviewResolver.swift",
    FILES + "PreviewFileLoader.swift", FILES + "PreviewFileWatch.swift", FILES + "PreviewDirectoryBrowser.swift",
    FILES + "PreviewSyntaxHighlighter.swift",
)
RENDERER_SOURCES = (
    "tests/support/preview/renderer_stubs.swift", "OMPGUI/UI/Theme/TypeScale.swift",
    "OMPGUI/UI/Common/RenderBudget.swift", "@PreviewChrome.swift", MODEL + "FilePreview.swift",
    *INLINE, MARKDOWN + "MarkdownParser.swift", FILES + "PreviewSyntaxHighlighter.swift",
    "OMPGUI/UI/Common/CodeSyntaxStyle.swift", "OMPGUI/UI/Theme/CodeHighlightTheme.swift",
    *(PREVIEW + name + ".swift" for name in (
        "FilePreviewContent", "PreviewFloatingControls", "PreviewNativeGlass", "FilePreviewText",
        "FilePreviewMarkdown", "FilePreviewImage", "FilePreviewPDF", "FilePreviewMedia", "FilePreviewQuickLook")),
    "OMPGUI/App/Preview/PreviewSidebarAnimation.swift", "@FrameHostingView.swift",
)
RENDERER_INPUTS = ("OMPGUI/App/Window/WindowManager.swift", "OMPGUI/UI/Chrome/Chrome.swift")
MARKDOWN_PREVIEW_SOURCES = (
    "@Support.swift", "OMPGUI/UI/Theme/TypeScale.swift", MODEL + "FilePreview.swift", PREVIEW + "PreviewNativeGlass.swift",
    "OMPGUI/UI/Theme/CodeHighlightTheme.swift", "OMPGUI/UI/Common/CodeSyntaxStyle.swift",
    FILES + "PreviewSyntaxHighlighter.swift", PREVIEW + "FilePreviewMarkdown.swift",
    "tests/support/math_compatibility.swift",
    "tests/functional/preview/markdown_tests.swift",
)
MARKDOWN_PREVIEW_INPUTS = (PREVIEW + "FilePreviewContent.swift", "tests/benchmarks/math_renderers/corpus.py",
                           "OMPGUI/Resources/MarkdownPreview")

CHECKS = (
    Check("browser-cookie-import", "Native Chrome snapshots, decryption, partition preservation, failure atomicity and fresh profiles",
          sources=app_source("functional/preview/browser_cookie_import"), app=True, recipe="capture"),
    Check("browser-downloads", "Explicit web-download quarantine, unchanged bytes, isolation and missing-file failures",
          sources=("OMPGUI/Services/Browser/BrowserDownloadQuarantine.swift",
                   "tests/functional/preview/browser_download_tests.swift")),
    Check("workspace-browser", "Shared profile selection, conversation-owned tabs, restore, close and bounded resource state",
          sources=app_source("functional/preview/workspace_browser"), app=True, recipe="capture", timeout=45),
    Check("browser-bridge", "Isolated SDK preparation, exact target routing, stale handles and cancellation", recipe="node",
          inputs=("tests/functional/omp/browser_bridge_tests.mjs", "OMPGUI/Resources/OMPBrowserCompatibility.js",
                  "OMPGUI/Resources/OMPBrowserPatches.json", "OMPGUI/Resources/OMPBrowserSupport.js"), tools=("node",)),
    Check("browser-sdk", "Installed public SDK resolves its guarded compatibility copy without a browser or model session",
          tier="native", recipe="native-sdk", inputs=("tests/native/browser_sdk_tests.mjs",
              "OMPGUI/Resources/OMPBrowserCompatibility.js", "OMPGUI/Resources/OMPBrowserPatches.json", "OMPGUI/Resources/OMPBrowserSupport.js",
              "tests/native/browser_eval_tests.mjs", "tests/native/browser_download_tests.mjs"), tools=("bun",), timeout=90),
    Check("documentation", "Local Markdown targets, heading anchors and navigation reachability", tier="static",
          recipe="python", inputs=("tests/tooling/documentation_tests.py", "docs", "README.md", "README.zh-CN.md",
              "AGENTS.md", "CHANGELOG.md", "THIRD_PARTY_NOTICES.md", "TRADEMARK.md", "LICENSE",
              ".github", "design", "release", "scripts", "tests", "OMPGUI", "config", "OMPGUI.xcodeproj", "project.yml"),
          tools=("git",)),
    Check("harness", "Runner contracts, dependency isolation and registry integrity", tier="static",
          recipe="harness", inputs=("tests/tooling",)),
    Check("syntax", "Parse Python, shell, JavaScript and Swift tooling without executing it", tier="static",
          recipe="syntax", inputs=("tests", "scripts"), tools=("bash", "node", "xcrun")),
    Check("organization", "Independent tasks, defaults, project paging, activity ordering and scoped archive deletion",
          sources=app_source("functional/chat/organization"), app=True, recipe="capture"),
    Check("recovery", "Partial library recovery, previous-launch fallback, schema backup and damaged turn preservation",
          sources=app_source("functional/store/recovery"), app=True, recipe="capture"),
    Check("selection", "Owned selection snapshots, fragment quotes, append preservation and Unicode streaming",
          sources=app_source("functional/chat/selection"), app=True, recipe="capture"),
    Check("dictation", "Local dictation permissions, asset setup, draft identity, delivery locks, cancellation and microphone ownership",
          sources=app_source("functional/chat/dictation"), app=True, recipe="capture", timeout=45),
    Check("provider-usage", "Confirmed quotas, compact configured-provider summaries, profile fences, visible read leases and clean vertical model picker",
          sources=app_source("functional/chat/provider_usage"), app=True, recipe="capture", timeout=60,
          dependencies=("functional:provider-balances",)),
    Check("provider-balances", "Official DeepSeek balances, exact money, endpoint ownership, bounded failure and cancellation", recipe="node",
          inputs=("tests/functional/omp/provider_balance_tests.mjs", "OMPGUI/Resources/OMPProviderUsage.js"), tools=("node",)),
    Check("provider-usage", "Installed native credential precedence for read-only DeepSeek balances", tier="native", recipe="native-sdk",
          inputs=("tests/native/provider_usage_tests.mjs", "OMPGUI/Resources/OMPProviderUsage.js", "OMPGUI/Resources/OMPModelConfiguration.js"),
          tools=("bun",), timeout=60),
    Check("provider-logos", "Single bundled brand table, audited native model/key/login identities, logo pixels and precise initial fallbacks",
          sources=app_source("functional/appearance/provider_logo"), app=True,
          inputs=("OMPGUI/Resources/ProviderLogos.json", "docs/evaluations/2026-10-26-provider-brand-audit/native-identities.json"), timeout=60),
    Check("fonts", "Installed monospaced font names, traits and live selection", sources=(
        "OMPGUI/UI/Theme/TypeScale.swift", "tests/functional/appearance/font_tests.swift")),
    Check("wallpaper", "Gaussian wallpaper, opacity, fill crop, dark contrast and solid fallbacks", app=True, recipe="capture",
          sources=app_source("functional/appearance/wallpaper"), timeout=60),
    Check("icons", "Tool-row vector templates, favicon masks, native/SwiftUI appearance and colour preservation",
          sources=app_source("functional/appearance/icon_appearance"), app=True, recipe="capture"),
    Check("lifecycle", "Session lifecycle, discovery coalescing and metrics boundaries",
          sources=app_source("functional/omp/lifecycle"), app=True, recipe="lifecycle", inputs=omp_fixture("rpc")),
    Check("rpc", "Framing, reply identity, cancellation, timeout and damaged new sessions",
          sources=(*app_source("functional/omp/rpc"), "tests/support/event_projection_fixture.swift"),
          app=True, recipe="capture", inputs=omp_fixture("transport")),
    Check("run-options", "Native Fast state, acknowledged retry overrides and request identity fences",
          sources=app_source("functional/omp/run_options"), app=True, recipe="capture", inputs=omp_fixture("run_options")),
    Check("resource-options", "Native Slow scope fences and bounded cache warming observations",
          sources=app_source("functional/omp/resource_options"), app=True, recipe="capture",
          inputs=(*omp_fixture("run_options"), *omp_fixture("goal"))),
    Check("memory", "Memory files, native text previews, repository sharing and graceful transitions", recipe="memory",
          sources=app_source("functional/omp/memory_session"), app=True,
          inputs=("tests/functional/omp/memory_tests.mjs", "OMPGUI/Resources/OMPMemoryControl.js"), tools=("node", "git", "/usr/bin/python3")),
    Check("memory", "Native Mnemopi scope, project/global recall and disabled state", tier="native", recipe="native-memory",
          sources=app_source("native/memory"), app=True,
          inputs=("tests/native/memory_tests.mjs", "OMPGUI/Resources/OMPMemoryControl.js"), tools=("bun", "git"), timeout=120),
    Check("queue", "Native queue identity, recall and removal", recipe="node",
          inputs=("tests/functional/omp/queue_tests.mjs", "OMPGUI/Resources/OMPQueueControl.js"), tools=("node",)),
    Check("debug-bridge", "Debug hooks, read-only queries, stale references, cancellation and bounded values", recipe="node",
          inputs=("tests/functional/omp/debug_bridge_tests.mjs", "OMPGUI/Resources/OMPDebugControl.js"), tools=("node",)),
    Check("debug", "Debug history persistence, process protection, identity and private protocol routing", app=True, recipe="capture",
          sources=app_source("functional/omp/debug"), dependencies=("functional:debug-bridge",)),
    Check("debug", "Installed OMP nested hooks and shared DAP session with an isolated adapter", tier="native", recipe="native-sdk",
          inputs=("tests/native/debug_tests.mjs", "tests/fixtures/omp/debug_adapter.mjs", "OMPGUI/Resources/OMPDebugControl.js"),
          tools=("bun",), timeout=60),
    Check("history", "Native message identity, active paths and malformed history", sources=(
        SUPPORT + "JSONValue.swift", MODEL + "OMPActivity.swift", MODEL + "OMPHistory.swift",
        "tests/functional/omp/history_tests.swift")),
    Check("request-capture", "Request capture correlation, callbacks, redaction, scoped health, failed boundaries, retention and fail-open storage", recipe="node",
          inputs=("tests/functional/omp/request_capture_tests.mjs", "OMPGUI/Resources/OMPRequestCapture.js", "OMPGUI/Resources/OMPContextComposition.js"), tools=("node",)),
    Check("context-bridge", "Native tokenizer composition, exact provenance, bounded metadata and read-only context commands", recipe="node",
          inputs=("tests/functional/omp/context_bridge_tests.mjs", "OMPGUI/Resources/OMPContextComposition.js", "OMPGUI/Resources/OMPContextControl.js"), tools=("node",)),
    Check("context-inspection", "Independent context accounting, branch-safe metadata, visible reader lifetime and responsive native pane",
          sources=app_source("functional/omp/context_inspection"), app=True, recipe="capture", dependencies=("functional:context-bridge",)),
    Check("request-capture", "Installed SDK main, child and side request capture with a local deterministic provider", tier="native", recipe="native-sdk",
          inputs=("tests/native/request_capture_tests.mjs", "OMPGUI/Resources/OMPRequestCapture.js", "OMPGUI/Resources/OMPContextComposition.js",
              "OMPGUI/Resources/OMPContextControl.js", "OMPGUI/Resources/OMPSDKHost.js", "OMPGUI/Resources/OMPQueueControl.js",
              "OMPGUI/Resources/OMPAskDialog.js", "OMPGUI/Resources/OMPDebugControl.js"), tools=("bun",), timeout=90),
    Check("session-records", "Native history paging, bounded tool detail, current ancestry, cached request sidecars, bounded capture summaries, reader lifetime and sidebar columns",
          sources=app_source("functional/omp/session_records"), app=True, recipe="capture"),
    Check("workflows", "Admission/consumption, branches, compaction and handoff fixtures",
          sources=app_source("functional/omp/workflows"), app=True, recipe="capture", inputs=omp_fixture("workflows")),
    Check("goal", "Native goal identity, budget semantics, control confirmation and terminal evidence",
          sources=app_source("functional/omp/goal"), app=True, recipe="capture", inputs=omp_fixture("goal")),
    Check("side-question", "Native side questions, cumulative budgets, draft identity and graceful sidecar disposal",
          sources=app_source("functional/omp/side_question"), app=True, recipe="capture", inputs=omp_fixture("side_question")),
    Check("provider-authentication", "Native login methods, unsupported prompts and API-key-only provider routing", recipe="node",
          inputs=("tests/functional/omp/provider_authentication_tests.mjs", "OMPGUI/Resources/OMPModelConfiguration.js"), tools=("node",)),
    Check("config", "Configuration, extension dialogs and capability fixtures",
          sources=app_source("functional/omp/config"), app=True, recipe="output", tools=("/usr/bin/python3",),
          dependencies=("functional:provider-authentication",)),
    Check("mcp", "Active-profile MCP editing, native overrides, literal secrets and safe atomic writes",
          sources=app_source("functional/omp/mcp_configuration"), app=True, recipe="output", tools=("/bin/sh",)),
    Check("mcp", "Installed OMP active-profile paths and isolated MCP file edits without server execution", tier="native",
          sources=app_source("native/mcp_configuration"), app=True, recipe="native-mcp"),
    Check("mcp-login", "Native OAuth delegation, secret boundaries, cancellation and configuration conflicts", recipe="node",
          inputs=("tests/functional/omp/mcp_login_tests.mjs", "OMPGUI/Resources/OMPMCPLogin.js"), tools=("node",)),
    Check("mcp-login", "Installed OMP OAuth discovery, PKCE, callback and credential storage with a loopback provider", tier="native",
          recipe="native-sdk", inputs=("tests/native/mcp_login_tests.mjs", "OMPGUI/Resources/OMPMCPLogin.js"), tools=("bun",), timeout=45),
    Check("usage", "OMP usage accounting, range boundaries, cache semantics, bounded history reads and native chart layout",
          sources=app_source("functional/chat/usage_statistics"), app=True, recipe="capture"),
    Check("settings", "Embedded settings navigation, window lifetime, retained drafts and bounded layout",
          sources=app_source("functional/chat/settings_navigation"), app=True, recipe="capture"),
    Check("models", "Model detail metadata, price semantics, bounded presentation and persistent picker visibility",
          sources=(*app_source("functional/omp/model_visibility"), "tests/functional/omp/model_metadata_tests.swift"),
          app=True, recipe="capture"),
    Check("workers", "Hydra metadata, history boundaries and worker lifecycle fixtures",
          sources=app_source("functional/omp/workers"), app=True, recipe="capture", inputs=omp_fixture("workers")),
    Check("interactions", "Conversation waiting status, request identity, drafts, cancellation, deadlines and response delivery",
          sources=app_source("functional/omp/interactions"), app=True, recipe="capture", inputs=omp_fixture("rpc")),
    Check("questions", "Ask form models, layout, drafts and serialized responses",
          sources=app_source("functional/chat/questions"), app=True, recipe="output"),
    Check("popovers", "Shared background opacity, inherited measurement environment, stable and content-following viewports, and memory context controls",
          sources=app_source("functional/chat/popover_environment"), app=True, recipe="capture"),
    Check("attachment-previews", "Image popover measurement, loading, cancellation, reopening and failure/retry",
          sources=app_source("functional/chat/attachment_preview"), app=True, recipe="capture", timeout=60),
    Check("resources", "Deterministic process ownership accounting", recipe="python",
          inputs=("tests/functional/omp/resources_tests.py", "tests/support/resource_ledger.py")),
    Check("files", "File loading, watching, encoding and directory boundaries",
          sources=(*FILE_READER, "tests/functional/preview/files_tests.swift")),
    Check("preview-store", "Preview store routing, caching and host environment", prepare="store", sources=(
        *FILE_READER, MODEL + "GitWorkspace.swift", MODEL + "GitBrowseNavigation.swift",
        SUPPORT + "Coding.swift", SUPPORT + "RuntimeMetrics.swift",
        PREVIEW + "FilePreviewActions.swift", "@PreviewReaderState.swift",
        "OMPGUI/App/Preview/FilePreviewStore.swift", "@HostedEnvironment.swift", "@PreviewChatRoot.swift",
        "@MarkdownLinkOpener.swift", "tests/functional/preview/hosting_tests.swift",
        "tests/support/preview/store_stubs.swift", "tests/functional/preview/store_tests.swift"), inputs=(
        PREVIEW + "FilePreviewContent.swift", "OMPGUI/App/Window/WindowManager.swift",
        "OMPGUI/App/Views/RootView.swift", MARKDOWN + "LinkParagraphView.swift")),
    Check("preview-browser", "Retained file-tree expansion, hidden-file policy, exact scroll position and release",
          sources=app_source("functional/preview/browser_state"), app=True, recipe="capture", timeout=45),
    Check("preview-diff", "Single-file Git previews, literal paths, read-only bounds and visible request ownership",
          sources=app_source("functional/preview/file_diff"), app=True, recipe="capture", tools=("git",), timeout=90),
    Check("terminal", "Independent terminal groups, explicit panel moves, retained output and adaptive transparent appearance",
          sources=app_source("functional/chat/terminal"), app=True, recipe="capture", timeout=60),
    Check("preview-entrypoints", "File references and journal entrypoint mapping", prepare="entrypoints", recipe="output",
          sources=(MODEL + "FilePreview.swift", SUPPORT + "JSONValue.swift", SUPPORT + "StdioFramer.swift",
                   MODEL + "OMPTool.swift", "@Models.swift", "@OMPFileReference.swift",
                   "OMPGUI/Services/Providers/OMPToolHistory.swift", "tests/functional/preview/entrypoints_tests.swift"),
          inputs=(MODEL + "Timeline.swift", "OMPGUI/Services/Providers/OMPEventDecoder.swift")),
    Check("preview-renderers", "Offscreen native rendering, opening, animation and controls", prepare="renderers",
          sources=(*RENDERER_SOURCES, *(f"tests/functional/preview/{name}_tests.swift" for name in (
              "text_layout", "animation", "opening", "floating_controls", "renderers"))), inputs=RENDERER_INPUTS),
    Check("markdown-parser", "Block syntax, copy semantics and incremental parsing", sources=(
        MARKDOWN + "MarkdownParser.swift", *INLINE, MARKDOWN + "MessageText.swift",
        "tests/functional/markdown/parser_tests.swift")),
    Check("markdown-layout", "Unicode/CJK, baseline, widths and attributed copy", recipe="output", sources=(
        MARKDOWN + "InlineCodeStyle.swift", MARKDOWN + "InlineLinkIconStyle.swift", *INLINE, MARKDOWN + "MarkdownParagraphLayout.swift",
        "tests/functional/markdown/layout_tests.swift")),
    Check("markdown-tables", "Native table column widths and horizontal overflow", app=True, recipe="capture",
          sources=("tests/functional/markdown/table_layout_tests.swift",)),
    Check("markdown-math", "Shared MathJax attachments, native alignment, alpha, selection, scale, streaming and idle release",
          app=True, recipe="capture", sources=(*app_source("functional/markdown/math"), "tests/support/math_compatibility.swift"),
          inputs=("OMPGUI/Resources/MarkdownPreview",)),
    Check("markdown-hosting", "Complete Markdown hosts settle with nested native math and width changes",
          app=True, recipe="capture", sources=("tests/functional/markdown/hosting_layout_tests.swift",),
          inputs=("OMPGUI/Resources/MarkdownPreview",), timeout=30),
    Check("chat-prose-layout", "Fixed long native prose: displayed-container versus isolated cached width proposals",
          tier="benchmark", app=True, recipe="capture", sources=("tests/benchmarks/chat_prose_layout_tests.swift",)),
    Check("sidebar-layout", "Long native chat/composer layout during resizing versus fixed-width sidebar viewports",
          tier="benchmark", app=True, recipe="capture", sources=("tests/benchmarks/sidebar_layout_tests.swift",)),
    Check("markdown-preparation", "Dense chat waiting, fast/small suppression, reentry, timeout and native scope isolation",
          app=True, recipe="capture", sources=("tests/functional/markdown/preparation_tests.swift",)),
    Check("markdown-preview", "Offline WebKit document host, revisions, links and release", recipe="markdown-preview",
          prepare="markdown-preview", sources=MARKDOWN_PREVIEW_SOURCES, inputs=MARKDOWN_PREVIEW_INPUTS),
    Check("highlighting", "Chat code aliases, syntax colors and native streaming appearance", recipe="output", sources=(
        FILES + "PreviewSyntaxHighlighter.swift", "OMPGUI/UI/Common/CodeSyntaxStyle.swift",
        "OMPGUI/UI/Theme/CodeHighlightTheme.swift",
        MARKDOWN + "MarkdownParser.swift", MARKDOWN + "StreamVeil.swift", *INLINE,
        "tests/functional/markdown/highlighting_tests.swift")),
    Check("diff", "Unified diff parsing and edge cases", sources=(
        "OMPGUI/Services/Git/DiffParser.swift", "tests/functional/git/diff_tests.swift")),
    Check("git-browser", "Read-only worktree browsing, exact topology, pinned pages, parent comparisons, stale reads and toolbar layout",
          sources=app_source("functional/git/browser"), app=True, recipe="capture", tools=("git",), timeout=120),
    Check("git-commit", "Literal staging, reviewed index commits, linked/unborn worktrees, hooks, locks, drafts and narrow toolbar layout",
          sources=app_source("functional/git/commit"), app=True, recipe="capture", tools=("git",), timeout=120),
    Check("file-attribution", "Command ownership across incoming commits, shared-file edits and persisted summaries",
          sources=app_source("functional/git/file_attribution"), app=True, recipe="capture", tools=("git",)),
    Check("timeline", "Timeline answers, snapshots and completion records", sources=app_source("functional/chat/timeline"),
          app=True, recipe="capture"),
    Check("todo", "Todo parsing and synchronization", sources=(
        SUPPORT + "JSONValue.swift", MODEL + "Todo.swift", "OMPGUI/Services/Providers/OMPTodoSnapshot.swift",
        "OMPGUI/Services/Providers/OMPTodoStateSync.swift", "tests/functional/chat/todo_tests.swift")),
    Check("eval", "Eval result decoding, persistence and runtime state", sources=app_source("functional/chat/eval"),
          app=True, recipe="capture"),
    Check("config", "Installed OMP config CLI against an isolated profile", tier="native", recipe="native-config",
          sources=app_source("native/config"), app=True, inputs=omp_fixture("config_cli")),
    Check("model-configuration", "Native provider keys, image backend inventory, credential presence and atomic YAML edits", tier="native",
          recipe="native-model-configuration", inputs=("tests/native/model_configuration_tests.mjs", "OMPGUI/Resources/OMPModelConfiguration.js"),
          tools=("bun",), timeout=90),
    Check("image-tools", "Native image tool activation, live registry changes and model-visible xd:// presentation", tier="native",
          recipe="native-sdk", inputs=("tests/native/image_tools_tests.mjs",), tools=("bun",), timeout=60),
    Check("rpc", "Native OMP protocol with a local deterministic provider", tier="native", recipe="native-rpc",
          sources=app_source("native/rpc"), app=True, inputs=("tests/native/rpc_provider.py",), timeout=300),
    Check("workers", "Installed OMP worker config inheritance and boundary message delivery without a model service",
          tier="native", recipe="native-workers", sources=app_source("native/workers"), app=True,
          inputs=("tests/native/workers_tests.mjs",), tools=("bun",), timeout=90),
    Check("approvals", "Installed native approval choices and production single-call/deny responses", tier="native",
          recipe="native-approvals", sources=app_source("native/approval"), app=True,
          inputs=("tests/native/approval_tests.mjs",), tools=("bun",), timeout=60),
    Check("run-options", "Installed OMP run-option acknowledgements without inference or profile changes", tier="native",
          recipe="native-rpc", sources=app_source("native/run_options"), app=True,
          inputs=("tests/native/rpc_provider.py",), timeout=90),
    Check("goal", "Public native Goal controls, completion, soft budget and process restore with a local provider",
          tier="native", recipe="native-rpc", sources=app_source("native/goal"), app=True,
          inputs=("tests/native/rpc_provider.py",), timeout=180),
    Check("side-question", "Installed OMP side questions, continuation and sidecar disposal", tier="native",
          recipe="native-rpc", sources=app_source("native/side_question"), app=True,
          inputs=("tests/native/rpc_provider.py",), timeout=120),
    Check("resource-options", "Installed OMP Slow refusal and cache warming modes without inference", tier="native",
          recipe="native-rpc", sources=app_source("native/resource_options"), app=True,
          inputs=("tests/native/rpc_provider.py",), timeout=90),
    Check("questions", "Feed Swift form responses to the installed native AskTool", tier="native", recipe="native-questions",
          dependencies=("functional:questions",), tools=("bun",), inputs=(
              "tests/native/questions_tests.mjs", "OMPGUI/Resources/OMPAskDialog.js")),
    Check("fast-write", "Native write hooks, delayed GUI diffs and persisted snapshots", tier="native", recipe="fast-write",
          sources=app_source("native/fast_write"), app=True, tools=("bun",), inputs=("tests/native/fast_write_tests.mjs",)),
    Check("lifecycle", "Explicit repeated lifecycle workload with resource samples", tier="benchmark", recipe="benchmark-lifecycle",
          sources=app_source("functional/omp/lifecycle"), app=True,
          inputs=(*omp_fixture("rpc"), "tests/benchmarks/lifecycle.py", "tests/support/resource_ledger.py"), timeout=200),
    Check("event-projection", "One synthetic full/delta wire-byte and production parse/decode comparison", tier="benchmark",
          sources=("tests/support/event_projection_fixture.swift", "tests/benchmarks/event_projection_tests.swift"),
          app=True, recipe="output"),
    Check("preview-wrap", "Large-source wrap/unwrap timings and viewport layout budget", tier="benchmark", prepare="renderers",
          sources=(*RENDERER_SOURCES, "tests/benchmarks/preview_wrap_tests.swift"), inputs=RENDERER_INPUTS),
    Check("markdown-preview", "Paper rendering and WebKit resource samples; requires --paper", tier="benchmark",
          recipe="benchmark-markdown", prepare="markdown-preview", sources=MARKDOWN_PREVIEW_SOURCES,
          inputs=(*MARKDOWN_PREVIEW_INPUTS, "tests/benchmarks/markdown_preview.py", "tests/benchmarks/math_renderers/run.py"),
          timeout=600),
    Check("math-renderers", "Independent SwiftMath/Temml comparison; downloads pinned dependencies", tier="benchmark",
          recipe="benchmark-math", inputs=("tests/benchmarks/math_renderers", MARKDOWN + "MarkdownMath.swift",
              "tests/benchmarks/math_renderers/SwiftMathBaseline.swift"), tools=("bash", "swift", "curl"), timeout=900),
    Check("chat-math-cold", "Production shared MathJax cold queue and streaming readiness", tier="benchmark",
          app=True, recipe="capture", sources=("tests/benchmarks/chat_math_cold_tests.swift",),
          inputs=("OMPGUI/Resources/MarkdownPreview",)),
    Check("mathjax-attachments", "Shared offline MathJax PDF/PNG attachments, native prose, streaming and resource ledger",
          tier="benchmark", recipe="mathjax-attachments", prepare="markdown-preview", tools=("swift",), timeout=900,
          sources=(*MARKDOWN_PREVIEW_SOURCES[:-1], *(MARKDOWN + name + ".swift" for name in (
              "MarkdownMath", "MarkdownInline", "StreamMend")),
              "tests/benchmarks/math_renderers/SwiftMathBaseline.swift",
              "tests/benchmarks/mathjax_attachments/SharedMathJaxRenderer.swift",
              "tests/benchmarks/mathjax_attachments/attachment_tests.swift"),
          inputs=(*MARKDOWN_PREVIEW_INPUTS, "tests/benchmarks/mathjax_attachments/browser.js",
              "tests/benchmarks/mathjax_attachments/run.py", "tests/benchmarks/mathjax_attachments/summarize.py",
              "tests/support/resource_ledger.py")),
)


def registry():
    result = {check.id: check for check in CHECKS}
    if len(result) != len(CHECKS):
        raise ValueError("Duplicate check IDs in tests/catalog.py")
    return result


def plan(areas, tier="functional", checks=None):
    """Validate all selections first; order dependencies once and reject cycles."""
    checks = registry() if checks is None else checks
    requested = [f"{tier}:{area}" for area in areas]
    unknown = [key for key in requested if key not in checks]
    if unknown:
        raise ValueError("Unknown checks: " + ", ".join(unknown) + ". List choices with make verify TIER=" + tier)
    ordered, visiting, visited = [], set(), set()

    def visit(key):
        if key in visiting:
            raise ValueError(f"Dependency cycle at {key}")
        if key in visited:
            return
        if key not in checks:
            raise ValueError(f"Missing dependency {key}")
        visiting.add(key)
        for dependency in checks[key].dependencies:
            visit(dependency)
        visiting.remove(key)
        visited.add(key)
        ordered.append(checks[key])

    for key in requested:
        visit(key)
    return ordered
