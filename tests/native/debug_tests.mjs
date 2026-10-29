import assert from "node:assert/strict";
import { mkdir, writeFile, readFile } from "node:fs/promises";
import { join, resolve } from "node:path";
import { pathToFileURL, fileURLToPath } from "node:url";
import { installDebugCommands, installNativeDebugObservation, debugControlChannel } from "../../OMPGUI/Resources/OMPDebugControl.js";

const [output, packageRoot] = process.argv.slice(2);
assert.ok(output.includes("/build.noindex/verification/runs/"));
process.env.PI_CONFIG_DIR = join(output, "config");
process.env.PI_CODING_AGENT_DIR = join(output, "agent");
for (const key of ["OMP_PROFILE", "PI_PROFILE", "PI_CONFIG_FILES", "OMP_AUTH_BROKER_URL", "PI_AUTH_BROKER_URL"]) delete process.env[key];
await mkdir(process.env.PI_CODING_AGENT_DIR, { recursive: true });
globalThis.fetch = async () => { throw new Error("Network disabled in the debug SDK check"); };
const imp = subpath => import(pathToFileURL(Bun.resolveSync("@oh-my-pi/pi-coding-agent" + (subpath ? "/" + subpath : ""), packageRoot)).href);
const sdk = await imp("");
const { dapSessionManager } = await imp("dap");
const { AuthStorage } = await imp("session/auth-storage");
const { ModelRegistry } = await imp("config/model-registry");
const { getBundledModel } = await import(pathToFileURL(Bun.resolveSync("@oh-my-pi/pi-catalog", packageRoot)).href);
const { ensureTheme, stopThemeWatcher } = await import(pathToFileURL(Bun.resolveSync("@oh-my-pi/pi-tui/theme", packageRoot)).href);
await ensureTheme();
const settings = sdk.Settings.isolated({ "debug.enabled": true, "tools.approvalMode": "yolo", "tools.xdev": false,
    "lsp.enabled": false, "memory.backend": "off", "autolearn.enabled": false, "startup.quiet": true });
const authStorage = await AuthStorage.create(join(output, "agent", "auth.db"));
const modelRegistry = new ModelRegistry(authStorage, join(output, "agent", "models.yml"), { settings });
const source = join(output, "main.c"), log = join(output, "dap-requests.jsonl");
await writeFile(source, "int main() {\n  return 42;\n}\n");
const result = await sdk.createAgentSession({ cwd: output, agentDir: process.env.PI_CODING_AGENT_DIR, settings, authStorage, modelRegistry,
    model: getBundledModel("openai", "gpt-4o-mini"), sessionManager: sdk.SessionManager.create(output, join(output, "sessions")),
    extensions: [installDebugCommands], disableExtensionDiscovery: true, skills: [], rules: [], contextFiles: [],
    cacheWarming: false, bindProcessState: false });
const observations = [];
const dispose = installNativeDebugObservation(result.session, result.eventBus, dapSessionManager, frame => observations.push(frame));
const current = () => observations.findLast(value => value.snapshot)?.snapshot;
const read = (operation, fields = {}) => new Promise(resolve => result.eventBus.emit(debugControlChannel, {
    requestID: crypto.randomUUID(), sessionID: result.session.sessionId, operation,
    stopToken: current()?.stopToken, dapSessionID: current()?.session?.id, ...fields, respond: resolve }));
try {
    assert.equal((await read("hello")).protocolVersion, 1);
    const adapter = fileURLToPath(new URL("../fixtures/omp/debug_adapter.mjs", import.meta.url));
    await dapSessionManager.launch({ cwd: output, program: source, adapter: { name: "fixture", command: process.execPath,
        resolvedCommand: process.execPath, args: [adapter, source, log], languages: ["c"], fileTypes: ["c"], rootMarkers: [],
        launchDefaults: {}, attachDefaults: {}, connectMode: "stdio", acceptsDirectoryProgram: false } }, undefined, 5000);
    const debug = result.session.getToolForEvalBridge("debug");
    assert.ok(debug, "The native discoverable debug tool is reachable through its nested/eval wrapper");
    const sessions = await debug.execute("nested-sessions", { action: "sessions", timeout: 5 });
    assert.equal(sessions.details.sessions[0].id, dapSessionManager.getActiveSession().id, "The debugger tool and observer share one module singleton");
    assert.ok(observations.some(value => value.record?.id.endsWith(":nested-sessions") && value.record.phase === "begin"));
    assert.ok(observations.some(value => value.record?.id.endsWith(":nested-sessions") && value.record.phase === "end"));
    assert.equal(current().session.status, "stopped");
    const runID = current().runID, stopID = current().stopID;
    assert.ok(runID && stopID && stopID !== current().stopToken);
    const stack = await read("stack"); assert.equal(stack.data.frames[0].source.path, source);
    const scopes = await read("scopes", { frameID: stack.data.frames[0].id });
    const values = await read("variables", { reference: scopes.data.scopes[0].reference });
    assert.equal(values.data.variables[0].value, "42");
    const registers = scopes.data.scopes.find(value => value.presentationHint === "registers");
    assert.ok(registers);
    assert.equal((await read("variables", { reference: registers.reference })).data.variables[0].value, "0x2a");
    assert.equal(current().runID, runID); assert.equal(current().stopID, stopID);
    await debug.execute("native-stack-detail", { action: "stack_trace", timeout: 5 });
    const stackDetail = observations.findLast(value => value.record?.nativeCallID === "native-stack-detail" && value.record.phase === "end").record;
    assert.equal(JSON.parse(stackDetail.details.inputJSON).action, "stack_trace");
    assert.equal(JSON.parse(stackDetail.details.resultJSON).stackFrames[0].source.path, source);
    assert.ok(stackDetail.details.output.includes("main"));
    await debug.execute("native-variable-detail", { action: "variables", variable_ref: scopes.data.scopes[0].reference, timeout: 5 });
    const variableDetail = observations.findLast(value => value.record?.nativeCallID === "native-variable-detail" && value.record.phase === "end").record;
    assert.equal(JSON.parse(variableDetail.details.resultJSON).variables[0].value, "42");
    assert.equal(variableDetail.summary.cwd, output);
    assert.equal((await read("continue")).error, "unsupported");
    await debug.execute("native-end", { action: "terminate", timeout: 5 });
    assert.equal(current().active, false);
    const requests = (await readFile(log, "utf8")).trim().split("\n").map(JSON.parse);
    assert.ok(requests.some(value => value.command === "variables"));
    assert.ok(!requests.some(value => ["continue", "evaluate", "setVariable", "writeMemory"].includes(value.command)));
    await writeFile(join(output, "result.json"), JSON.stringify({ installedSDK: true, nativeHooks: true,
        sameProcessManager: true, stack: true, scopes: true, variables: true, registers: true, runAndStopIdentity: true, executedProgram: false }, null, 2));
    console.log("PASS installed OMP: nested debug hooks, same-process DAP manager, stop/stack/scopes/variables and native termination; isolated adapter, no model or GUI");
} finally {
    dispose();
    await dapSessionManager.terminate(undefined, 1000).catch(() => {});
    await result.session.dispose();
    authStorage.close(); stopThemeWatcher();
}
