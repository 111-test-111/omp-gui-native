// Edits OMP's native provider key overrides. Authentication and key selection
// remain in OMP. The editor never resolves keys; explicit balance reads use OMP's key cascade.
import * as fs from "node:fs";
import * as path from "node:path";
import * as os from "node:os";
import { createHash, randomUUID } from "node:crypto";
import { pathToFileURL } from "node:url";

const limit = 2 * 1024 * 1024;
const record = value => value !== null && typeof value === "object" && !Array.isArray(value);
const fail = code => { throw new Error(code); };

// OMP's login catalogue includes key-paste flows and hooks that ask for a host,
// account or email before opening a browser. Its RPC login cannot handle those
// pre-URL prompts or secret input. Unknown custom flows stay out until audited.
const browserLoginHooks = new Set(["cursor", "openai-codex-device", "kilo"]);

export function supportsBrowserLogin(policy) {
    if (policy?.available === false || policy?.showInLoginList === false) return false;
    const login = policy?.login;
    return login?.kind === "oauth-code" || login?.kind === "device-code"
        || (login?.kind === "custom" && browserLoginHooks.has(login.hook));
}

export function readConfiguration(directory, native) {
    const files = ["models.yml", "models.yaml", "models.json"].map(name => {
        const file = path.join(directory, name);
        try {
            fs.lstatSync(file);
            const target = fs.realpathSync(file);
            if (!fs.statSync(target).isFile() || fs.statSync(target).size > limit) fail("invalid_file");
            const bytes = fs.readFileSync(target);
            if (bytes.length > limit) fail("invalid_file");
            return { file, target, bytes };
        } catch (error) {
            if (error.code === "ENOENT") {
                try { fs.lstatSync(file); } catch (missing) {
                    if (missing.code === "ENOENT") return { file, target: file, bytes: null };
                }
            }
            fail("invalid_file");
        }
    });
    const selected = files.find(file => file.bytes !== null) ?? files[0];
    let value;
    try {
        value = selected.bytes === null || !selected.bytes.toString("utf8").trim() ? {} : native.parse(selected.bytes.toString("utf8"), selected.file);
    } catch { fail("invalid_file"); }
    if (!record(value) || (value.providers !== undefined && !record(value.providers))) fail("invalid_file");
    for (const provider of Object.values(value.providers ?? {})) {
        if (!record(provider) || (provider.apiKey !== undefined && typeof provider.apiKey !== "string")) fail("invalid_file");
    }
    const hash = createHash("sha256");
    for (const file of files) {
        hash.update(JSON.stringify([file.file, file.target, file.bytes !== null]));
        if (file.bytes !== null) hash.update(file.bytes);
    }
    // Reading legacy JSON never migrates it. Saving follows OMP's YAML format.
    const destination = selected.file.endsWith(".json") ? files[0] : selected;
    return { value, revision: hash.digest("hex"), file: destination.file, target: destination.target };
}

export function providerRows(configuration, native) {
    const entries = native.providerEntries();
    const policies = new Map(native.authProviders().map(provider => [provider.id, provider]));
    const ids = new Set(native.listProvidersWithEnvKey());
    for (const policy of policies.values()) {
        if (policy.login?.kind === "api-key" || policy.result === "api-key") ids.add(policy.id);
    }
    // Some native model providers (e.g. minimax-cn) have no auth/env registry row.
    // Their exact models.yml key override remains supported by OMP's model registry.
    for (const id of native.modelProviderIDs?.() ?? []) {
        if (!policies.has(id)) ids.add(id);
    }
    // Existing custom providers remain editable alongside the native catalogue.
    for (const id of Object.keys(configuration.value.providers ?? {})) ids.add(id);
    return [...ids].filter(id => {
        if (Object.hasOwn(configuration.value.providers ?? {}, id)) return true;
        const policy = policies.get(id);
        if (policy?.storeAs || policy?.apiKeyFormat === "structured") return false;
        const names = policy?.env?.vars ?? entries[id]?.envVars ?? [];
        return !names.length || !names.every(name => policy?.oauthTokenEnv?.includes(name));
    }).sort((a, b) => a.localeCompare(b)).map(id => {
        const policy = policies.get(id);
        return {
            id, name: policy?.name ?? id,
            environmentKeys: policy?.env?.vars ?? entries[id]?.envVars ?? [],
            value: configuration.value.providers?.[id]?.apiKey ?? "",
            hasOAuth: native.hasOAuth(id),
        };
    });
}

export function saveConfiguration(directory, request, native) {
    const original = readConfiguration(directory, native);
    if (request.revision !== original.revision || request.file !== original.file) fail("conflict");
    if (!record(request.changes)) fail("invalid_request");
    const allowed = new Set(providerRows(original, native).map(row => row.id));
    const value = structuredClone(original.value);
    const providers = value.providers ?? {};
    let changed = false;
    for (const [id, raw] of Object.entries(request.changes)) {
        if (!allowed.has(id) || typeof raw !== "string" || raw.length > 32768 || /[\r\n\0]/.test(raw)) fail("invalid_request");
        const key = raw.trim();
        if (key === (providers[id]?.apiKey ?? "")) continue;
        const provider = { ...(providers[id] ?? {}) };
        if (key) provider.apiKey = key;
        else delete provider.apiKey;
        if (Object.keys(provider).length) Object.defineProperty(providers, id, { value: provider, enumerable: true, configurable: true, writable: true });
        else delete providers[id];
        changed = true;
    }
    if (!changed) return { saved: false };
    value.providers = providers;
    // Validate using the installed OMP schema, without discarding unknown data.
    try { native.validate(value); } catch { fail("invalid_configuration"); }
    const text = native.stringify(value);
    if (Buffer.byteLength(text) > limit) fail("invalid_file");
    fs.mkdirSync(path.dirname(original.target), { recursive: true, mode: 0o700 });
    const temporary = `${original.target}.${randomUUID()}.tmp`;
    let descriptor;
    try {
        descriptor = fs.openSync(temporary, "wx", 0o600);
        fs.writeFileSync(descriptor, text);
        fs.fsyncSync(descriptor);
        fs.closeSync(descriptor);
        descriptor = undefined;
        if (readConfiguration(directory, native).revision !== original.revision) fail("conflict");
        fs.renameSync(temporary, original.target);
    } finally {
        if (descriptor !== undefined) fs.closeSync(descriptor);
        try { fs.unlinkSync(temporary); } catch (error) { if (error.code !== "ENOENT") throw error; }
    }
    return { saved: true };
}

async function nativeContext(executable, expectedDirectory) {
    const root = path.dirname(path.dirname(fs.realpathSync(executable)));
    const load = name => import(pathToFileURL(Bun.resolveSync(name, root)).href);
    const dirs = await load("@oh-my-pi/pi-utils/dirs.js");
    dirs.setProfile(dirs.resolveProfileEnv(process.env.OMP_PROFILE, process.env.PI_PROFILE));
    if (expectedDirectory !== undefined && expectedDirectory !== dirs.getAgentDir()) fail("profile_changed");
    return { load, directory: dirs.getAgentDir() };
}

// Capability discovery reads public policies only: no credential store, login
// flow, key command, token refresh or provider request is opened.
export async function nativeAuthentication(executable, expectedDirectory) {
    const { load, directory } = await nativeContext(executable, expectedDirectory);
    const auth = await load("@oh-my-pi/pi-catalog/compat/auth");
    return authenticationMetadata(directory, auth.authProviders());
}

export function authenticationMetadata(directory, policies) {
    return { directory, providers: policies.map(policy => ({
        id: policy.id, supportsBrowserLogin: supportsBrowserLogin(policy),
        credentialProviderID: policy.storeAs || policy.id,
    })) };
}

export async function nativeConfiguration(executable, expectedDirectory) {
    const { load, directory } = await nativeContext(executable, expectedDirectory);
    const [providers, auth, keys, models, utils, storage, catalogue] = await Promise.all([
        load("@oh-my-pi/pi-catalog/compat/providers"), load("@oh-my-pi/pi-catalog/compat/auth"),
        load("@oh-my-pi/pi-ai/env-api-key"), load("@oh-my-pi/pi-coding-agent/config/models-config"),
        load("@oh-my-pi/pi-utils/yaml-config"), load("@oh-my-pi/pi-coding-agent/session/auth-broker-config"),
        load("@oh-my-pi/pi-catalog"),
    ]);
    const { JSONC, YAML } = await import("bun");
    let accounts;
    try { accounts = await storage.discoverAuthStorage(directory); } catch { /* Unknown, not signed out. */ }
    return {
        ...providers, ...auth, ...keys,
        directory,
        hasOAuth: id => accounts ? accounts.credentials.hasOAuth(id) : null,
        modelProviderIDs: () => catalogue.getBundledProviders?.() ?? [],
        close: () => accounts?.close(),
        async balances(fetchImpl = globalThis.fetch) {
            if (!accounts) fail("usage_unavailable");
            const [configuration, catalogue, sdk, usage] = await Promise.all([
                load("@oh-my-pi/pi-coding-agent/config/settings"),
                load("@oh-my-pi/pi-coding-agent/config/model-registry"), load("@oh-my-pi/pi-coding-agent"),
                import("./OMPProviderUsage.js"),
            ]);
            const settings = await configuration.Settings.loadReadOnly({ agentDir: directory, cwd: os.tmpdir() });
            const registry = new catalogue.ModelRegistry(accounts, undefined, { settings });
            if (registry.getError()) fail("usage_unavailable");
            await sdk.loadCliExtensionProviders(registry, settings, os.tmpdir(), { includeAmbientHooks: false, discoverModels: false });
            const baseUrl = registry.getProviderBaseUrl("deepseek");
            // Check endpoint ownership before OMP resolves a command-backed key.
            if (baseUrl && !usage.isOfficialDeepSeekURL(baseUrl)) return { directory, reports: [] };
            const apiKey = await accounts.keys.get("deepseek");
            const report = await usage.deepSeekUsageProvider.fetchUsage(
                { provider: "deepseek", baseUrl, credential: { type: "api_key", apiKey } }, { fetch: fetchImpl });
            return { directory, reports: report ? [report] : [] };
        },
        async images() {
            if (!accounts) fail("image_credentials_unavailable");
            const [configuration, catalogue, resolver, imageAPI] = await Promise.all([
                load("@oh-my-pi/pi-coding-agent/config/settings"), load("@oh-my-pi/pi-coding-agent/config/model-registry"),
                load("@oh-my-pi/pi-coding-agent/config/model-resolver"), load("@oh-my-pi/pi-ai/images"),
            ]);
            const settings = await configuration.Settings.loadReadOnly({ agentDir: directory, cwd: os.tmpdir() });
            const registry = new catalogue.ModelRegistry(accounts, undefined, { settings });
            if (registry.getError()) fail("image_configuration_invalid");
            // Offline catalogue and the native presence check: never mint a model
            // key, run its !command, refresh OAuth, or issue an image request.
            const models = registry.getAll("image").filter(model => imageAPI.isImageGenerationApi(model.api));
            const selector = settings.getModelRole("image") ?? "";
            const selected = selector ? resolver.resolveModelRoleValue(selector, models, { settings }).model : undefined;
            const chain = resolver.resolveRoleChain("image", settings, models).map(candidate => candidate.model);
            const modelConfiguration = readConfiguration(directory, this);
            const keyRows = providerRows(modelConfiguration, this);
            const policies = new Map(auth.authProviders().map(policy => [policy.id, policy]));
            const providerNames = providers.providerEntries();
            const id = model => `${model.provider}/${model.id}`;
            const rows = models.map(model => ({
                id: id(model), provider: model.provider, name: model.name ?? model.id,
                hasCredentials: registry.hasConfiguredAuth(model),
                requiresCredentials: modelConfiguration.value.providers?.[model.provider]?.auth !== "none" && !accounts.keys.keyless(model.provider),
            })).sort((a, b) => a.id.localeCompare(b.id));
            const backends = [...new Set(rows.map(row => row.provider))].sort().map(provider => {
                const policy = policies.get(provider);
                const environmentKeys = policy?.env?.vars ?? providerNames[provider]?.envVars ?? [];
                // Shared environment aliases do not imply shared models.yml keys.
                // Keep configuration overrides on the exact native provider id.
                const keyProvider = keyRows.find(row => row.id === provider);
                return {
                    id: provider, name: policy?.name ?? provider,
                    preferredModel: id(chain.find(model => model.provider === provider) ?? models.find(model => model.provider === provider)),
                    loginProvider: supportsBrowserLogin(policy) ? policy.id : null,
                    keyProvider: keyProvider?.id ?? null,
                    environmentKeys,
                };
            });
            return { directory, selector, selected: selected ? id(selected) : null, models: rows, backends };
        },
        parse: (text, file) => file.endsWith(".json") ? JSONC.parse(text) : YAML.parse(text),
        stringify: utils.stringifyYamlConfig,
        validate(value) {
            if (!models.ModelsConfigFile.schema.allows(value)) fail("invalid_configuration");
            for (const [id, provider] of Object.entries(value.providers ?? {})) {
                models.validateProviderConfiguration(id, { ...provider, models: provider.models ?? [] }, "models-config");
            }
        },
    };
}

if (import.meta.main) {
    let native;
    let request;
    try {
        const chunks = [];
        let length = 0;
        for await (const chunk of process.stdin) {
            length += chunk.length;
            if (length > limit) fail("invalid_request");
            chunks.push(chunk);
        }
        request = JSON.parse(Buffer.concat(chunks).toString("utf8"));
        if (!record(request) || typeof request.directory !== "string") fail("invalid_request");
        let result;
        if (request.action === "authentication") {
            result = await nativeAuthentication(process.argv[2], request.directory);
        } else {
            native = await nativeConfiguration(process.argv[2], request.directory);
            if (request.action === "read") {
                const file = readConfiguration(native.directory, native);
                result = { directory: native.directory, file: file.file, revision: file.revision, providers: providerRows(file, native) };
            } else if (request.action === "save") result = saveConfiguration(native.directory, request, native);
            else if (request.action === "images") result = await native.images();
            else if (request.action === "balances") result = await native.balances();
            else fail("invalid_request");
        }
        process.stdout.write(JSON.stringify(result));
    } catch (error) {
        const known = ["conflict", "invalid_file", "invalid_request", "invalid_configuration", "profile_changed", "image_credentials_unavailable", "image_configuration_invalid"];
        const fallback = request?.action === "images" ? "images_unavailable" : native && request?.action === "save" ? "write_failed" : "unavailable";
        process.stdout.write(JSON.stringify({ error: known.includes(error.message) ? error.message : fallback }));
        process.exitCode = 1;
    } finally { native?.close(); }
}
