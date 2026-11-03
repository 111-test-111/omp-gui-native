import { closeSync, constants, fstatSync, openSync, readSync, realpathSync } from "node:fs";
import { homedir } from "node:os";
import { basename, dirname, join, resolve } from "node:path";

// Run inside OMP's awaited tool hooks, before any bytes are changed. RPC start
// notifications are observations and cannot serve as a before-write barrier.
export function installFileSnapshots(omp) {
    const byteLimit = 1_000_000;
    const pendingByteLimit = 8 * byteLimit;
    const pending = new Map();

    async function filePath(raw, ctx) {
        if (typeof raw !== "string" || !raw || raw.includes("\0")) return;
        try {
            // OMP hosts these public imports for extensions, including standalone
            // installs. Never derive local:// from cwd or another agent's journal.
            if (raw.startsWith("[")) {
                const { unwrapHashlineHeaderPath } = await import("@oh-my-pi/pi-coding-agent/tools/plan-mode-guard");
                raw = unwrapHashlineHeaderPath(raw);
            }
            if (/^[a-z][a-z0-9+.-]*:/i.test(raw)) {
                const { InternalUrlRouter } = await import("@oh-my-pi/pi-coding-agent/internal-urls");
                const router = InternalUrlRouter.instance();
                const normalized = router.normalize(raw);
                const scheme = normalized.match(/^([a-z][a-z0-9+.-]*):/i)?.[1]?.toLowerCase();
                const spec = router.spec(scheme);
                if (spec?.backing !== "file" || spec.immutable || spec.write?.via !== "file") return;
                return await router.locate(normalized, {
                    cwd: ctx.cwd,
                    localProtocolOptions: ctx.localProtocolOptions ?? {
                        getArtifactsDir: () => ctx.sessionManager.getArtifactsDir(),
                        getSessionId: () => ctx.sessionManager.getSessionId(),
                    },
                }, { create: true, localOnly: true }) ?? undefined;
            }
            const expanded = raw === "~" ? homedir() : raw.startsWith("~/") ? join(homedir(), raw.slice(2)) : raw;
            return resolve(ctx.cwd, expanded);
        } catch { /* An unavailable observation must not change tool execution. */ }
    }

    function canonical(path) {
        try { return realpathSync(path); }
        catch {
            // New files can have missing parent directories or a symlinked root.
            const parent = dirname(path);
            return parent === path ? path : join(canonical(parent), basename(path));
        }
    }

    function text(path, missingIsEmpty = false) {
        let fd;
        try {
            fd = openSync(path, constants.O_RDONLY | constants.O_NONBLOCK);
            const info = fstatSync(fd);
            if (!info.isFile() || info.size > byteLimit) return;
            // Bound the read too: a file may grow after fstat.
            const bytes = Buffer.alloc(byteLimit + 1);
            let count = 0;
            while (count < bytes.length) {
                const read = readSync(fd, bytes, count, bytes.length - count, null);
                if (!read) break;
                count += read;
            }
            if (count > byteLimit) return;
            const value = new TextDecoder("utf-8", { fatal: true, ignoreBOM: true }).decode(bytes.subarray(0, count));
            return value.includes("\0") ? undefined : value;
        } catch (error) {
            return missingIsEmpty && error.code === "ENOENT" ? "" : undefined;
        } finally {
            if (fd !== undefined) {
                try { closeSync(fd); } catch { /* Observation must not fail the tool. */ }
            }
        }
    }

    function advance(key, after) {
        let retained = [...pending.values()].reduce((sum, value) => sum +
            (value.key === key || value.before === undefined ? 0 : Buffer.byteLength(value.before)), 0);
        const bytes = after === undefined ? 0 : Buffer.byteLength(after);
        for (const next of pending.values()) {
            if (next.key !== key) continue;
            next.before = after !== undefined && retained + bytes <= pendingByteLimit ? after : undefined;
            if (next.before !== undefined) retained += bytes;
        }
    }

    omp.on("tool_call", async (event, ctx) => {
        if (event.toolName !== "write") return;
        const path = await filePath(event.input.path, ctx);
        if (!path) return;
        // One factory is bound per native session, including isolated workers.
        let before = text(path, true);
        const retained = [...pending.values()].reduce((sum, value) => sum + (value.before === undefined ? 0 : Buffer.byteLength(value.before)), 0);
        if (before !== undefined && retained + Buffer.byteLength(before) > pendingByteLimit) before = undefined;
        pending.set(event.toolCallId, { path, key: canonical(path), before });
    });

    omp.on("tool_result", async (event, ctx) => {
        const before = pending.get(event.toolCallId);
        pending.delete(event.toolCallId);
        const details = event.details;
        if (details != null && (typeof details !== "object" || Array.isArray(details))) return;
        if (event.toolName === "edit") {
            // Prepared writes can straddle a native edit in the same batch. The
            // edit already owns its diff; only advance the waiting write baselines.
            for (const row of details?.perFileResults ?? [details]) {
                if (!pending.size) break;
                // A rename also removes its source, and deletion establishes a
                // known empty baseline for a later write that recreates the file.
                for (const raw of [row?.resolvedPath ?? row?.path, row?.sourcePath]) {
                    const path = await filePath(raw, ctx);
                    if (path) advance(canonical(path), text(path, true));
                }
            }
            return;
        }
        if (!before || event.toolName !== "write") return;
        const path = details?.resolvedPath ?? before.path;
        if (typeof path !== "string" || !path.startsWith("/") || canonical(path) !== before.key) return;
        const after = text(path);

        // OMP may prepare an entire batch's tool_call hooks before scheduling its
        // exclusive writes. Advance later writes' baselines when this one ends.
        advance(before.key, after);
        if (event.isError) return;
        const snapshot = { version: 1, path };
        if (before.before !== undefined && after !== undefined) {
            snapshot.oldText = before.before;
            snapshot.newText = after;
        }
        // Retain native diagnostics/diffs and mark unreadable/oversized text as
        // unavailable, rather than allowing a late GUI read to invent a patch.
        return { details: { ...details, ompGUI: { ...details?.ompGUI, fileSnapshot: snapshot } } };
    });

    omp.on("tool_execution_end", (event) => pending.delete(event.toolCallId));
    for (const event of ["agent_end", "session_switch", "session_branch", "session_shutdown"]) {
        omp.on(event, () => pending.clear());
    }
}
