import assert from "node:assert/strict";
import { execFile as execFileCallback } from "node:child_process";
import { promisify } from "node:util";
import { mkdtemp, mkdir, realpath, rm, symlink } from "node:fs/promises";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { repositoryMemoryScope, boundedMemoryPreview } from "../../../OMPGUI/Resources/OMPMemoryControl.js";

const execFile = promisify(execFileCallback);
const root = await mkdtemp(join(tmpdir(), "omp-gui-memory-"));
try {
    const main = join(root, "main"), linked = join(root, "linked"), clone = join(root, "clone");
    await mkdir(main);
    await execFile("git", ["init", "-q", main]);
    await execFile("git", ["-C", main, "-c", "user.name=Memory Check", "-c", "user.email=check@invalid", "commit", "--allow-empty", "-qm", "Initial"]);
    await execFile("git", ["-C", main, "worktree", "add", "-qb", "task", linked]);
    await execFile("git", ["clone", "-q", main, clone]);
    const io = { execFile: (command, args, options) => execFile(command, args,
        { ...options, env: { ...process.env, GIT_CEILING_DIRECTORIES: dirname(root) } }), realpath };
    const scope = await repositoryMemoryScope(main, io);
    assert.equal(await repositoryMemoryScope(linked, io), scope, "Linked worktrees share a repository identity");
    await mkdir(join(linked, "nested"));
    assert.equal(await repositoryMemoryScope(join(linked, "nested"), io), scope, "Nested cwd shares repository identity");
    await symlink(linked, join(root, "alias"));
    assert.equal(await repositoryMemoryScope(join(root, "alias"), io), scope, "Symlink spellings share identity");
    assert.notEqual(await repositoryMemoryScope(clone, io), scope, "Independent clones never share project memory");
    assert.equal(await repositoryMemoryScope(root, io), await realpath(root), "A non-Git project has its own identity");
    await assert.rejects(repositoryMemoryScope(main, { realpath, execFile: async () => { throw new Error("Git unavailable"); } }),
        /Git unavailable/, "Failure cannot silently choose a different memory bank");
    console.log("PASS memory repository identity: worktrees, nested cwd, symlinks, clone isolation and errors");
} finally { await rm(root, { recursive: true, force: true }); }

const unicode = "记忆😀".repeat(4000);
const preview = boundedMemoryPreview(Array.from({ length: 60 }, (_, i) =>
    ({ id: String(i), content: unicode, source: "coding-agent-transcript", timestamp: "2026-10-17" })));
assert(preview.limited && preview.items.length <= 50);
assert(preview.items.reduce((bytes, item) => bytes + Buffer.byteLength(item.content), 0) <= 65536,
    "File previews have an aggregate UTF-8 content budget");
assert(preview.items.every(item => !item.content.includes("\uFFFD") && unicode.startsWith(item.content)),
    "Clipping preserves Chinese and supplementary Unicode characters");
assert(preview.items[0].truncated && preview.items[0].source === "coding-agent-transcript");
assert.equal(boundedMemoryPreview(Array.from({ length: 60 }, () => ({ content: "short" }))).items.length, 50,
    "Many small entries cannot exceed the row limit");
assert(boundedMemoryPreview([{ content: "native shortened text", truncated: true }]).limited,
    "Native truncation remains visible to the user");
assert.deepEqual(boundedMemoryPreview([]), { items: [], limited: false });
console.log("PASS memory file previews: row/byte budgets, Unicode boundaries, provenance and empty/shortened results");
