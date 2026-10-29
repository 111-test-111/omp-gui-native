// No GUI, CEF, provider credentials or model session. Resolve the repaired
// public SDK using exactly the self-package resolution used by OMPSDKHost.
import assert from "node:assert/strict";
import { readFile, writeFile } from "node:fs/promises";
import { join } from "node:path";
import { pathToFileURL } from "node:url";
import { prepareBrowserSDK } from "../../OMPGUI/Resources/OMPBrowserCompatibility.js";
import { checkBrowserEval } from "./browser_eval_tests.mjs";
import { checkBrowserDownloads } from "./browser_download_tests.mjs";

const [output, source] = process.argv.slice(2);
const dirs = await import(pathToFileURL(Bun.resolveSync("@oh-my-pi/pi-utils/dirs", source)));
assert.equal(dirs.getBaseConfigRoot(), join(output, "profile"), "Native profile/cache/log paths stay inside this check");
const repaired = await prepareBrowserSDK(source, join(output, "sdk"));
assert.ok(repaired, "Installed SDK must match the reviewed compatibility specification");
const paths = {};
for (const subpath of ["sdk", "main", "cli", "cli/args", "cli/profile-bootstrap", "session/queued-messages", "tools/browser/frames", "tools/browser/tab-supervisor", "tools/browser/tab-worker", "tools/browser/storage-state", "tools/browser/tab-call"]) {
    const path = Bun.resolveSync("@oh-my-pi/pi-coding-agent/" + subpath, repaired);
    assert.ok(path.startsWith(repaired + "/"), "Every native module resolves inside the isolated copy: " + subpath);
    paths[subpath] = path;
}
const imp = subpath => import(pathToFileURL(join(repaired, "src", subpath)));
// Import all executable patch paths, including the actual Browser worker.
const supervisor = await import(pathToFileURL(paths["tools/browser/tab-supervisor"]));
assert.equal(typeof supervisor.acquireTab, "function");
await import(pathToFileURL(paths["tools/browser/tab-worker"]));
const { renderTabCall } = await imp("tools/browser/tab-call.ts");
const support = await imp("tools/browser/omp-gui.js");
const execute = code => new Function("tab", `return (async () => { ${code} })()`);
const frameCode = renderTabCall([{ method: "frame", args: ["#child"] }, { method: "evaluate", args: ["document.title"] }]);
assert.equal(await execute(frameCode)({ frame: async () => ({ evaluate: expression => {
    assert.equal(expression, "document.title", "String expression must reach the frame's execution context"); return "child";
} }) }), "child");
const functionCode = renderTabCall([{ method: "frame", args: ["#child"] }, { method: "evaluate", args: [{ __omp_fn: "() => 42" }] }]);
assert.equal(await execute(functionCode)({ frame: async () => ({ evaluate: fn => fn() }) }), 42);
const elementCode = renderTabCall([{ method: "id", args: [1] }, { method: "evaluate", args: ["node => node.value"] }]);
assert.equal(await execute(elementCode)({ id: async () => ({ evaluate: fn => fn({ value: "element" }) }) }), "element");
const screenshotCode = renderTabCall([{ method: "frame", args: ["#child"] }, { method: "screenshot", args: ["#subject"] }]);
assert.equal(await execute(screenshotCode)({ frame: async () => ({ screenshot: selector => selector }) }), "#subject");

const storage = await imp("tools/browser/storage-state.ts");
let jar = [], writes = [], current = "https://fixture.invalid";
const page = { browserContext() { throw new Error("State must not use the browser's default profile"); },
    createCDPSession: async () => ({ send: async (method, args) => {
        if (method === "Network.setCookies") jar = structuredClone(args.cookies);
        return { cookies: structuredClone(jar) };
    }, detach: async () => {} }),
    evaluate: async (fn, ...args) => {
        if (fn.name === "readOriginStorageInPage") return { origin: current, localStorage: [], sessionStorage: [] };
        if (args.length) { writes.push(args); return; }
        return current;
    },
};
support.markGuiPage(page);
const stateFile = join(output, "synthetic-state.json");
const state = { cookies: [{ name: "synthetic", value: "fixture", domain: "fixture.invalid", path: "/", expires: -1,
    httpOnly: true, secure: true, sameSite: "Lax" }], origins: [
        { origin: current, localStorage: [{ name: "test", value: "restored" }], sessionStorage: [] },
        { origin: "https://elsewhere.invalid", localStorage: [{ name: "other", value: "untouched" }] },
    ] };
await writeFile(stateFile, JSON.stringify(state));
const loaded = await storage.loadStorageState(page, stateFile, output, { navigationTimeoutMs: 1000, allowOtherOrigins: true });
assert.deepEqual(loaded, { loadedOrigins: [current], skippedOrigins: ["https://elsewhere.invalid"] });
assert.equal(writes.length, 1);
assert.deepEqual(jar, state.cookies);
const saved = await storage.saveStorageState(page, "test", join(output, "saved-state.json"), output);
assert.deepEqual(JSON.parse(await readFile(saved, "utf8")).cookies, state.cookies);
state.cookies[0].partitionKey = { topLevelSite: current };
await writeFile(stateFile, JSON.stringify(state));
await assert.rejects(storage.loadStorageState(page, stateFile, output, { navigationTimeoutMs: 1000 }));
assert.equal(writes.length, 1, "Unsupported state is rejected before changing storage");
const evalChecks = await checkBrowserEval(repaired, output);
const downloadChecks = await checkBrowserDownloads(repaired, output);
const originals = JSON.parse(await readFile(new URL("../../OMPGUI/Resources/OMPBrowserPatches.json", import.meta.url)));
const { createHash } = await import("node:crypto");
for (const file of originals.files) {
    assert.equal(createHash("sha256").update(await readFile(join(source, file.path))).digest("hex"), file.sourceSHA256);
}
await writeFile(join(output, "result.json"), JSON.stringify({ version: originals.version, resolvedModules: Object.keys(paths),
    installedSourceUnchanged: true, frameContext: true, targetProfileState: true, evalChecks, downloadChecks }, null, 2));
console.log("Native browser SDK: imports, frame calls, target-profile state, Eval retention/restart and original hashes passed");
