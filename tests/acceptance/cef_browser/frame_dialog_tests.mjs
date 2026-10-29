import assert from 'node:assert/strict';
import { readFile, writeFile, stat, copyFile } from 'node:fs/promises';
import { join } from 'node:path';
import { createCefBrowserSession } from '../../support/cef_browser_session.mjs';

const [root, packageRoot, base] = process.argv.slice(2);
const config = JSON.parse(await readFile(join(root, 'environment.json'), 'utf8'));
assert(packageRoot.includes('/build.noindex/cef-prototype/dependencies/omp-sdk'));
const installed = await createCefBrowserSession(root, packageRoot, config.cdpURL);
const evidence = { status: 'running', phase: 'repairs', ompVersion: installed.version,
    dependencyPatches: config.dependencyPatches, modelRequests: 0, checks: [], cells: [] };
const save = () => writeFile(join(root, 'result.json'), JSON.stringify(evidence, null, 2));
const check = (value, message) => { assert.ok(value, message); evidence.checks.push(message); };
const state = () => fetch(base + '/native-state').then(r => r.json());
const control = (action, tab = 'A') => fetch(base + '/control', {
    method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({ action, tab }),
}).then(r => { assert(r.ok); return r.json(); });
async function waitFor(read, matches, milliseconds = 4000) {
    const until = Date.now() + milliseconds;
    do { const result = await read(); if (matches(result)) return result; await Bun.sleep(40); } while (Date.now() < until);
    throw new Error('Acceptance condition timed out');
}
const program = fn => "var repairJSON=JSON.stringify(await (" + fn.toString() + ")()); for(var repairOffset=0;repairOffset<repairJSON.length;repairOffset+=180) console.log('REPAIR_PART='+repairJSON.slice(repairOffset,repairOffset+180));";
async function cell(label, code, signal) {
    evidence.currentCell = label; await save();
    const start = performance.now();
    const result = await installed.tool.execute(crypto.randomUUID(), { language: 'js', code, timeout: 10, title: label }, signal);
    const text = result.content.filter(x => x.type === 'text').map(x => x.text).join('\n');
    evidence.cells.push({ label, elapsedMs: Math.round(performance.now() - start), text }); await save();
    if (result.isError || result.details?.isError) throw new Error(text);
    const parts = text.split('\n').filter(x => x.startsWith('REPAIR_PART=')).map(x => x.slice('REPAIR_PART='.length));
    return parts.length ? JSON.parse(parts.join('')) : { text };
}
const selected = new Set((process.env.CEF_PROTOTYPE_GROUPS || 'frames,dialogs,lifecycle,shutdown').split(','));
for (const name of selected) assert(['frames', 'dialogs', 'lifecycle', 'shutdown'].includes(name), 'Unknown repair group: ' + name);
async function pixels(path) {
    const probe = Bun.spawn([join(root, '../../image-probe'), path], { stdout: 'pipe', stderr: 'pipe' });
    const output = await new Response(probe.stdout).text();
    assert.equal(await probe.exited, 0, await new Response(probe.stderr).text());
    return JSON.parse(output);
}
// Compare against a top-document rendering of the same palette. This preserves
// default Display P3 colour management instead of assuming raw sRGB byte values.
const targetPixels = (result, reference) => Math.abs(result.width / result.height - 1.8) < 0.04 &&
    result.samples.every((color, i) => color.every((value, j) => Math.abs(value - reference.samples[i][j]) < 24));
async function frames(nativeA) {
    evidence.frameCases = [];
    for (const scale of [2, 1]) {
        await cell('frame-scale-' + scale, `await a.emulate({viewport:{width:960,height:600,scale:${scale}}});`);
        for (const kind of ['same', 'cross', 'nested']) {
            const frame = kind === 'nested' ? 'nested-child' : kind + '-shot';
            const captured = await cell('frame-' + kind + '-' + scale, program(async () => {
                await a.goto(base + '/repair?instance=' + (await a.evaluate(() => window.nativeIdentity.instance)));
                const reference = await a.screenshot({ selector: '#reference', format: 'png' });
                await a.evaluate(() => window.scrollTo(100, 100));
                const f = a.frame(FRAME);
                await f.waitFor('#capture-target', { timeout: 3000 });
                const path = await f.screenshot('#capture-target');
                return { path, reference, top: await a.evaluate(() => ({ x: scrollX, y: scrollY, scale: devicePixelRatio })),
                    child: await f.evaluate(() => ({ x: scrollX, y: scrollY })),
                    marker: await f.attr('#capture-target', 'aria-label'), identity: await a.evaluate(() => window.nativeIdentity) };
            }).replace('FRAME', JSON.stringify(frame)));
            const image = await pixels(captured.path);
            const reference = await pixels(captured.reference);
            const [red, green, blue, yellow] = reference.samples;
            check(red[0] > red[1] * 2 && green[1] > green[0] * 1.5 && blue[2] > blue[1] * 1.5 && yellow[1] > yellow[2] * 2,
                `Reference palette ${kind}/${scale} has the four intended distinct colours`);
            await copyFile(captured.path, join(root, `frame-${kind}-${scale}.${captured.path.split('.').at(-1)}`));
            evidence.frameCases.push({ kind, scale, ...captured, image, referenceImage: reference }); await save();
            check(captured.identity.instance === nativeA.instance && captured.marker === kind,
                `Frame ${kind} at scale ${scale} belongs to the hosted A page`);
            check(captured.top.y > 100 && captured.child.y > 100 && captured.top.scale === scale,
                `Frame ${kind} at scale ${scale} exercises top-page and child-frame scrolling`);
            check(targetPixels(image, reference), `Frame ${kind} at scale ${scale} captures all four target quadrants`);
            if (kind === 'cross' && scale === 2) {
                const baseline = await cell('upstream-coordinate-control', program(async () => await a.run(async ({ page }, path) => {
                    const frame = page.frames().find(frame => frame.name() === 'cross-shot');
                    const handle = await frame.$('#capture-target');
                    try { await handle.screenshot({ path, type: 'png', scrollIntoView: false }); } finally { await handle.dispose(); }
                    return path;
                }, { args: [root + '/upstream-frame.png'] })));
                evidence.upstreamFrame = { path: baseline, image: await pixels(baseline) };
                check(!targetPixels(evidence.upstreamFrame.image, reference), 'The original Puppeteer element screenshot reproduces the wrong crop on this same page');
            }
        }
    }
    await cell('restore-native-viewport', "await a.emulate({viewport:{width:1040,height:615,scale:2}});");
}

async function dialogs() {
    await cell('policy-accept', "await a.setDialogs('accept');");
    await cell('click-confirm-accept', "await a.click('#confirm');");
    check((await cell('click-accepted-result', program(async () => await a.evaluate(() => cap.confirm)))) === true,
        'A normal OMP click with accept policy settles confirm');
    await cell('click-confirm-dismiss', "await a.setDialogs('dismiss'); await a.click('#confirm');");
    check((await cell('click-dismissed-result', program(async () => await a.evaluate(() => cap.confirm)))) === false,
        'OMP dismiss policy returns false to the page');
    const manual = await cell('same-run-manual-prompt', program(async () => {
        await a.setDialogs(null);
        return await a.run(async ({ tab, page }) => {
            const pending = page.evaluate(() => prompt('OMP concurrent prompt', 'default'));
            let dialog;
            for (let i = 0; i < 40; i++) { dialog = await tab.dialog(); if (dialog.open) break; await new Promise(r => setTimeout(r, 25)); }
            await tab.handleDialog({ accept: true, text: 'OMP concurrent reply' });
            return { dialog, reply: await pending };
        });
    }));
    evidence.concurrentPrompt = manual;
    check(manual.dialog.open && manual.reply === 'OMP concurrent reply', 'A synchronous page prompt can be inspected and answered inside one OMP run');
    await control('dialog');
    const dialog = await waitFor(() => cell('pending-prompt', program(async () => await a.dialog())), x => x.open);
    check(dialog.type === 'prompt' && dialog.defaultValue === 'default', 'OMP inspects the native-owner-triggered pending prompt');
    const before = (await stat(join(root, 'native-state.json'))).mtimeMs;
    await cell('other-tab-during-prompt', "await b.fill('#name','B remains responsive');");
    await Bun.sleep(150);
    check((await stat(join(root, 'native-state.json'))).mtimeMs > before, 'Native host timer remains responsive while A has a pending dialog');
    await cell('prompt-answer', "await a.handleDialog({accept:true,text:'OMP prompt reply'});");
    check((await cell('prompt-result', program(async () => await a.evaluate(() => cap.prompt)))) === 'OMP prompt reply',
        'OMP manual prompt reply returns exact text');
    await cell('alert-click', "await a.setDialogs('accept'); await a.click('#alert');");
    check((await cell('alert-result', program(async () => await a.evaluate(() => cap.alert)))) === true,
        'OMP accepts alert and the page continues');
    await cell('beforeunload-setup', "await a.click('#double'); await a.evaluate(()=>{onbeforeunload=e=>{e.preventDefault();e.returnValue='';}}); await a.setDialogs('dismiss');");
    const blocked = await cell('beforeunload-dismiss', program(async () => {
        let error;
        try { await a.goto(base + '/capabilities?step=blocked'); } catch (caught) { error = String(caught); }
        return { error, url: await a.url() };
    }));
    check(blocked.error && !blocked.url.includes('step=blocked'), 'Dismissing beforeunload cancels navigation without blocking the host');
    await cell('beforeunload-accept', "await a.setDialogs('accept'); await a.goto((await a.url())+'&step=accepted');");
    check((await cell('beforeunload-result', program(async () => await a.url()))).includes('step=accepted'),
        'Accepting beforeunload allows navigation to finish');
    await cell('dialog-default-policy', "await a.setDialogs(null);");
}

async function lifecycle(nativeA, nativeB) {
    await cell('lifecycle-policy', "await a.setDialogs(null); await b.fill('#name','B lifecycle baseline');");
    await control('dialog');
    await waitFor(() => cell('cancel-dialog-state', program(async () => await a.dialog())), x => x.open);
    const controller = new AbortController(), begin = performance.now();
    const pending = cell('cancel-with-open-dialog', "await a.waitFor('#never-created',{timeout:20000}); await b.fill('#name','LATE');", controller.signal);
    const timer = setTimeout(() => controller.abort(), 600);
    let interrupted;
    try { await pending; } catch (error) { interrupted = String(error); } finally { clearTimeout(timer); }
    evidence.cancellation = { elapsedMs: Math.round(performance.now() - begin), interrupted };
    check(/abort|cancel|interrupt/i.test(interrupted) && evidence.cancellation.elapsedMs < 6000,
        'AbortSignal interrupts an OMP operation while a real prompt is open');
    // Eval cancellation restarts its JavaScript realm; rebuild every local
    // facade variable, while the named native/browser handles remain distinct.
    await cell('reacquire-after-cancel', `var root=${JSON.stringify(root)},base=${JSON.stringify(base)};
        var a=await browser.open({name:'repair-a',dialogs:'dismiss',app:{cdp_url:${JSON.stringify(config.cdpURL)},target:${JSON.stringify(nativeA.instance)}}});
        var b=browser.tab('repair-b');`);
    await cell('continue-after-cancel', "await a.fill('#name','after dialog cancellation'); await a.setDialogs(null);");
    check((await cell('cancel-isolation', program(async () => await b.value('#name')))) === 'B lifecycle baseline',
        'Cancellation cannot perform the late B write and the attached page recovers');
    await control('dialog');
    await waitFor(() => cell('close-dialog-state', program(async () => await a.dialog())), x => x.open);
    const closed = await control('close');
    check(closed.tabs.length === 1 && closed.tabs[0].id === 'B', 'The native owner can close A while its prompt is pending');
    await control('reopen');
    const native = await waitFor(state, x => x.tabs.some(t => t.id === 'A' && t.bound && t.instance !== nativeA.instance));
    const fresh = native.tabs.find(x => x.id === 'A');
    await cell('reconnect-after-pending-close', `await browser.close({all:true});
        var a=await browser.open({name:'repair-a',app:{cdp_url:${JSON.stringify(config.cdpURL)},target:${JSON.stringify(fresh.instance)}}});
        var b=await browser.open({name:'repair-b',app:{cdp_url:${JSON.stringify(config.cdpURL)},target:${JSON.stringify(nativeB.instance)}}});
        await a.fill('#name','REOPENED after prompt');`);
    const recovered = await cell('recovered-identities', program(async () => ({ a: await a.value('#name'), b: await b.value('#name'), identity: await a.evaluate(() => nativeIdentity) })));
    check(recovered.a === 'REOPENED after prompt' && recovered.b === 'B lifecycle baseline' && recovered.identity.instance === fresh.instance,
        'Recreated A accepts input after pending-dialog close and B preserves its contents');
    evidence.recovered = recovered;
}

try {
    const native = await fetch(base + '/native-state').then(r => r.json());
    const nativeA = native.tabs.find(x => x.id === 'A'), nativeB = native.tabs.find(x => x.id === 'B');
    await cell('attach', `var root=${JSON.stringify(root)},base=${JSON.stringify(base)};
        var a=await browser.open({name:'repair-a',app:{cdp_url:${JSON.stringify(config.cdpURL)},target:${JSON.stringify(nativeA.instance)}}});
        var b=await browser.open({name:'repair-b',app:{cdp_url:${JSON.stringify(config.cdpURL)},target:${JSON.stringify(nativeB.instance)}}});
        await a.goto(base+'/capabilities?tab=A&instance='+${JSON.stringify(nativeA.instance)});`);
    if (selected.has('frames')) await frames(nativeA);
    if (selected.has('dialogs') || selected.has('lifecycle') || selected.has('shutdown')) {
        await cell('prepare-dialog-page', `await a.goto(base+'/capabilities?tab=A&instance='+${JSON.stringify(nativeA.instance)});`);
        if (selected.has('dialogs')) await dialogs();
        if (selected.has('lifecycle')) await lifecycle(nativeA, nativeB);
    }
    if (selected.has('shutdown')) {
        await cell('prepare-pending-shutdown', "await a.goto(base+'/capabilities?instance='+(await a.evaluate(()=>nativeIdentity.instance))); await a.setDialogs(null);");
        await control('dialog');
        await waitFor(() => cell('shutdown-dialog-state', program(async () => await a.dialog())), x => x.open);
        const closed = await control('quit');
        check(closed.tabs.length === 0, 'The native owner can quit the host with a prompt pending and OMP still attached');
        evidence.shutdownWithPendingDialog = true;
    }
    await cell('release', 'await browser.close({all:true});');
    if (!selected.has('shutdown')) check((await state()).tabs.length === 2, 'Releasing OMP borrowed handles preserves the two native pages');
    evidence.status = 'passed';
} catch (error) {
    evidence.status = 'failed'; evidence.error = String(error?.stack ?? error); throw error;
} finally {
    await save(); await installed.dispose();
}
