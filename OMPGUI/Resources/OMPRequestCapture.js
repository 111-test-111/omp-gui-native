// Read-only observation of public OMP stream, registry and extension-runner APIs.
// Never changes provider routing, retries, credentials, context or stream consumption.
import { AsyncLocalStorage } from "node:async_hooks";
import { createHash, randomUUID } from "node:crypto";
import * as fs from "node:fs/promises";
import { constants } from "node:fs";
import { basename, dirname, join, resolve, sep } from "node:path";
import { pathToFileURL } from "node:url";
import { contextComposition } from "./OMPContextComposition.js";

export const captureLimits = Object.freeze({ section: 1024 * 1024, document: 5 * 1024 * 1024,
    nodes: 40000, depth: 32, active: 16, pending: 32, records: 512,
    sessionBytes: 64 * 1024 * 1024, totalBytes: 512 * 1024 * 1024, totalRecords: 8192, days: 30 });
const scope = new AsyncLocalStorage();
const callbackScope = new AsyncLocalStorage();
const installed = new WeakSet();
const abortCleanups = new WeakMap();
const deferredRecords = new WeakSet();
const observedRegistries = new WeakSet();
const secretKey = /^(?:.*(?:api.?key|authorization|password|passwd|access.?token|refresh.?token|id.?token|client.?secret|private.?key|cookie|credential|signature|providerPayload).*)$/i;
const safeOptionKeys = ["sessionId", "parentSessionId", "temperature", "topP", "maxTokens", "reasoning", "thinkingBudgets", "disableReasoning", "minimizeEffort", "serviceTier", "toolChoice", "cacheRetention", "preferWebsockets", "maxRetryDelayMs", "maxRetries", "timeout", "hideThinkingSummary"];
const safeHeader = /^(?:content-type|content-length|date|retry-after|request-id|x-request-id|x-amzn-requestid|x-ratelimit-[\w-]+|anthropic-ratelimit-[\w-]+|openai-processing-ms)$/i;
const safeOptions = options => Object.fromEntries(safeOptionKeys.filter(key => options?.[key] !== undefined).map(key => [key, options[key]]));
const redactText = text => text.replace(/\b(?:Bearer|Basic)\s+[A-Za-z0-9+/_=.-]+/gi, "[redacted]")
    .replace(/\b(?:sk|sess)-[A-Za-z0-9_-]{12,}/g, "[redacted]")
    .replace(/data:[^;,\s]+;base64,[A-Za-z0-9+/=]+/g, "[image omitted]");
const cut = (value, bytes) => {
    const data = Buffer.from(value);
    if (data.length <= bytes) return value;
    let end = bytes;
    while (end && (data[end] & 0xc0) === 0x80) end--;
    return data.subarray(0, end).toString() + "…";
};

// No JSON.stringify of live objects, getters, binary buffers, callbacks or auth stores.
// Both traversal and the final encoded value are bounded, including escaped text.
export function captureSnapshot(value, budget = captureLimits.section) {
    const seen = new WeakSet();
    let remaining = budget, nodes = 0, truncated = false, redacted = false;
    const omit = () => { truncated = true; return "[capture limit]"; };
    const visit = (v, depth, key = "", parent) => {
        if (++nodes > captureLimits.nodes || depth > captureLimits.depth || remaining < 80) return omit();
        if (secretKey.test(key) || (/^(data|blob|bytes|base64)$/i.test(key) && (parent?.type === "image" || parent?.type === "base64" || /image|audio/.test(parent?.mimeType ?? "")))) {
            redacted = true; return "[redacted]";
        }
        if (typeof v === "string") {
            const bounded = cut(v, budget * 6), safe = redactText(bounded);
            truncated ||= bounded !== v;
            let text = safe;
            if (Buffer.byteLength(JSON.stringify(text)) > remaining - 32) {
                let low = 0, high = Math.min(Buffer.byteLength(text), remaining - 32);
                while (low < high) {
                    const mid = Math.ceil((low + high) / 2);
                    if (Buffer.byteLength(JSON.stringify(cut(safe, mid))) <= remaining - 32) low = mid;
                    else high = mid - 1;
                }
                text = cut(safe, low);
            }
            redacted ||= safe !== v; truncated ||= safe !== text;
            remaining -= Buffer.byteLength(JSON.stringify(text)); return text;
        }
        if (v == null || typeof v === "boolean" || typeof v === "number") { remaining -= 24; return v ?? null; }
        if (typeof v !== "object" || ArrayBuffer.isView(v) || v instanceof ArrayBuffer) { redacted = true; return "[omitted]"; }
        if (seen.has(v)) return omit();
        seen.add(v);
        const output = Array.isArray(v) ? [] : Object.create(null);
        let count = 0;
        for (const name in v) {
            if (!Object.hasOwn(v, name)) continue;
            if (++count > 10000 || remaining < 128 || nodes >= captureLimits.nodes) { truncated = true; break; }
            const descriptor = Object.getOwnPropertyDescriptor(v, name);
            if (!descriptor || !("value" in descriptor) || descriptor.value === undefined) continue;
            if (Buffer.byteLength(name) > 256) { truncated = true; continue; }
            remaining -= Buffer.byteLength(JSON.stringify(name)) + 4;
            output[name] = visit(descriptor.value, depth + 1, name, v);
        }
        seen.delete(v);
        return output;
    };
    try {
        const data = visit(value, 0);
        if (Buffer.byteLength(JSON.stringify(data)) > budget) return { value: "[capture limit]", truncated: true, redacted };
        return { value: data, truncated, redacted };
    } catch { return { value: "[capture unavailable]", truncated: true, redacted }; }
}

export const captureDirectory = file => createHash("sha256").update(resolve(file)).digest("hex");
const privateDirectory = async path => {
    await fs.mkdir(path, { recursive: true, mode: 0o700 });
    const info = await fs.lstat(path);
    if (!info.isDirectory() || info.isSymbolicLink() || await fs.realpath(path) !== resolve(path)) throw new Error("Unsafe capture directory");
    await fs.chmod(path, 0o700);
};
const atomicWrite = async (path, value) => {
    const temporary = path + "." + randomUUID() + ".tmp";
    const handle = await fs.open(temporary, constants.O_WRONLY | constants.O_CREAT | constants.O_EXCL | constants.O_NOFOLLOW, 0o600);
    try {
        try { await handle.writeFile(JSON.stringify(value)); }
        finally { await handle.close(); }
        await fs.rename(temporary, path);
    }
    finally { await fs.unlink(temporary).catch(() => {}); }
};

export class RequestCaptureWriter {
    constructor(root, sessionsRoot, limits = {}) {
        this.root = resolve(root); this.sessionsRoot = resolve(sessionsRoot);
        this.limits = { ...captureLimits, ...limits }; this.pending = new Map();
        this.ownerID = randomUUID(); this.lastError = null; this.running = null; this.lastPrune = 0;
    }
    enqueue(document) {
        if (this.pending.size >= this.limits.pending && !this.pending.has(document.id)) {
            this.report("capture_queue_full", document.sessionFile); return;
        }
        // A replacement snapshot releases the old one; no per-token write queue.
        this.pending.set(document.id, structuredClone(document));
        this.kick();
    }
    kick() {
        this.running ??= this.drain().finally(() => { this.running = null; if (this.pending.size) this.kick(); });
    }
    async flush() { while (this.running) await this.running; }
    async refreshLease() {
        await privateDirectory(this.root);
        await atomicWrite(join(this.root, this.ownerID + ".owner.json"), { id: this.ownerID, pid: process.pid, updatedAt: Date.now() });
        await fs.unlink(join(this.root, this.ownerID + ".health.json")).catch(() => {});
    }
    async report(code, sessionFile = null) {
        this.lastError = code;
        process.stderr.write(`[OMP GUI request capture] ${code}\n`);
        try {
            await privateDirectory(this.root);
            // Session-scoped failures must not mark unrelated history. Keep a
            // separate owner-scoped file only for context-free diagnostics.
            const health = sessionFile ? join(this.root, captureDirectory(sessionFile) + ".health.json")
                : join(this.root, this.ownerID + ".health.json");
            await atomicWrite(health, { code, timestamp: Date.now(), sessionFile: sessionFile ? resolve(sessionFile) : null });
            if (sessionFile) await atomicWrite(join(this.root, ".revision"), { timestamp: Date.now() });
        } catch {}
    }
    async drain() {
        while (this.pending.size) {
            const [id, document] = this.pending.entries().next().value; this.pending.delete(id);
            try {
                const file = resolve(document.sessionFile);
                // OMP can dispatch before its buffered initial JSONL write. Its
                // existing parent must still resolve exactly inside our store.
                if (!file.startsWith(this.sessionsRoot + sep) || !file.endsWith(".jsonl") ||
                    join(await fs.realpath(dirname(file)), basename(file)) !== file) throw new Error("session_outside_store");
                const source = await fs.lstat(file).catch(error => { if (error.code === "ENOENT") return null; throw error; });
                if (source && (!source.isFile() || source.isSymbolicLink())) throw new Error("session_outside_store");
                await this.refreshLease();
                const directory = join(this.root, captureDirectory(file));
                await privateDirectory(directory);
                if (Buffer.byteLength(JSON.stringify(document)) > this.limits.document) throw new Error("capture_document_limit");
                await atomicWrite(join(directory, id + ".json"), document);
                const { schema, sessionID, sessionFile, leafID, kind, startedAt, updatedAt, status, model, provider, duration, tokens, ownerID, pid, truncated, redacted, eventCount,
                    composition, reportedUsage, contextWindow, payloadObserved } = document;
                await atomicWrite(join(directory, id + ".summary.json"), { schema, id, sessionID, sessionFile, leafID, kind,
                    startedAt, updatedAt, status, model, provider, duration, tokens, ownerID, pid, truncated, redacted, eventCount,
                    composition, reportedUsage, contextWindow, payloadObserved });
                await this.prune(directory);
                await atomicWrite(join(this.root, ".revision"), { id, updatedAt });
                await fs.unlink(join(this.root, captureDirectory(file) + ".health.json")).catch(() => {});
                if (this.lastError) this.lastError = null;
            } catch { await this.report("capture_write_failed", document.sessionFile); }
        }
    }
    async prune(directory) {
        const now = Date.now(), files = [];
        for (const name of await fs.readdir(directory)) {
            if (/^[\da-f-]{36}\.(?:summary\.)?json\.[\da-f-]{36}\.tmp$/.test(name)) {
                const file = join(directory, name), info = await fs.lstat(file);
                if (info.isFile() && now - info.mtimeMs > 86400000) await fs.unlink(file).catch(() => {});
                continue;
            }
            if (!/^[\da-f-]{36}\.json$/.test(name)) continue;
            const path = join(directory, name), stat = await fs.lstat(path);
            if (stat.isFile() && !stat.isSymbolicLink()) files.push({ path, stat, summary: path.replace(/\.json$/, ".summary.json") });
        }
        files.sort((a, b) => b.stat.mtimeMs - a.stat.mtimeMs);
        let size = 0;
        for (let i = 0; i < files.length; i++) {
            const { path, stat, summary } = files[i]; size += stat.size;
            if (i >= this.limits.records || size > this.limits.sessionBytes || now - stat.mtimeMs > this.limits.days * 86400000) {
                await fs.unlink(summary).catch(() => {}); await fs.unlink(path).catch(() => {});
            }
        }
        // Global retention runs at most once per minute, never on the model's await path.
        if (now - this.lastPrune < 60000) return;
        this.lastPrune = now;
        const all = [], directories = [];
        for (const name of await fs.readdir(this.root)) {
            if (/^[\da-f-]{36}\.(owner|health)\.json$/.test(name) || /^[\da-f]{64}\.health\.json$/.test(name)) {
                const file = join(this.root, name), stat = await fs.lstat(file);
                if (stat.isFile() && now - stat.mtimeMs > 86400000) await fs.unlink(file).catch(() => {});
                continue;
            }
            if (!/^[\da-f]{64}$/.test(name)) continue;
            const path = join(this.root, name), stat = await fs.lstat(path);
            if (!stat.isDirectory() || stat.isSymbolicLink()) continue;
            directories.push(path);
            for (const entry of await fs.readdir(path)) {
                if (!/^[\da-f-]{36}\.json$/.test(entry)) continue;
                const file = join(path, entry), info = await fs.lstat(file);
                if (info.isFile() && !info.isSymbolicLink()) all.push({ file, info });
            }
        }
        all.sort((a, b) => b.info.mtimeMs - a.info.mtimeMs); size = 0;
        let count = 0;
        for (const { file, info } of all) {
            size += info.size;
            if (++count > this.limits.totalRecords || size > this.limits.totalBytes || now - info.mtimeMs > this.limits.days * 86400000) {
                await fs.unlink(file.replace(/\.json$/, ".summary.json")).catch(() => {}); await fs.unlink(file).catch(() => {});
            }
        }
        for (const path of directories) await fs.rmdir(path).catch(() => {});
    }
}

export class RequestCapture {
    constructor(writer, convertToLlm, toolWireSchema) { this.writer = writer; this.convertToLlm = convertToLlm; this.toolWireSchema = toolWireSchema; this.active = new Set(); }
    start(session, model, kind, context, options = {}, deferred = false) {
        const manager = session.sessionManager;
        const file = manager?.getSessionFile(), sessionID = manager?.getSessionId();
        if (!file || typeof sessionID !== "string" || sessionID.length > 512) return null;
        if (this.active.size >= captureLimits.active) { void this.writer.report("capture_active_limit", file); return null; }
        const record = { schema: 1, id: randomUUID(), sessionFile: resolve(file), sessionID,
            leafID: manager.getLeafId?.() ?? null, kind, status: "running", model: model?.id, provider: model?.provider,
            startedAt: Date.now(), updatedAt: Date.now(), ownerID: this.writer.ownerID, pid: process.pid,
            truncated: false, redacted: false, eventCount: 0, sections: {}, payloads: [], responses: [] };
        this.active.add(record);
        if (kind === "model_request") {
            record.composition = safeObserve(() => contextComposition(context, session.agent?.tokenizer, session.messages, this.convertToLlm, this.toolWireSchema));
            record.contextWindow = model?.contextWindow;
        }
        if (!this.heartbeat) {
            this.heartbeat = setInterval(() => { this.writer.refreshLease().catch(() => this.writer.report("capture_write_failed")); }, 10000);
            this.heartbeat.unref?.();
        }
        this.put(record, "requestContext", context);
        const allowedOptions = safeOptions(options);
        if (Object.keys(allowedOptions).length) this.put(record, "requestOptions", allowedOptions, 65536);
        record.sections.capture = { boundary: kind === "model_request" ? "agent.streamFn" : kind === "side_request" ? "prepareSimpleStreamOptions" : "extensionRunner",
            api: model?.api, payloadBoundary: "provider callback after native extension hooks; not transport bytes",
            limits: captureLimits, sessionID, leafID: record.leafID, requestID: record.id };
        if (deferred) deferredRecords.add(record);
        else this.save(record);
        return record;
    }
    put(record, key, value, budget = captureLimits.section) {
        if (!record || value === undefined) return;
        const snapshot = captureSnapshot(value, budget);
        record.sections[key] = snapshot.value;
        record.truncated ||= snapshot.truncated; record.redacted ||= snapshot.redacted;
    }
    save(record) {
        if (!record) return;
        record.updatedAt = Date.now();
        // Keep the latest payload in full; prior revisions are bounded independently.
        record.sections.payloads = record.payloads;
        record.sections.responses = record.responses;
        record.payloadObserved = record.payloads.length > 0;
        Object.assign(record.sections.capture, { truncated: record.truncated, redacted: record.redacted, eventCount: record.eventCount });
        const { payloads, responses, ...document } = record;
        this.writer.enqueue(document);
    }
    payload(record, value) {
        if (!record || !["running", "observed"].includes(record.status)) return;
        if (record.payloads.length >= 8) { record.payloads.shift(); record.truncated = true; }
        const snapshot = captureSnapshot(value, 32 * 1024);
        record.payloads.push({ id: randomUUID(), timestamp: Date.now(), value: snapshot.value });
        this.put(record, "requestPayload", value);
        record.truncated ||= snapshot.truncated; record.redacted ||= snapshot.redacted;
        this.save(record);
    }
    response(record, value) {
        if (!record || !["running", "observed"].includes(record.status)) return;
        const headers = Object.fromEntries(Object.entries(value?.headers ?? {}).filter(([key]) => safeHeader.test(key)));
        const snapshot = captureSnapshot({ status: value?.status, requestId: value?.requestId, headers, metadata: value?.metadata }, 8192);
        if (record.responses.length >= 32) { record.responses.shift(); record.truncated = true; }
        record.responses.push({ timestamp: Date.now(), ...snapshot.value });
        record.redacted ||= snapshot.redacted; record.truncated ||= snapshot.truncated;
        this.save(record);
    }
    finish(record, result, error, status) {
        if (!record || record.status !== "running") return;
        this.put(record, "requestOutput", result);
        if (error) this.put(record, "requestError", { name: error.name, message: String(error.message ?? error) });
        record.status = status ?? (result?.stopReason === "aborted" ? "cancelled" : error || result?.stopReason === "error" ? "failed" : "completed");
        record.duration = Date.now() - record.startedAt;
        record.tokens = result?.usage?.totalTokens;
        const usage = result?.usage;
        if (usage && (!["error", "aborted"].includes(result?.stopReason) || [usage.input, usage.output, usage.cacheRead, usage.cacheWrite].some(value => value > 0))) record.reportedUsage = Object.fromEntries(["input", "output", "cacheRead", "cacheWrite", "totalTokens", "reasoningTokens"]
            .filter(key => Number.isSafeInteger(usage[key]) && usage[key] >= 0).map(key => [key, usage[key]]));
        abortCleanups.get(record)?.(); abortCleanups.delete(record);
        this.active.delete(record);
        if (!this.active.size) { clearInterval(this.heartbeat); this.heartbeat = undefined; }
        // A successful local operation without provider evidence is not a model
        // request. A failed public boundary is retained even without that evidence.
        if (!deferredRecords.has(record) || record.payloads.length || record.responses.length || record.sections.requestError) this.save(record);
    }
    // Do not retain stream deltas. Preserve first-event timing, count and final
    // SSE envelope for side requests whose public API has no result() handle.
    event(record, event) {
        if (!record || record.status !== "running") return;
        record.eventCount++;
        record.sections.capture.firstEventAt ??= Date.now();
        const data = event?.data;
        let parsed;
        try { parsed = typeof data === "string" && data.length < captureLimits.section ? JSON.parse(data) : undefined; } catch {}
        const type = parsed?.type ?? event?.event;
        if (["response.completed", "response.failed", "response.incomplete", "message_stop"].includes(type) || data === "[DONE]") {
            if (record.kind !== "model_request" && !record.sections.capture.resultBoundary) this.finish(record, parsed, undefined, type === "response.failed" ? "failed" : "completed");
        }
    }
}

function safeObserve(action) { try { return action(); } catch { /* Observation never alters inference. */ } }
function observedOptions(capture, record, options) {
    return { ...options,
        onPayload: async (...args) => {
            const replacement = await callbackScope.run(record, () => options.onPayload?.(...args));
            safeObserve(() => capture.payload(record, replacement === undefined ? args[0] : replacement));
            return replacement;
        },
        onResponse: async (...args) => {
            safeObserve(() => capture.response(record, args[0]));
            return await callbackScope.run(record, () => options.onResponse?.(...args));
        },
        onSseEvent: (...args) => {
            safeObserve(() => capture.event(record, args[0]));
            return options.onSseEvent?.(...args);
        },
    };
}

export function installSessionCapture(session, capture) {
    if (installed.has(session) || typeof session.agent?.streamFn !== "function") return;
    installed.add(session);
    const original = session.agent.streamFn;
    session.agent.streamFn = function(model, context, options = {}) {
        const record = safeObserve(() => capture.start(session, model, "model_request", context, options));
        if (!record) return original.call(this, model, context, options);
        const end = error => safeObserve(() => capture.finish(record, undefined, error, options.signal?.aborted ? "cancelled" : undefined));
        const observeStream = stream => {
            // result() does not consume the async iterator or change backpressure.
            stream.result().then(result => safeObserve(() => capture.finish(record, result)), end);
            return stream;
        };
        try {
            const result = scope.run(record, () => original.call(this, model, context, observedOptions(capture, record, options)));
            return result?.then ? result.then(observeStream, error => { end(error); throw error; }) : observeStream(result);
        } catch (error) { end(error); throw error; }
    };
    // Public operation boundaries provide completion/error evidence for side
    // calls and maintenance. Concurrent calls each get their own async scope.
    for (const name of ["runEphemeralTurn", "compact", "handoff", "generateTitle"]) {
        const operation = session[name];
        if (typeof operation !== "function") continue;
        session[name] = function(...args) {
            const record = safeObserve(() => capture.start(session, this.model, "side_request", undefined, {}, true));
            if (!record) return operation.apply(this, args);
            record.sections.capture.resultBoundary = name;
            const signal = args[0]?.signal ?? args[1]?.signal;
            return scope.run(record, async () => {
                try {
                    const result = await operation.apply(this, args);
                    safeObserve(() => capture.finish(record, result?.assistantMessage ?? result));
                    return result;
                } catch (error) {
                    safeObserve(() => capture.finish(record, undefined, error, signal?.aborted ? "cancelled" : undefined));
                    throw error;
                }
            });
        };
    }
    const buildContext = session.agent.buildSideRequestContext;
    if (typeof buildContext === "function") session.agent.buildSideRequestContext = async function(...args) {
        const context = await buildContext.apply(this, args);
        safeObserve(() => capture.put(scope.getStore(), "requestContext", context));
        return context;
    };
    const prepare = session.prepareSimpleStreamOptions;
    if (typeof prepare === "function") session.prepareSimpleStreamOptions = function(...args) {
        const options = prepare.apply(this, args);
        let record = scope.getStore();
        const hasResultBoundary = Boolean(record);
        if (record) safeObserve(() => {
            const allowedOptions = safeOptions(options);
            if (Object.keys(allowedOptions).length) capture.put(record, "requestOptions", allowedOptions, 65536);
        });
        const get = model => {
            if (!record) {
                record = safeObserve(() => capture.start(session, model, "side_request", undefined, options));
                if (record) abortCleanups.set(record, () => options.signal?.removeEventListener("abort", abort));
            }
            return record;
        };
        const wrapped = { ...options,
            onPayload: async (...payloadArgs) => {
                const current = get(payloadArgs[1]);
                return await scope.run(current, async () => {
                    try {
                        const result = await observedOptions(capture, current, options).onPayload(...payloadArgs);
                        // Without a public result boundary this is evidence of
                        // observation, not a claim that the model completed.
                        if (!hasResultBoundary) safeObserve(() => capture.finish(current, undefined, undefined, "observed"));
                        return result;
                    }
                    catch (error) { safeObserve(() => capture.finish(current, undefined, error)); throw error; }
                });
            },
            onResponse: async (...responseArgs) => {
                const current = get(responseArgs[1]);
                return await scope.run(current, () => observedOptions(capture, current, options).onResponse(...responseArgs));
            },
            onSseEvent: (...eventArgs) => observedOptions(capture, record, options).onSseEvent(...eventArgs),
        };
        const abort = () => safeObserve(() => capture.finish(record, undefined, undefined, "cancelled"));
        options.signal?.addEventListener("abort", abort, { once: true });
        return wrapped;
    };
    // Remaining native helper requests expose only session-bound provider hooks.
    // Store these as independent observations: never guess a response/request join
    // from a reused signal, model, timestamps or message text.
    const runner = session.extensionRunner;
    if (runner) for (const [name, kind] of [["emitBeforeProviderRequest", "provider_payload"], ["emitAfterProviderResponse", "provider_response"]]) {
        const method = runner[name];
        if (typeof method !== "function") continue;
        runner[name] = async function(value, model, signal) {
            const active = scope.getStore();
            const result = await method.call(this, value, model, signal);
            if (active && callbackScope.getStore() !== active) safeObserve(() => {
                // Maintenance can invoke the session hook directly, without
                // prepareSimpleStreamOptions. Its public operation still owns
                // this observation. The outer callback wrapper, when present,
                // records after any additional per-request modifier instead.
                if (kind === "provider_payload") capture.payload(active, result === undefined ? value : result);
                else capture.response(active, value);
            });
            if (!active) safeObserve(() => {
                const record = capture.start(session, model, kind, undefined);
                if (kind === "provider_payload") capture.payload(record, result === undefined ? value : result);
                else capture.response(record, value);
                capture.finish(record, undefined, undefined, "observed");
            });
            return result;
        };
    }
    session.addDisposer?.(() => {
        for (const record of capture.active) if (record.sessionID === session.sessionManager.getSessionId()) capture.finish(record, undefined, undefined, "interrupted");
    });
}

export function installRegistryCapture(registry, capture) {
    const observe = ref => { if (ref?.session) safeObserve(() => installSessionCapture(ref.session, capture)); };
    for (const ref of registry.list()) observe(ref);
    if (observedRegistries.has(registry)) return;
    observedRegistries.add(registry);
    registry.onChange(event => observe(event.ref));
}
let runtime;
export async function installRequestCaptureRuntime(registry) {
    const root = process.env.OMP_GUI_CAPTURE_ROOT, sessions = process.env.OMP_GUI_SESSION_ROOT;
    if (!root || !sessions) return;
    if (!runtime) {
        let convertToLlm, toolWireSchema;
        if (process.env.OMP_GUI_NATIVE_EXECUTABLE && typeof Bun !== "undefined") {
            try {
                const packageRoot = dirname(dirname(await fs.realpath(process.env.OMP_GUI_NATIVE_EXECUTABLE)));
                ({ convertToLlm } = await import(pathToFileURL(Bun.resolveSync("@oh-my-pi/pi-coding-agent/session/messages", packageRoot)).href));
                ({ toolWireSchema } = await import(pathToFileURL(Bun.resolveSync("@oh-my-pi/pi-ai/utils/schema", packageRoot)).href));
            } catch { /* Older SDKs retain ordinary capture without composition. */ }
        }
        runtime = new RequestCapture(new RequestCaptureWriter(root, sessions), convertToLlm, toolWireSchema);
    }
    if (!registry) {
        const executable = process.env.OMP_GUI_NATIVE_EXECUTABLE;
        if (!executable || typeof Bun === "undefined") return;
        const packageRoot = dirname(dirname(await fs.realpath(executable)));
        const { AgentRegistry } = await import(pathToFileURL(Bun.resolveSync("@oh-my-pi/pi-coding-agent/registry/agent-registry", packageRoot)).href);
        registry = AgentRegistry.global();
    }
    installRegistryCapture(registry, runtime);
    return runtime;
}
export function installRequestCaptureExtension(omp) {
    const install = async () => { try { await installRequestCaptureRuntime(); } catch { process.stderr.write("[OMP GUI request capture] initialization_failed\n"); } };
    omp.on("session_start", install);
    omp.on("agent_start", install);
    omp.on("session_shutdown", async () => { await runtime?.writer.flush(); });
}
