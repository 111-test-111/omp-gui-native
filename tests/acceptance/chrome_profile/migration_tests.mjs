import assert from 'node:assert/strict';
import {spawn, spawnSync} from 'node:child_process';
import {once} from 'node:events';
import {createServer} from 'node:http';
import {createServer as createSocketServer} from 'node:net';
import {mkdir, readFile, writeFile, cp, access} from 'node:fs/promises';
import {createWriteStream} from 'node:fs';
import {join, resolve} from 'node:path';

const [output, probe, chrome] = process.argv.slice(2, 5).map(value => resolve(value));
const scope = process.argv[5] ?? 'all';
assert(output.includes('/build.noindex/chrome-profile/runs/'));
const report = {scope: 'isolated synthetic Chrome login only', selectedCase: scope, checks: [], cases: {}, passed: false};
const children = new Set();
const delay = ms => new Promise(resolve => setTimeout(resolve, ms));
function expect(condition, message) { assert(condition, message); report.checks.push(message); console.log('PASS:', message); }
async function exists(path) { try { await access(path); return true; } catch { return false; } }
async function until(read, message, process = null, seconds = 15) {
    const end = Date.now() + seconds * 1000;
    let last;
    while (Date.now() < end) {
        if (process?.exitCode !== null && process?.exitCode !== undefined) throw new Error(`${message}: process exited ${process.exitCode}`);
        try { const value = await read(); if (value) return value; } catch (error) { last = error; }
        await delay(50);
    }
    throw new Error(`${message}: timed out${last ? '; ' + last.message : ''}`);
}
function launch(binary, args, folder, env = {}) {
    const log = createWriteStream(join(folder, 'process.log'));
    const process = spawn(binary, args, {env: {...globalThis.process.env, ...env}, stdio: ['ignore', 'pipe', 'pipe']});
    process.stdout.pipe(log); process.stderr.pipe(log, {end: false});
    children.add(process);
    process.once('exit', () => children.delete(process));
    return process;
}
async function exited(process, seconds = 10) {
    if (process.exitCode !== null) return process.exitCode;
    await Promise.race([once(process, 'exit'), delay(seconds * 1000).then(() => { throw new Error('Owned browser did not exit'); })]);
    return process.exitCode;
}
async function port() {
    const socket = createSocketServer(); socket.listen(0, '127.0.0.1'); await once(socket, 'listening');
    const port = socket.address().port; await new Promise(resolve => socket.close(resolve)); return port;
}
class CDP {
    constructor(socket) {
        this.socket = socket; this.next = 0; this.pending = new Map();
        socket.addEventListener('message', event => {
            const message = JSON.parse(event.data);
            if (!message.id) return;
            const pending = this.pending.get(message.id);
            if (!pending) return;
            this.pending.delete(message.id); clearTimeout(pending.timer);
            message.error ? pending.reject(new Error(JSON.stringify(message.error))) : pending.resolve(message.result);
        });
    }
    static async connect(url) {
        const socket = new WebSocket(url); const client = new CDP(socket);
        await new Promise((resolve, reject) => { socket.addEventListener('open', resolve, {once: true}); socket.addEventListener('error', reject, {once: true}); });
        return client;
    }
    send(method, params = {}) {
        const id = ++this.next;
        return new Promise((resolve, reject) => {
            const timer = setTimeout(() => { this.pending.delete(id); reject(new Error(`CDP timeout: ${method}`)); }, 8000);
            this.pending.set(id, {resolve, reject, timer}); this.socket.send(JSON.stringify({id, method, params}));
        });
    }
    async evaluate(expression) {
        const result = await this.send('Runtime.evaluate', {expression, awaitPromise: true, returnByValue: true});
        assert(!result.exceptionDetails, JSON.stringify(result.exceptionDetails)); return result.result.value;
    }
    close() { this.socket.close(); }
}
async function connectPage(endpoint, origin) {
    const target = await until(async () => (await (await fetch(endpoint + '/json/list')).json()).find(t => t.type === 'page' && t.url.startsWith(origin)), 'fixture target');
    const cdp = await CDP.connect(target.webSocketDebuggerUrl);
    await until(() => cdp.evaluate(`location.origin === ${JSON.stringify(origin)} && document.readyState === 'complete'`), 'fixture document');
    const {targetInfo} = await cdp.send('Target.getTargetInfo');
    cdp.context = targetInfo.browserContextId ? {browserContextId: targetInfo.browserContextId} : {};
    cdp.origin = origin;
    const version = await (await fetch(endpoint + '/json/version')).json();
    cdp.browser = await CDP.connect(version.webSocketDebuggerUrl);
    return cdp;
}
const readState = `(async () => {
    let indexed = null;
    if ((await indexedDB.databases()).some(x => x.name === 'migration-login')) indexed = await new Promise((resolve, reject) => {
        const request = indexedDB.open('migration-login', 1);
        request.onerror = () => reject(request.error);
        request.onsuccess = () => { const db = request.result; const get = db.transaction('identity').objectStore('identity').get('account');
            get.onsuccess = () => { resolve(get.result ?? null); db.close(); }; get.onerror = () => reject(get.error); };
    });
    return {auth: await (await fetch('/auth', {cache: 'no-store'})).json(), local: Object.fromEntries(Object.entries(localStorage)), indexed,
        scriptCookies: document.cookie};
})()`;
const writeState = state => `(async () => {
    const state = ${JSON.stringify(state)};
    for (const [key, value] of Object.entries(state.local)) localStorage.setItem(key, value);
    await new Promise((resolve, reject) => { const request = indexedDB.open('migration-login', 1);
        request.onupgradeneeded = () => request.result.createObjectStore('identity'); request.onerror = () => reject(request.error);
        request.onsuccess = () => { const db = request.result; const tx = db.transaction('identity', 'readwrite');
            tx.objectStore('identity').put(state.indexed, 'account'); tx.oncomplete = () => { db.close(); resolve(true); }; tx.onerror = () => reject(tx.error); };
    }); return true;
})()`;
async function cookies(cdp) { return (await cdp.send('Network.getCookies', {urls: [cdp.origin + '/', cdp.origin + '/restricted']})).cookies; }
function cookieParam(cookie, origin) {
    const result = {name: cookie.name, value: cookie.value, path: cookie.path, secure: cookie.secure, httpOnly: cookie.httpOnly};
    if (cookie.domain.startsWith('.')) result.domain = cookie.domain;
    else result.url = origin + cookie.path;
    if (!cookie.session) result.expires = cookie.expires;
    for (const key of ['sameSite', 'priority', 'sourceScheme', 'sourcePort', 'partitionKey']) if (cookie[key] !== undefined) result[key] = cookie[key];
    return result;
}
function cookieMetadata(list) {
    return list.map(({name, domain, path, secure, httpOnly, sameSite, session, partitionKey}) => ({name, domain, path, secure, httpOnly, sameSite, session, partitionKey})).sort((a,b) => a.name.localeCompare(b.name));
}
async function cef(name, root, origin, named = false, allowFailure = false) {
    const folder = join(output, name); await mkdir(folder, {recursive: true});
    const cdpPort = await port();
    const process = launch(probe, [], folder, {PROFILE_PROBE_ROOT: root, PROFILE_PROBE_OUTPUT: folder, PROFILE_PROBE_PORT: String(cdpPort),
        PROFILE_PROBE_URL: origin + '/', PROFILE_PROBE_NAMED: named ? '1' : '0'});
    if (allowFailure) {
        const outcome = await until(async () => process.exitCode !== null ? {exitCode: process.exitCode} : await exists(join(folder, 'ready')) ? {ready: true} : null, 'shared-root startup', null, 20);
        if (!outcome.ready) return {folder, process, outcome};
    } else await until(() => exists(join(folder, 'ready')), 'CEF readiness', process);
    const page = await connectPage(`http://127.0.0.1:${cdpPort}`, origin);
    return {folder, process, page, async stop() { page.browser.close(); page.close(); await writeFile(join(folder, 'finish'), ''); assert.equal(await exited(process), 0); expect(await exists(join(folder, 'closed')), `${name}: CEF shuts down cleanly`); }};
}
async function chromeInstance(name, origin) {
    const folder = join(output, name), root = join(folder, 'profile'); await mkdir(root, {recursive: true});
    const process = launch(chrome, ['--headless=new', '--no-first-run', '--no-default-browser-check', '--disable-background-networking', '--disable-component-update',
        '--remote-debugging-port=0', '--user-data-dir=' + root, origin + '/'], folder);
    const cdpPort = await until(async () => (await readFile(join(root, 'DevToolsActivePort'), 'utf8')).split('\n')[0], 'Chrome debugging port', process);
    const endpoint = `http://127.0.0.1:${cdpPort}`;
    const page = await connectPage(endpoint, origin);
    const version = await page.send('Browser.getVersion'); report.chrome = version.product;
    return {folder, root, process, page, async stop() {
        await page.browser.send('Browser.close').catch(() => {}); page.browser.close(); page.close(); assert.equal(await exited(process), 0);
    }};
}
function inspectCookies(root, profile = 'Default') {
    const script = `import json, sqlite3, pathlib, sys
r=pathlib.Path(sys.argv[1]); files=list(r.glob(sys.argv[2]+'/**/Cookies'))
db=sqlite3.connect(files[0].as_uri()+'?mode=ro',uri=True)
rows=db.execute('select name, length(value), length(encrypted_value) from cookies').fetchall()
print(json.dumps({'schema':dict(db.execute('select key,value from meta')),'count':len(rows),'encrypted':sum(x[2]>0 for x in rows),'plaintext':sum(x[1]>0 for x in rows)}))`;
    const result = spawnSync('python3', ['-c', script, root, profile], {encoding: 'utf8'}); assert.equal(result.status, 0, result.stderr); return JSON.parse(result.stdout);
}
const server = createServer((request, response) => {
    response.setHeader('Cache-Control', 'no-store');
    if (request.url === '/login' && request.method === 'POST') {
        response.setHeader('Set-Cookie', [
            'omp_persistent=fixture-account; Max-Age=3600; Path=/; HttpOnly; SameSite=Lax',
            'omp_session=fixture-account; Path=/; HttpOnly; SameSite=Strict',
            '__Host-omp=fixture-host; Max-Age=3600; Path=/; HttpOnly; Secure; SameSite=None',
            'omp_chip=fixture-partition; Max-Age=3600; Path=/; HttpOnly; Secure; SameSite=None; Partitioned',
            'omp_path=fixture-path; Max-Age=3600; Path=/restricted; HttpOnly; SameSite=Lax']);
        response.end('<!doctype html><title>Signed in</title><h1 id="signed-in">Signed in</h1>');
    } else if (request.url === '/auth') {
        const cookies = Object.fromEntries((request.headers.cookie ?? '').split('; ').filter(Boolean).map(x => x.split('=')));
        response.setHeader('Content-Type', 'application/json'); response.end(JSON.stringify({authenticated: cookies.omp_persistent === 'fixture-account' && cookies.omp_session === 'fixture-account'}));
    } else response.end('<!doctype html><title>Chrome migration fixture</title><h1>Local test login</h1><form id="login" action="/login" method="post"><button>Sign in</button></form>');
});
try {
    if (scope === 'database') {
        report.destinationDatabase = inspectCookies(join(output, 'api-import-profile'), 'Profile-migration');
        expect(report.destinationDatabase.count === 5 && report.destinationDatabase.encrypted === 5 && report.destinationDatabase.plaintext === 0,
            'the selected CEF profile stores all five imported cookies encrypted, with no plaintext values');
        report.passed = true;
    } else {
        server.listen(0, '127.0.0.1'); await once(server, 'listening'); const origin = `http://127.0.0.1:${server.address().port}`;
        report.origin = origin;
        const source = await chromeInstance('chrome-source', origin);
        await source.page.evaluate("document.querySelector('#login').requestSubmit(); true");
        await until(() => source.page.evaluate("!!document.querySelector('#signed-in')"), 'Chrome HTTP login');
        await source.page.evaluate(writeState({local: {account: 'fixture-account', theme: 'dark'}, indexed: {account: 'fixture-account', nested: [1, '中文']}}));
        const state = await source.page.evaluate(readState), exported = await cookies(source.page);
        expect(state.auth.authenticated && state.local.account === 'fixture-account' && state.indexed.account === 'fixture-account', 'installed Chrome logs in and writes real localStorage/IndexedDB');
        expect(exported.some(c => c.name === 'omp_session' && c.httpOnly && c.session), 'the export contains HttpOnly session cookies unavailable to document.cookie');
        expect(exported.some(c => c.name === '__Host-omp' && c.secure) && exported.some(c => c.name === 'omp_chip' && c.partitionKey), 'the source includes Secure host-prefixed and partitioned cookies');
        report.cookieMetadata = cookieMetadata(exported);
        // The same user-data root is intentionally tested only with this disposable Chrome.
        if (scope === 'all') {
            const locked = await cef('shared-live-root', source.root, origin, false, true);
            report.cases.liveRoot = locked.outcome ?? {ready: true};
            if (locked.stop) await locked.stop();
            expect(!locked.stop, 'a live Chrome root cannot also create the independent CEF browser');
            await source.stop();
            report.sourceDatabase = inspectCookies(source.root);
            expect(report.sourceDatabase.encrypted > 0 && report.sourceDatabase.plaintext === 0, 'Chrome stores fixture cookie values encrypted on disk');
            const copied = join(output, 'raw-copy-profile'); await cp(source.root, copied, {recursive: true});
            const raw = await cef('raw-copy', copied, origin, false, true);
            if (raw.stop) {
                const rawState = await raw.page.evaluate(readState); const rawCookies = await cookies(raw.page);
                report.cases.rawCopy = {authenticated: rawState.auth.authenticated, localStorageRestored: JSON.stringify(rawState.local) === JSON.stringify(state.local),
                    indexedDBRestored: JSON.stringify(rawState.indexed) === JSON.stringify(state.indexed), cookieNames: rawCookies.map(c => c.name)};
                expect(!rawState.auth.authenticated, 'copying the closed Chrome profile does not recover its encrypted login in Debug CEF');
                await raw.stop();
            } else {
                report.cases.rawCopy = {startupRejected: true, ...raw.outcome};
                expect(true, 'the older CEF runtime rejects the copied Chrome profile during startup');
            }
        } else await source.stop();
        const importedRoot = join(output, 'api-import-profile'); await mkdir(importedRoot);
        const target = await cef('api-import', importedRoot, origin, true);
        expect(!(await target.page.evaluate(readState)).auth.authenticated, 'the destination starts without the Chrome login');
        await target.page.send('Network.setCookies', {cookies: exported.map(c => cookieParam(c, origin))});
        const cookieOnly = await target.page.evaluate(readState);
        expect(cookieOnly.auth.authenticated, 'semantic Cookie import restores server-side login without Chrome encryption keys');
        expect(Object.keys(cookieOnly.local).length === 0 && cookieOnly.indexed === null, 'Cookie import alone does not transfer localStorage or IndexedDB');
        await target.page.evaluate(writeState(state));
        const importedCookies = await cookies(target.page);
        expect(JSON.stringify(cookieMetadata(importedCookies)) === JSON.stringify(cookieMetadata(exported)), 'Cookie metadata, session flags, paths, HttpOnly, Secure and partition keys survive import');
        const complete = await target.page.evaluate(readState);
        expect(JSON.stringify(complete.local) === JSON.stringify(state.local) && JSON.stringify(complete.indexed) === JSON.stringify(state.indexed), 'separate origin-scoped semantic storage import restores the fixture application state');
        await target.stop();
        const restart = await cef('api-import-restart', importedRoot, origin, true);
        const reopened = await restart.page.evaluate(readState);
        expect(reopened.auth.authenticated, 'imported persistent and session login cookies survive a real CEF process restart');
        expect(JSON.stringify(reopened.local) === JSON.stringify(state.local) && JSON.stringify(reopened.indexed) === JSON.stringify(state.indexed), 'imported localStorage and IndexedDB survive the destination restart');
        await restart.stop();
        report.destinationDatabase = inspectCookies(importedRoot, 'Profile-migration');
        expect(report.destinationDatabase.encrypted > 0 && report.destinationDatabase.plaintext === 0, 'CEF re-encrypts imported cookies in its own store');
        report.cases.apiImport = {cookieOnlyLogin: true, metadataPreserved: true, siteStorageSeparate: true, survivesRestart: true};
        report.passed = true;
    }
} catch (error) {
    report.error = error.stack; console.error(error); process.exitCode = 1;
} finally {
    for (const process of children) process.kill('SIGTERM');
    if (server.listening) await new Promise(resolve => server.close(resolve));
    await writeFile(join(output, scope === 'database' ? 'database.json' : 'summary.json'), JSON.stringify(report, null, 2) + '\n');
}
