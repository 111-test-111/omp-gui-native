// Observation only. OMP's native debug tool retains exclusive ownership of
// launches, execution control, approvals and adapter/session lifecycle.
export const debugControlCommand = "omp-gui-debug";
export const debugControlChannel = "omp-gui:debug-control";
export const debugObservationChannel = "omp-gui:debug-observation";
export const debugResultPrefix = "OMP_GUI_DEBUG_RESULT:";
export const debugObservationPrefix = "OMP_GUI_DEBUG_OBSERVATION:";
const debugReads = new Set(["sessions", "stack_trace", "threads", "scopes", "variables", "output",
    "modules", "loaded_sources", "disassemble", "read_memory", "data_breakpoint_info"]);
const debugMoves = new Set(["launch", "attach", "continue", "pause", "step_over", "step_in", "step_out"]);

function debugText(value, bytes = 2048) {
    if (typeof value !== "string") return undefined;
    const encoded = new TextEncoder().encode(value);
    if (encoded.length <= bytes) return value;
    let end = bytes;
    while (end > 0 && (encoded[end] & 0xc0) === 0x80) end--;
    return new TextDecoder().decode(encoded.subarray(0, end)) + "…";
}
function debugInteger(value) { return Number.isSafeInteger(value) && value >= 0 ? value : undefined; }
function debugSource(source) {
    if (!source || typeof source !== "object") return undefined;
    return { path: debugText(source.path), name: debugText(source.name, 256), sourceReference: debugInteger(source.sourceReference) };
}
// A bounded, literal snapshot of the native call. Historical references are data,
// never authority for a later adapter read. Keep JSON valid when clipping it.
export function debugDetails(input, result, content) {
    let limited = false;
    const encode = (value, budget) => {
        if (value == null) return undefined;
        let remaining = budget, nodes = 0;
        const cost = value => new TextEncoder().encode(JSON.stringify(value)).length;
        const visit = (value, depth) => {
            if (++nodes > 800 || depth > 8 || remaining < 32) { limited = true; return "…"; }
            if (typeof value === "string") {
                let text = debugText(value, Math.min(4096, Math.floor(remaining / 6)));
                limited ||= text !== value;
                remaining -= cost(text); return text;
            }
            if (value == null || typeof value === "boolean" || typeof value === "number") {
                remaining -= 24; return value;
            }
            const entries = Array.isArray(value) ? value.entries() : Object.entries(value);
            const output = Array.isArray(value) ? [] : Object.create(null);
            let count = 0;
            for (const [key, child] of entries) {
                if (child === undefined) continue;
                if (count++ >= 200 || nodes >= 800 || remaining < 64) { limited = true; break; }
                const name = typeof key === "string" ? debugText(key, 128) : key;
                remaining -= cost(name) + 4;
                output[name] = visit(child, depth + 1);
            }
            return output;
        };
        const encoded = JSON.stringify(visit(value, 0));
        if (new TextEncoder().encode(encoded).length > budget) { limited = true; return JSON.stringify("…"); }
        return encoded;
    };
    const inputJSON = encode(input, 8 * 1024);
    const resultJSON = encode(result, 24 * 1024);
    const text = Array.isArray(content) ? content.filter(part => part.type === "text").map(part => part.text).join("\n") : content;
    const output = debugText(text, 12 * 1024);
    limited ||= output !== text;
    return { inputJSON, resultJSON, output, limited };
}
export function debugSummary(value) {
    if (!value || typeof value.id !== "string" || !["launching", "configuring", "running", "stopped", "terminated"].includes(value.status)) return null;
    return { id: debugText(value.id, 256), status: value.status, adapter: debugText(value.adapter, 256),
        program: debugText(value.program), cwd: debugText(value.cwd), threadId: debugInteger(value.threadId),
        frameName: debugText(value.frameName), stopReason: debugText(value.stopReason, 256),
        stopDescription: debugText(value.stopDescription), source: debugSource(value.source),
        line: debugInteger(value.line), column: debugInteger(value.column), exitCode: value.exitCode,
        instructionPointerReference: debugText(value.instructionPointerReference, 256) };
}

// These hooks also see discoverable tools invoked inside eval. They never return
// a tool override. The GUI keeps bounded read-only result snapshots separately.
export function installDebugCommands(omp) {
    const pending = new Map();
    const publish = (record, ctx) => {
        const observation = { sessionID: ctx.sessionManager.getSessionId(),
            sessionFile: ctx.sessionManager.getSessionFile(), record, handled: false };
        omp.events.emit(debugObservationChannel, observation);
        if (!observation.handled) ctx.ui.notify(debugObservationPrefix + JSON.stringify(observation), "info");
    };
    const observe = phase => (event, ctx) => {
        if (ctx.agent.kind !== "main" || event.toolName !== "debug") return;
        const details = event.details?.xdev?.inner ?? event.details;
        const previous = pending.get(event.toolCallId)?.record;
        const record = { id: debugText(event.toolCallId, 256), action: debugText(event.input?.action ?? details?.action ?? previous?.action, 128),
            nativeCallID: debugText(event.toolCallId, 256),
            phase, timestamp: Date.now(), failed: event.isError === true || details?.success === false,
            summary: debugSummary(details?.snapshot),
            details: debugDetails(event.input, details, event.content),
            error: event.isError === true || details?.success === false
                ? debugText(event.content?.filter(part => part.type === "text").map(part => part.text).join("\n")) : undefined };
        if (!record.id || !record.action) return;
        const sessionID = ctx.sessionManager.getSessionId();
        if (phase === "begin") {
            if (pending.size >= 128) pending.delete(pending.keys().next().value);
            pending.set(record.id, { record, sessionID });
        } else pending.delete(record.id);
        publish(record, ctx);
    };
    omp.on("tool_call", observe("begin"));
    omp.on("tool_result", observe("end"));
    omp.on("agent_end", (_, ctx) => {
        if (ctx.agent.kind !== "main") return;
        for (const value of pending.values()) {
            if (value.sessionID === ctx.sessionManager.getSessionId()) {
                publish({ ...value.record, phase: "interrupted", timestamp: Date.now() }, ctx);
            }
        }
        pending.clear();
    });
    omp.registerCommand(debugControlCommand, {
        description: "OMP GUI debug inspection",
        async handler(args, ctx) {
            let request;
            try { request = JSON.parse(args); } catch { return; }
            if (typeof request?.requestID !== "string" || request.requestID.length > 128 || typeof request.operation !== "string") return;
            let respond;
            const result = new Promise(resolve => { respond = resolve; });
            const call = { ...request, sessionID: ctx.sessionManager.getSessionId(), handled: false, respond };
            if (ctx.agent.kind === "main") omp.events.emit(debugControlChannel, call);
            if (!call.handled) respond({ requestID: request.requestID, operation: request.operation, success: false, error: "unsupported" });
            ctx.ui.notify(debugResultPrefix + JSON.stringify(await result), "info");
        },
    });
}

// Only public SDK methods on the SAME module singleton as OMP's DebugTool.
// listSessions/getActiveSession do not touch the native idle deadline. Adapter
// reads are issued only by a visible inspector and have no polling loop.
export function installNativeDebugObservation(session, eventBus, manager, output) {
    if (![session?.subscribe, session?.sessionManager?.getSessionId, eventBus?.on,
        manager?.getActiveSession, manager?.listSessions, manager?.stackTrace,
        manager?.scopes, manager?.variables].every(value => typeof value === "function")) return () => {};
    const processID = globalThis.crypto.randomUUID();
    let revision = 0, timer, disposed = false, previousState = "", previousWire = "", querying = false, readID;
    let origin = session.sessionManager.getSessionId();
    let file = session.sessionFile;
    let current = null, last = null, active = false, runID, stopID, stopSequence = 0, previousStop = "", awaitingStop = false;
    const pending = new Map();
    const frameIDs = new Set(), references = new Set();
    const controllers = new Set();
    const token = () => processID + ":" + revision;
    const invalidate = () => {
        revision++;
        frameIDs.clear(); references.clear();
        for (const controller of controllers) controller.abort();
    };
    const send = fields => output({ type: "omp_gui_debug", sessionFile: file, sessionID: origin, ...fields });
    const sample = (force = false) => {
        if (disposed) return;
        if (origin !== session.sessionManager.getSessionId() || file !== session.sessionFile) {
            invalidate(); pending.clear(); last = null; previousState = ""; previousWire = "";
            origin = session.sessionManager.getSessionId(); file = session.sessionFile;
            runID = undefined; stopID = undefined; previousStop = ""; awaitingStop = false;
        }
        const sessions = manager.listSessions();
        const selected = manager.getActiveSession();
        current = debugSummary(selected);
        active = sessions.some(value => value.status !== "terminated");
        if (selected) {
            let root = selected;
            const visited = new Set();
            while (root.parentSessionId && !visited.has(root.id)) {
                visited.add(root.id);
                const parent = sessions.find(value => value.id === root.parentSessionId);
                if (!parent) break;
                root = parent;
            }
            const nextRun = processID + ":run:" + root.id;
            if (nextRun !== runID) { runID = nextRun; stopID = undefined; previousStop = ""; }
        }
        const stopped = current?.status === "stopped" && !pending.size;
        const stop = stopped ? JSON.stringify([runID, current.id, current.threadId, current.stopReason]) : "";
        if (stopped && (!stopID || stop !== previousStop || awaitingStop)) {
            stopID = processID + ":stop:" + ++stopSequence;
            awaitingStop = false;
        }
        if (stopped) previousStop = stop;
        else if (current?.status !== "stopped") previousStop = "";
        const state = JSON.stringify([current?.id, current?.status, current?.threadId, current?.stopReason]);
        if (state !== previousState) {
            invalidate(); previousState = state;
            if (current || last) {
                const summary = current ?? { ...last, status: "terminated" };
                send({ record: { id: processID + ":state:" + revision, action: summary.status,
                    phase: "state", timestamp: Date.now(), summary, stopID: stopped ? stopID : undefined }, runID });
            }
        }
        if (current) last = current;
        else if (last) last = { ...last, status: "terminated" };
        const value = { supported: true, stopToken: token(), runID, stopID: stopped ? stopID : undefined, session: last,
            active, busy: pending.size > 0 };
        const wire = JSON.stringify(value);
        if (force || wire !== previousWire) { previousWire = wire; send({ snapshot: value }); }
        if ((active || pending.size) && !timer) {
            timer = setTimeout(() => { timer = undefined; sample(); }, 750);
            timer.unref?.();
        } else if (!active && !pending.size && timer) { clearTimeout(timer); timer = undefined; }
    };
    const offObservation = eventBus.on(debugObservationChannel, observation => {
        if (disposed || observation?.sessionID !== session.sessionManager.getSessionId()) return;
        observation.handled = true;
        const record = observation.record;
        if (record.phase === "begin") {
            if (pending.size >= 128) pending.delete(pending.keys().next().value);
            pending.set(record.id, record);
            if (debugMoves.has(record.action)) awaitingStop = true;
            if (!debugReads.has(record.action)) invalidate();
        } else pending.delete(record.id);
        sample();
        const launching = record.phase === "begin" && ["launch", "attach"].includes(record.action);
        send({ record: { ...record, id: processID + ":" + record.id,
            stopID: !launching && current?.status === "stopped" ? stopID : undefined }, runID: launching ? undefined : runID });
    });
    const offSession = session.subscribe(event => {
        if (event.type === "agent_end") {
            for (const record of pending.values()) send({ record: { ...record,
                id: processID + ":" + record.id, phase: "interrupted", timestamp: Date.now() } });
            pending.clear(); sample();
        }
    });
    const offControl = eventBus.on(debugControlChannel, async request => {
        if (disposed || request?.sessionID !== session.sessionManager.getSessionId() || typeof request.respond !== "function") return;
        request.handled = true;
        const reply = fields => request.respond({ requestID: request.requestID, operation: request.operation, ...fields });
        let controller;
        try {
            sample();
            if (request.operation === "hello") { reply({ success: true, protocolVersion: 1 }); sample(true); return; }
            if (request.operation === "cancel") {
                if (readID === request.targetRequestID) for (const value of controllers) value.abort();
                reply({ success: true }); return;
            }
            if (!["stack", "scopes", "variables"].includes(request.operation)) throw new Error("unsupported");
            if (querying) throw new Error("busy");
            const expected = token(), nativeID = origin;
            const validate = () => {
                sample();
                if (disposed || nativeID !== origin || request.stopToken !== expected || token() !== expected
                    || current?.id !== request.dapSessionID || current?.status !== "stopped" || pending.size) throw new Error("stale");
            };
            validate();
            if (request.operation === "scopes" && !frameIDs.has(request.frameID)) throw new Error("stale");
            if (request.operation === "variables" && !references.has(request.reference)) throw new Error("stale");
            querying = true;
            readID = request.requestID;
            controller = new AbortController(); controllers.add(controller);
            let data;
            if (request.operation === "stack") {
                const result = await manager.stackTrace(64, controller.signal, 5000);
                validate();
                const frames = (result.stackFrames ?? []).slice(0, 64).filter(value => debugInteger(value.id) !== undefined).map(value => ({
                    id: value.id, name: debugText(value.name, 1024) ?? "", source: debugSource(value.source),
                    line: debugInteger(value.line), column: debugInteger(value.column),
                    instructionPointerReference: debugText(value.instructionPointerReference, 256) }));
                for (const frame of frames) frameIDs.add(frame.id);
                data = { frames, limited: (result.totalFrames ?? result.stackFrames?.length ?? 0) > frames.length };
            } else if (request.operation === "scopes") {
                const result = await manager.scopes(request.frameID, controller.signal, 5000);
                validate();
                const scopes = (result.scopes ?? []).slice(0, 32).map(value => ({ name: debugText(value.name, 512) ?? "",
                    reference: debugInteger(value.variablesReference) ?? 0, expensive: value.expensive === true,
                    presentationHint: debugText(value.presentationHint, 128) }));
                for (const scope of scopes) if (scope.reference > 0 && references.size < 2048) references.add(scope.reference);
                data = { scopes, limited: (result.scopes?.length ?? 0) > scopes.length };
            } else {
                const result = await manager.variables(request.reference, controller.signal, 5000);
                validate();
                let budget = 48 * 1024;
                const variables = [];
                for (const value of result.variables ?? []) {
                    if (variables.length >= 200 || budget <= 0) break;
                    const row = { name: debugText(value.name, 512) ?? "", value: debugText(value.value, Math.min(4096, budget)) ?? "",
                        type: debugText(value.type, 256), reference: debugInteger(value.variablesReference) ?? 0 };
                    budget -= new TextEncoder().encode(JSON.stringify(row)).length;
                    variables.push(row);
                    if (row.reference > 0 && references.size < 2048) references.add(row.reference);
                }
                data = { variables, limited: (result.variables?.length ?? 0) > variables.length };
            }
            reply({ success: true, stopToken: expected, data });
        } catch (error) {
            const code = ["unsupported", "stale", "busy"].includes(error?.message) ? error.message : "inspection_failed";
            reply({ success: false, error: code });
        } finally {
            if (controller) { controllers.delete(controller); querying = false; readID = undefined; }
        }
    });
    sample();
    return () => {
        disposed = true; invalidate(); clearTimeout(timer);
        offObservation(); offControl(); offSession();
    };
}
