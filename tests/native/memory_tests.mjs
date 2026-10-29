import assert from "node:assert/strict";
import { execFile as callback } from "node:child_process";
import { promisify } from "node:util";
import { mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { realpath } from "node:fs/promises";
import { join, resolve } from "node:path";
import { pathToFileURL } from "node:url";
import { installNativeMemoryControls, memoryChannel } from "../../OMPGUI/Resources/OMPMemoryControl.js";

const root = resolve(process.argv[2]), packageRoot = resolve(process.argv[3]);
assert(root.includes("/build.noindex/verification/runs/"));
// Set all native roots before importing OMP; no active profile, account or model service.
process.env.PI_CONFIG_DIR = join(root, "omp");
process.env.PI_CODING_AGENT_DIR = join(root, "agent");
process.env.HOME = join(root, "home");
for (const key of ["OMP_PROFILE", "PI_PROFILE", "PI_CONFIG_FILES", "XDG_DATA_HOME", "XDG_STATE_HOME", "XDG_CACHE_HOME"]) delete process.env[key];
mkdirSync(process.env.HOME, { recursive: true });
mkdirSync(process.env.PI_CODING_AGENT_DIR, { recursive: true });
globalThis.fetch = async () => { throw new Error("Network is disabled in the isolated memory check"); };
const imp = p => import(pathToFileURL(join(packageRoot, "src", p + ".ts")));
const sdk = await imp("index");
const [backend, memorySettings, registry, scopes, state, transcript] = await Promise.all([
    imp("memory-backend/resolve"), imp("memory-backend/settings"), imp("config/registry"), imp("mnemopi/config"), imp("mnemopi/state"), imp("hindsight/transcript"),
]);
const native = { ...backend, ...memorySettings, ...registry, ...scopes, ...state, ...transcript };
const { getBundledModel } = await import(pathToFileURL(Bun.resolveSync("@oh-my-pi/pi-catalog", packageRoot)));
const { AuthStorage } = await imp("session/auth-storage");
const { AssistantMessageEventStream } = await import(pathToFileURL(Bun.resolveSync("@oh-my-pi/pi-ai", packageRoot)));
const { ModelRegistry } = await imp("config/model-registry");
const { ensureTheme, stopThemeWatcher } = await import(pathToFileURL(Bun.resolveSync("@oh-my-pi/pi-tui/theme", packageRoot)));
await ensureTheme();
const options = JSON.parse(readFileSync(join(root, "memory-options.json"), "utf8"));
const execFile = promisify(callback);
const repo = join(root, "project"), linked = join(root, "linked"), other = join(root, "other");
mkdirSync(repo); mkdirSync(other);
await execFile("git", ["init", "-q", repo]);
await execFile("git", ["init", "-q", other]);
await execFile("git", ["-C", repo, "-c", "user.name=Check", "-c", "user.email=check@invalid", "commit", "--allow-empty", "-qm", "Initial"]);
await execFile("git", ["-C", repo, "worktree", "add", "-qb", "linked", linked]);
const agentDir = process.env.PI_CODING_AGENT_DIR;
const profile = join(agentDir, "config.yml"), original = "memory:\n  backend: off\n";
writeFileSync(profile, original);
const authStorage = await AuthStorage.create(join(agentDir, "auth.db"));
authStorage.keys.setRuntime("openai", "isolated-check");
const sessions = [];
let checks = 0;
const expect = (value, message) => { assert.ok(value, message); checks++; };
async function open(cwd, enabled = true, manager) {
    const settings = await sdk.Settings.loadReadOnly({ cwd, agentDir, overrides: {
        "memory.backend": "off", "mnemopi.dbPath": join(agentDir, "memories", "mnemopi.db"),
        "mnemopi.noEmbeddings": true, "mnemopi.llmMode": "none", "lsp.enabled": false,
        "autolearn.enabled": false, "startup.quiet": true, "tools.xdev": false,
    } });
    const modelRegistry = new ModelRegistry(authStorage, join(agentDir, "models.yml"), { settings });
    const result = await sdk.createAgentSession({ cwd, agentDir, settings, authStorage, modelRegistry,
        model: getBundledModel("openai", "gpt-4o-mini"), sessionManager: manager ?? sdk.SessionManager.create(cwd, join(root, "sessions")),
        getApiKey: async () => "isolated-check", disableExtensionDiscovery: true, skills: [], rules: [], contextFiles: [], cacheWarming: false,
        bindProcessState: false });
    sessions.push(result.session);
    const dispose = await installNativeMemoryControls(result.session, result.eventBus, native, enabled ? options.on : options.off, { execFile, realpath });
    const read = (operation, fields = {}) => new Promise(resolve => result.eventBus.emit(memoryChannel,
        { ...fields, requestID: crypto.randomUUID(), operation, sessionID: result.session.sessionId, respond: resolve }));
    return { ...result, read, dispose };
}
try {
    const a = await open(repo), b = await open(linked), c = await open(other);
    const sa = a.session.getMnemopiSessionState(), sb = b.session.getMnemopiSessionState(), sc = c.session.getMnemopiSessionState();
    expect(sa.config.retainBank === sb.config.retainBank, "Same repository worktrees use one native project bank");
    expect(sa.config.retainBank !== sc.config.retainBank, "Other projects stay isolated");
    sa.rememberScoped("Shared repository fact: cobalt-memory-marker", { scope: "bank", extract: false });
    sa.rememberScoped("Shared user preference: amber-global-marker", { scope: "bank", extract: false }, sa.getGlobalRetainTarget());
    const recalledB = await sb.beforeAgentStartPrompt("cobalt-memory-marker amber-global-marker");
    expect(recalledB.context?.includes("cobalt-memory-marker") && recalledB.context?.includes("amber-global-marker"), "Native first-turn recall merges project and global memories across worktrees");
    const recalledC = await sc.beforeAgentStartPrompt("cobalt-memory-marker amber-global-marker");
    expect(!recalledC.context?.includes("cobalt-memory-marker") && recalledC.context?.includes("amber-global-marker"), "Other projects only receive the global fact");
    expect(a.session.getActiveToolNames().includes("recall"), "Native tools are registered when enabled");
    const view = await b.read("inspect");
    expect(view.success && view.data.files.length === 2 && !Object.hasOwn(view.data, "status") && !Object.hasOwn(view.data, "payload"),
        "File inspection reports project/global files without status or prompt text");
    const filesA = (await a.read("inspect")).data.files;
    expect(JSON.stringify(view.data.files) === JSON.stringify(filesA), "Linked worktrees browse the same actual native files");
    const projectFile = view.data.files.find(file => file.scope === "project");
    const globalFile = view.data.files.find(file => file.scope === "global");
    const projectPreview = await b.read("preview", projectFile);
    expect(projectPreview.success && JSON.stringify(projectPreview.data.items).includes("cobalt-memory-marker")
        && !JSON.stringify(projectPreview.data.items).includes("amber-global-marker"), `Project file preview is confined to its native bank: ${JSON.stringify(projectPreview)}`);
    const globalPreview = await b.read("preview", { ...globalFile, query: "amber-global-marker" });
    expect(globalPreview.success && JSON.stringify(globalPreview.data.items).includes("amber-global-marker"), "Global file supports native lexical search");
    const foreignFile = (await c.read("inspect")).data.files.find(file => file.scope === "project");
    expect(!(await b.read("preview", foreignFile)).success, "A stale or unrelated file cannot be opened through another project");
    expect(!(await b.read("preview", { ...projectFile, path: globalFile.path })).success, "Path and bank identity must both match");
    expect(!(await b.read("preview", { ...projectFile, query: "x".repeat(4001) })).success, "Oversized queries are rejected before native search");
    let captured;
    b.session.agent.streamFn = (_model, context) => {
        captured = { systemPrompt: context.systemPrompt?.slice() };
        const stream = new AssistantMessageEventStream();
        queueMicrotask(() => {
            const usage = { input: 1, output: 1, cacheRead: 0, cacheWrite: 0, totalTokens: 2,
                cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0, total: 0 } };
            const message = { role: "assistant", api: "openai-completions", provider: "openai", model: "gpt-4o-mini",
                content: [{ type: "text", text: "Isolated memory check complete" }], stopReason: "stop", usage, timestamp: Date.now() };
            stream.push({ type: "start", partial: message });
            stream.push({ type: "done", reason: "stop", message });
        });
        return stream;
    };
    await b.session.prompt("cobalt-memory-marker amber-global-marker");
    expect(JSON.stringify(captured?.systemPrompt).includes("<memories>") && JSON.stringify(captured?.systemPrompt).includes("cobalt-memory-marker"),
        "The native prompt path actually injects recalled project memory into the first model request");
    const recallEntry = b.session.sessionManager.getBranch().find(entry => entry.customType === "memory_recall");
    expect(recallEntry?.data?.text.includes("cobalt-memory-marker"), "Native transcript persists the delivered recall snapshot");
    const recallBeforePreview = sb.lastRecallSnippet;
    await b.read("preview", { ...globalFile, query: "a different preview query" });
    expect(sb.lastRecallSnippet === recallBeforePreview && b.session.sessionManager.getBranch().find(entry => entry.customType === "memory_recall") === recallEntry,
        "Browsing memory files preserves cached recall and the native persisted prompt snapshot");
    const file = b.session.sessionFile;
    await b.session.dispose();
    const off = await open(linked, false, await sdk.SessionManager.open(file));
    expect(!off.session.getMnemopiSessionState() && !off.session.getActiveToolNames().includes("recall"), "Disabled sessions have neither memory state nor memory tools");
    expect(!off.session.agent.state.systemPrompt.join("\n").includes("# Memory"), "Disabled prompt contains no memory guidance");
    expect(!off.session.agent.state.systemPrompt.join("\n").includes("<memories>"), "Resuming a previously enabled conversation while off drops recalled system context");
    await off.session.dispose();
    const resumed = await open(linked, true, await sdk.SessionManager.open(file));
    const reuse = await resumed.session.getMnemopiSessionState().beforeAgentStartPrompt("a different later question");
    expect(reuse.context === recallEntry.data.text, "Re-enabling/resuming reuses the native historical recall bytes");
    expect(resumed.session.getMnemopiSessionState().lastRetainedTurn === transcript.countUserTurns(resumed.session.sessionManager),
        "The native retention cursor excludes earlier/off-period turns on a new connection");
    expect(readFileSync(profile, "utf8") === original, "GUI settings never modify the isolated native profile");
    writeFileSync(join(root, "summary.json"), JSON.stringify({ status: "passed", checks,
        boundary: "Installed OMP SDK, real Mnemopi SQLite and FTS; no network, external model or GUI" }, null, 2));
    console.log(`PASS native memory: ${checks} shared-scope, recall, inspection and off-state checks`);
} finally {
    for (const session of sessions) await session.dispose();
    stopThemeWatcher();
}
