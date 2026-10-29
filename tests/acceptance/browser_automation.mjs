import assert from "node:assert/strict";
import { readFile, writeFile, rename, stat } from "node:fs/promises";
import { join } from "node:path";
import { pathToFileURL } from "node:url";
import { prepareBrowserSDK } from "../../OMPGUI/Resources/OMPBrowserCompatibility.js";
import { createCefBrowserSession } from "../support/cef_browser_session.mjs";
import { checkRecoveryOptions, checkDownloadLifecycle, checkCertificateOptions } from "./browser_recovery.mjs";

const [root, source, startAt = "start"] = process.argv.slice(2);
const dirs = await import(pathToFileURL(Bun.resolveSync("@oh-my-pi/pi-utils/dirs", source)).href);
assert.equal(dirs.getBaseConfigRoot(), join(root, "omp-profile"), "Native state must remain inside this acceptance run");
const phase = ["start", "state", "frames", "recovery", "options", "downloads", "tls"].indexOf(startAt);
assert.ok(phase >= 0, "Unknown acceptance start phase");
const attachment = JSON.parse(await readFile(join(root, "automation-ready.json"), "utf8"));
const repaired = await prepareBrowserSDK(source, join(root, "sdk"));
assert.ok(repaired, "Installed native SDK must match the production compatibility guards");
// Production host reentry passes this root into the actual OMP Browser/Eval workers.
process.env.OMP_GUI_BROWSER_SDK_ROOT = repaired;
const native = await createCefBrowserSession(root, repaired, attachment.a.open.app.cdp_url);
const evidence = { status: "running", startAt, modelRequests: 0, checks: [], cells: [] };
const save = () => writeFile(join(root, "automation-result.json"), JSON.stringify(evidence, null, 2));
const check = (value, message) => { assert.ok(value, message); evidence.checks.push(message); };
let sequence = 0;
async function control(action, tab = "a") {
    const request = { action, tab, sequence: ++sequence };
    await writeFile(join(root, "automation-request.tmp"), JSON.stringify(request));
    await rename(join(root, "automation-request.tmp"), join(root, "automation-request.json"));
    const deadline = Date.now() + 8000;
    do {
        const response = await readFile(join(root, "automation-response.json"), "utf8").then(JSON.parse).catch(() => null);
        if (response?.sequence === sequence) { assert.equal(response.ok, true, response.error); return response; }
        await Bun.sleep(30);
    } while (Date.now() < deadline);
    throw new Error("Native control did not settle: " + action);
}
async function cell(label, code, { failure = false, timeout = 12 } = {}) {
    evidence.current = label; await save();
    const result = await native.tool.execute(crypto.randomUUID(), { language: "js", code, timeout, title: label });
    const text = result.content.filter(x => x.type === "text").map(x => x.text).join("\n");
    evidence.cells.push({ label, text, failed: !!(result.isError || result.details?.isError) }); await save();
    assert.equal(!!(result.isError || result.details?.isError), failure, text);
    const line = text.split("\n").find(line => line.startsWith("AUTOMATION="));
    return line ? JSON.parse(line.slice("AUTOMATION=".length)) : text;
}
const emit = expression => "console.log('AUTOMATION='+JSON.stringify(" + expression + "));";
const open = (name, options) => `var ${name} = await browser.open(${JSON.stringify(options)});`;
try {
    const scoped = { options: checkRecoveryOptions, downloads: checkDownloadLifecycle, tls: checkCertificateOptions }[startAt];
    if (scoped) {
        await scoped({ root, attachment, cell, check, open, emit, control });
    } else {
    check(!("dialogs" in attachment.a.open), "GUI supplies valid native open options without manual enum");
    await cell("attach-two-identical-pages", open("a", attachment.a.open) + open("b", attachment.b.open));
    if (phase === 0) {
    await cell("hidden-sibling-input", "await b.fill('#name','后台 B 中文'); await b.click('#apply');");
    let proof = await control("sample", "b");
    check(proof.sample.value === "后台 B 中文" && proof.sample.output === proof.sample.value && proof.sample.trusted > 0,
        "Second background page receives trusted native input and click");
    check((await control("sample", "a")).sample.value === "", "Identical URL/title sibling remains untouched");
    await cell("manual-policy", "await a.setDialogs(null);");
    await control("dialog", "a");
    await cell("reattach-while-sibling-has-dialog", "await b.close();" + open("b", attachment.b.open) + "await b.fill('#name','B with sibling dialog');");
    await cell("answer-dialog", "await a.handleDialog({accept:false});");
    check((await control("sample", "b")).sample.value === "B with sibling dialog", "Sibling modal cannot stall exact reattachment");
    await control("hide");
    await cell("parked-input-scroll-drag", "await a.fill('#name','parked'); await a.click('#apply'); await a.drag('#drag','#drop'); await a.run(async ({tab,page,wait}) => { await tab.scroll(0,300); await wait(async () => await page.evaluate(() => scrollY > 0), {timeout:2000}); });");
    proof = await control("sample");
    check(proof.sample.value === "parked" && proof.sample.output === "parked" && proof.sample.dropped,
        "Parked production page retains input and trusted drag");
    check(proof.sample.scrollY > 0, "Parked page completes native wheel scrolling");
    check(!proof.windowVisible && proof.selected === "a", "Automation never reveals or switches the GUI tab");
    await control("show");
    }
    if (phase <= 1) {
    await cell("native-state-roundtrip", `await a.setCookies({name:'omp_acceptance',value:'roundtrip',domain:'127.0.0.1',path:'/',httpOnly:true,sameSite:'Lax'}); var savedState=await a.saveState(${JSON.stringify(join(root, "state.json"))}); await a.clearCookies({names:['omp_acceptance']}); await a.loadState(savedState);`);
    check((await cell("state-readback", emit("(await a.cookies()).find(x=>x.name==='omp_acceptance')"))).value === "roundtrip",
        "Native save/load restores cookies in the selected CEF profile");
    }
    if (phase <= 2) {
    check(await cell("frame-string-evaluation", "var child=a.frame('#child');" + emit("await child.evaluate('document.title')")) === "Child frame",
        "Direct frame string evaluation executes in the cross-origin frame");
    const shot = await cell("frame-selector-screenshot", emit("await child.screenshot('#frame-name')"));
    check((await stat(typeof shot === "string" ? shot : shot.dest ?? shot.path)).size > 0, "Correct frame screenshot selector produces an artifact");
    }
    await cell("modal-timeout", "await a.setDialogs(null); await a.run(async ({tab}) => { await tab.click('#confirm'); }, {timeout:2});", { failure: true });
    await cell("input-after-native-recovery", "await a.fill('#name','recovered'); await a.click('#apply');");
    check((await control("sample")).sample.output === "recovered", "Timed-out worker recovery restores real input, verified outside OMP");
    await cell("release-and-reattach", "await browser.close({all:true});" + open("a", attachment.a.open) + open("b", attachment.b.open));
    await cell("post-release-input", "await b.fill('#name','reopened');");
    check((await control("sample", "b")).sample.value === "reopened", "Both borrowed pages survive all-handle release and reopen");
    await cell("release-b", "await b.close();");
    await control("close", "b");
    await cell("closed-target", open("stale", attachment.b.open), { failure: true });
    check((await control("sample", "a")).sample.value === "recovered", "Closed exact target never falls back to its sibling");
    }
    evidence.status = "passed";
} catch (error) {
    evidence.status = "failed"; evidence.error = String(error); throw error;
} finally {
    await save(); await native.dispose();
}
