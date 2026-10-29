import assert from "node:assert/strict";
import { mkdirSync, readFileSync, writeFileSync, existsSync, statSync, symlinkSync, lstatSync } from "node:fs";
import { join, resolve, dirname } from "node:path";
import { pathToFileURL } from "node:url";

const root = resolve(process.argv[2]), executable = resolve(process.argv[3]), helper = resolve(process.argv[4]);
assert(root.includes("/build.noindex/verification/runs/"));
const agent = process.env.PI_CODING_AGENT_DIR;
assert(agent.startsWith(root + "/"));
mkdirSync(agent, { recursive: true });
const { nativeConfiguration, nativeAuthentication, readConfiguration, providerRows, saveConfiguration } = await import(pathToFileURL(helper));
let native = await nativeConfiguration(executable);
assert.equal(native.directory, agent);
const packageRoot = dirname(dirname(executable));
const load = name => import(pathToFileURL(Bun.resolveSync(name, packageRoot)));
const { discoverAuthStorage } = await load("@oh-my-pi/pi-coding-agent/session/auth-broker-config");
const accounts = await discoverAuthStorage(agent);
await accounts.credentials.set("anthropic", { type: "oauth", access: "fixture-access", refresh: "fixture-refresh", expires: Date.now() + 86400000 });
const credentials = JSON.stringify(accounts.credentials.all());
native.close();
native = await nativeConfiguration(executable);
let checks = 0;
const expect = (condition, message) => { assert.ok(condition, message); checks++; };
const authenticationFetch = globalThis.fetch;
let authenticationNetworkCalls = 0;
let authentication;
globalThis.fetch = () => { authenticationNetworkCalls++; throw new Error("Authentication discovery must remain offline"); };
try { authentication = await nativeAuthentication(executable, agent); } finally { globalThis.fetch = authenticationFetch; }
const browserLogins = new Set(authentication.providers.filter(row => row.supportsBrowserLogin).map(row => row.id));
expect(authentication.directory === agent && authentication.providers.length === native.authProviders().length,
    "Authentication capabilities cover the installed public provider policies and active profile");
expect(!browserLogins.has("typesafe") && browserLogins.has("openrouter") && browserLogins.has("openai-codex"),
    "TypeSafe uses a key while OpenRouter and Codex retain real browser authorization");
for (const policy of native.authProviders()) {
    if (policy.login?.kind === "api-key") expect(!browserLogins.has(policy.id), `${policy.id} has no misleading browser-login entry`);
}
for (const id of ["github-copilot", "perplexity", "snowflake", "alibaba-coding-plan", "alibaba-token-plan",
    "cloudflare-ai-gateway", "cloudflare-workers-ai", "xiaomi"]) {
    expect(!browserLogins.has(id), `${id} cannot route unsupported prompts through RPC login`);
}
expect(authenticationNetworkCalls === 0 && JSON.stringify(accounts.credentials.all()) === credentials,
    "Inspecting authentication policies sends no network requests and leaves stored credentials untouched");
expect(authentication.providers.every(row => Object.keys(row).sort().join(",") === "credentialProviderID,id,supportsBrowserLogin"),
    "Authentication discovery returns only provider identity and capability metadata");
expect(authentication.providers.find(row => row.id === "openai-codex-device")?.credentialProviderID === "openai-codex"
    && authentication.providers.find(row => row.id === "openai-codex")?.credentialProviderID === "openai-codex",
    "The installed native Codex browser and device routes share exactly one credential namespace");
const file = join(agent, "models.yml");
const initial = `# owner's model configuration\nfutureTopLevel:\n  nested: keep\nproviders:\n  anthropic:\n    apiKey: EXISTING_ENV_REFERENCE\n    modelOverrides:\n      owner-model:\n        name: Owner model\n  custom-relay:\n    apiKey: '!op read fixture'\n    baseUrl: https://example.invalid/v1\n    headers:\n      X-Owner: keep\n    models:\n      - id: relay-model\n        api: openai-completions\n`;
writeFileSync(file, initial);
const original = readConfiguration(agent, native);
const rows = providerRows(original, native);
expect(["typesafe", "openai", "google", "xai", "openrouter", "anthropic", "brave", "custom-relay"].every(id => rows.some(row => row.id === id)), "Native API providers and existing custom definitions are discoverable without credentials");
expect(!rows.some(row => row.id === "google-antigravity" || row.id === "openai-codex-device"), "Structured OAuth credentials and login aliases are not offered as interchangeable API keys");
expect(rows.find(row => row.id === "anthropic").hasOAuth === true, "The same provider can expose both a key override and stored OAuth");
expect(rows.find(row => row.id === "custom-relay").value === "!op read fixture", "Native command references are read without execution");
expect(readFileSync(file, "utf8") === initial, "Opening the form leaves the source file unchanged");
const request = (snapshot, changes) => ({ file: snapshot.file, revision: snapshot.revision, changes });
expect(saveConfiguration(agent, request(original, {}), native).saved === false && readFileSync(file, "utf8") === initial, "A no-op save preserves exact formatting and comments");

const result = saveConfiguration(agent, request(original, { anthropic: "fixture-config-key", openai: "fixture-openai-key" }), native);
expect(result.saved, "Multiple provider fields save together");
let saved = readConfiguration(agent, native);
expect(saved.value.providers.anthropic.modelOverrides["owner-model"].name === "Owner model", "Provider model overrides survive credential edits");
expect(saved.value.futureTopLevel.nested === "keep" && saved.value.providers["custom-relay"].headers["X-Owner"] === "keep", "Unknown top-level and custom-provider fields survive");
expect((statSync(file).mode & 0o777) === 0o600, "The native credential file has private permissions");
accounts.keys.setConfig("anthropic", saved.value.providers.anthropic.apiKey);
expect(await accounts.keys.get("anthropic") === "fixture-config-key", "OMP's native key cascade prioritizes the explicit config key over stored OAuth");

saveConfiguration(agent, request(saved, { anthropic: "", openai: "" }), native);
saved = readConfiguration(agent, native);
expect(!Object.hasOwn(saved.value.providers.anthropic, "apiKey") && !Object.hasOwn(saved.value.providers, "openai"), "Clearing removes only the key and prunes newly empty definitions");
accounts.keys.removeConfig("anthropic");
expect(await accounts.keys.get("anthropic") === "fixture-access", "Removing the config override restores OMP's stored OAuth selection");
expect(JSON.stringify(accounts.credentials.all()) === credentials, "Editing key overrides never changes OAuth accounts or tokens");

const beforeConflict = readFileSync(file, "utf8");
writeFileSync(file, beforeConflict + "\nexternalOwnerChange: keep\n");
assert.throws(() => saveConfiguration(agent, request(saved, { google: "must-not-save" }), native), /conflict/);
expect(readFileSync(file, "utf8").endsWith("externalOwnerChange: keep\n"), "An external edit is rejected and retained");
const current = readConfiguration(agent, native);
assert.throws(() => saveConfiguration(agent, request(current, { "custom-relay": "" }), native), /invalid_configuration/);
expect(readConfiguration(agent, native).revision === current.revision, "Invalid custom model authentication does not partially save other fields");

const fallback = join(root, "yaml-fallback"); mkdirSync(fallback);
writeFileSync(join(fallback, "models.yaml"), "providers:\n  google:\n    apiKey: OWNER_GEMINI_KEY\n");
const yaml = readConfiguration(fallback, native);
saveConfiguration(fallback, request(yaml, { google: "updated-reference" }), native);
expect(!existsSync(join(fallback, "models.yml")) && readConfiguration(fallback, native).value.providers.google.apiKey === "updated-reference", "The effective models.yaml remains authoritative");
const legacy = join(root, "legacy"); mkdirSync(legacy);
writeFileSync(join(legacy, "models.json"), '{"providers":{"openai":{"apiKey":"legacy-reference"}},"owner":true}');
const json = readConfiguration(legacy, native);
expect(!existsSync(join(legacy, "models.yml")), "Reading legacy JSON does not trigger migration");
saveConfiguration(legacy, request(json, { openai: "new-reference" }), native);
expect(existsSync(join(legacy, "models.yml")) && readConfiguration(legacy, native).value.owner === true, "An explicit save migrates legacy JSON while retaining owner fields");
const linked = join(root, "linked"); mkdirSync(linked);
const target = join(linked, "owner-config.yaml"); writeFileSync(target, "providers: {}\n");
symlinkSync(target, join(linked, "models.yml"));
saveConfiguration(linked, request(readConfiguration(linked, native), { google: "linked-reference" }), native);
expect(lstatSync(join(linked, "models.yml")).isSymbolicLink() && readConfiguration(linked, native).value.providers.google.apiKey === "linked-reference", "Atomic save updates a symlink target while retaining the link");
const invalid = join(root, "invalid"); mkdirSync(invalid); writeFileSync(join(invalid, "models.yml"), "providers: [invalid]\n");
assert.throws(() => readConfiguration(invalid, native), /invalid_file/);
checks++;

const subprocess = Bun.spawn([process.execPath, helper, executable], { stdin: "pipe", stdout: "pipe", stderr: "pipe" });
subprocess.stdin.write(JSON.stringify({ action: "save", directory: join(root, "wrong-profile"), changes: { openai: "fixture-secret-not-for-output" } }));
subprocess.stdin.end();
const [stdout, stderr] = await Promise.all([new Response(subprocess.stdout).text(), new Response(subprocess.stderr).text()]);
expect(await subprocess.exited !== 0 && JSON.parse(stdout).error === "profile_changed", "The helper rejects a stale native profile before saving");
expect(!stdout.includes("fixture-secret-not-for-output") && !stderr.includes("fixture-secret-not-for-output"), "Failure responses never echo request secrets");
const unicodeKey = "样".repeat(24000);
const pipeSave = Bun.spawn([process.execPath, helper, executable], { stdin: "pipe", stdout: "pipe", stderr: "pipe" });
pipeSave.stdin.write(JSON.stringify({ action: "save", directory: agent, ...request(readConfiguration(agent, native), { openai: unicodeKey }) }));
pipeSave.stdin.end();
const pipeOutput = await new Response(pipeSave.stdout).text();
const pipeError = await new Response(pipeSave.stderr).text();
expect(await pipeSave.exited === 0 && JSON.parse(pipeOutput).saved === true, "A save travels through the production stdin-only helper entry point");
expect(readConfiguration(agent, native).value.providers.openai.apiKey === unicodeKey, "UTF-8 values survive pipe chunk boundaries without corruption");
expect(!pipeOutput.includes(unicodeKey) && !pipeError.includes(unicodeKey), "Successful saves return no key values");
await accounts.credentials.reload();
expect(JSON.stringify(accounts.credentials.all()) === credentials, "Stored OAuth survives helper subprocesses and all edits");

// Image discovery shares the same native credential cascade, including missing
// credentials and command references, without contacting a model service.
for (const row of providerRows(readConfiguration(agent, native), native)) {
    for (const name of row.environmentKeys) delete process.env[name];
}
for (const policy of native.authProviders()) {
    for (const name of policy.oauthTokenEnv ?? []) delete process.env[name];
}
const marker = join(root, "image-key-command-ran");
const commandKey = `!touch '${marker}'`;
const imageFixture = {
    providers: {
        "fixture-images": { api: "google-generative-ai", baseUrl: "https://images.invalid/v1", apiKey: commandKey,
            models: [{ id: "draw", name: "Fixture image", kind: "image" }, { id: "also-draw", kind: "image" }] },
        "fixture-keyless": { api: "google-generative-ai", baseUrl: "https://keyless.invalid/v1", auth: "none",
            models: [{ id: "draw", kind: "image" }] },
        "fixture-chat": { api: "openai-completions", baseUrl: "https://chat.invalid/v1", auth: "none",
            models: [{ id: "chat", kind: "chat" }] },
        openai: { apiKey: "fixture-shared-image-key" },
    },
};
writeFileSync(file, native.stringify(imageFixture));
const settingsFile = join(agent, "config.yml");
const settingsText = "modelRoles:\n  image: fixture-images/draw\n  default: owner/chat-model\n";
writeFileSync(settingsFile, settingsText);
await accounts.credentials.set("openai-codex", { type: "oauth", access: "fixture-image-oauth-access", refresh: "fixture-image-oauth-refresh", expires: 1 });
native.close();
native = await nativeConfiguration(executable);
const imageCredentials = JSON.stringify(accounts.credentials.all());
const originalFetch = globalThis.fetch;
let networkCalls = 0;
globalThis.fetch = () => { networkCalls++; throw new Error("Image discovery must remain offline"); };
let images;
try { images = await native.images(); } finally { globalThis.fetch = originalFetch; }
expect(images.selected === "fixture-images/draw", "The explicit image role resolves against the full catalogue");
expect(images.models.some(row => row.id === "fixture-images/draw" && row.hasCredentials), "Command-backed keys count as configured without execution");
expect(!existsSync(marker) && networkCalls === 0, "Presence checks run no key command, OAuth refresh or network request");
expect(images.models.some(row => row.provider === "openrouter" && !row.hasCredentials), "Unauthenticated native image backends remain selectable");
expect(images.models.some(row => row.provider === "openai" && row.hasCredentials), "Images reuse the provider's models.yml key");
expect(images.models.some(row => row.provider === "openai-codex" && row.hasCredentials), "Stored OAuth is recognized without refreshing an expired access token");
expect(images.models.some(row => row.provider === "fixture-keyless" && !row.requiresCredentials), "Keyless native endpoints are distinct from missing credentials");
expect(!images.backends.some(row => row.id === "fixture-chat"), "Chat-only models are excluded from image backend choices");
expect(images.backends.find(row => row.id === "fixture-images").keyProvider === "fixture-images", "Custom image backends link to their shared key editor");
expect(images.backends.find(row => row.id === "openai-codex").loginProvider === "openai-codex", "OAuth image backends retain their native login identity");
expect(images.backends.every(row => row.loginProvider === null || browserLogins.has(row.loginProvider)), "Image backends offer only supported browser sign-in methods");
expect(images.backends.every(row => row.keyProvider === null || row.keyProvider === row.id), "Shared environment aliases never redirect a provider's config key to another provider");
expect(!JSON.stringify(images).includes("fixture-shared-image-key") && !JSON.stringify(images).includes(commandKey) && !JSON.stringify(images).includes("fixture-image-oauth-access"), "Only credential presence metadata leaves the image SDK helper");
expect(readFileSync(settingsFile, "utf8") === settingsText && readFileSync(file, "utf8") === native.stringify(imageFixture), "Image settings discovery preserves native configuration bytes");
await accounts.credentials.reload();
expect(JSON.stringify(accounts.credentials.all()) === imageCredentials, "Image discovery leaves OAuth credentials unchanged");
const imagePipe = Bun.spawn([process.execPath, helper, executable], { stdin: "pipe", stdout: "pipe", stderr: "pipe" });
imagePipe.stdin.write(JSON.stringify({ action: "images", directory: agent })); imagePipe.stdin.end();
const imageOutput = await new Response(imagePipe.stdout).text();
const imageError = await new Response(imagePipe.stderr).text();
expect(await imagePipe.exited === 0 && JSON.parse(imageOutput).selected === "fixture-images/draw", "The image inventory travels through the production helper entry point");
expect(!imageOutput.includes("fixture-shared-image-key") && !imageError.includes("fixture-image-oauth-access"), "The image subprocess does not print credentials");
const regionalRows = providerRows(readConfiguration(agent, native), native);
expect(regionalRows.some(row => row.id === "minimax-cn") && regionalRows.some(row => row.id === "minimax"),
    "Public bundled models contribute the missing China provider as an independent key editor row");
const regionalBefore = readConfiguration(agent, native);
saveConfiguration(agent, request(regionalBefore, { "minimax-cn": "fixture-cn-key", minimax: "fixture-global-key" }), native);
const regionalSaved = readConfiguration(agent, native);
expect(regionalSaved.value.providers["minimax-cn"].apiKey === "fixture-cn-key"
    && regionalSaved.value.providers.minimax.apiKey === "fixture-global-key",
    "Editing China credentials preserves the exact regional ID and does not overwrite international keys");
const { ModelsConfigFile } = await load("@oh-my-pi/pi-coding-agent/config/models-config");
const { ModelRegistry } = await load("@oh-my-pi/pi-coding-agent/config/model-registry");
const { Settings } = await load("@oh-my-pi/pi-coding-agent/config/settings");
ModelsConfigFile.invalidate();
const regionalSettings = await Settings.loadReadOnly({ agentDir: agent, cwd: root });
const regionalRegistry = new ModelRegistry(accounts, undefined, { settings: regionalSettings });
expect(!regionalRegistry.getError() && regionalRegistry.getAvailableForProviders(new Set(["minimax-cn"])).length > 0,
    "OMP's real model registry accepts and makes available the separately configured China provider");
expect(await accounts.keys.get("minimax-cn") === "fixture-cn-key" && await accounts.keys.get("minimax") === "fixture-global-key",
    "The native public key cascade resolves the two regional overrides independently");
expect(JSON.stringify(accounts.credentials.all()) === imageCredentials,
    "Regional key editing never migrates or deletes stored OAuth credentials");
accounts.close(); native.close();
writeFileSync(join(root, "summary.json"), JSON.stringify({ status: "passed", checks, boundary: "Installed OMP registry, schema, credential cascade and native YAML; isolated profile only, no service requests or GUI" }, null, 2));
console.log(`PASS native model configuration: ${checks} provider, image backend, credential coexistence and file-integrity checks`);
