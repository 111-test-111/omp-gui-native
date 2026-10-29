import assert from "node:assert/strict";
import { readFile, writeFile } from "node:fs/promises";
import { dirname, join } from "node:path";

// Real native workers and CEF. Collect independent observations before asserting
// them, so a lost download path does not hide a lost UA/script in the same recycle.
export async function checkRecoveryOptions({ root, attachment, cell, check, open, emit }) {
    const directory = join(root, "downloads A 中文");
    const ua = "OMP-Recovery-Acceptance/1.0";
    const script = "window.startupRuns = (window.startupRuns || 0) + 1;";
    const options = { ...attachment.a.open, url: attachment.a.url, downloads: directory,
        user_agent: ua, init_scripts: [script], viewport: { width: 803, height: 601, scale: 1 },
        allowed_domains: ["127.0.0.1", "localhost"] };
    const proof = { options, observations: {}, failures: [] };
    const expect = (condition, message) => {
        if (condition) check(true, message);
        else proof.failures.push(message);
    };
    const snapshot = async label => await cell(label, emit(`await a.run(async ({tab,page}) => ({
        page: await page.evaluate(() => ({ua:navigator.userAgent, width:innerWidth, height:innerHeight,
            startupRuns:window.startupRuns ?? 0})), scripts:await tab.initScripts(), domains:await tab.allowedDomains(),
        workerMarker:typeof recoveryMarker === 'undefined' ? null : recoveryMarker
    }))`));
    const download = async label => {
        const url = new URL("/download?name=" + label, attachment.a.url).href;
        const value = await cell(label, emit(`await a.run(async ({tab,page}) => {
            await page.$eval('#download',(link,url)=>link.href=url,${JSON.stringify(url)});
            const pending = tab.waitForDownload(); await tab.click('#download'); return await pending;
        })`));
        const content = await readFile(value.path, "utf8");
        expect(content === `OMP acceptance ${label} 中文✓\n`, label + ": actual file has exact response bytes");
        return value;
    };
    try {
        await cell("open-startup-options", open("a", options));
        proof.observations.initial = await snapshot("initial-startup-state");
        proof.observations.firstDownload = await download("before-timeout");
        const viewport = { width: 719, height: 547, scale: 1 };
        await cell("reuse-with-new-viewport", open("a", { name: options.name, app: options.app, viewport }));
        proof.observations.reused = await snapshot("reused-startup-state");
        expect(proof.observations.reused.page.width === viewport.width && proof.observations.reused.page.height === viewport.height,
            "Reopening only the viewport applies the updated dimensions on the existing worker");
        await cell("worker-marker", "await a.run(() => { globalThis.recoveryMarker = 'old worker'; });");
        const timeout = await cell("modal-timeout-with-options", "await a.setDialogs(null); await a.run(async ({tab}) => { await tab.click('#confirm'); }, {timeout:3});", { failure: true });
        assert.match(timeout, /Browser code execution timed out after 3000ms.*confirm/s,
            "The fixture must reach a real modal timeout, not an unrelated tool error");
        await cell("reload-after-recovery", "await a.reload();");
        proof.observations.recovered = await snapshot("recovered-startup-state");
        proof.observations.secondDownload = await download("after-timeout");
        const { initial, recovered, firstDownload, secondDownload } = proof.observations;
        expect(dirname(firstDownload.path) === directory, "Initial download uses the explicit directory");
        expect(dirname(secondDownload.path) === directory, "Recovered worker retains the explicit download directory");
        expect(recovered.workerMarker === null, "Timeout actually replaces the tab worker");
        for (const [label, state] of Object.entries({ initial, recovered })) {
            expect(state.page.ua === ua, label + ": startup User-Agent is applied");
            expect(state.page.startupRuns === 1 && state.scripts.length === 1 && state.scripts[0].source === script,
                label + ": startup script runs once and remains registered");
            const dimensions = label === "initial" ? options.viewport : viewport;
            expect(state.page.width === dimensions.width && state.page.height === dimensions.height,
                label + ": the latest explicit open viewport is applied");
            expect(JSON.stringify(state.domains) === JSON.stringify(options.allowed_domains), label + ": domain policy is retained");
        }
        const replacement = join(root, "downloads replacement");
        await cell("replace-download-directory", open("a", { ...attachment.a.open, downloads: replacement }));
        proof.observations.replacedDownload = await download("after-reopen");
        expect(dirname(proof.observations.replacedDownload.path) === replacement,
            "Explicit reopen switches to the newly requested download directory");
        assert.deepEqual(proof.failures, [], "Startup/recovery contract violations");
    } finally {
        await writeFile(join(root, "recovery-options.json"), JSON.stringify(proof, null, 2));
    }
}

export async function checkDownloadLifecycle({ root, attachment, cell, check, open, emit, control }) {
    const directories = { a: join(root, "lifecycle A"), b: join(root, "lifecycle B") };
    const evidence = [];
    const download = async (tab, name, value = name) => {
        const url = new URL("/download", attachment.a.url);
        url.searchParams.set("name", name); url.searchParams.set("value", value);
        const result = await cell(`${tab}-${value}`, emit(`await ${tab}.run(async ({tab,page}) => {
            await page.$eval('#download',(link,url)=>link.href=url,${JSON.stringify(url.href)});
            const waiting=tab.waitForDownload(); await tab.click('#download'); return await waiting;
        })`));
        evidence.push(result);
        check(dirname(result.path) === directories[tab], `${tab}-${value}: selected tab rearms its requested directory`);
        check(await readFile(result.path, "utf8") === `OMP acceptance ${value} 中文✓\n`, `${tab}-${value}: reported path contains this download's bytes`);
        return result;
    };
    try {
        await cell("open-two-download-targets", open("a", { ...attachment.a.open, downloads: directories.a })
            + open("b", { ...attachment.b.open, downloads: directories.b }));
        const first = await download("a", "collision", "first");
        await download("b", "sibling");
        const second = await download("a", "collision", "second");
        // OMP downloads.ts explicitly replaces same-named files, as CDP allow
        // does. GUI manual-download folders have a different, unique-path policy.
        check(second.path === first.path && await readFile(second.path, "utf8") === "OMP acceptance second 中文✓\n",
            "A duplicate filename follows the native replacement contract and reports the current bytes");
        const expired = await cell("download-wait-deadline", "await a.run(async ({tab}) => { await tab.waitForDownload({timeout:80}); });", { failure: true });
        assert.match(expired, /tab\.waitForDownload\(\) timed out after 80ms/);
        await download("a", "after-wait-timeout");
        await cell("release-download-sibling", "await b.close();");
        await download("a", "after-sibling-release");
        await cell("release-final-download-handle", "await a.close();");
        const manual = await control("download", "a");
        const restored = manual.downloads.find(path => path.endsWith("/manual-after-release.txt"));
        check(restored?.startsWith(join(root, "storage/browser/downloads") + "/"),
            "Releasing all handles restores the GUI's normal download destination");
        check(await readFile(restored, "utf8") === "OMP acceptance manual-after-release 中文✓\n",
            "The GUI download remains usable after every OMP download session is detached");
        evidence.push({ manualPath: restored });
    } finally {
        await writeFile(join(root, "download-lifecycle.json"), JSON.stringify(evidence, null, 2));
    }
}

export async function checkCertificateOptions({ root, attachment, cell, check, open, emit, control }) {
    const { url } = JSON.parse(await readFile(join(root, "tls-fixture.json"), "utf8"));
    const outcomes = {};
    const probe = async (label, handle = "a") => {
        // Each policy observation starts outside Chromium's prior interstitial.
        // Retrying the same failed URL from that page can wait for a load event
        // without a new certificate decision, which is not a policy assertion.
        await cell(label + "-normal-page", `await ${handle}.goto(${JSON.stringify(attachment.a.url)});`);
        const target = new URL(url); target.searchParams.set("probe", label);
        const result = await cell(label, emit(`await ${handle}.run(async ({page}) => {
            const events = [];
            const client = page.mainFrame().client;
            const failed = event => events.push({event:'loadingFailed', ...event});
            const navigated = event => events.push({event:'frameNavigated', ...event});
            client.on('Network.loadingFailed',failed); client.on('Page.frameNavigated',navigated);
            try { await page.goto(${JSON.stringify(target.href)}, {timeout:2500}); return {title:await page.title(),events}; }
            catch(error) { return {error:error.message,events}; }
            finally {client.off('Network.loadingFailed',failed);client.off('Page.frameNavigated',navigated);}
        })`));
        const native = await control("status", handle);
        result.nativeErrors = native.loadErrors.filter(error => error.url === target.href);
        outcomes[label] = result; return result;
    };
    try {
        await cell("default-certificate-policy", open("a", attachment.a.open));
        const denied = await probe("untrusted-certificate-default");
        await cell("explicit-certificate-opt-in", "await a.close();" + open("a", { ...attachment.a.open, ignore_https_errors: true }));
        const initial = await probe("untrusted-certificate-opt-in");
        await cell("certificate-default-sibling", open("b", attachment.b.open));
        const sibling = await probe("untrusted-certificate-sibling", "b");
        await cell("release-certificate-sibling", "await b.close();");
        const withoutDownloadOption = { ...attachment.a.open };
        delete withoutDownloadOption.downloads;
        await cell("disable-certificate-before-recovery", open("a", { ...withoutDownloadOption, ignore_https_errors: false }));
        const disabledBeforeRecovery = await probe("untrusted-certificate-before-recovery-disable");
        await cell("reenable-certificate-before-recovery", open("a", { ...withoutDownloadOption, ignore_https_errors: true }));
        await cell("return-to-modal-fixture", `await a.goto(${JSON.stringify(attachment.a.url)});`);
        const timeout = await cell("certificate-option-modal-timeout", "await a.setDialogs(null); await a.run(async ({tab}) => { await tab.click('#confirm'); }, {timeout:3});", {failure:true});
        assert.match(timeout, /Browser code execution timed out after 3000ms.*confirm/s);
        const recovered = await probe("untrusted-certificate-after-recovery");
        await cell("disable-certificate-opt-in", open("a", { ...withoutDownloadOption, ignore_https_errors: false }));
        const disabled = await probe("untrusted-certificate-after-disable");
        await cell("release-certificate-opt-in", "await a.close();" + open("a", withoutDownloadOption));
        const reset = await probe("untrusted-certificate-after-release");
        const violations = [];
        for (const [condition, message] of [
            [/ERR_CERT_/.test(denied.error), "Untrusted local TLS is rejected by default"],
            [initial.title === "TLS fixture", "Explicit certificate opt-in is effective"],
            [/ERR_CERT_/.test(sibling.error), "A sibling without the opt-in still validates certificates"],
            [/ERR_CERT_/.test(disabledBeforeRecovery.error), "Explicit false restores validation before any timeout"],
            [recovered.title === "TLS fixture", "Certificate opt-in survives native worker recovery"],
            [/ERR_CERT_/.test(disabled.error), "Explicit false on reopen restores certificate validation"],
            [/ERR_CERT_/.test(reset.error), "Releasing the opt-in restores certificate validation"],
        ]) { if (condition) check(true, message); else violations.push(message); }
        assert.deepEqual(violations, [], "Certificate policy contract violations");
    } finally { await writeFile(join(root, "certificate-options.json"), JSON.stringify(outcomes, null, 2)); }
}
