import assert from "node:assert/strict";
import { mkdirSync, readFileSync, rmSync, symlinkSync, writeFileSync } from "node:fs";
import { join, resolve } from "node:path";
import { pathToFileURL } from "node:url";

const root = resolve(process.argv[2]);
assert(root.includes("/build.noindex/verification/runs/"));
const sdk = await import(pathToFileURL(process.argv[3]));
const cwd = join(root, "files");
rmSync(cwd, { recursive: true, force: true });
mkdirSync(cwd, { recursive: true });
const settings = sdk.Settings.isolated({ "tools.approvalMode": "yolo", "lsp.enabled": false });

async function nativeWriter(directory = cwd) {
    const loaded = await sdk.loadExtensions([join(root, "extension.ts")], directory);
    assert.equal(loaded.errors.length, 0, JSON.stringify(loaded.errors));
    const runner = new sdk.ExtensionRunner(loaded.extensions, loaded.runtime, directory,
        sdk.SessionManager.inMemory(directory), {}, undefined, settings);
    const errors = [];
    runner.onError(error => errors.push(error));
    const native = new sdk.WriteTool({ cwd: directory, hasUI: false, settings,
        getSessionFile: () => null, getSessionSpawns: () => null });
    const tool = new sdk.ExtensionToolWrapper(native, runner);
    return { runner, errors, tool };
}

const { runner, errors, tool } = await nativeWriter();
const results = [];
async function write(id, path, content, old) {
    const result = await tool.execute(id, { path, content });
    assert(!result.isError, JSON.stringify(result));
    const snapshot = result.details.ompGUI.fileSnapshot;
    assert.equal(snapshot.oldText, old, id);
    assert.equal(snapshot.newText, readFileSync(snapshot.path, "utf8"), id);
    results.push({ id, args: { path }, result,
        // The existing unified renderer represents a new trailing newline as
        // an added empty line; overwrites share that unchanged final line.
        additions: old || !content.endsWith("\n") ? 1 : 2, deletions: old ? 1 : 0,
        tokens: [...(old ? [`-${old.trimEnd()}`] : []), `+${content.trimEnd()}`] });
    await runner.emit({ type: "tool_execution_end", toolCallId: id, toolName: "write", result, isError: false });
    return result;
}

// All writes finish before Swift receives any RPC event. This reproduces the
// original UI race deterministically, without a model, network or GUI process.
for (let i = 0; i < 40; i++) await write(`new-${i}`, join(cwd, `new-${i}.txt`), `created-${i}\n`, "");
await write("overwrite-1", "new-0.txt", "replacement-one\n", "created-0\n");
await write("overwrite-2", "new-0.txt", "replacement-two\n", "replacement-one\n");

// The real agent loop can prepare every hook first, then run exclusive writes.
const batch = ["batch-first\n", "batch-second\n", "batch-third\n"];
for (const [i, content] of batch.entries()) {
    const id = `batch-${i}`;
    await runner.emitToolCall({ type: "tool_call", toolName: "write", toolCallId: id, input: { path: "batch.txt", content } });
    runner.markToolCallEmitted(id, "write");
}
for (const [i, content] of batch.entries()) await write(`batch-${i}`, "batch.txt", content, i ? batch[i - 1] : "");

// Resolve symlinked directories, missing parents, and Unicode/CRLF exactly as OMP.
rmSync(join(root, "file-alias"), { force: true });
symlinkSync(cwd, join(root, "file-alias"));
await write("symlink-new", join(root, "file-alias", "new-child", "你好.txt"), "保留内容\r\n", "");
await write("symlink-overwrite", join(root, "file-alias", "new-child", "你好.txt"), "第二次内容\r\n", "保留内容\r\n");

// A separate native session gets its own map even with the same call IDs/path.
const child = await nativeWriter();
await runner.emitToolCall({ type: "tool_call", toolName: "write", toolCallId: "reused", input: { path: "isolation.txt", content: "lead\n" } });
const childResult = await child.tool.execute("reused", { path: "isolation.txt", content: "worker\n" });
assert.equal(childResult.details.ompGUI.fileSnapshot.oldText, "");
const leadResult = await runner.emitToolResult({ type: "tool_result", toolName: "write", toolCallId: "reused", input: { path: "isolation.txt" },
    details: { resolvedPath: join(cwd, "isolation.txt"), keep: { native: true } }, content: [], isError: false });
assert.equal(leadResult.details.ompGUI.fileSnapshot.oldText, "");
assert.deepEqual(leadResult.details.keep, { native: true });

for (const [name, original, content] of [
    ["invalid-utf8", Buffer.from([0xff, 0xfe]), "now-text\n"],
    ["binary", Buffer.from([0, 1, 2]), "now-readable\n"],
    ["large-before", Buffer.alloc(1_000_001, 0x61), "now-small\n"],
    ["large-after", Buffer.from("small\n"), "z".repeat(1_000_001)],
]) {
    const path = join(cwd, name + ".txt");
    writeFileSync(path, original);
    const result = await tool.execute(name, { path, content });
    assert.equal(result.details.ompGUI.fileSnapshot.oldText, undefined, name);
    assert.equal(result.details.ompGUI.fileSnapshot.newText, undefined, name);
    results.push({ id: name, args: { path }, result, unavailable: true });
}

// Failed, unrelated and virtual writes do not acquire a successful snapshot.
let failure;
try {
    failure = await tool.execute("failure", { path: cwd, content: "cannot overwrite directory" });
} catch (error) {
    failure = { content: [{ type: "text", text: error.message }], isError: true };
}
assert(failure.isError);
assert.equal(failure.details?.ompGUI, undefined);
results.push({ id: "failure", args: { path: cwd }, result: failure, failed: true });
for (const path of ["xd://todo", "https://example.test/resource"]) {
    await runner.emitToolCall({ type: "tool_call", toolName: "write", toolCallId: path, input: { path, content: "payload" } });
    assert.equal(await runner.emitToolResult({ type: "tool_result", toolName: "write", toolCallId: path, input: { path }, content: [], details: {}, isError: false }), undefined);
}
await runner.emitToolCall({ type: "tool_call", toolName: "write", toolCallId: "cancelled", input: { path: "new-0.txt", content: "discarded" } });
await runner.emit({ type: "session_branch" });
assert.equal(await runner.emitToolResult({ type: "tool_result", toolName: "write", toolCallId: "cancelled", input: {}, content: [], details: {}, isError: false }), undefined);

// The file pane can show later bytes while every earlier inline diff stays fixed.
for (const entry of results.filter(entry => !entry.failed)) writeFileSync(entry.result.details.ompGUI.fileSnapshot.path, "later-unrelated-content\n");
assert.deepEqual(errors, []);
assert.deepEqual(child.errors, []);
writeFileSync(join(root, "results.json"), JSON.stringify(results));
await sdk.emitSessionShutdownEvent(runner);
await sdk.emitSessionShutdownEvent(child.runner);
console.log(`Native OMP fast-write checks passed: ${results.length} delayed GUI fixtures, prepared batches and isolated sessions`);
process.exit(0);
