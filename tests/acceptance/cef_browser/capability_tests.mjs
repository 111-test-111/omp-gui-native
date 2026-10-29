import assert from "node:assert/strict";
import { readFile, writeFile, stat } from "node:fs/promises";
import { join, resolve } from "node:path";
import { createCefBrowserSession } from "../../support/cef_browser_session.mjs";

const [root, packageRoot, base] = process.argv.slice(2);
assert(root.includes("/build.noindex/cef-prototype/runs/"));
const config = JSON.parse(await readFile(join(root, "environment.json"), "utf8"));
const installed = await createCefBrowserSession(root, packageRoot, config.cdpURL);
const evidence = { status: "running", phase: "capabilities", ompVersion: installed.version,
    cefSwiftRevision: config.cefSwiftRevision, modelRequests: 0, checks: [], groups: [], cells: [],
    scope: "Real OMP Browser against existing CEF Alloy pages; isolated loopback fixtures" };
const save = () => writeFile(join(root, "result.json"), JSON.stringify(evidence, null, 2));
const check = (value, message) => { assert.ok(value, message); evidence.checks.push(message); };
// Eval truncates long individual output lines. Keep JSON transport below that boundary.
const program = fn => "var capJSON=JSON.stringify(await (" + fn.toString() + ")()); for(var capOffset=0;capOffset<capJSON.length;capOffset+=180) console.log('CEF_CAP_PART='+capJSON.slice(capOffset,capOffset+180));";
async function cell(label, code, seconds = 12) {
    const start = performance.now();
    const result = await installed.tool.execute(crypto.randomUUID(), { language: "js", code, timeout: seconds, title: label });
    const text = result.content.filter(x => x.type === "text").map(x => x.text).join("\n");
    evidence.cells.push({ label, elapsedMs: Math.round(performance.now() - start), text,
        images: result.content.filter(x => x.type === "image").length, details: result.details });
    await save();
    if (result.isError || result.details?.isError) throw new Error(text);
    const parts = text.split("\n").filter(x => x.startsWith("CEF_CAP_PART=")).map(x => x.slice("CEF_CAP_PART=".length));
    return parts.length ? JSON.parse(parts.join('')) : { text };
}
const definitions = [];
const define = (name, run, validate, cleanup) => definitions.push({ name, run, validate, cleanup });

define("navigation", async () => {
    await a.goto(capsURL + '&step=two');
    await a.waitForUrl('step=two', { timeout: 3000 });
    const atTwo = await a.url();
    await a.back(); const back = await a.url();
    await a.forward(); const forward = await a.url();
    await a.reload();
    await a.pushState(capsURL + '&step=spa');
    return { atTwo, back, forward, final: await a.url(), title: await a.title(),
        identity: await a.evaluate(() => window.nativeIdentity) };
}, x => {
    check(x.atTwo.includes('step=two') && x.forward.includes('step=two'), "goto/forward/waitForUrl navigate the hosted page");
    check(!x.back.includes('step=two') && x.final.includes('step=spa'), "back/reload/pushState preserve native page ownership");
    check(x.identity?.instance && x.title.includes(x.identity.instance), "Navigation retains the native-instance marker");
});

define("selectors", async () => {
    // Puppeteer's interestingOnly root snapshot keeps only the first flattened
    // child of this unnamed group (a static label). includeAll preserves its subtree.
    const defaultScoped = await a.observe({ selector: '#controls' });
    const observation = await a.observe({ selector: '#controls', includeAll: true });
    const input = observation.elements.find(x => x.role === 'textbox');
    if (input) await a.id(input.id).fill('numeric-handle');
    const snapshot = await a.ariaSnapshot('#controls');
    const line = snapshot.split('\n').find(x => x.includes('textbox') && /ref=e\d+/.test(x));
    const ref = line.match(/ref=(e\d+)/)[1];
    await a.ref(ref).fill('aria-handle');
    await a.fill('pierce/#shadow-name', 'shadow-value');
    return { observation, defaultScopedElements: defaultScoped.elements.length, numericHandle: !!input, value: await a.value('#name'), text: await a.text('#article'), html: await a.html('#article'),
        xpath: await a.count("xpath///input[@id='name']"), testid: await a.count('testid/main-name'),
        role: await a.count('role/textbox[name="名称"]'), visible: await a.isVisible('#name'),
        disabled: await a.isEnabled('#disabled'), box: await a.box('#name'), styles: await a.styles('#article', ['display']),
        shadow: await a.value('pierce/#shadow-name'), extracted: await a.extract('markdown', { selector: '#article' }), snapshot };
}, x => {
    check(x.value === 'aria-handle' && x.shadow === 'shadow-value', "ARIA refs and open Shadow DOM handles work");
    check(x.xpath === 1 && x.testid === 1 && x.role >= 1, "XPath, test-id and semantic-role selectors resolve correctly");
    check(x.visible && !x.disabled && x.box.width > 0 && x.styles.display === 'block', "Visibility, enabled state, geometry and computed-style reads work");
    check(x.text.includes('OMP browser') && x.html.includes('<h2>') && x.extracted.includes('CEF'), "Text/HTML/Markdown extraction reads the embedded document");
    check(x.numericHandle, "CDP accessibility observation exposes numeric element handles");
});

define("form-controls", async () => {
    await a.check('#check'); const checked = await a.isChecked('#check');
    await a.uncheck('#check');
    const selected = await a.select('#choice', 'B');
    await a.focus('#name'); await a.type('#name', 'CEF');
    await a.hover('#double'); await a.dblclick('#double');
    return { checked, unchecked: !(await a.isChecked('#check')), selected, value: await a.value('#choice'),
        state: await a.evaluate(() => ({ ...cap, name: document.querySelector('#name').value })) };
}, x => {
    check(x.checked && x.unchecked && x.value === 'B' && x.selected.includes('B'), "Checkboxes and native select controls retain their requested values");
    check(x.state.name === 'CEF' && x.state.hover && x.state.double === 1, "focus/type/hover/dblclick reach the intended DOM controls");
});

define("pointer-scroll", async () => {
    const box = await a.box('#check');
    await a.clickAt(box.x + box.width / 2, box.y + box.height / 2);
    await a.drag('#drag', '#drop');
    await a.scrollIntoView('#below');
    const scrolled = await a.evaluate(() => scrollY);
    await a.scroll(0, -10000); await a.wheel(0, 120);
    return { checked: await a.isChecked('#check'), scrolled, state: await a.evaluate(() => cap) };
}, x => {
    check(x.checked && x.state.pointer, "CSS coordinate clickAt uses the hosted viewport correctly");
    check(x.state.dropped === true, "Drag dispatch reaches the fixture drop target");
    check(x.scrolled > 500, "scrollIntoView and scroll/wheel operate the page viewport");
});

define("javascript-init", async () => {
    const evaluated = await a.evaluate(async n => { await new Promise(r => setTimeout(r, 15)); return n * 2; }, 21);
    const inner = await a.run(async ({ page }) => ({ title: await page.title(), count: await page.$$eval('input', x => x.length) }));
    const script = await a.addInitScript('window.cefInit = (window.cefInit || 0) + 1');
    await a.reload();
    const initialized = await a.evaluate(() => window.cefInit);
    const scripts = await a.initScripts();
    await a.removeInitScript(script.id); await a.reload();
    return { evaluated, inner, initialized, count: scripts.length, removed: await a.evaluate(() => window.cefInit ?? null) };
}, x => {
    check(x.evaluated === 42 && x.inner.count >= 4, "Async page evaluate and tab.run Puppeteer facade return structured results");
    check(x.initialized === 1 && x.count >= 1 && x.removed === null, "Document-start scripts install, survive reload and can be removed");
});

define("frames", async () => {
    await a.evaluate(async () => { await Promise.all([...document.querySelectorAll('iframe')].map(frame => new Promise(resolve => {
        frame.onload = resolve; frame.src = frame.dataset.url;
    }))); });
    const frames = await a.frames();
    const same = a.frame('#same-frame'), cross = a.frame('#cross-frame');
    await same.fill('#frame-name', 'same-frame'); await same.click('#frame-apply');
    await cross.fill('#frame-name', '跨域 CEF'); await cross.click('#frame-apply');
    const guarded = await a.evaluate(() => document.querySelector('#cross-frame').contentDocument === null);
    return { frames, guarded, same: await same.text('#frame-output'), cross: await cross.text('#frame-output'),
        screenshot: await cross.screenshot('body'),
        ownerScreenshot: await a.screenshot({ selector: '#cross-frame', format: 'png' }),
        snapshot: await cross.ariaSnapshot() };
}, async x => {
    check(x.frames.length >= 3 && x.guarded, "Same-origin and cross-site frames exist with genuine DOM origin separation");
    check(x.same === 'same-frame' && x.cross === '跨域 CEF', "OMP frame-scoped click/fill/text work across origins");
    check(x.snapshot.includes('textbox'), "Cross-origin frame ARIA snapshots expose its controls");
    check((await stat(x.screenshot)).size > 0 && (await stat(x.ownerScreenshot)).size > 0,
        "Frame and owner-element screenshot artifacts are emitted; crop correctness requires visual acceptance");
});

define("storage", async () => {
    await a.setCookies({ name: 'cef_fixture', value: 'cookie-value', url: base });
    await a.setStorage('local', { cef_fixture: 'local-value' });
    await a.setStorage('session', 'cef_fixture', 'session-value');
    const before = { cookies: await a.cookies(), local: await a.storage('local'), session: await a.storage('session'), shared: await b.storage('local') };
    const path = await a.saveState(root + '/storage-state.json');
    await a.clearCookies({ names: ['cef_fixture'] }); await a.clearStorage('local'); await a.clearStorage('session');
    const loaded = await a.loadState(path);
    return { before, loaded, restored: { cookies: await a.cookies(), local: await a.storage('local'), session: await a.storage('session') } };
}, x => {
    check(x.before.cookies.some(c => c.name === 'cef_fixture' && c.value === 'cookie-value'), "Cookies can be set and read in the isolated CEF profile");
    check(x.before.local.cef_fixture === 'local-value' && x.before.session.cef_fixture === 'session-value', "Local and session storage can be written and read");
    check(x.before.shared.cef_fixture === 'local-value', "Same-profile tabs intentionally share same-origin local storage");
    check(x.restored.local.cef_fixture === 'local-value' && x.restored.session.cef_fixture === 'session-value' && x.loaded.loadedOrigins.length === 1,
        "Storage state exports and restores the current origin");
});

define("network", async () => {
    await a.clearRequests(); await a.harStart({ content: 'text' });
    const fetched = await a.evaluate(url => fetch(url).then(r => r.json()), base + '/api/data?case=record');
    const records = await a.requests({ filter: 'case=record' });
    const detail = await a.request(records.at(-1).id);
    const har = await a.harStop({ path: root + '/network.har' });
    await a.route('**/api/routed', { status: 201, contentType: 'application/json', body: { mocked: 'CEF' } });
    const routed = await a.evaluate(url => fetch(url).then(async r => ({ status: r.status, body: await r.json() })), base + '/api/routed');
    const routes = await a.routes(); await a.unroute();
    await a.route('**/api/blocked', { abort: true });
    const blocked = await a.evaluate(url => fetch(url).then(() => false, () => true), base + '/api/blocked');
    await a.unroute();
    const responseWait = await a.run(async ({ tab, page }, url) => {
        const pending = tab.waitForResponse(url, { timeout: 3000 });
        await page.evaluate(url => fetch(url), url);
        return (await pending).status();
    }, { args: [base + '/api/data?case=wait'] });
    return { fetched, records, detail, har, routed, routes, blocked, responseWait };
}, async x => {
    check(x.fetched.fixture === 'CEF' && x.records.some(r => r.status === 200) && String(x.detail.body).includes('CEF'), "Requests, headers and response-body diagnostics capture real fetch traffic");
    const har = JSON.parse(await readFile(x.har, 'utf8'));
    check(har.log.entries.some(e => e.request.url.includes('case=record')), "HAR output contains the fixture network request");
    check(x.routed.status === 201 && x.routed.body.mocked === 'CEF' && x.routes.length === 1 && x.blocked, "Persistent routes fulfill and abort requests, then unregister");
    check(x.responseWait === 200, "tab.run response wait observes the actual HTTP response");
}, async () => { await cell('network-cleanup', 'await a.unroute();'); });

define("dialogs", async () => {
    await a.setDialogs('accept'); await a.click('#confirm');
    const accepted = await a.evaluate(() => cap.confirm);
    await a.setDialogs('dismiss'); await a.click('#confirm');
    const dismissed = await a.evaluate(() => cap.confirm);
    await a.setDialogs(null);
    const manual = await a.run(async ({ tab, page }) => {
        // Do not await a blocking page prompt before issuing its answer. Keep
        // the pending evaluation and dialog handling inside one worker run.
        const pending = page.evaluate(() => { cap.prompt = prompt('CEF fixture'); return cap.prompt; });
        let dialog;
        for (let i = 0; i < 40; i++) { dialog = await tab.dialog(); if (dialog.open) break; await new Promise(r => setTimeout(r, 25)); }
        await tab.handleDialog({ accept: true, text: 'OMP prompt reply' });
        return { dialog, prompt: await pending };
    });
    await a.setDialogs('accept'); await a.click('#alert');
    return { accepted, dismissed, ...manual, alert: await a.evaluate(() => cap.alert) };
}, x => {
    check(x.accepted === true && x.dismissed === false, "Dialog policy accepts and dismisses confirm prompts");
    check(x.dialog.open && x.prompt === 'OMP prompt reply' && x.alert, "Pending prompt inspection, manual reply and alert handling work");
}, async () => { await cell('dialogs-cleanup', "await a.setDialogs('dismiss');"); });

define("upload", async () => {
    await a.uploadFile('#upload', root + '/upload.txt');
    return await a.evaluate(async url => {
        const file = document.querySelector('#upload').files[0];
        return { name: file.name, content: await file.text(), sent: await fetch(url, { method: 'POST', body: file }).then(r => r.json()) };
    }, base + '/api/upload');
}, x => {
    check(x.name === 'upload.txt' && x.content === 'OMP CEF upload 中文\n', "uploadFile installs the actual local file into the CEF file input");
    check(x.sent.contents === x.content, "The page uploads the exact file contents to the isolated server");
});

define("download", async () => {
    return await a.run(async ({ tab }) => {
        const pending = tab.waitForDownload({ timeout: 4000 });
        await tab.click('#download');
        return { download: await pending, list: await tab.downloads() };
    });
}, async x => {
    check(x.download.bytes > 0 && x.list.length >= 1, "Download events report the completed CEF download");
    const path = x.download.path;
    check(typeof path === 'string' && resolve(path).startsWith(root + '/') && (await readFile(path, 'utf8')) === 'OMP CEF download fixture\n',
        "The downloaded file is complete and stays inside this acceptance run");
});

define("capture-pdf", async () => {
    const first = await a.screenshot({ selector: '#controls', format: 'png', ifChanged: true });
    const unchanged = await a.screenshot({ selector: '#controls', format: 'png', ifChanged: true });
    await a.fill('#name', 'changed screenshot');
    const changed = await a.screenshot({ selector: '#controls', format: 'png', ifChanged: true });
    const annotated = await a.screenshot({ annotate: true, format: 'png' });
    const annotationElements = (await a.observe()).elements.length;
    const pdf = await a.pdf({ path: root + '/fixture.pdf', format: 'a4', printBackground: true });
    return { first, unchanged, changed, annotated, annotationElements, pdf };
}, async x => {
    check(x.first.changed && !x.unchanged.changed && x.changed.changed, "Element screenshots detect real page changes and suppress unchanged output");
    check((await readFile(x.pdf)).subarray(0, 4).toString() === '%PDF', "CEF Page.printToPDF produces a valid PDF artifact");
    check(x.annotationElements > 0 && (await stat(x.annotated)).size > 0, "Annotated screenshots have observable element targets");
});

define("diagnostics", async () => {
    await a.clearConsole();
    await a.evaluate(() => { console.log('CEF-console-marker'); setTimeout(() => { throw new Error('CEF-error-marker'); }, 0); });
    await new Promise(r => setTimeout(r, 80));
    const logs = await a.console(), errors = await a.errors(), metrics = await a.metrics();
    await a.traceStart({ categories: ['devtools.timeline'] });
    await a.evaluate(() => document.querySelector('#name').value = 'trace');
    const trace = await a.traceStop({ path: root + '/trace.json' });
    await a.profileStart(); await a.evaluate(() => [1, 2, 3].reduce((a, b) => a + b, 0));
    const profile = await a.profileStop({ path: root + '/profile.json' });
    const vitals = await a.vitals();
    return { logs, errors, metrics, trace, profile, vitals };
}, async x => {
    check(JSON.stringify(x.logs).includes('CEF-console-marker') && JSON.stringify(x.errors).includes('CEF-error-marker'), "Console logs and JavaScript errors are captured");
    check(Number.isFinite(x.metrics.Nodes) && x.metrics.Nodes > 0, "DOM and lifecycle metrics are available");
    check(Array.isArray(JSON.parse(await readFile(x.trace, 'utf8')).traceEvents), "Tracing produces DevTools timeline events");
    check(Array.isArray(JSON.parse(await readFile(x.profile, 'utf8')).nodes), "CPU profiling produces a CDP profile artifact");
});

define("emulation", async () => {
    const original = await a.evaluate(() => ({ width: innerWidth, height: innerHeight, scale: devicePixelRatio, ua: navigator.userAgent }));
    const other = await b.evaluate(() => innerWidth);
    await a.emulate({ viewport: { width: 800, height: 600, scale: 1 }, colorScheme: 'dark', reducedMotion: true,
        timezone: 'UTC', locale: 'en-US', userAgent: 'OMP-CEF-acceptance', headers: { 'X-CEF-Test': 'yes' } });
    const state = await a.evaluate(() => ({ width: innerWidth, dark: matchMedia('(prefers-color-scheme:dark)').matches,
        motion: matchMedia('(prefers-reduced-motion:reduce)').matches, ua: navigator.userAgent, zone: Intl.DateTimeFormat().resolvedOptions().timeZone }));
    const headers = await a.evaluate(url => fetch(url).then(r => r.json()), base + '/api/data?case=emulation');
    const otherAfter = await b.evaluate(() => innerWidth);
    await a.emulate({ offline: true });
    const offline = await a.evaluate(url => fetch(url).then(() => false, () => true), base + '/api/data?case=offline');
    await a.emulate({ offline: false, viewport: original, colorScheme: 'no-preference', reducedMotion: false,
        timezone: null, locale: null, userAgent: null, headers: null });
    return { state, headers, other, otherAfter, offline, devices: (await a.devices()).length };
}, x => {
    check(x.state.width === 800 && x.state.dark && x.state.motion && x.state.zone === 'UTC', "Viewport, media preferences and timezone emulation apply");
    check(x.state.ua === 'OMP-CEF-acceptance' && x.headers.header === 'yes' && x.offline, "User agent, HTTP headers and offline simulation work");
    check(x.other === x.otherAfter && x.devices > 0, "Emulation remains scoped to A and known device profiles are listed");
}, async () => { await cell('emulation-cleanup', "await a.emulate({offline:false,headers:null,userAgent:null,timezone:null,locale:null,colorScheme:'no-preference',reducedMotion:false});"); });

define("feature-detection", async () => ({ webmcp: await a.webmcpList(), setup: await a.reactEnable(), react: await a.reactTree() }), x => {
    evidence.featureDetection = x;
    check(x.webmcp && Array.isArray(x.react), "Optional WebMCP/React discovery returns structured results on a non-React page");
});

try {
    await writeFile(join(root, 'upload.txt'), 'OMP CEF upload 中文\n');
    const native = await fetch(base + '/native-state').then(r => r.json());
    const nativeA = native.tabs.find(x => x.id === 'A'), nativeB = native.tabs.find(x => x.id === 'B');
    const capsURL = base + '/capabilities?tab=A&instance=' + nativeA.instance;
    evidence.nativeIdentity = { instance: nativeA.instance, cefBrowserID: nativeA.cefBrowserID };
    await cell('attach', `var root=${JSON.stringify(root)},base=${JSON.stringify(base)},capsURL=${JSON.stringify(capsURL)};
        var a=await browser.open({name:'cap-a',downloads:root+'/downloads',app:{cdp_url:${JSON.stringify(config.cdpURL)},target:${JSON.stringify(nativeA.instance)}}});
        var b=await browser.open({name:'cap-b',app:{cdp_url:${JSON.stringify(config.cdpURL)},target:${JSON.stringify(nativeB.instance)}}});`);
    const selected = new Set((process.env.CEF_PROTOTYPE_GROUPS ?? '').split(',').filter(Boolean));
    for (const id of selected) assert(definitions.some(x => x.name === id), 'Unknown capability group: ' + id);
    // A modal-dialog failure can stall a renderer; perform that group after independent capabilities.
    for (const definition of definitions.toSorted((x, y) => Number(x.name === 'dialogs') - Number(y.name === 'dialogs'))) {
        if (selected.size && !selected.has(definition.name)) continue;
        const group = { name: definition.name, status: 'running', checks: [], startedAt: new Date().toISOString() };
        evidence.groups.push(group); const before = evidence.checks.length;
        try {
            await cell('prepare-' + definition.name, "await a.setDialogs('dismiss'); await a.goto(capsURL,{waitUntil:'load'}); await a.waitFor('#controls',{timeout:3000});");
            const result = await cell(definition.name, program(definition.run), definition.name === 'dialogs' ? 8 : 15);
            group.value = result;
            await definition.validate(result);
            group.status = 'passed';
        } catch (error) {
            group.status = 'failed'; group.error = String(error?.stack ?? error);
        } finally {
            if (definition.cleanup) {
                try { await definition.cleanup(); } catch (error) { group.cleanupError = String(error); }
            }
            group.checks = evidence.checks.slice(before); await save();
            console.log(group.status.toUpperCase() + ' ' + group.name + (group.error ? ': ' + group.error.slice(0, 900) : ''));
        }
    }
    evidence.deferred = ["System clipboard (no access to owner's clipboard)", "React component instrumentation (no React application fixture)",
        "Video recording and WebMCP invocation are not included in the selected core matrix"];
    evidence.status = evidence.groups.every(x => x.status === 'passed') ? 'passed' : 'partial';
    await cell('release', 'await browser.close({all:true});');
} catch (error) {
    evidence.status = 'failed'; evidence.error = String(error?.stack ?? error); throw error;
} finally {
    await save(); await installed.dispose();
}
