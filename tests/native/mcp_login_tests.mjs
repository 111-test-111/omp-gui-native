import assert from "node:assert/strict";
import { mkdir, writeFile } from "node:fs/promises";
import { join } from "node:path";
import { createRequire } from "node:module";
import { authorizeMCP, loadNativeMCP } from "../../OMPGUI/Resources/OMPMCPLogin.js";

const [output, packageRoot] = process.argv.slice(2);
assert.ok(output.includes("/build.noindex/verification/runs/"));
const profile = "gui-mcp-login";
process.env.HOME = join(output, "home");
process.env.PI_CONFIG_DIR = ".omp-isolated";
process.env.OMP_PROFILE = process.env.PI_PROFILE = profile;
for (const key of ["OMP_AUTH_BROKER_URL", "PI_AUTH_BROKER_URL", "PI_CODING_AGENT_DIR", "PI_CONFIG_FILES"]) delete process.env[key];
const requireNative = createRequire(join(packageRoot, "package.json"));
requireNative("@oh-my-pi/pi-utils/dirs.js").setProfile(profile);
const native = await loadNativeMCP(packageRoot);
const directory = join(process.env.HOME, ".omp-isolated/profiles", profile, "agent");
await mkdir(directory, { recursive: true });
await writeFile(join(directory, "mcp.json"), "{}\n");
let tokenExchanges = 0;
let registrations = 0;
const server = Bun.serve({ hostname: "127.0.0.1", port: 0, async fetch(request) {
    const url = new URL(request.url);
    const base = url.origin;
    if (url.pathname.startsWith("/.well-known/oauth-protected-resource")) {
        return Response.json({ resource: base + "/mcp", authorization_servers: [base], scopes_supported: ["tools:read"] });
    }
    if (url.pathname.startsWith("/.well-known/oauth-authorization-server") || url.pathname.startsWith("/.well-known/openid-configuration")) {
        return Response.json({ issuer: base, authorization_endpoint: base + "/authorize", token_endpoint: base + "/token",
            registration_endpoint: base + "/register", response_types_supported: ["code"],
            grant_types_supported: ["authorization_code", "refresh_token"], code_challenge_methods_supported: ["S256"] });
    }
    if (url.pathname === "/register") {
        registrations++;
        const client = await request.json();
        assert.ok(client.redirect_uris.length);
        return Response.json({ ...client, client_id: "native-test-client", client_secret: "native-private-client-secret" }, { status: 201 });
    }
    if (url.pathname === "/token") {
        tokenExchanges++;
        const body = new URLSearchParams(await request.text());
        assert.equal(body.get("grant_type"), "authorization_code");
        assert.ok(body.get("code_verifier"));
        return Response.json({ access_token: "native-private-access", refresh_token: "native-private-refresh", expires_in: 3600, token_type: "Bearer" });
    }
    if (url.pathname === "/mcp") return new Response("Unauthorized", { status: 401,
        headers: { "WWW-Authenticate": `Bearer resource_metadata="${base}/.well-known/oauth-protected-resource"` } });
    return new Response("Not found", { status: 404 });
} });
const portLease = Bun.serve({ hostname: "127.0.0.1", port: 0, fetch: () => new Response("unused") });
const callbackPort = portLease.port;
await portLease.stop(true);
const endpoint = `http://127.0.0.1:${server.port}/mcp`;
const abort = new AbortController();
const timeout = setTimeout(() => abort.abort(new Error("Native OAuth fixture timed out")), 20000);
let callback;
let checks = 0;
try {
    const auth = await authorizeMCP({ directory, definition: { type: "http", url: endpoint, oauth: { callbackPort } } }, native, {
        signal: abort.signal, verifyUnchanged: async () => {},
        onAuth: info => {
            const authorization = new URL(info.url);
            assert.equal(authorization.origin, new URL(endpoint).origin);
            assert.ok(authorization.searchParams.get("code_challenge")); checks++;
            const redirect = new URL(authorization.searchParams.get("redirect_uri"));
            redirect.searchParams.set("code", "isolated-code");
            redirect.searchParams.set("state", authorization.searchParams.get("state"));
            callback = fetch(redirect).then(response => assert.ok(response.ok));
        },
        onPrompt: async (_, signal) => new Promise((_, reject) => signal.addEventListener("abort", () => reject(signal.reason), { once: true })),
    });
    await callback;
    assert.equal(registrations, 1); checks++;
    assert.equal(tokenExchanges, 1); checks++;
    assert.ok(auth.credentialId.includes(profile)); checks++;
    assert.ok(!JSON.stringify(auth).includes("native-private")); checks++;
    const storage = await native.discoverAuthStorage(directory, { cwd: directory });
    try {
        const credential = native.lookupMcpOAuthCredentialForServer(storage, auth, endpoint)?.credential;
        assert.equal(credential.access, "native-private-access"); checks++;
        assert.equal(credential.refresh, "native-private-refresh"); checks++;
        assert.equal(credential.clientSecret, "native-private-client-secret"); checks++;
        assert.equal(credential.clientId, "native-test-client"); checks++;
    } finally { storage.close(); }
    await writeFile(join(output, "result.json"), JSON.stringify({ checks, registrations, tokenExchanges, profile, externalServices: false }, null, 2));
    console.log(`Native MCP SDK OAuth checks passed: ${checks}; isolated loopback provider, no browser or model.`);
} finally { clearTimeout(timeout); abort.abort(new Error("Fixture complete")); await server.stop(true); }
