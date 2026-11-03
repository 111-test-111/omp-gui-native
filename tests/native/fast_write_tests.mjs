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

async function nativeWriter(directory = cwd, artifacts = join(root, "artifacts-main")) {
    const loaded = await sdk.loadExtensions([join(root, "extension.ts")], directory);
    assert.equal(loaded.errors.length, 0, JSON.stringify(loaded.errors));
    const manager = sdk.SessionManager.inMemory(directory);
    const localProtocolOptions = { getArtifactsDir: () => artifacts, getSessionId: () => manager.getSessionId() };
    const runner = new sdk.ExtensionRunner(loaded.extensions, loaded.runtime, directory,
        manager, {}, undefined, settings, localProtocolOptions);
    const errors = [];
    runner.onError(error => errors.push(error));
    const session = { cwd: directory, hasUI: false, settings, localProtocolOptions,
        getSessionFile: () => null, getSessionSpawns: () => null,
        getArtifactsDir: localProtocolOptions.getArtifactsDir, getSessionId: localProtocolOptions.getSessionId };
    const native = new sdk.WriteTool(session);
    const tool = new sdk.ExtensionToolWrapper(native, runner);
    const edit = new sdk.ExtensionToolWrapper(new sdk.EditTool(session, "replace"), runner);
    const patch = new sdk.ExtensionToolWrapper(new sdk.EditTool(session, "apply_patch"), runner);
    return { runner, errors, tool, edit, patch };
}

const { runner, errors, tool, edit, patch } = await nativeWriter();
const results = [];
async function write(id, path, content, old) {
    const result = await tool.execute(id, { path, content });
    assert(!result.isError, JSON.stringify(result));
    const snapshot = result.details.ompGUI.fileSnapshot;
    assert.equal(snapshot.oldText, old, id);
    assert.equal(snapshot.newText, readFileSync(snapshot.path, "utf8"), id);
    results.push({ id, args: { path, content }, result,
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

// Session-backed URLs use the caller's native mapping, including new parents,
// encoded Unicode/space names and hashline path wrappers accepted by write.
await write("local-new", "local://notes/你好%20brief.md", "local-first\n", "");
await write("local-overwrite", "local://notes/你好%20brief.md", "local-second\n", "local-first\n");
await write("local-bracket", "[local://bracket.md]", "bracketed\n", "");
await write("local-alias", "local:/alias.md", "alias\n", "");

// The write hook must also observe edits between prepared writes, otherwise the
// later write includes the edit's lines in its own patch.
await runner.emitToolCall({ type: "tool_call", toolName: "write", toolCallId: "after-edit",
    input: { path: "batch.txt", content: "after-native-edit\n" } });
runner.markToolCallEmitted("after-edit", "write");
const editArgs = { path: "batch.txt", old_string: "batch-third", new_string: "native-edited" };
const editResult = await edit.execute("native-edit", editArgs);
assert(!editResult.isError, JSON.stringify(editResult));
assert.equal(readFileSync(join(cwd, "batch.txt"), "utf8"), "native-edited\n");
results.push({ id: "native-edit", toolName: "edit", args: editArgs, result: editResult,
    additions: 1, deletions: 1, tokens: ["-batch-third", "+native-edited"] });
await write("after-edit", "batch.txt", "after-native-edit\n", "native-edited\n");
await runner.emit({ type: "tool_execution_end", toolCallId: "native-edit", toolName: "edit", result: editResult, isError: false });

// Real native edit results cover multi-file creation, rename and deletion.
writeFileSync(join(cwd, "remove.txt"), "remove-me\n");
writeFileSync(join(cwd, "rename.txt"), "rename-before\n");
for (const [id, path] of [["after-create", "add.txt"], ["after-rename", "rename.txt"], ["after-delete", "remove.txt"]]) {
    await runner.emitToolCall({ type: "tool_call", toolName: "write", toolCallId: id, input: { path } });
    runner.markToolCallEmitted(id, "write");
}
const patchArgs = { input: "*** Begin Patch\n*** Add File: add.txt\n+added\n*** Update File: rename.txt\n*** Move to: renamed.txt\n@@\n-rename-before\n+rename-after\n*** Delete File: remove.txt\n*** End Patch" };
const patchResult = await patch.execute("native-multi", patchArgs);
assert(!patchResult.isError, JSON.stringify(patchResult));
assert.equal(patchResult.details.perFileResults.length, 3);
results.push({ id: "native-multi", toolName: "edit", args: patchArgs, result: patchResult, expectedEdits: [
    { path: "add.txt", tokens: ["+added"] },
    { path: "renamed.txt", tokens: ["-rename-before", "+rename-after"] },
    { path: "remove.txt", tokens: ["-remove-me"] },
] });
await write("after-create", "add.txt", "after-create\n", "added\n");
await write("after-rename", "rename.txt", "after-rename\n", "");
await write("after-delete", "remove.txt", "after-delete\n", "");

// Resolve symlinked directories, missing parents, and Unicode/CRLF exactly as OMP.
rmSync(join(root, "file-alias"), { force: true });
symlinkSync(cwd, join(root, "file-alias"));
await write("symlink-new", join(root, "file-alias", "new-child", "你好.txt"), "保留内容\r\n", "");
await write("symlink-overwrite", join(root, "file-alias", "new-child", "你好.txt"), "第二次内容\r\n", "保留内容\r\n");

// A separate native session gets its own map even with the same call IDs/path.
const child = await nativeWriter(cwd, join(root, "artifacts-child"));
await runner.emitToolCall({ type: "tool_call", toolName: "write", toolCallId: "reused", input: { path: "isolation.txt", content: "lead\n" } });
const childResult = await child.tool.execute("reused", { path: "isolation.txt", content: "worker\n" });
assert.equal(childResult.details.ompGUI.fileSnapshot.oldText, "");
const leadResult = await runner.emitToolResult({ type: "tool_result", toolName: "write", toolCallId: "reused", input: { path: "isolation.txt" },
    details: { resolvedPath: join(cwd, "isolation.txt"), keep: { native: true } }, content: [], isError: false });
assert.equal(leadResult.details.ompGUI.fileSnapshot.oldText, "");
assert.deepEqual(leadResult.details.keep, { native: true });
const childLocal = await child.tool.execute("local-isolation", { path: "local://notes/你好%20brief.md", content: "child-local\n" });
assert.equal(childLocal.details.ompGUI.fileSnapshot.oldText, "");
assert.equal(childLocal.details.ompGUI.fileSnapshot.newText, "child-local\n");
assert.equal(readFileSync(join(root, "artifacts-main/local/notes/你好 brief.md"), "utf8"), "local-second\n");

// Advancing a same-file batch must retain the existing total baseline budget.
for (let i = 0; i < 11; i++) {
    const id = `budget-${i}`;
    await runner.emitToolCall({ type: "tool_call", toolName: "write", toolCallId: id, input: { path: "budget.txt" } });
    runner.markToolCallEmitted(id, "write");
}
await tool.execute("budget-0", { path: "budget.txt", content: "z".repeat(900_000) });
const budgetLast = await tool.execute("budget-10", { path: "budget.txt", content: "small-again\n" });
assert.equal(budgetLast.details.ompGUI.fileSnapshot.oldText, undefined);
assert.equal(budgetLast.details.ompGUI.fileSnapshot.newText, undefined);
await runner.emit({ type: "agent_end" });

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
for (const entry of results.filter(entry => !entry.failed)) {
    const details = entry.result.details;
    const paths = details.ompGUI?.fileSnapshot ? [details.ompGUI.fileSnapshot.path]
        : (details.perFileResults ?? [details]).map(row => row.resolvedPath ?? row.path);
    for (const path of paths) writeFileSync(resolve(cwd, path), "later-unrelated-content\n");
}
assert.deepEqual(errors, []);
assert.deepEqual(child.errors, []);
writeFileSync(join(root, "results.json"), JSON.stringify(results));
await sdk.emitSessionShutdownEvent(runner);
await sdk.emitSessionShutdownEvent(child.runner);
console.log(`Native OMP fast-write checks passed: ${results.length} delayed GUI fixtures, prepared batches and isolated sessions`);
process.exit(0);
