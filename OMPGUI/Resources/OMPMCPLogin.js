// This host invokes OMP's public MCP OAuth SDK. OMP owns discovery, PKCE,
// the callback server, token exchange, refresh material and credential storage.
// No MCP server, tool manager or model session is created here.
export async function authorizeMCP(request, native, io) {
    const definition = native.expandEnvVarsDeep(request.definition);
    if (!definition || !["http", "sse"].includes(definition.type)) throw new Error("MCP sign-in requires a remote server.");
    const endpoint = new URL(definition.url);
    if (!["http:", "https:"].includes(endpoint.protocol) || endpoint.username || endpoint.password) {
        throw new Error("MCP sign-in requires an HTTP endpoint without URL credentials.");
    }
    io.signal.throwIfAborted();
    const discovered = await native.discoverOAuthEndpoints(definition.url, undefined, undefined, { signal: io.signal });
    if (!discovered) throw new Error("OMP could not discover OAuth endpoints for this server.");
    io.signal.throwIfAborted();
    const storage = await native.discoverAuthStorage(request.directory, { cwd: request.directory });
    try {
        const stored = native.lookupMcpOAuthCredentialForServer(storage, definition.auth, definition.url)?.credential;
        const explicit = definition.oauth ?? {};
        const auth = definition.auth ?? {};
        const clientId = explicit.clientId?.trim() || auth.clientId?.trim() || stored?.clientId?.trim()
            || (!discovered.registrationUrl ? discovered.clientId?.trim() : undefined);
        const clientSecret = (clientId === explicit.clientId?.trim() ? explicit.clientSecret : undefined)
            ?? (clientId === auth.clientId?.trim() ? auth.clientSecret : undefined)
            ?? (clientId === stored?.clientId?.trim() ? stored?.clientSecret : undefined);
        const resource = discovered.resource ?? auth.resource ?? definition.url;
        const flow = new native.MCPOAuthFlow({
            ...discovered, clientId, clientSecret, resource,
            stripSameOriginResource: !discovered.resource && !auth.resource,
            scopes: discovered.scopes || explicit.scope,
            callbackPort: explicit.callbackPort, callbackPath: explicit.callbackPath,
            redirectUri: explicit.redirectUri, prompt: explicit.prompt,
        }, {
            signal: io.signal, onAuth: io.onAuth,
            onManualCodeInput: signal => io.onPrompt({ message: "Paste the callback URL or authorization code." }, signal),
            onPrompt: prompt => io.onPrompt(prompt, io.signal),
        });
        const credentials = await flow.login();
        io.signal.throwIfAborted();
        await io.verifyUnchanged();
        io.signal.throwIfAborted();
        const credentialId = native.mcpOAuthCredentialId(definition.url);
        await storage.credentials.set(credentialId, {
            type: "oauth", ...credentials, tokenUrl: discovered.tokenUrl,
            clientId: flow.resolvedClientId?.trim() || clientId,
            clientSecret: flow.registeredClientSecret ?? clientSecret,
            resource: flow.resource, authorizationUrl: flow.authorizationUrl,
        });
        // Return references only. Access tokens, refresh tokens and DCR secrets
        // never cross into Swift or the GUI profile's JSON file.
        return { type: "oauth", credentialId, tokenUrl: discovered.tokenUrl,
            clientId: flow.resolvedClientId?.trim() || clientId, resource: flow.resource };
    } finally { storage.close(); }
}

export async function loadNativeMCP(packageRoot) {
    const { pathToFileURL } = await import("node:url");
    const load = subpath => import(pathToFileURL(Bun.resolveSync("@oh-my-pi/pi-coding-agent/" + subpath, packageRoot)).href);
    const [{ discoverAuthStorage }, flow, discovery, credentials, helpers] = await Promise.all([
        load("sdk"), load("mcp/oauth-flow"), load("mcp/oauth-discovery"), load("mcp/oauth-credentials"), load("discovery/helpers"),
    ]);
    const native = { discoverAuthStorage, ...flow, ...discovery, ...credentials, expandEnvVarsDeep: helpers.expandEnvVarsDeep };
    for (const name of ["discoverAuthStorage", "MCPOAuthFlow", "discoverOAuthEndpoints", "mcpOAuthCredentialId", "lookupMcpOAuthCredentialForServer", "expandEnvVarsDeep"]) {
        if (typeof native[name] !== "function") throw new Error("This OMP SDK does not support native MCP sign-in.");
    }
    return native;
}

export async function verifyMCPConfiguration(input) {
    const { open, realpath } = await import("node:fs/promises");
    const { constants } = await import("node:fs");
    const { join } = await import("node:path");
    const conflict = () => new Error("The OMP configuration changed. Reopen the editor before saving.");
    const expected = Buffer.from(input.original, "utf8");
    if (expected.length > 2 * 1024 * 1024 || await realpath(input.directory) !== input.resolvedDirectory) throw conflict();
    const file = await open(join(input.directory, "mcp.json"), constants.O_RDONLY | constants.O_NOFOLLOW);
    try {
        const stat = await file.stat();
        if (!stat.isFile() || stat.size !== expected.length) throw conflict();
        // A concurrent growth cannot turn validation into an unbounded read.
        const buffer = Buffer.alloc(expected.length + 1);
        let count = 0;
        while (count < buffer.length) {
            const { bytesRead } = await file.read(buffer, count, buffer.length - count, count);
            if (!bytesRead) break;
            count += bytesRead;
        }
        if (count !== expected.length || !buffer.subarray(0, count).equals(expected)
            || await realpath(input.directory) !== input.resolvedDirectory) throw conflict();
    } finally { await file.close(); }
}

if (import.meta.main) {
    const { realpath } = await import("node:fs/promises");
    const { dirname, join } = await import("node:path");
    const { createRequire } = await import("node:module");
    const { createInterface } = await import("node:readline");
    const abort = new AbortController();
    const timer = setTimeout(() => abort.abort(new Error("MCP sign-in timed out.")), 5 * 60 * 1000);
    const emit = value => process.stdout.write(JSON.stringify(value) + "\n");
    let pendingInput;
    let finished = false;
    const lines = createInterface({ input: process.stdin });
    let begin;
    const request = new Promise(resolve => { begin = resolve; });
    lines.on("line", line => {
        try {
            const frame = JSON.parse(line);
            if (begin) { const accept = begin; begin = undefined; accept(frame); }
            else if (pendingInput && frame.type === "input") { const accept = pendingInput; pendingInput = undefined; accept(frame.value); }
        } catch { abort.abort(new Error("Invalid MCP sign-in request.")); }
    });
    lines.on("close", () => { if (!finished) abort.abort(new Error("MCP sign-in closed.")); });
    process.on("SIGTERM", () => abort.abort(new Error("MCP sign-in cancelled.")));
    process.on("SIGINT", () => abort.abort(new Error("MCP sign-in cancelled.")));
    abort.signal.addEventListener("abort", () => { emit({ type: "error", message: String(abort.signal.reason?.message ?? abort.signal.reason) }); process.exit(1); }, { once: true });
    try {
        const input = await request;
        const executable = await realpath(process.env.OMP_GUI_NATIVE_EXECUTABLE);
        const root = dirname(dirname(executable));
        const requireNative = createRequire(join(root, "package.json"));
        const dirs = requireNative("@oh-my-pi/pi-utils/dirs.js");
        dirs.setProfile(dirs.resolveProfileEnv(process.env.OMP_PROFILE, process.env.PI_PROFILE));
        const native = await loadNativeMCP(root);
        const auth = await authorizeMCP(input, native, {
            signal: abort.signal,
            onAuth: info => emit({ type: "open_url", url: info.url, instructions: info.instructions }),
            onPrompt: (prompt, signal) => new Promise((resolve, reject) => {
                const cancelled = () => { pendingInput = undefined; reject(signal.reason); };
                signal?.addEventListener("abort", cancelled, { once: true });
                pendingInput = value => { signal?.removeEventListener("abort", cancelled); resolve(value); };
                emit({ type: "input", message: prompt.message });
            }),
            verifyUnchanged: () => verifyMCPConfiguration(input),
        });
        emit({ type: "complete", auth });
    } catch (error) {
        emit({ type: "error", message: String(error.message ?? error).slice(0, 8192) });
        process.exitCode = 1;
    } finally { finished = true; clearTimeout(timer); lines.close(); }
}
