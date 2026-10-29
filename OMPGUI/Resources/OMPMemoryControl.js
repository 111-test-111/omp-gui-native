// All recall, retention, tools, prompt construction and storage use OMP's
// published SDK. This bridge supplies repository identity and bounded reads.
export const memoryCommand = "omp-gui-memory";
export const memoryChannel = "omp-gui:memory";
export const memoryResultPrefix = "OMP_GUI_MEMORY_RESULT:";

export function installMemoryCommands(omp) {
    omp.registerCommand(memoryCommand, {
        description: "OMP GUI native memory inspection",
        async handler(args, ctx) {
            let request;
            try { request = JSON.parse(args); } catch { return; }
            if (typeof request?.requestID !== "string" || !["prepare", "inspect", "preview"].includes(request.operation)) return;
            let respond;
            const result = new Promise(resolve => { respond = resolve; });
            const call = { ...request, sessionID: ctx.sessionManager.getSessionId(), handled: false, respond };
            if (ctx.agent.kind === "main") omp.events.emit(memoryChannel, call);
            if (!call.handled) respond({ requestID: request.requestID, operation: request.operation, success: false, error: "unsupported" });
            ctx.ui.notify(memoryResultPrefix + JSON.stringify(await result), "info");
        },
    });
}

export async function repositoryMemoryScope(cwd, { execFile, realpath }) {
    // Git's common directory identifies the repository across linked worktrees,
    // nested working directories and symlink spellings. Different clones stay separate.
    try {
        const { stdout } = await execFile("/usr/bin/git", ["-C", cwd, "rev-parse", "--path-format=absolute", "--git-common-dir"],
            { timeout: 5000, maxBuffer: 16384 });
        return await realpath(stdout.trim());
    } catch (error) {
        // Only a directory outside Git falls back to its own canonical identity.
        const { stdout } = await execFile("/usr/bin/git", ["-C", cwd, "rev-parse", "--is-inside-work-tree"],
            { timeout: 5000, maxBuffer: 16384 }).catch(probe => {
                if (probe.code === 128 && String(probe.stderr).includes("not a git repository")) return { stdout: "false" };
                throw error;
            });
        if (stdout.trim() === "true") throw error;
        return await realpath(cwd);
    }
}

export async function installNativeMemoryControls(session, eventBus, native, options, scopeIO) {
    const { cfgMemoryBackend, lookup, computeMnemopiBankScope,
        MnemopiSessionState, setMnemopiSessionState, countUserTurns } = native;
    if (![session?.settleMemoryBackend, session?.refreshBaseSystemPrompt, session?.getMnemopiSessionState,
        lookup, computeMnemopiBankScope, MnemopiSessionState, setMnemopiSessionState, countUserTurns].every(v => typeof v === "function")) {
        throw new Error("This OMP SDK does not expose the required Mnemopi lifecycle interfaces.");
    }
    const sessionID = () => session.sessionManager.getSessionId();
    // Runtime overrides never write the external active profile. Startup's
    // --config overlay is explicitly off, so no wrong-cwd memory starts first.
    for (const [key, value] of Object.entries({
        "mnemopi.scoping": "per-project-tagged", "mnemopi.autoRecall": options.autoRecall,
        "mnemopi.autoRetain": options.autoRetain,
        "mnemopi.embeddingVariant": options.multilingual ? "multilingual" : "en",
        "mnemopi.injectionTokenLimit": options.tokenBudget,
    })) lookup(key).override(session.settings, value);
    cfgMemoryBackend.override(session.settings, options.enabled ? "mnemopi" : "off");
    await session.settleMemoryBackend();

    let scope = "";
    let scopedState;
    let prepareTail = Promise.resolve();
    const prepare = () => {
        const task = prepareTail.then(async () => {
            await session.settleMemoryBackend();
            if (!options.enabled) return;
            const state = session.getMnemopiSessionState();
            if (!state) throw new Error("OMP could not initialise Mnemopi. Check the native memory configuration.");
            const currentScope = await repositoryMemoryScope(session.sessionManager.getCwd(), scopeIO);
            if (state === scopedState && scope === currentScope) return;
            if (session.isStreaming || session.isCompacting || session.hasPostPromptWork) throw new Error("Wait for OMP to finish before changing the memory scope.");
            // Compose OMP's exported scope and session-state APIs. No SQL, database
            // aliases, private fields, alternate scheduler or custom prompt injection.
            const config = { ...state.config,
                ...computeMnemopiBankScope(state.config.baseBank, currentScope, "per-project-tagged"),
                scoping: "per-project-tagged" };
            setMnemopiSessionState(session, undefined);
            await state.dispose({ retain: false });
            const replacement = new MnemopiSessionState({ session, sessionId: session.sessionId, config,
                // Enabling memory does not retrospectively retain turns written while off.
                lastRetainedTurn: countUserTurns(session.sessionManager) });
            setMnemopiSessionState(session, replacement);
            replacement.attachSessionListeners();
            replacement.promoteEligibleWorkingMemory();
            scope = currentScope;
            scopedState = replacement;
            await session.refreshBaseSystemPrompt();
        });
        prepareTail = task.catch(() => {});
        return task;
    };
    await prepare();
    return eventBus.on(memoryChannel, async request => {
        if (!request || typeof request.respond !== "function" || request.sessionID !== sessionID()) return;
        request.handled = true;
        const origin = sessionID();
        const reply = fields => request.respond({ requestID: request.requestID, operation: request.operation, ...fields });
        try {
            await prepare();
            const state = session.getMnemopiSessionState();
            const data = { enabled: options.enabled, scope,
                projectBank: state?.config.retainBank ?? "", globalBank: state?.config.globalBank ?? "" };
            if (request.operation !== "prepare") {
                const targets = state?.getScopedRecallTargets?.();
                if (!Array.isArray(targets)) throw new Error("This OMP SDK does not expose memory file previews.");
                data.files = targets.slice(0, 16).map(target => {
                    if (typeof target.memory.dbPath !== "string" || !target.memory.dbPath.startsWith("/")) {
                        throw new Error("OMP did not report a memory file path.");
                    }
                    return { bank: target.bank, path: target.memory.dbPath,
                        scope: target.bank === state.config.globalBank ? "global" : "project" };
                });
                if (request.operation === "preview") {
                    const target = targets.find(target => target.bank === request.bank && target.memory.dbPath === request.path);
                    if (!target) throw new Error("This memory file is no longer available for the selected conversation.");
                    const query = request.query ?? "";
                    if (typeof query !== "string" || query.length > 4000) throw new Error("Invalid memory query.");
                    // The public SDK database handle belongs to this exact bank.
                    // Blank recall queries intentionally return no matches, so use
                    // a capped SELECT for browsing. Keyword searches stay native.
                    // Neither path rebuilds the session's prompt/recall snapshot.
                    const items = query.trim() ? await target.memory.recallEnhanced(query, 51, { channelId: target.bank,
                        includeFacts: true, queryEmbedding: null, useCache: false, contentPreviewChars: 4000 })
                        : recentMemoryRows(target.memory);
                    const preview = boundedMemoryPreview(items);
                    Object.assign(data, preview, { bank: target.bank, path: target.memory.dbPath });
                }
            }
            if (sessionID() !== origin) throw new Error("The native session changed during memory inspection.");
            reply({ success: true, data });
        } catch (error) { reply({ success: false, error: String(error.message ?? error) }); }
    });
}

function recentMemoryRows(memory) {
    if (typeof memory.db?.prepare !== "function") throw new Error("This OMP SDK does not expose memory file previews.");
    // Fixed, read-only projection of the native working/episodic/fact stores.
    // Limit both returned rows and content inside SQLite before crossing RPC.
    const statement = memory.db.prepare(`WITH entries AS (
        SELECT id, content, source, timestamp FROM working_memory
        UNION ALL SELECT id, content, source, timestamp FROM episodic_memory
        UNION ALL SELECT fact_id AS id,
            trim(coalesce(subject, '') || ' ' || coalesce(predicate, '') || ' ' || coalesce(object, '')) AS content,
            'facts' AS source, timestamp FROM facts
    ) SELECT substr(id, 1, 256) AS id, substr(content, 1, 4000) AS content,
        substr(source, 1, 256) AS source, substr(timestamp, 1, 128) AS timestamp,
        length(content) > 4000 AS truncated FROM entries ORDER BY timestamp DESC, id LIMIT 51`);
    try { return statement.all().map(row => ({ ...row, truncated: row.truncated === 1 })); }
    finally { statement.finalize(); }
}

export function boundedMemoryPreview(items) {
    let remaining = 65536;
    let limited = items.length > 50;
    const result = [];
    for (const item of items.slice(0, 50)) {
        if (remaining <= 0) { limited = true; break; }
        const content = clipMemoryText(item.content, Math.min(8192, remaining));
        remaining -= new TextEncoder().encode(content.text).length;
        const truncated = item.truncated === true || content.truncated;
        limited ||= truncated;
        result.push({ id: clipMemoryText(item.id, 256).text, content: content.text,
            source: clipMemoryText(item.source, 256).text, timestamp: clipMemoryText(item.timestamp, 128).text, truncated });
    }
    return { items: result, limited };
}

function clipMemoryText(value, limit) {
    const text = String(value ?? "");
    const bytes = new TextEncoder().encode(text);
    if (bytes.length <= limit) return { text, truncated: false };
    let end = limit;
    while (end > 0 && (bytes[end] & 0xc0) === 0x80) end--;
    return { text: new TextDecoder().decode(bytes.subarray(0, end)), truncated: true };
}
