import { closeSync, constants, fstatSync, openSync, readSync, realpathSync } from "node:fs";
import { homedir } from "node:os";
import { basename, dirname, join, resolve } from "node:path";

// Run inside OMP's awaited tool hooks, before any bytes are changed. RPC start
// notifications are observations and cannot serve as a before-write barrier.
export function installFileSnapshots(omp) {
    const byteLimit = 1_000_000;
    const pendingByteLimit = 8 * byteLimit;
    const pending = new Map();

    function filePath(raw, cwd) {
        if (typeof raw !== "string" || !raw || raw.includes("\0") || /^[a-z][a-z0-9+.-]*:/i.test(raw)) return;
        const expanded = raw === "~" ? homedir() : raw.startsWith("~/") ? join(homedir(), raw.slice(2)) : raw;
        return resolve(cwd, expanded);
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

    omp.on("tool_call", (event, ctx) => {
        if (event.toolName !== "write") return;
        const path = filePath(event.input.path, ctx.cwd);
        if (!path) return;
        // One factory is bound per native session, including isolated workers.
        let before = text(path, true);
        const retained = [...pending.values()].reduce((sum, value) => sum + (value.before === undefined ? 0 : Buffer.byteLength(value.before)), 0);
        if (before !== undefined && retained + Buffer.byteLength(before) > pendingByteLimit) before = undefined;
        pending.set(event.toolCallId, { path, key: canonical(path), before });
    });

    omp.on("tool_result", (event) => {
        const before = pending.get(event.toolCallId);
        pending.delete(event.toolCallId);
        if (!before || event.toolName !== "write") return;
        const details = event.details;
        if (event.isError || (details != null && (typeof details !== "object" || Array.isArray(details)))) return;
        const path = details?.resolvedPath ?? before.path;
        if (typeof path !== "string" || canonical(path) !== before.key) return;
        const after = text(path);

        // OMP may prepare an entire batch's tool_call hooks before scheduling its
        // exclusive writes. Advance later writes' baselines when this one ends.
        for (const next of pending.values()) {
            if (next.key === before.key) next.before = after;
        }
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
