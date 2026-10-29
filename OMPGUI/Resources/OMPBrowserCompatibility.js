// Version-guarded repairs to the real native OMP SDK. The installed package is
// read-only; Browser/Eval/workers still belong to OMP, including cancellation.
import { createHash, randomUUID } from "node:crypto";
import { readFile, mkdir, cp, symlink, rename, rm } from "node:fs/promises";
import { join, basename, dirname, isAbsolute } from "node:path";
import { pathToFileURL } from "node:url";

const hash = value => createHash("sha256").update(value).digest("hex");

export async function prepareBrowserSDK(source, cache, patchURL = new URL("./OMPBrowserPatches.json", import.meta.url)) {
    if (!cache) return null;
    const specification = await readFile(patchURL, "utf8");
    const patches = JSON.parse(specification);
    const pkg = JSON.parse(await readFile(join(source, "package.json"), "utf8"));
    if (pkg.name !== "@oh-my-pi/pi-coding-agent" || pkg.version !== patches.version) return null;
    const results = new Map();
    for (const patch of patches.files) {
        let text = await readFile(join(source, patch.path), "utf8");
        if (hash(text) !== patch.sourceSHA256) return null;
        for (const change of patch.changes) {
            if (text.split(change.before).length !== 2) return null;
            text = text.replace(change.before, () => change.after);
        }
        if (hash(text) !== patch.patchedSHA256) return null;
        results.set(patch.path, text);
    }
    const specificationURL = patchURL instanceof URL ? patchURL : pathToFileURL(patchURL);
    for (const addition of patches.additions ?? []) {
        if (isAbsolute(addition.path) || addition.path.split(/[\\/]/).includes("..")
            || basename(addition.resource) !== addition.resource || results.has(addition.path)) return null;
        const text = await readFile(new URL(addition.resource, specificationURL), "utf8");
        if (hash(text) !== addition.sha256) return null;
        results.set(addition.path, text);
    }
    const identity = hash(source + "\n" + specification);
    const destination = join(cache, identity);
    async function validCopy() {
        try {
            if ((await readFile(join(destination, ".omp-gui-browser"), "utf8")) !== identity) return false;
            for (const [path, text] of results) {
                if (hash(await readFile(join(destination, path))) !== hash(text)) return false;
            }
            return true;
        } catch { return false; }
    }
    if (await validCopy()) return destination;
    await mkdir(cache, { recursive: true, mode: 0o700 });
    const staging = join(cache, ".prepare-" + randomUUID());
    const { writeFile } = await import("node:fs/promises");
    try {
        await cp(source, staging, { recursive: true, dereference: false,
            filter: path => path === source || !["node_modules", ".git", ".build", ".cef"].includes(basename(path)) });
        await symlink(join(source, "node_modules"), join(staging, "node_modules"), "dir");
        for (const [path, text] of results) {
            await mkdir(dirname(join(staging, path)), { recursive: true });
            await writeFile(join(staging, path), text);
        }
        await writeFile(join(staging, ".omp-gui-browser"), identity, { mode: 0o600 });
        try { await rename(staging, destination); }
        catch (error) {
            // Concurrent session starts may prepare the same immutable version.
            if (!(await validCopy())) throw error;
        }
    } finally { await rm(staging, { recursive: true, force: true }); }
    return destination;
}
