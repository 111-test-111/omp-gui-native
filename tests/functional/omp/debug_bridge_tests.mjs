import assert from "node:assert/strict";
import { EventEmitter } from "node:events";
import { installDebugCommands, installNativeDebugObservation, debugControlChannel,
    debugObservationChannel, debugDetails } from "../../../OMPGUI/Resources/OMPDebugControl.js";

const emitter = new EventEmitter();
const bus = { on(name, listener) { emitter.on(name, listener); return () => emitter.off(name, listener); },
    emit: (name, value) => emitter.emit(name, value) };
let nativeID = "native-one", subscribe;
const session = { sessionFile: "/isolated/native-one.jsonl", sessionManager: { getSessionId: () => nativeID },
    subscribe(handler) { subscribe = handler; return () => { subscribe = undefined; }; } };
let current = null, adapterReads = 0, variableGate, sessionTree;
const manager = {
    getActiveSession: () => current,
    listSessions: () => sessionTree ?? (current ? [current] : []),
    async stackTrace(levels) {
        adapterReads++; assert.equal(levels, 64);
        return { stackFrames: [{ id: 1, name: "main", source: { path: "/isolated/main.c", sourceReference: 7 }, line: 9,
            instructionPointerReference: "0x10203040" }, { id: 2, name: "caller" }], totalFrames: 90 };
    },
    async scopes(frame) { adapterReads++; assert.ok([1, 2].includes(frame)); return { scopes: [
        { name: "Locals", variablesReference: 100 }, { name: "Registers", variablesReference: 200, presentationHint: "registers" }] }; },
    async variables(reference, signal) {
        adapterReads++; assert.ok([100, 101, 200].includes(reference));
        if (variableGate) return await variableGate(signal);
        return { variables: Array.from({ length: 240 }, (_, i) => ({ name: "值" + i,
            value: "中文😀".repeat(3000), type: "string", variablesReference: 101 })) };
    },
};
const observations = [], hooks = new Map(), commands = new Map();
installDebugCommands({ events: bus, on: (name, fn) => hooks.set(name, fn), registerCommand: (name, command) => commands.set(name, command) });
const dispose = installNativeDebugObservation(session, bus, manager, frame => observations.push(frame));
const latest = () => observations.findLast(value => value.snapshot)?.snapshot;
const ctx = { agent: { kind: "main" }, sessionManager: { getSessionId: () => nativeID, getSessionFile: () => session.sessionFile },
    ui: { notify: () => assert.fail("SDK observations do not fall through to notifications") } };
const event = (action, id = action) => ({ toolName: "debug", toolCallId: id, input: { action } });
let sequence = 0;
function control(operation, extra = {}) {
    return new Promise(resolve => {
        const call = { requestID: "request-" + ++sequence, operation, sessionID: nativeID,
            stopToken: latest()?.stopToken, dapSessionID: current?.id, ...extra, respond: resolve };
        bus.emit(debugControlChannel, call);
        if (!call.handled) resolve({ error: "unhandled" });
    });
}
try {
    assert.equal((await control("hello")).protocolVersion, 1);
    assert.equal(adapterReads, 0, "Handshake and idle metadata must not query the adapter");
    hooks.get("tool_call")(event("launch"), ctx);
    assert.equal(latest().busy, true, "Pending launch blocks recycle before a native DAP session exists");
    current = { id: "dap-one", adapter: "fixture", status: "stopped", threadId: 1, stopReason: "entry" };
    hooks.get("tool_result")({ ...event("launch"), details: { snapshot: current, success: true } }, ctx);
    assert.equal(latest().active, true); assert.equal(latest().busy, false);
    const initialToken = latest().stopToken;
    const initialStop = latest().stopID, initialRun = latest().runID;
    assert.ok(initialStop && initialRun && initialStop !== initialToken);
    assert.equal((await control("variables", { reference: 100 })).error, "stale", "Cannot guess adapter references");
    assert.equal((await control("scopes", { frameID: 1 })).error, "stale", "Cannot guess frame IDs");
    for (const operation of ["continue", "evaluate", "custom_request", "launch", "write_memory"]) {
        assert.equal((await control(operation)).error, "unsupported", "Inspection has no execution/write escape hatch");
    }
    assert.equal(adapterReads, 0);
    const stack = await control("stack");
    assert.equal(stack.data.frames[0].source.path, "/isolated/main.c"); assert.ok(stack.data.limited);
    assert.equal(stack.data.frames[0].source.sourceReference, 7, "Virtual sources retain authority over path-shaped display names");
    assert.equal(stack.data.frames[0].instructionPointerReference, "0x10203040");
    const scopes = await control("scopes", { frameID: 1 });
    assert.equal(scopes.data.scopes[0].reference, 100);
    assert.equal(scopes.data.scopes[1].presentationHint, "registers", "Register classification survives the public scopes projection");
    const variables = await control("variables", { reference: 100 });
    assert.ok(variables.data.limited && variables.data.variables.length < 200);
    assert.ok(Buffer.byteLength(JSON.stringify(variables)) < 55 * 1024);
    assert.ok(variables.data.variables.every(row => !row.value.includes("\uFFFD")), "UTF-8 clipping preserves CJK/emoji");
    await control("variables", { reference: 200 });
    assert.equal(latest().stopID, initialStop, "Read-only inspections retain one logical stop identity");
    const before = adapterReads;
    await new Promise(resolve => setTimeout(resolve, 800));
    assert.equal(adapterReads, before, "Background monitoring never reads stack, variables or output");
    let finish;
    variableGate = () => new Promise(resolve => { finish = resolve; });
    const delayed = control("variables", { reference: 100 });
    hooks.get("tool_call")(event("step_over"), ctx);
    hooks.get("tool_result")({ ...event("step_over"), details: { snapshot: current } }, ctx);
    assert.notEqual(latest().stopToken, initialToken, "A step invalidates references even if it stops on the same line");
    assert.notEqual(latest().stopID, initialStop, "A same-line step still creates a separate historical stop");
    assert.equal(latest().runID, initialRun, "Stepping does not create a new run");
    finish({ variables: [{ name: "stale", value: "must not publish" }] });
    assert.equal((await delayed).error, "stale");
    assert.equal((await control("variables", { reference: 100 })).error, "stale");
    variableGate = undefined;
    await control("stack"); await control("scopes", { frameID: 1 });
    variableGate = signal => new Promise((_, reject) => signal.addEventListener("abort", () => reject(new Error("aborted")), { once: true }));
    const cancelled = control("variables", { requestID: "cancel-me", reference: 100 });
    assert.equal((await control("cancel", { targetRequestID: "cancel-me" })).success, true);
    assert.equal((await cancelled).error, "inspection_failed");
    variableGate = undefined;
    const root = current;
    current = { ...root, id: "dap-child", parentSessionId: root.id };
    sessionTree = [root, current];
    await control("hello");
    assert.equal(latest().runID, initialRun, "Adapter-created child sessions belong to their root run");
    current = { ...root, id: "dap-next" };
    sessionTree = undefined;
    await control("hello");
    assert.notEqual(latest().runID, initialRun, "A new root session has an independent run identity");
    const count = observations.length;
    hooks.get("tool_call")(event("launch", "worker"), { ...ctx, agent: { kind: "subagent" } });
    assert.equal(observations.length, count, "Worker hooks cannot populate the parent debugger");
    hooks.get("tool_call")(event("pause", "aborted"), ctx);
    subscribe({ type: "agent_end" });
    assert.equal(latest().busy, false);
    assert.equal(observations.findLast(value => value.record?.id.endsWith(":aborted")).record.phase, "interrupted");
    const oldToken = latest().stopToken;
    nativeID = "native-two"; session.sessionFile = "/isolated/native-two.jsonl";
    assert.equal((await control("variables", { reference: 100, stopToken: oldToken })).error, "stale");
    current = null;
    await control("hello");
    assert.equal(latest().active, false); assert.equal(latest().session.status, "terminated");
    assert.ok(!observations.some(frame => JSON.stringify(frame).includes("must not publish")));
    const notifications = [];
    await commands.get("omp-gui-debug").handler(JSON.stringify({ requestID: "foreign", operation: "hello" }),
        { ...ctx, agent: { kind: "subagent" }, ui: { notify: value => notifications.push(value) } });
    assert.ok(notifications[0].includes('"error":"unsupported"'));
    const input = { action: "evaluate", expression: "state.lock.owner", frame_id: 42 };
    hooks.get("tool_call")({ toolName: "debug", toolCallId: "detail", input }, ctx);
    hooks.get("tool_result")({ toolName: "debug", toolCallId: "detail", input,
        details: { xdev: { inner: { action: "evaluate", success: true, snapshot: current,
            evaluation: { result: "worker-2", type: "String", variablesReference: 42 } } } },
        content: [{ type: "text", text: "worker-2" }] }, ctx);
    const detail = observations.findLast(value => value.record?.nativeCallID === "detail").record.details;
    assert.deepEqual(JSON.parse(detail.inputJSON), input);
    assert.equal(JSON.parse(detail.resultJSON).evaluation.result, "worker-2");
    assert.equal(detail.output, "worker-2");
    assert.equal(detail.limited, false);
    console.log("PASS debug bridge: native hooks, read-only boundary, identity fences, bounded variables, cancellation, idle monitoring and worker isolation");
} finally { dispose(); }
assert.equal(emitter.listenerCount(debugControlChannel), 0);
assert.equal(emitter.listenerCount(debugObservationChannel), 0);
const fallback = [];
const fallbackContext = { ...ctx, ui: { notify: value => fallback.push(value) } };
hooks.get("agent_end")({}, fallbackContext); // Retire any earlier simulated preflight.
fallback.length = 0;
hooks.get("tool_call")(event("launch", "fallback-aborted"), fallbackContext);
hooks.get("agent_end")({}, fallbackContext);
assert.equal(fallback.length, 2);
assert.ok(fallback[1].includes('"phase":"interrupted"'), "Standalone fallback retires aborted preflight calls");
console.log("PASS standalone debug interruption releases pending observations");
const large = debugDetails({ action: "variables" }, { variables: Array.from({ length: 10000 }, (_, i) => ({
    name: "值" + i, value: "中文😀\"\\\n".repeat(3000), variablesReference: i })) }, "输出😀".repeat(10000));
assert.ok(large.limited && JSON.parse(large.resultJSON).variables.length < 200);
assert.ok(Buffer.byteLength(JSON.stringify(large)) < 64 * 1024);
assert.ok(!JSON.stringify(large).includes("\uFFFD"));
console.log("PASS step details preserve native parameters/results/output with bounded valid UTF-8 JSON");
