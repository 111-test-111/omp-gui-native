import assert from "node:assert/strict";
import { join } from "node:path";
import { pathToFileURL } from "node:url";

export async function checkBrowserDownloads(repaired, output) {
    const { DownloadManager } = await import(pathToFileURL(join(repaired, "src/tools/browser/downloads.ts")));
    const { markGuiPage } = await import(pathToFileURL(join(repaired, "src/tools/browser/omp-gui.js")));
    const calls = [], detached = [];
    const session = scope => ({ on() {}, off() {},
        async send(method, params) { calls.push({ scope, method, params }); },
        async detach() { detached.push(scope); },
    });
    let pageConnections = 0;
    const browser = { target: () => ({ createCDPSession: async () => session("events") }) };
    const page = { browserContext() { throw new Error("Wrong CEF profile"); },
        async createCDPSession() { pageConnections++; return session("profile"); } };
    markGuiPage(page);
    const manager = new DownloadManager(browser, page, "fixture", { perTab: false });
    const first = join(output, "first 中文"), second = join(output, "second");
    await manager.enable(first);
    assert.deepEqual(calls, [
        { scope: "events", method: "Browser.setDownloadBehavior", params: { behavior: "default", eventsEnabled: true } },
        { scope: "profile", method: "Page.setDownloadBehavior", params: { behavior: "allow", downloadPath: first } },
    ], "Download events and the selected profile's destination use their respective CDP sessions");
    assert.deepEqual(detached, [], "A profile override must remain alive until the native manager closes");
    await manager.enable(second);
    assert.equal(pageConnections, 1, "Rearming reuses the profile lease");
    assert.equal(calls.at(-1).params.downloadPath, second);
    await manager.close(); await manager.close();
    assert.deepEqual(detached.sort(), ["events", "profile"], "Release each lease exactly once");

    calls.length = 0;
    const ordinary = new DownloadManager(browser, { browserContext: () => ({ id: "native-context" }) }, "ordinary", { perTab: true });
    await ordinary.enable(first);
    assert.deepEqual(calls, [{ scope: "events", method: "Browser.setDownloadBehavior",
        params: { behavior: "allowAndName", downloadPath: first, eventsEnabled: true, browserContextId: "native-context" } }],
        "Ordinary OMP-owned browsers keep native per-tab GUID handling");
    await ordinary.close();
    const { applyIgnoreHttpsErrors } = await import(pathToFileURL(join(repaired, "src/tools/browser/open-options.ts")));
    const security = [];
    let certificateDetached = false;
    const certificateSession = { async send(method, params) { security.push({ method, params }); },
        async detach() { certificateDetached = true; } };
    const securePage = { async createCDPSession() { return certificateSession; } };
    markGuiPage(securePage);
    const certificateLease = await applyIgnoreHttpsErrors(securePage);
    assert.deepEqual(security, [{ method: "Security.setIgnoreCertificateErrors", params: { ignore: true } }]);
    assert.equal(certificateLease, certificateSession, "Native OMP owns the certificate session lease");
    assert.equal(certificateDetached, false, "The certificate override survives navigation until its worker closes");
    await certificateLease.detach();
    assert.equal(certificateDetached, true);
    return { targetProfile: true, sessionLifetime: true, nativeBackendUnchanged: true, certificateSessionLifetime: true };
}
