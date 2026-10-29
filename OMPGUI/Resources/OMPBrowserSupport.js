// Helpers for the reviewed OMP SDK copy. No browser/process ownership lives here.
// Only exact OMP GUI attachments opt into these CEF compatibility paths.
const guiPages = new WeakSet();
const prefix = "omp-gui-target:";

export const isGuiTarget = matcher => typeof matcher === "string" && matcher.startsWith(prefix);
export const isGuiPage = page => guiPages.has(page);
export const markGuiPage = page => { guiPages.add(page); };
export class GuiPageStateError extends Error {}

// Keep the initial contract separate from state changed by later tab.run calls.
// Copies prevent a caller's arrays/viewport from changing a future recovery.
export function workerOpenOptions(payload) {
    return {
        downloadsPath: payload.downloadsPath,
        initScripts: payload.initScripts ? [...payload.initScripts] : undefined,
        userAgent: payload.userAgent,
        ignoreHttpsErrors: payload.ignoreHttpsErrors,
        viewport: payload.viewport && !(payload.mode === "headless" && payload.emulateViewport === false)
            ? { ...payload.viewport } : undefined,
    };
}

// CEF can publish a main-document certificate failure without settling the
// corresponding Page.navigate command (notably after an ignore-errors lease).
// Give Puppeteer's existing navigation watcher the same error response it
// normally receives, so it disposes its lifecycle wait and reports ERR_CERT_*
// instead of waiting for a timeout. No certificate decision is changed here.
export function installGuiNavigationErrors(page) {
    if (!isGuiPage(page)) return;
    const client = page.mainFrame().client;
    const send = client.send.bind(client);
    client.send = async (method, parameters, ...rest) => {
        if (method !== "Page.navigate" || !parameters?.url) return await send(method, parameters, ...rest);
        const frameId = parameters.frameId ?? page.mainFrame()._id;
        let destination;
        try { destination = new URL(parameters.url); destination.hash = ""; }
        catch { return await send(method, parameters, ...rest); }
        const requests = new Set();
        let resolveFailure;
        const failure = new Promise(resolve => { resolveFailure = resolve; });
        const requested = event => {
            if (event.frameId === frameId && event.type === "Document"
                && event.request.url === destination.href) requests.add(event.requestId);
        };
        const failed = event => {
            if (requests.has(event.requestId) && event.type === "Document"
                && /^net::ERR_CERT_/.test(event.errorText)) {
                resolveFailure({ frameId, errorText: event.errorText });
            }
        };
        client.on("Network.requestWillBeSent", requested);
        client.on("Network.loadingFailed", failed);
        try {
            const response = await Promise.race([send(method, parameters, ...rest), failure]);
            if (/^net::ERR_CERT_/.test(response?.errorText)) {
                // Also stop the failed pending navigation before the next input
                // or focus command. Keep cleanup inside OMP's native grace.
                await bounded(undefined, 250, "OMP GUI failed navigation cleanup",
                    () => send("Page.stopLoading")).catch(() => {});
            }
            return response;
        } finally {
            client.off("Network.requestWillBeSent", requested);
            client.off("Network.loadingFailed", failed);
        }
    };
}

async function bounded(signal, timeoutMs, label, action) {
    signal?.throwIfAborted();
    let timer, onAbort;
    try {
        return await Promise.race([
            Promise.resolve().then(() => { signal?.throwIfAborted(); return action(); }),
            new Promise((_, reject) => {
                timer = setTimeout(() => reject(new Error(`${label} timed out`)), Math.max(1, timeoutMs));
                if (signal) {
                    onAbort = () => reject(signal.reason);
                    signal.addEventListener("abort", onAbort, { once: true });
                }
            }),
        ]);
    } finally {
        clearTimeout(timer);
        if (onAbort) signal.removeEventListener("abort", onAbort);
    }
}

// Metadata only: initializing a Puppeteer Page here would duplicate the worker's
// attachment and retain a rejected pagePromise in the shared supervisor connection.
export async function resolveGuiTarget(connection, matcher, signal, timeoutMs = 5000) {
    if (!isGuiTarget(matcher)) throw new Error("Expected an exact OMP GUI target");
    const targetId = matcher.slice(prefix.length);
    if (!/^[A-Za-z0-9_-]{1,256}$/.test(targetId)) throw new Error("Invalid OMP GUI target identity");
    let targetInfo;
    try {
        ({ targetInfo } = await bounded(signal, timeoutMs, "OMP GUI target lookup",
            () => connection.send("Target.getTargetInfo", { targetId })));
    } catch (error) {
        signal?.throwIfAborted();
        throw new Error(`Cannot attach OMP GUI target ${targetId}: ${error.message}`, { cause: error });
    }
    if (targetInfo?.targetId !== targetId || targetInfo.type !== "page") {
        throw new Error("The requested OMP GUI tab is unavailable; list its current tabs again");
    }
    return targetId;
}

async function withSession(target, signal, timeoutMs, label, action) {
    let session, finished = false;
    const creating = Promise.resolve().then(() => {
        signal?.throwIfAborted();
        return target.createCDPSession();
    }).then(value => {
        if (finished) { void value.detach().catch(() => {}); return value; }
        session = value;
        return value;
    });
    creating.catch(() => {});
    try {
        return await bounded(signal, timeoutMs, label, async () => {
            const value = await creating;
            if (finished) throw new Error(`${label} already ended`);
            signal?.throwIfAborted();
            return action({ send: (...args) => {
                // A reply can arrive after the deadline while detach is still
                // draining. It must not advance recovery or issue another write.
                if (finished) throw new Error(`${label} already ended`);
                signal?.throwIfAborted();
                return value.send(...args);
            } });
        });
    } finally {
        finished = true;
        if (session) await bounded(undefined, 250, "CDP session detach", () => session.detach()).catch(() => {});
    }
}

// A dialog belongs to the CDP session that observed its opening. A new session
// cannot inherit that callback. Dismiss through the old worker before OMP
// recycles it, within its 750ms cleanup grace; successful manual runs keep it.
export async function settleGuiRunDialog(page, dialogs, interrupted) {
    if (!isGuiPage(page) || !interrupted || !dialogs?.state().open) return;
    await bounded(undefined, 200, "OMP GUI interrupted dialog cleanup",
        () => dialogs.handle({ accept: false }));
}

// Recovery is requested by OMP only after it has stopped the previous worker.
// Its dialog has already been settled above. Do not enable Page/Inspector here:
// those renderer roundtrips cannot recover a modal owned by a different session.
export async function recoverGuiTarget(target, signal, timeoutMs = 1500) {
    await withSession(target, signal, timeoutMs, "OMP GUI tab recovery", async session => {
        await session.send("Page.stopLoading");
        await session.send("Fetch.disable");
    });
}

// CEF parks background views. Keep rendering/input alive during native calls
// and recording, without selecting a GUI tab or raising a window.
export async function setGuiPageActive(page, active, signal, dialogPending = false) {
    // Emulation commands wait on a modal renderer. Let the native dialog API
    // settle it first; otherwise even handleDialog() would deadlock on setup.
    if (!isGuiPage(page) || dialogPending) return;
    try {
        await bounded(signal, active ? 2000 : 400, "OMP GUI focus emulation",
            () => page.emulateFocusedPage(active));
    } catch (error) {
        signal?.throwIfAborted();
        throw new GuiPageStateError(error.message, { cause: error });
    }
}

export async function readGuiCookies(page, signal) {
    return await withSession(page, signal, 5000, "OMP GUI cookie read", async session => {
        // A page session selects CEF's actual request context. BrowserContext's
        // absent ID otherwise addresses CEF's default context, a different jar.
        const result = await session.send("Network.getAllCookies");
        assertGuiStateCookies(result.cookies);
        return result.cookies;
    });
}

// OMP 18.12.5's state schema cannot represent CHIPS. Refuse lossy state files;
// the GUI's separate Chrome import path has its own full partition support.
export function assertGuiStateCookies(cookies) {
    if (Array.isArray(cookies) && cookies.some(cookie => cookie &&
        (cookie.partitionKey !== undefined || cookie.partitionKeyOpaque === true))) {
        throw new Error("OMP browser state cannot preserve partitioned cookies");
    }
}

const cookieKey = cookie => JSON.stringify([cookie.name, cookie.domain, cookie.path]);
export async function restoreGuiCookies(page, cookies, signal) {
    assertGuiStateCookies(cookies);
    await withSession(page, signal, 5000, "OMP GUI cookie restore", async session => {
        await session.send("Network.setCookies", { cookies });
        const { cookies: restored } = await session.send("Network.getAllCookies");
        const actual = new Map(restored.filter(cookie => cookie.partitionKey === undefined && !cookie.partitionKeyOpaque)
            .map(cookie => [cookieKey(cookie), cookie]));
        const now = Date.now() / 1000;
        for (const expected of cookies) {
            const found = actual.get(cookieKey(expected));
            const expired = expected.expires >= 0 && expected.expires <= now;
            const expiryMatches = expected.expires < 0 ? found?.session || found?.expires === -1
                : found?.expires > now && Math.abs(found.expires - Math.min(expected.expires, now + 400 * 86400)) < 5;
            if (expired ? found !== undefined : !found || found.value !== expected.value
                || found.secure !== expected.secure || found.httpOnly !== expected.httpOnly
                || (found.sameSite ?? "Lax") !== expected.sameSite || !expiryMatches) {
                // Never expose the cookie's name, value or site in diagnostic output.
                throw new Error("OMP GUI cookie restore was not retained by the target profile");
            }
        }
    });
}
