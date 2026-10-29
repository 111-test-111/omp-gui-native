import assert from "node:assert/strict";
import { authorizeMCP, verifyMCPConfiguration } from "../../../OMPGUI/Resources/OMPMCPLogin.js";
import { mkdtemp, writeFile, realpath, symlink, rm } from "node:fs/promises";
import { join } from "node:path";
import { tmpdir } from "node:os";

let checks = 0;
const expect = (value, message) => { assert.ok(value, message); checks++; };
function fixture(options = {}) {
    const calls = { writes: [], closed: 0, auth: [], prompts: [], discovery: 0, verify: 0 };
    const abort = new AbortController();
    const native = {
        expandEnvVarsDeep: value => structuredClone(value),
        discoverOAuthEndpoints: async () => {
            calls.discovery++;
            return options.noDiscovery ? null : { authorizationUrl: "https://auth.invalid/authorize", tokenUrl: "https://auth.invalid/token",
                registrationUrl: "https://auth.invalid/register", resource: "https://example.invalid/mcp" };
        },
        discoverAuthStorage: async () => ({ credentials: { set: async (...args) => calls.writes.push(args) }, close: () => calls.closed++ }),
        lookupMcpOAuthCredentialForServer: () => options.stored ? { credential: options.stored } : undefined,
        mcpOAuthCredentialId: url => "mcp_oauth:profile:fixture:" + url,
        MCPOAuthFlow: class {
            constructor(config, controller) {
                calls.config = config;
                this.controller = controller;
                this.resolvedClientId = config.clientId ?? "native-dcr-client";
                this.registeredClientSecret = "native-dcr-secret";
                this.resource = config.resource;
                this.authorizationUrl = config.authorizationUrl;
            }
            async login() {
                this.controller.onAuth({ url: "https://auth.invalid/authorize?state=native-state" });
                if (options.manual) await this.controller.onManualCodeInput(abort.signal);
                if (options.fail) throw new Error("Provider rejected the grant");
                if (options.cancel) abort.abort(new Error("Cancelled"));
                return { access: "private-access", refresh: "private-refresh", expires: 123456 };
            }
        },
    };
    const io = { signal: abort.signal, onAuth: info => calls.auth.push(info),
        onPrompt: async prompt => { calls.prompts.push(prompt); return "private-callback-code"; },
        verifyUnchanged: async () => { calls.verify++; if (options.conflict) throw new Error("Configuration changed"); } };
    const request = { directory: "/isolated/profile", definition: { type: "http", url: "https://example.invalid/mcp" } };
    return { calls, native, io, request };
}

{
    const f = fixture({ manual: true });
    const auth = await authorizeMCP(f.request, f.native, f.io);
    expect(f.calls.writes.length === 1 && f.calls.closed === 1, "Only native storage receives credentials and is closed");
    expect(f.calls.writes[0][1].access === "private-access" && f.calls.writes[0][1].refresh === "private-refresh", "Native OAuth owns tokens");
    expect(f.calls.writes[0][1].clientSecret === "native-dcr-secret", "DCR refresh material stays in native storage");
    expect(auth.credentialId.endsWith(f.request.definition.url), "Profile-scoped URL identity is preserved");
    expect(!JSON.stringify(auth).includes("private-") && !JSON.stringify(auth).includes("native-dcr-secret"), "GUI receives references without any token or DCR secret");
    expect(f.calls.auth.length === 1 && f.calls.prompts.length === 1, "Native browser and manual input are forwarded");
    expect(f.calls.verify === 1 && f.calls.config.registrationUrl, "Configuration is revalidated before persisting the discovered grant");
    expect(f.request.definition.auth === undefined, "The supplied definition is immutable");
}
for (const options of [{ fail: true }, { cancel: true }, { conflict: true }]) {
    const f = fixture(options);
    await assert.rejects(authorizeMCP(f.request, f.native, f.io)); checks++;
    expect(f.calls.writes.length === 0 && f.calls.closed === 1, "Failure, cancellation and profile conflicts cannot save a grant");
}
{
    const f = fixture({ noDiscovery: true });
    await assert.rejects(authorizeMCP(f.request, f.native, f.io)); checks++;
    expect(f.calls.closed === 0 && f.calls.writes.length === 0, "Failed discovery never opens or mutates credentials");
}
for (const definition of [{ type: "stdio", command: "never-run" }, { type: "http", url: "file:///private" },
    { type: "http", url: "https://user:secret@example.invalid/mcp" }]) {
    const f = fixture(); f.request.definition = definition;
    await assert.rejects(authorizeMCP(f.request, f.native, f.io)); checks++;
    expect(f.calls.discovery === 0, "Invalid transports and URL credentials are rejected before network work");
}
{
    const f = fixture({ stored: { clientId: "previous-native-client", clientSecret: "stored-private" } });
    f.request.definition.url = "https://example.invalid";
    await authorizeMCP(f.request, f.native, f.io);
    expect(f.calls.config.clientId === "previous-native-client" && f.calls.config.clientSecret === "stored-private", "Reauthorization reuses OMP's registered native client");
    expect(f.calls.writes[0][0].endsWith("https://example.invalid"), "Root endpoint identity does not acquire an extra slash");
}
{
    const directory = await mkdtemp(join(tmpdir(), "omp-mcp-login-check-"));
    try {
        const input = { directory, resolvedDirectory: await realpath(directory), original: "{}\n" };
        await writeFile(join(directory, "mcp.json"), input.original);
        await verifyMCPConfiguration(input); checks++;
        await writeFile(join(directory, "mcp.json"), "[]\n");
        await assert.rejects(verifyMCPConfiguration(input)); checks++;
        await writeFile(join(directory, "mcp.json"), Buffer.alloc(2 * 1024 * 1024 + 1));
        await assert.rejects(verifyMCPConfiguration(input)); checks++;
        await rm(join(directory, "mcp.json"));
        await writeFile(join(directory, "external.json"), input.original);
        await symlink(join(directory, "external.json"), join(directory, "mcp.json"));
        await assert.rejects(verifyMCPConfiguration(input)); checks++;
    } finally { await rm(directory, { recursive: true, force: true }); }
}
console.log(`MCP login contracts passed: ${checks}`);
