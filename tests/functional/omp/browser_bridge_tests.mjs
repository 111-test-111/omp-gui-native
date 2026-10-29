import assert from "node:assert/strict";
import { mkdtemp, mkdir, writeFile, readFile, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { createHash } from "node:crypto";
import { EventEmitter } from "node:events";
import { prepareBrowserSDK } from "../../../OMPGUI/Resources/OMPBrowserCompatibility.js";
import { isGuiTarget, resolveGuiTarget, markGuiPage, setGuiPageActive, GuiPageStateError,
    recoverGuiTarget, settleGuiRunDialog, readGuiCookies, restoreGuiCookies, workerOpenOptions,
    installGuiNavigationErrors } from "../../../OMPGUI/Resources/OMPBrowserSupport.js";

const root = await mkdtemp(join(tmpdir(), "omp-gui-browser-"));
const hash = text => createHash("sha256").update(text).digest("hex");
const sleep = ms => new Promise(resolve => setTimeout(resolve, ms));
try {
    const transport = new EventEmitter(), navigationCommands = [];
    let completeNavigation;
    transport.send = async method => {
        navigationCommands.push(method);
        if (method === "Page.navigate") return await new Promise(resolve => { completeNavigation = resolve; });
        return {};
    };
    const navigationPage = { mainFrame: () => ({ _id: "main", client: transport }) };
    const originalSend = transport.send;
    installGuiNavigationErrors(navigationPage);
    assert.equal(transport.send, originalSend, "Ordinary browsers keep their native navigation transport");
    markGuiPage(navigationPage); installGuiNavigationErrors(navigationPage);
    const request = (id, frame, url, type = "Document") => transport.emit("Network.requestWillBeSent",
        { requestId: id, frameId: frame, type, request: { url } });
    const fail = (id, type = "Document", errorText = "net::ERR_CERT_AUTHORITY_INVALID") =>
        transport.emit("Network.loadingFailed", { requestId: id, type, errorText });
    let finished = false;
    const navigation = transport.send("Page.navigate", { url: "https://fixture.invalid/#fragment", frameId: "main" })
        .then(value => { finished = true; return value; });
    request("child", "iframe", "https://fixture.invalid/"); fail("child");
    request("old", "main", "https://other.invalid/"); fail("old");
    request("script", "main", "https://fixture.invalid/", "Script"); fail("script", "Script");
    request("current", "main", "https://fixture.invalid/"); fail("current", "Document", "net::ERR_HTTP_RESPONSE_CODE_FAILURE");
    await sleep(0);
    assert.equal(finished, false, "Sibling, stale, subresource and HTTP-status failures cannot reject this navigation");
    fail("current");
    assert.deepEqual(await navigation, { frameId: "main", errorText: "net::ERR_CERT_AUTHORITY_INVALID" });
    assert.deepEqual(navigationCommands, ["Page.navigate", "Page.stopLoading"]);
    assert.equal(transport.listenerCount("Network.loadingFailed"), 0);
    assert.equal(transport.listenerCount("Network.requestWillBeSent"), 0);
    completeNavigation({ frameId: "main", errorText: "late reply" });
    const success = transport.send("Page.navigate", { url: "https://fixture.invalid/" });
    completeNavigation({ frameId: "main", loaderId: "loaded" });
    assert.deepEqual(await success, { frameId: "main", loaderId: "loaded" });
    assert.deepEqual(navigationCommands, ["Page.navigate", "Page.stopLoading", "Page.navigate"], "A successful navigation is never stopped");
    assert.equal(transport.listenerCount("Network.loadingFailed"), 0);

    const configured = { mode: "attach", downloadsPath: "/tmp/fixture 中文", initScripts: ["window.fixture=1"],
        userAgent: "fixture/1", ignoreHttpsErrors: false, viewport: { width: 803, height: 601, deviceScaleFactor: 1 },
        signal: new AbortController().signal, url: "https://initial.invalid/" };
    const initial = workerOpenOptions(configured);
    configured.initScripts.push("later"); configured.viewport.width = 999;
    assert.deepEqual(initial.initScripts, ["window.fixture=1"], "Recovery retains the initial script sources");
    assert.equal(initial.viewport.width, 803, "A later caller cannot mutate recovery geometry");
    assert.equal(initial.downloadsPath, "/tmp/fixture 中文");
    assert.equal(initial.userAgent, "fixture/1");
    assert.equal(initial.ignoreHttpsErrors, false, "An omitted or false setting is not enabled on recovery");
    assert.equal("url" in initial || "signal" in initial, false, "Recovery neither re-navigates nor reuses the failed signal");
    assert.equal(workerOpenOptions({ ...configured, mode: "headless", emulateViewport: false }).viewport, undefined);
    const source = join(root, "installed"), cache = join(root, "cache"), patch = join(root, "patch.json");
    await mkdir(join(source, "src"), { recursive: true });
    await mkdir(join(source, "node_modules"));
    await writeFile(join(source, "package.json"), JSON.stringify({ name: "@oh-my-pi/pi-coding-agent", version: "18.12.5" }));
    await writeFile(join(source, "src/browser.ts"), "original\n");
    await writeFile(join(root, "helper.js"), "export const enabled = true;\n");
    await writeFile(patch, JSON.stringify({ version: "18.12.5", files: [{ path: "src/browser.ts", sourceSHA256: hash("original\n"),
        patchedSHA256: hash("repaired\n"), changes: [{ before: "original", after: "repaired" }] }],
        additions: [{ path: "src/browser/helper.js", resource: "helper.js", sha256: hash("export const enabled = true;\n") }] }));
    const copies = await Promise.all([prepareBrowserSDK(source, cache, patch), prepareBrowserSDK(source, cache, patch)]);
    assert.equal(copies[0], copies[1], "Concurrent launches share one immutable result");
    assert.equal(await readFile(join(source, "src/browser.ts"), "utf8"), "original\n", "Installed runtime remains unchanged");
    assert.equal(await readFile(join(copies[0], "src/browser.ts"), "utf8"), "repaired\n");
    assert.equal(await readFile(join(copies[0], "src/browser/helper.js"), "utf8"), "export const enabled = true;\n");
    assert.equal(await prepareBrowserSDK(source, cache, patch), copies[0], "Reuse verified preparation");
    await writeFile(join(root, "helper.js"), "changed\n");
    assert.equal(await prepareBrowserSDK(source, cache, patch), null, "Helper changes also require review");
    await writeFile(join(root, "helper.js"), "export const enabled = true;\n");
    await writeFile(join(copies[0], "src/browser/helper.js"), "damaged\n");
    await assert.rejects(prepareBrowserSDK(source, cache, patch), "Never reuse a damaged cached helper");
    await writeFile(join(source, "src/browser.ts"), "upgraded\n");
    assert.equal(await prepareBrowserSDK(source, cache, patch), null, "Changed upstream source fails closed");
    await writeFile(join(source, "package.json"), JSON.stringify({ name: "@oh-my-pi/pi-coding-agent", version: "19.0.0" }));
    assert.equal(await prepareBrowserSDK(source, cache, patch), null, "Unreviewed runtime versions are not patched");

    const targets = new Map(["A", "B"].map(id => [id, { targetId: id, type: "page", url: "https://same.example/", title: "Same" }]));
    const touched = [];
    const connection = { send: async (method, { targetId }) => {
        assert.equal(method, "Target.getTargetInfo"); touched.push(targetId);
        if (!targets.has(targetId)) throw new Error("Target closed");
        return { targetInfo: targets.get(targetId) };
    } };
    assert.equal(await resolveGuiTarget(connection, "omp-gui-target:B"), "B");
    assert.deepEqual(touched, ["B"], "Supervisor never initializes a Page or touches a sibling renderer");
    targets.delete("B");
    await assert.rejects(resolveGuiTarget(connection, "omp-gui-target:B"), /Target closed/);
    assert.deepEqual(touched, ["B", "B"], "Stale target never falls back to the same-URL sibling");
    assert.equal(isGuiTarget("ordinary URL matcher"), false);
    await assert.rejects(resolveGuiTarget(connection, "omp-gui-target:../A"), /Invalid/);
    const abort = new AbortController(); abort.abort(new Error("cancelled"));
    await assert.rejects(resolveGuiTarget(connection, "omp-gui-target:A", abort.signal), /cancelled/);
    await assert.rejects(resolveGuiTarget({ send: () => new Promise(() => {}) }, "omp-gui-target:A", undefined, 5), /timed out/);
    assert.deepEqual(touched, ["B", "B"], "Invalid and cancelled lookups send no CDP command");

    const recoveryCommands = [];
    let detached = 0;
    const recoverable = { createCDPSession: async () => ({
        send: async method => { recoveryCommands.push(method); if (method === "Page.handleJavaScriptDialog") throw new Error("No dialog is showing"); },
        detach: async () => { detached++; },
    }) };
    await recoverGuiTarget(recoverable);
    assert.deepEqual(recoveryCommands, ["Page.stopLoading", "Fetch.disable"]);
    assert.equal(detached, 1);
    await assert.rejects(recoverGuiTarget({ createCDPSession: async () => ({
        send: async () => { throw new Error("Target crashed"); }, detach: async () => { detached++; },
    }) }), /Target crashed/, "Transport failures must reach native recovery diagnostics");
    let lateCommands = 0, releaseSession;
    const lateSession = new Promise(resolve => { releaseSession = resolve; });
    await assert.rejects(recoverGuiTarget({ createCDPSession: () => lateSession }, undefined, 5), /timed out/);
    releaseSession({ send: async () => { lateCommands++; }, detach: async () => { detached++; } });
    await sleep(0);
    assert.equal(lateCommands, 0, "Timed-out recovery never dismisses a later dialog");
    assert.equal(detached, 3, "Even a late session is detached");
    let releaseCommand;
    const stalledCommand = new Promise(resolve => { releaseCommand = resolve; });
    const lateRecovery = [];
    await assert.rejects(recoverGuiTarget({ createCDPSession: async () => ({
        send: method => { lateRecovery.push(method); return stalledCommand; }, detach: async () => {},
    }) }, undefined, 5), /timed out/);
    releaseCommand({}); await sleep(0);
    assert.deepEqual(lateRecovery, ["Page.stopLoading"], "A late reply cannot advance abandoned recovery");

    const focus = [];
    const page = { emulateFocusedPage: async enabled => { focus.push(enabled); } };
    await setGuiPageActive(page, true);
    assert.deepEqual(focus, [], "Ordinary borrowed browsers retain native behavior");
    markGuiPage(page);
    const decisions = [];
    const dialogs = { state: () => ({ open: true }), handle: async decision => { decisions.push(decision); } };
    await settleGuiRunDialog({}, dialogs, true);
    await settleGuiRunDialog(page, dialogs, false);
    await settleGuiRunDialog(page, { ...dialogs, state: () => ({ open: false }) }, true);
    assert.deepEqual(decisions, [], "Only an interrupted GUI run dismisses its own pending modal");
    await settleGuiRunDialog(page, dialogs, true);
    assert.deepEqual(decisions, [{ accept: false }]);
    await assert.rejects(settleGuiRunDialog(page, { ...dialogs, handle: () => new Promise(() => {}) }, true), /timed out/,
        "A wedged original session cannot exhaust the native cleanup grace");
    await setGuiPageActive(page, true, undefined, true);
    await setGuiPageActive(page, false, undefined, true);
    assert.deepEqual(focus, [], "An open modal must not block its own handling on a focus command");
    await setGuiPageActive(page, true); await setGuiPageActive(page, false);
    assert.deepEqual(focus, [true, false], "Call-scoped activity restores background behavior");
    page.emulateFocusedPage = async () => { throw new Error("Renderer unavailable"); };
    await assert.rejects(setGuiPageActive(page, false), GuiPageStateError, "Failed cleanup requests native recovery");

    let jar = [], ignoreWrites = false;
    const cookieCommands = [];
    const cookiePage = { browserContext() { throw new Error("Wrong default profile"); }, createCDPSession: async () => ({
        send: async (method, args) => {
            cookieCommands.push(method);
            if (method === "Network.setCookies" && !ignoreWrites) jar = structuredClone(args.cookies);
            return { cookies: structuredClone(jar) };
        }, detach: async () => {},
    }) };
    const cookies = [{ name: "synthetic", value: "secret-test-value", domain: "fixture.invalid", path: "/", expires: -1,
        secure: false, httpOnly: true, sameSite: "Lax" }];
    await restoreGuiCookies(cookiePage, cookies);
    assert.deepEqual(await readGuiCookies(cookiePage), cookies);
    assert.deepEqual(cookieCommands, ["Network.setCookies", "Network.getAllCookies", "Network.getAllCookies"]);
    ignoreWrites = true; jar = [];
    await assert.rejects(restoreGuiCookies(cookiePage, cookies), error =>
        /not retained/.test(error.message) && !error.message.includes("secret-test-value"));
    jar = [{ ...cookies[0], partitionKey: { topLevelSite: "https://fixture.invalid" } }];
    await assert.rejects(readGuiCookies(cookiePage), /partitioned/, "State export must not discard a partition key");
    await assert.rejects(restoreGuiCookies(cookiePage, jar), /partitioned/);
    const beforeAbort = cookieCommands.length;
    await assert.rejects(readGuiCookies(cookiePage, abort.signal), /cancelled/);
    assert.equal(cookieCommands.length, beforeAbort, "Cancelled cookie access sends no commands");
    console.log("Browser bridge: guarded copies, exact targets, bounded recovery, background focus and target-profile cookies passed");
} finally { await rm(root, { recursive: true, force: true }); }
