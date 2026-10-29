import assert from "node:assert/strict";
import { readFile, writeFile, mkdir } from "node:fs/promises";
import { join } from "node:path";
import { pathToFileURL } from "node:url";

// Real installed OMP Eval -> browser prelude -> Puppeteer -> the hosted CEF.
// No model requests, account access, extra Chromium or mocked browser backend.
const [root, packageRoot, base] = process.argv.slice(2);
assert(root.includes("/build.noindex/cef-prototype/runs/"));
const config = JSON.parse(await readFile(join(root, "environment.json"), "utf8"));
const imp = name => import(pathToFileURL(Bun.resolveSync(name, packageRoot)).href);
const sdk = await imp("@oh-my-pi/pi-coding-agent");
const { getBundledModel } = await imp("@oh-my-pi/pi-catalog");
const { ensureTheme, stopThemeWatcher } = await imp("@oh-my-pi/pi-tui/theme");
await ensureTheme();
const agentDir = process.env.PI_CODING_AGENT_DIR;
assert(agentDir.startsWith(root + "/"));
await mkdir(agentDir, { recursive: true });
const settings = sdk.Settings.isolated({ "browser.enabled": true, "browser.cdpUrl": config.cdpURL,
    "browser.relay": false, "browser.tern": false, "browser.cmux": false,
    "eval.js": true, "eval.py": false, "tools.approvalMode": "yolo", "tools.xdev": false,
    "memory.backend": "off", "autolearn.enabled": false, "lsp.enabled": false, "startup.quiet": true });
const authStorage = await sdk.AuthStorage.create(join(agentDir, "auth.db"));
const modelRegistry = new sdk.ModelRegistry(authStorage, join(agentDir, "models.yml"), { settings });
const { session } = await sdk.createAgentSession({ cwd: root, agentDir, settings, authStorage, modelRegistry,
    model: getBundledModel("openai", "gpt-4o-mini"), sessionManager: sdk.SessionManager.inMemory(root),
    disableExtensionDiscovery: true, extensions: [], skills: [], rules: [], contextFiles: [],
    enableMCP: false, cacheWarming: false, bindProcessState: false });
const tool = session.getToolForEvalBridge("eval");
assert(tool, "The installed runtime exposes its real Eval tool");
const evidence = { status: "running", checks: [], cells: [], ompVersion: JSON.parse(await readFile(join(packageRoot, "package.json"), "utf8")).version,
    cefSwiftRevision: config.cefSwiftRevision, modelRequests: 0, scope: "Standalone visible CefWebView, native OMP SDK/Eval/Browser; loopback fixture only" };
const save = () => writeFile(join(root, "result.json"), JSON.stringify(evidence, null, 2));
const expect = (value, label) => { assert.ok(value, label); evidence.checks.push(label); console.log("PASS " + label); };
const state = () => fetch(base + "/native-state").then(r => r.json());
const control = (action, tab) => fetch(base + "/control", { method: "POST", headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ action, tab }) }).then(r => { assert(r.ok); return r.json(); });
async function waitFor(read, predicate, seconds = 15) {
    const until = Date.now() + seconds * 1000;
    do { const value = await read(); if (predicate(value)) return value; await Bun.sleep(100); } while (Date.now() < until);
    throw new Error("Acceptance condition did not complete");
}
async function nativeProof(tab) {
    const previous = (await fetch(base + "/proof").then(r => r.json())).length;
    await control("sample", tab);
    return (await waitFor(() => fetch(base + "/proof").then(r => r.json()), value => value.length > previous)).at(-1);
}
async function cell(label, code, signal) {
    const begin = performance.now();
    const result = await tool.execute(crypto.randomUUID(), { language: "js", code, timeout: 25, title: label }, signal);
    const text = result.content.filter(x => x.type === "text").map(x => x.text).join("\n");
    evidence.cells.push({ label, elapsedMs: Math.round(performance.now() - begin), text, details: result.details,
        images: result.content.filter(x => x.type === "image").length });
    await save();
    console.log(label + ": " + text.slice(0, 1600));
    if (result.isError || result.details?.isError) throw new Error(text);
    const marker = text.split("\n").find(x => x.startsWith("CEF_RESULT="));
    return marker ? JSON.parse(marker.slice("CEF_RESULT=".length)) : { text };
}
const openCode = (name, target) => `var ${name} = await browser.open({name:${JSON.stringify(name)},app:{cdp_url:${JSON.stringify(config.cdpURL)},target:${JSON.stringify(target)}}});`;
const emit = expression => `console.log('CEF_RESULT='+JSON.stringify(${expression}));`;
const phase = process.env.CEF_PROTOTYPE_CASE ?? "all";
evidence.phase = phase;
try {
    const initial = await state();
    const a = initial.tabs.find(x => x.id === "A"), b = initial.tabs.find(x => x.id === "B");
    const targets = await fetch(config.cdpURL + "/json/list").then(r => r.json());
    evidence.initialTargets = targets.map(({ id, type, title, url }) => ({ id, type, title, url }));
    expect(targets.filter(x => x.type === "page").length === 2, "Exactly two embedded page targets, no external Chrome page");
    const identities = await cell("attach-and-identify", openCode("a", a.instance) + openCode("b", b.instance) +
        emit("await Promise.all([a.evaluate(() => window.nativeIdentity),b.evaluate(() => window.nativeIdentity)])"));
    expect(identities[0].instance === a.instance && identities[1].instance === b.instance,
        "OMP reads the distinct instance UUIDs injected by the native hosted browsers");
    expect(identities[0].cefBrowserID === String(a.cefBrowserID) && identities[1].cefBrowserID === String(b.cefBrowserID),
        "CDP observations match both native CEF browser identifiers");
    let proofB;
    if (phase !== "closing") {
    const observation = await cell("observe", emit("await a.observe()"));
    expect(observation.elements.length >= 3, "OMP observes the actual input, textarea and button");
    await cell("input-a", "await a.fill('#name','OMP 中文 A'); await a.press('End',{selector:'#name'}); await a.press('!'); await a.click('#apply');");
    const proofA = await nativeProof("A"), untouchedB = await nativeProof("B");
    expect(proofA.value === "OMP 中文 A!" && proofA.output === proofA.value, "Native owner independently confirms OMP Chinese fill, key press and click");
    expect(proofA.trusted.some(x => x.kind === "keydown" && x.trusted), "Keyboard input includes a browser-trusted key event");
    expect(untouchedB.value === "" && untouchedB.output === "", "Input in A leaves same-origin B untouched");
    await cell("input-hidden-b", "await b.fill('#name','OMP 中文 B'); await b.fill('#notes'," + JSON.stringify("第二个标签\n独立内容") + "); await b.click('#apply');");
    proofB = await nativeProof("B"); const unchangedA = await nativeProof("A");
    expect(proofB.value === "OMP 中文 B" && unchangedA.value === proofA.value, "Explicit target B works while A is selected, without cross-tab input");
    await control("select", "A");
    const screenshot = await cell("screenshot-a", emit("await a.screenshot({format:'png'})"));
    assert.equal(typeof screenshot, "string");
    const pixels = await readFile(screenshot);
    expect(pixels.subarray(0, 8).equals(Buffer.from([137, 80, 78, 71, 13, 10, 26, 10])), "OMP produces a real PNG screenshot of embedded A");
    await writeFile(join(root, "embedded-a.png"), pixels);
    evidence.screenshot = { path: "embedded-a.png", bytes: pixels.length, width: pixels.readUInt32BE(16), height: pixels.readUInt32BE(20) };
    const controller = new AbortController();
    const start = performance.now();
    const pending = cell("cancel-wait", "await a.waitFor('#never-created',{timeout:20000}); await a.fill('#name','LATE-CANCELLED-WRITE');", controller.signal);
    const abortTimer = setTimeout(() => controller.abort(), 600);
    let cancelled;
    try { cancelled = await pending; } catch (error) { cancelled = { error: String(error) }; }
    clearTimeout(abortTimer);
    evidence.cancellation = { elapsedMs: Math.round(performance.now() - start), result: cancelled };
    expect(controller.signal.aborted && /abort|cancel|interrupt/i.test(JSON.stringify(cancelled)), "A real AbortSignal interrupts the pending browser operation");
    expect(evidence.cancellation.elapsedMs < 6000, "Abort returns within six seconds instead of waiting for selector timeout");
    await Bun.sleep(500);
    const afterCancel = await nativeProof("A");
    expect(afterCancel.value !== "LATE-CANCELLED-WRITE", "Cancelled sequence cannot execute its later write");
    evidence.cancellation.preservedInput = afterCancel.value === proofA.value;
    await cell("recover-after-cancel", openCode("a", a.instance) + "await a.fill('#name','RECOVERED'); await a.click('#apply');");
    expect((await nativeProof("A")).output === "RECOVERED", "OMP can reacquire and operate A after cancellation");
    } else {
        await cell("closing-setup", "await b.fill('#name','B-CLOSE-BASELINE'); await b.click('#apply');");
        proofB = await nativeProof("B");
    }
    if (phase !== "cancellation") {
    await cell("detach", "await a.close();");
    expect((await state()).tabs.find(x => x.id === "A").cefBrowserID === a.cefBrowserID,
        "Closing an OMP attached handle preserves the user-owned embedded browser");
    await cell("reattach", openCode("a", a.instance));
    await control("close", "A");
    await waitFor(() => fetch(config.cdpURL + "/json/list").then(r => r.json()), targets => !targets.some(x => x.url.includes(a.instance)));
    evidence.afterNativeClose = { state: await state(), targets: await fetch(config.cdpURL + "/json/list").then(r => r.json()) };
    await save();
    expect((await nativeProof("B")).value === proofB.value, "Closing A preserves B and its input before stale-handle recovery");
    let staleFailed = false;
    try { await cell("closed-target", emit("await a.evaluate(() => document.title)")); } catch { staleFailed = true; }
    expect(staleFailed, "Operations on the natively closed target fail instead of selecting B");
    expect((await nativeProof("B")).value === proofB.value, "Closing A preserves B and its input");
    await control("reopen", "A");
    const restored = await waitFor(state, value => value.tabs.some(x => x.id === "A" && x.bound && x.instance !== a.instance));
    const freshA = restored.tabs.find(x => x.id === "A");
    // The old Puppeteer connection can retain a closed Alloy target whose
    // frame is unreadable. OMP deliberately refuses ambiguous discovery.
    // Release borrowed handles and reconnect, preserving native browser state.
    await cell("recover-after-close", "await browser.close({all:true});" + openCode("a", freshA.instance) + openCode("b", b.instance) +
        "await a.fill('#name','REOPENED 中文'); await a.click('#apply');");
    expect((await nativeProof("A")).output === "REOPENED 中文", "OMP opens a fresh handle and operates the recreated embedded tab");
    expect(freshA.cefBrowserID !== a.cefBrowserID, "Reopened A is a new native browser instance");
    expect((await nativeProof("B")).value === proofB.value, "Refreshing the attached connection preserves B and its input");
    const recoveredShot = await cell("screenshot-recovered", emit("await a.screenshot({format:'png'})"));
    await writeFile(join(root, "embedded-recovered.png"), await readFile(recoveredShot));
    }
    await cell("release-all", "await browser.close({all:true});");
    expect((await state()).tabs.length === 2, "Releasing all OMP handles preserves both user-owned tabs");
    evidence.status = "passed";
} catch (error) {
    evidence.status = "failed";
    evidence.error = String(error?.stack ?? error);
    throw error;
} finally {
    await save();
    await session.dispose();
    authStorage.close(); stopThemeWatcher();
}
