import assert from "node:assert/strict";
import { mkdir, readFile, readdir, writeFile } from "node:fs/promises";
import { join, resolve } from "node:path";
import { pathToFileURL } from "node:url";
import { installRequestCaptureRuntime, captureDirectory } from "../../OMPGUI/Resources/OMPRequestCapture.js";
import { installNativeContextInspection, contextResultPrefix } from "../../OMPGUI/Resources/OMPContextControl.js";

const [output, packageRoot] = process.argv.slice(2);
assert(output.includes("/build.noindex/verification/runs/"));
const sessions = join(output, "sessions"), captureRoot = join(output, "requests"), agentDir = process.env.PI_CODING_AGENT_DIR;
assert(agentDir.startsWith(output + "/"));
await mkdir(sessions, { recursive: true }); await mkdir(agentDir, { recursive: true });
process.env.OMP_GUI_NATIVE_EXECUTABLE = join(packageRoot, "dist", "cli.js");
process.env.OMP_GUI_CAPTURE_ROOT = captureRoot; process.env.OMP_GUI_SESSION_ROOT = sessions;
const imp = name => import(pathToFileURL(Bun.resolveSync(name, packageRoot)).href);
const sdk = await imp("@oh-my-pi/pi-coding-agent");
const { toolWireSchema } = await imp("@oh-my-pi/pi-ai/utils/schema");
const { initializeExtensions } = await imp("@oh-my-pi/pi-coding-agent/modes/runtime-init");
const { AgentRegistry } = await imp("@oh-my-pi/pi-coding-agent/registry/agent-registry");
const { getBundledModel } = await imp("@oh-my-pi/pi-catalog");
const { ModelRegistry } = await imp("@oh-my-pi/pi-coding-agent/config/model-registry");
const { ensureTheme, stopThemeWatcher } = await imp("@oh-my-pi/pi-tui/theme");
await ensureTheme();
const capture = await installRequestCaptureRuntime(AgentRegistry.global());
const requests = [];
let holdMain = true, releaseMain;
const server = Bun.serve({ hostname: "127.0.0.1", port: 0, async fetch(request) {
    assert(new URL(request.url).pathname.endsWith("/chat/completions"));
    const payload = await request.json(); requests.push(payload);
    if (holdMain && JSON.stringify(payload.messages).includes("main capture")) {
        holdMain = false;
        await new Promise(resolve => { releaseMain = resolve; });
    }
    const id = "request-" + requests.length;
    return new Response([
        { id, object: "chat.completion.chunk", created: 1, model: "fixture", choices: [{ index: 0, delta: { role: "assistant", content: "captured answer" }, finish_reason: null }] },
        { id, object: "chat.completion.chunk", created: 1, model: "fixture", choices: [{ index: 0, delta: {}, finish_reason: "stop" }],
            usage: { prompt_tokens: 12, completion_tokens: 3, total_tokens: 15,
                prompt_tokens_details: { cached_tokens: 4 }, completion_tokens_details: { reasoning_tokens: 1 } } },
    ].map(value => `data: ${JSON.stringify(value)}\n\n`).join("") + "data: [DONE]\n\n", {
        headers: { "content-type": "text/event-stream", "x-request-id": id, "set-cookie": "secret=do-not-save" },
    });
} });
const nativeFetch = globalThis.fetch;
globalThis.fetch = (input, options) => {
    const url = new URL(typeof input === "string" || input instanceof URL ? input : input.url);
    assert.equal(url.origin, `http://127.0.0.1:${server.port}`, "Native verification never reaches an external provider");
    return nativeFetch(input, options);
};
const authStorage = await sdk.AuthStorage.create(join(agentDir, "auth.db"));
authStorage.keys.setRuntime("openai", "fixture-only-secret");
const model = { ...getBundledModel("openai", "gpt-4o-mini"), api: "openai-completions",
    baseUrl: `http://127.0.0.1:${server.port}/v1` };

const extension = join(output, "capture-extension.ts");
await writeFile(extension, `import { installRequestCaptureExtension } from ${JSON.stringify(new URL("../../OMPGUI/Resources/OMPRequestCapture.js", import.meta.url).href)};
import { installContextCommands } from ${JSON.stringify(new URL("../../OMPGUI/Resources/OMPContextControl.js", import.meta.url).href)};
export default function(omp) {
    installRequestCaptureExtension(omp);
    installContextCommands(omp);
    omp.on("before_provider_request", event => ({ ...event.payload, capture_fixture: "final-native-hook" }));
}`);
const owned = [];
const inspections = [];
try {
    const create = async (agentId, taskDepth, parent) => {
        const settings = sdk.Settings.isolated({ "memory.backend": "off", "autolearn.enabled": false, "lsp.enabled": false,
            "startup.quiet": true, "compaction.enabled": false, "tools.xdev": false });
        const created = await sdk.createAgentSession({ cwd: output, agentDir, settings, authStorage,
            modelRegistry: new ModelRegistry(authStorage, join(agentDir, "models.yml"), { settings }), model,
            sessionManager: sdk.SessionManager.create(output, sessions), agentId, taskDepth, parentAgentId: taskDepth ? "Main" : undefined,
            disableExtensionDiscovery: true, skills: [], rules: [], contextFiles: [], enableMCP: false, enableLsp: false,
            cacheWarming: false, autoTitle: false, bindProcessState: false, toolNames: ["read"],
            additionalExtensionPaths: parent ? [] : [extension], preloadedPreparedExtensions: parent?.preparedExtensions,
            restrictToolNames: Boolean(parent),
        });
        owned.push(created.session);
        installNativeContextInspection(created.session, created.eventBus, sdk.convertToLlm, toolWireSchema);
        await initializeExtensions(created.session, { reportSendError: (_, error) => { throw error; }, reportRuntimeError: error => { throw new Error(JSON.stringify(error)); },
            uiContext: { ...created.session.extensionRunner.getUIContext(), notify(message) {
                if (message.startsWith(contextResultPrefix)) inspections.push(JSON.parse(message.slice(contextResultPrefix.length)));
            } } });
        return created.session;
    };
    const main = await create("Main", 0);
    const child = await create("capture-child", 1, main);
    const mainRun = main.prompt("main capture"), childRun = child.prompt("child capture");
    const deadline = Date.now() + 5000;
    while (!releaseMain) { assert(Date.now() < deadline, "Main provider request did not arrive"); await Bun.sleep(10); }
    assert(main.isStreaming);
    const leafBefore = main.sessionManager.getLeafId(), messageCount = main.messages.length;
    await main.prompt('/omp-gui-context {"requestID":"native-live-inspection"}');
    const inspection = inspections.find(value => value.requestID === "native-live-inspection");
    assert.equal(inspection.success, true); assert.equal(inspection.protocolVersion, 1);
    assert.equal(inspection.sessionFile, main.sessionFile);
    assert.equal(inspection.native.usedTokens, main.getContextBreakdown().usedTokens);
    assert.equal(inspection.native.systemToolsTokens, main.getContextBreakdown().systemToolsTokens);
    assert.equal(inspection.composition.total, inspection.composition.categories.reduce((n, row) => n + row.tokens, 0));
    assert(inspection.composition.categories.find(row => row.kind === "toolSchemas")?.tokens > 0);
    assert.equal(main.sessionManager.getLeafId(), leafBefore, "Inspection during streaming cannot append a transcript entry");
    assert.equal(main.messages.length, messageCount, "The private command is never model input");
    releaseMain(); releaseMain = null;
    await Promise.all([mainRun, childRun]);
    const side = await main.runEphemeralTurn({ promptText: "side capture", tools: false, dedupeReply: false });
    assert.equal(side.replyText, "captured answer");
    await capture.writer.flush();
    const read = async session => {
        const directory = join(captureRoot, captureDirectory(session.sessionFile));
        return await Promise.all((await readdir(directory)).filter(name => /^[\da-f-]{36}\.json$/.test(name)).map(async name => JSON.parse(await readFile(join(directory, name), "utf8"))));
    };
    const mainRecords = await read(main), childRecords = await read(child);
    assert.equal(capture.writer.lastError, null, "No capture write failure may be hidden by inference success");
    assert.equal(requests.length, 3);
    assert(requests.every(payload => payload.capture_fixture === "final-native-hook"), "Native hooks preserve their final replacement");
    assert.equal(mainRecords.filter(r => r.kind === "model_request").length, 1);
    assert.equal(childRecords.filter(r => r.kind === "model_request").length, 1);
    assert.equal(mainRecords.filter(r => r.kind === "side_request").length, 1);
    for (const [session, records] of [[main, mainRecords], [child, childRecords]]) for (const record of records) {
        assert.equal(record.sessionID, session.sessionId); assert.equal(record.status, "completed");
        assert(record.leafID, "Native branch anchor exists before dispatch");
        assert.equal(record.sections.requestPayload.capture_fixture, "final-native-hook");
        assert(record.sections.requestContext.messages.length > 0);
        assert.equal(record.sections.requestOutput.content[0].text, "captured answer");
        assert(record.sections.responses[0].requestId.startsWith("request-"));
        assert(!JSON.stringify(record).includes("fixture-only-secret"));
        assert(!JSON.stringify(record).includes("do-not-save"));
        if (record.kind === "model_request") {
            assert(record.composition?.total > 0, "Real native tokenizer produces request metadata before clipping");
            assert.equal(record.composition.total, record.composition.categories.reduce((n, row) => n + row.tokens, 0));
            assert.equal(record.reportedUsage.input, 8); assert.equal(record.reportedUsage.output, 3);
            assert.equal(record.reportedUsage.cacheRead, 4); assert.equal(record.reportedUsage.cacheWrite, 0);
            assert.equal(record.reportedUsage.reasoningTokens, 1);
            assert.equal(record.payloadObserved, true);
            const summary = JSON.parse(await readFile(join(captureRoot, captureDirectory(session.sessionFile), record.id + ".summary.json"), "utf8"));
            assert.deepEqual(summary.composition, record.composition, "History reads metadata without loading request bodies");
            assert.deepEqual(summary.reportedUsage, record.reportedUsage, "Fresh sessions persist every reported usage field in the summary read by Context");
            assert.equal(summary.payloadObserved, true, "Fresh summaries retain actual payload callback evidence");
        }
    }
    // Exercise the actual production CLI host as well as direct SDK wiring.
    // The synthetic provider rejects inference; these are inspection commands only.
    const hostExtension = join(output, "context-host-extension.ts");
    await writeFile(hostExtension, `import { installContextCommands } from ${JSON.stringify(new URL("../../OMPGUI/Resources/OMPContextControl.js", import.meta.url).href)};
export default function(omp) {
    installContextCommands(omp);
    omp.registerProvider("omp-gui-context-check", {
        baseUrl: "https://example.invalid/no-model-calls", api: "omp-gui-context-fixture", apiKey: "synthetic-only",
        models: [{ id: "fixture", name: "Context fixture", reasoning: false, input: ["text"],
            cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 }, contextWindow: 8192, maxTokens: 128 }],
        streamSimple() { throw new Error("Host inspection must never call a model"); },
    });
}`);
    const host = new URL("../../OMPGUI/Resources/OMPSDKHost.js", import.meta.url).pathname;
    const processHost = Bun.spawn([process.execPath, host, "--mode", "rpc-ui", "--no-title", "--no-extensions",
        "--model", "omp-gui-context-check/fixture", "--resume", main.sessionFile, "--extension", hostExtension],
        { cwd: output, env: { ...process.env, OMP_GUI_MEMORY_CONFIG: '{"enabled":false}' }, stdin: "pipe", stdout: "pipe", stderr: "pipe" });
    const frames = [], stderr = new Response(processHost.stderr).text();
    let readError;
    const reading = (async () => {
        const decoder = new TextDecoder(); let buffer = "";
        for await (const chunk of processHost.stdout) {
            buffer += decoder.decode(chunk, { stream: true });
            let end;
            while ((end = buffer.indexOf("\n")) >= 0) {
                const line = buffer.slice(0, end); buffer = buffer.slice(end + 1);
                if (line.trim()) frames.push(JSON.parse(line));
            }
        }
    })().catch(error => { readError = error; });
    const send = frame => processHost.stdin.write(JSON.stringify(frame) + "\n");
    const wait = async predicate => {
        const deadline = Date.now() + 10000;
        while (Date.now() < deadline) {
            if (readError) throw readError;
            const frame = frames.find(predicate); if (frame) return frame;
            if (processHost.exitCode !== null) throw Error("Production SDK host exited: " + await stderr);
            await Bun.sleep(10);
        }
        throw Error("Production SDK context inspection timed out");
    };
    try {
        send({ type: "get_state", id: "context-state" });
        const state = await wait(frame => frame.id === "context-state" && frame.type === "response");
        assert.equal(state.success, true);
        send({ type: "prompt", id: "context-read", message: '/omp-gui-context {"requestID":"host-inspection"}' });
        const notification = await wait(frame => frame.type === "extension_ui_request" && frame.message?.startsWith(contextResultPrefix));
        const snapshot = JSON.parse(notification.message.slice(contextResultPrefix.length));
        assert.equal(snapshot.success, true, "The production SDK host must install its optional native inspector");
        assert.equal(snapshot.native.contextWindow, 8192);
        assert(snapshot.composition?.total > 0);
        send({ type: "get_state", id: "context-after" });
        const after = await wait(frame => frame.id === "context-after" && frame.type === "response");
        assert.equal(after.data.messageCount, state.data.messageCount, "Host inspection cannot enter the conversation");
        assert.equal(after.data.isStreaming, false);
    } finally {
        processHost.stdin.end();
        const exited = await Promise.race([processHost.exited.then(() => true), Bun.sleep(5000).then(() => false)]);
        if (!exited) { processHost.kill("SIGTERM"); await processHost.exited; }
        await reading;
    }
    await writeFile(join(output, "summary.json"), JSON.stringify({ status: "passed", requests: requests.length, records: mainRecords.length + childRecords.length,
        boundary: "Installed OMP SDK main, child and ephemeral side calls; native OpenAI HTTP/SSE on loopback; no GUI or external provider" }, null, 2));
    console.log("PASS native request capture: main/child/side identity, final payload, persisted tokenizer metadata, live context command and production SDK host without a model call");
} finally {
    releaseMain?.();
    for (const session of owned.reverse()) await session.dispose();
    await capture.writer.flush(); server.stop(true); authStorage.close(); stopThemeWatcher();
}
