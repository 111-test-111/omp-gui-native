import assert from "node:assert/strict";
import { join } from "node:path";
import { pathToFileURL } from "node:url";

// Runs the actual repaired Eval kernel with synthetic remote replies, then the
// actual context manager with its native transport seam. No model or browser.
export async function checkBrowserEval(repaired, output) {
    const { WorkerCore } = await import(pathToFileURL(join(repaired, "src/eval/js/worker-core.ts")));
    const { postmortem } = await import(pathToFileURL(Bun.resolveSync("@oh-my-pi/pi-utils", repaired)));
    let receive, consume, owned;
    const messages = [], waiters = [];
    const waitFor = predicate => {
        const found = messages.find(predicate);
        if (found) return Promise.resolve(found);
        return new Promise((resolve, reject) => {
            const item = { predicate, resolve: value => { clearTimeout(item.timer); resolve(value); } };
            item.timer = setTimeout(() => reject(new Error("Native Eval fixture did not settle")), 5000);
            waiters.push(item);
        });
    };
    const core = new WorkerCore({
        onMessage(handler) { receive = handler; return () => {}; }, close() {},
        send(message) {
            messages.push(message);
            for (let i = waiters.length - 1; i >= 0; i--) {
                if (waiters[i].predicate(message)) waiters.splice(i, 1)[0].resolve(message);
            }
        },
    }, { mode: "inline", interceptUnhandledRejections(handler) {
        consume = handler;
        return postmortem.interceptUnhandledRejections(reason => { owned = handler(reason); return owned; });
    } });
    const snapshot = { cwd: output, sessionId: "browser-eval-fixture" };
    const sendRun = (id, code) => receive({ type: "run", runId: id, code, filename: `browser-eval-${id}.js`, snapshot });
    const remoteError = { name: "ToolError", message: "tab.waitForDownload() timed out", isToolError: true,
        stack: "ToolError: tab.waitForDownload() timed out\n    at remoteTabWorker (tab-worker.ts:10:2)" };
    try {
        receive({ type: "init", snapshot });
        await waitFor(m => m.type === "ready");
        sendRun("float", 'var retainedBrowserValue = 42; void __omp_call_tool__("browser", { action: "run" });');
        const call = await waitFor(m => m.type === "tool-call" && m.runId === "float");
        assert.equal((await waitFor(m => m.type === "result" && m.runId === "float")).ok, true);
        receive({ type: "tool-reply", id: call.id, reply: { ok: false, error: remoteError } });
        const diagnostic = await waitFor(m => m.type === "log" && m.meta?.filename === "browser-eval-float.js");
        assert.equal(owned, true, "A late remote rejection belongs to its finished cell, not a fatal host error");
        assert.match(diagnostic.meta.error.stack, /remoteTabWorker/, "Original remote diagnostic remains available");
        assert.equal(consume(new Error("Unrelated host failure")), false, "Real host failures retain the native fatal path");
        sendRun("retained", 'console.log("RETAINED=" + retainedBrowserValue);');
        assert.equal((await waitFor(m => m.type === "result" && m.runId === "retained")).ok, true);
        assert.ok(messages.some(m => m.type === "text" && m.runId === "retained" && m.chunk.includes("RETAINED=42")));
        sendRun("awaited", 'await __omp_call_tool__("browser", { action: "run" });');
        const awaited = await waitFor(m => m.type === "tool-call" && m.runId === "awaited");
        receive({ type: "tool-reply", id: awaited.id, reply: { ok: false, error: remoteError } });
        const failure = await waitFor(m => m.type === "result" && m.runId === "awaited");
        assert.equal(failure.ok, false, "Awaited browser failures still fail their cell");
        assert.match(failure.error.message, /waitForDownload/);
    } finally {
        core.dispose();
        for (const waiter of waiters) clearTimeout(waiter.timer);
    }

    const manager = await import(pathToFileURL(join(repaired, "src/eval/js/context-manager.ts")));
    const workers = [];
    const create = () => {
        let message, error;
        const worker = { mode: "process",
            onMessage(fn) { message = fn; return () => {}; }, onError(fn) { error = fn; return () => {}; },
            send(value) { queueMicrotask(() => message(value.type === "init" ? { type: "ready" }
                : { type: "result", runId: value.runId, ok: true })); },
            async close() { return true; }, async terminate() {},
            crash() { error(new Error("Synthetic worker exit")); },
        };
        workers.push(worker); return worker;
    };
    const restoreFactories = manager.setJsEvalWorkerFactoriesForTests({ spawnProcess: create, spawnWorker: create });
    const notices = [];
    const key = "browser-worker-loss-fixture";
    const options = { sessionKey: key, sessionId: key, cwd: output, session: { cwd: output }, code: "1",
        filename: "browser-restart.js", timeoutMs: 1000, runState: { onText: text => notices.push(text) } };
    try {
        await manager.executeInVmContext(options);
        assert.deepEqual(notices, []);
        workers.at(-1).crash();
        await manager.executeInVmContext({ ...options, sessionKey: key + "-other" });
        assert.equal(notices.length, 0, "A different kernel owned by the same session did not lose state");
        await manager.executeInVmContext(options);
        assert.equal(notices.length, 1); assert.match(notices[0], /previous variables/);
        await manager.executeInVmContext(options);
        assert.equal(notices.length, 1, "Only the first cell after an unexpected exit reports lost state");
        await manager.executeInVmContext({ ...options, reset: true });
        assert.equal(notices.length, 1, "Explicit reset does not masquerade as a worker crash");
    } finally {
        await manager.resetVmContext(key); await manager.resetVmContext(key + "-other"); restoreFactories();
    }
    return { remoteRejectionPreservesVariables: true, awaitedErrorsPreserved: true, restartNoticeOnce: true };
}
