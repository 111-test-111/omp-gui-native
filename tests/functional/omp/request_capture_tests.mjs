import assert from "node:assert/strict";
import { mkdtemp, mkdir, writeFile, readFile, readdir, rm, stat, symlink } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { captureSnapshot, captureDirectory, RequestCaptureWriter, RequestCapture, installSessionCapture, installRegistryCapture } from "../../../OMPGUI/Resources/OMPRequestCapture.js";

const root = await mkdtemp(join(tmpdir(), "omp-gui-capture-"));
const sessions = join(root, "sessions"), captures = join(root, "requests");
await mkdir(sessions);
const file = join(sessions, "native.jsonl"); await writeFile(file, "{}\n");
const writer = new RequestCaptureWriter(captures, sessions);
const capture = new RequestCapture(writer);
const model = { id: "fixture", provider: "local", api: "fixture" };
const result = { role: "assistant", content: [{ type: "text", text: "answer" }], stopReason: "stop", usage: { totalTokens: 12 } };
let leafID = "leaf-one", fileID = "session-one", modifierCalls = 0, responseCalls = 0;
const session = { sessionManager: { getSessionFile: () => file, getSessionId: () => fileID, getLeafId: () => leafID },
    prepareSimpleStreamOptions: options => options,
    model,
    async compact() {
        await this.extensionRunner.emitBeforeProviderRequest({ maintenance: true }, model);
        await this.extensionRunner.emitAfterProviderResponse({ status: 200, requestId: "maintenance" }, model);
        return { summary: "compacted" };
    },
    async generateTitle() { return "local title"; },
    async handoff() { throw new Error("handoff failure"); },
    agent: { streamFn(m, ctx, opts) {
        const done = (async () => {
            const payload = { messages: ctx.messages, password: "private", image: { type: "image", data: "binary" } };
            assert.equal(await opts.onPayload(payload, m), undefined, "Undefined modifiers preserve the original native return");
            payload.messages[0] = "mutated after observation";
            await opts.onResponse({ status: 200, requestId: ctx.id, headers: { "x-request-id": ctx.id, "set-cookie": "secret", authorization: "token" } }, m);
            opts.onSseEvent({ event: "message", data: "{}" }, m);
            return result;
        })();
        return { result: () => done, async *[Symbol.asyncIterator]() { await done; yield result; } };
    } }, extensionRunner: { async emitBeforeProviderRequest(payload) { return { ...payload, final: true }; }, async emitAfterProviderResponse() {} }, addDisposer(fn) { this.dispose = fn; } };
try {
    installSessionCapture(session, capture);
    const wrapped = session.agent.streamFn; installSessionCapture(session, capture); assert.equal(session.agent.streamFn, wrapped);
    const runs = ["one", "two"].map(id => session.agent.streamFn(model, { id, messages: [id] }, {
        apiKey: "super-secret", onPayload() { modifierCalls++; }, onResponse() { responseCalls++; }, sessionId: id,
    }));
    await Promise.all(runs.map(async stream => { for await (const event of stream) assert.equal(event, result); }));
    await writer.flush();
    const directory = join(captures, captureDirectory(file));
    const documents = async () => Promise.all((await readdir(directory)).filter(name => /^[\da-f-]{36}\.json$/.test(name)).map(async name => JSON.parse(await readFile(join(directory, name), "utf8"))));
    let docs = await documents();
    assert.equal(docs.length, 2); assert.equal(modifierCalls, 2); assert.equal(responseCalls, 2);
    for (const d of docs) {
        assert.equal(d.status, "completed"); assert.equal(d.leafID, "leaf-one"); assert.equal(d.tokens, 12);
        assert.equal(d.sections.requestPayload.messages[0], d.sections.requestOptions.sessionId);
        assert.equal(d.sections.responses[0].requestId, d.sections.requestOptions.sessionId, "Concurrent responses use their own logical request closure");
        assert.equal(d.sections.requestPayload.password, "[redacted]");
        assert.equal(d.sections.requestPayload.image.data, "[redacted]");
        assert(!JSON.stringify(d).includes("super-secret")); assert(!JSON.stringify(d).includes("set-cookie"));
        assert.equal(d.sections.requestOutput.content[0].text, "answer");
        assert.equal((await stat(join(directory, d.id + ".json"))).mode & 0o777, 0o600);
    }
    // Side calls retain final callback replacements and response ownership,
    // even when the same AbortSignal and model are used concurrently.
    const controller = new AbortController();
    const sideA = session.prepareSimpleStreamOptions({ signal: controller.signal, onPayload: payload => ({ ...payload, replacement: "A" }) });
    const sideB = session.prepareSimpleStreamOptions({ signal: controller.signal, onPayload: payload => ({ ...payload, replacement: "B" }) });
    assert.equal((await sideA.onPayload({}, model)).replacement, "A");
    await sideB.onPayload({}, model);
    await sideB.onResponse({ requestId: "B" }, model); await sideA.onResponse({ requestId: "A" }, model);
    sideB.onSseEvent({ data: "[DONE]" }); controller.abort(); await writer.flush();
    docs = await documents();
    const sides = docs.filter(d => d.kind === "side_request"); assert.equal(sides.length, 2);
    for (const d of sides) { assert.equal(d.sections.responses[0].requestId, d.sections.requestPayload.replacement); assert.equal(d.status, "observed", "A callback-only observation must not invent a terminal model result"); }
    assert(sides.every(d => !("requestOptions" in d.sections)), "Callback-only side requests must not record empty options");
    // A provider stream exception is passed through unchanged and persisted.
    const failure = new Error("synthetic failure");
    const broken = { ...session, extensionRunner: undefined, agent: { streamFn() { throw failure; } } };
    installSessionCapture(broken, capture);
    assert.throws(() => broken.agent.streamFn(model, {}), e => e === failure);
    // Native helpers without a public request scope stay separate observations.
    await session.extensionRunner.emitBeforeProviderRequest({ helper: true }, model);
    await session.extensionRunner.emitAfterProviderResponse({ requestId: "unpaired" }, model);
    await writer.flush(); docs = await documents();
    assert.equal(docs.filter(d => d.kind === "provider_payload").length, 1);
    const providerPayload = docs.find(d => d.kind === "provider_payload");
    const providerResponse = docs.find(d => d.kind === "provider_response");
    assert.equal(providerPayload.sections.requestPayload.helper, true);
    assert(!("requestOptions" in providerPayload.sections), "Provider observations must not record empty request options");
    assert(!("requestOptions" in providerResponse.sections), "Provider responses must not default to empty request options");
    assert.equal(providerResponse.sections.responses[0].requestId, "unpaired");
    assert.equal(docs.find(d => d.status === "failed").sections.requestError.message, "synthetic failure");
    await session.compact();
    await session.generateTitle();
    await writer.flush(); docs = await documents();
    const maintenance = docs.find(d => d.sections.capture.resultBoundary === "compact");
    assert.equal(maintenance.sections.requestPayload.maintenance, true);
    assert.equal(maintenance.sections.responses[0].requestId, "maintenance");
    assert.equal(maintenance.sections.requestOutput.summary, "compacted");
    assert(!docs.some(d => d.sections.capture.resultBoundary === "generateTitle"), "A local operation without provider callbacks must not invent a request");
    await assert.rejects(session.handoff(), /handoff failure/);
    await writer.flush(); docs = await documents();
    const rejectedSide = docs.find(d => d.sections.capture.resultBoundary === "handoff");
    assert(rejectedSide && rejectedSide.status === "failed" && rejectedSide.sections.requestError.message === "handoff failure",
        "A failed maintenance boundary must be retained without provider evidence");
    // Future registry sessions and switched branches resolve identities at dispatch.
    let listener; const registry = { list: () => [], onChange(fn) { listener = fn; } };
    installRegistryCapture(registry, capture);
    const child = { ...session, extensionRunner: undefined, agent: { streamFn: () => ({ result: async () => result }) } };
    listener({ ref: { session: child } }); leafID = "leaf-two"; fileID = "session-two";
    await child.agent.streamFn(model, {}).result(); await writer.flush();
    assert((await documents()).some(d => d.leafID === "leaf-two" && d.sessionID === "session-two"));
    // Bounded cyclic/large snapshots; native getters and auth containers never run.
    let getter = false; const value = { text: "中文😀".repeat(100000), api_key: "secret", tokens: 12 };
    value.cycle = value; Object.defineProperty(value, "get", { enumerable: true, get() { getter = true; throw failure; } });
    const snapshot = captureSnapshot(value, 4096); assert(snapshot.truncated); assert(!getter); assert(Buffer.byteLength(JSON.stringify(snapshot.value)) <= 4096);
    // Retention and write failures never reject provider work or follow symlinks.
    const tiny = new RequestCaptureWriter(join(root, "tiny"), sessions, { records: 1 });
    for (const d of (await documents()).slice(0, 3)) { tiny.enqueue(d); await tiny.flush(); }
    assert.equal((await readdir(join(root, "tiny", captureDirectory(file)))).filter(n => n.endsWith(".summary.json")).length, 1);
    const unsafeRoot = join(root, "unsafe"); await symlink(captures, unsafeRoot);
    const unsafe = new RequestCaptureWriter(unsafeRoot, sessions); unsafe.enqueue(docs[0]); await unsafe.flush();
    assert.equal(unsafe.lastError, "capture_write_failed");
    // Health follows the failed session, not the whole capture store, and a
    // successful write for that session clears it.
    const healthSessions = join(root, "health-sessions"); await mkdir(healthSessions);
    const healthFile = join(healthSessions, "health.jsonl"); await writeFile(healthFile, "{}\n");
    const healthRoot = join(root, "health-requests");
    const healthWriter = new RequestCaptureWriter(healthRoot, healthSessions);
    const healthName = captureDirectory(healthFile) + ".health.json";
    await healthWriter.report("capture_write_failed", healthFile);
    const health = join(healthRoot, healthName);
    assert.equal(JSON.parse(await readFile(health, "utf8")).code, "capture_write_failed");
    assert((await readdir(healthRoot)).includes(healthName), "Session health must be written at the capture root");
    assert(!(await readdir(healthRoot)).some(name => name.endsWith(".health.json") && !/^[\da-f]{64}\.health\.json$/.test(name)),
        "Session failures must not create a process-wide health mark");
    healthWriter.enqueue({ id: "00000000-0000-4000-8000-000000000000", sessionFile: healthFile, schema: 1,
        sessionID: "health", leafID: null, kind: "model_request", status: "completed", startedAt: 1, updatedAt: 1,
        pid: process.pid, ownerID: healthWriter.ownerID, sections: {}, payloads: [], responses: [] });
    await healthWriter.flush();
    await assert.rejects(readFile(health, "utf8"), error => error.code === "ENOENT");
    console.log("PASS request capture: immutable concurrent snapshots, callbacks, side requests, exceptions, registry, identity, redaction, scoped health, retention and fail-open storage");
} finally { await writer.flush(); await rm(root, { recursive: true, force: true }); }
