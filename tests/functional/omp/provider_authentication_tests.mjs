import assert from "node:assert/strict";
import { providerRows, supportsBrowserLogin, authenticationMetadata } from "../../../OMPGUI/Resources/OMPModelConfiguration.js";

let checks = 0;
const expect = (condition, message) => { assert.ok(condition, message); checks++; };
const policy = (id, kind, extra = {}) => ({ id, name: id, login: { kind }, ...extra });

const typesafe = policy("typesafe", "api-key", { env: { vars: ["TYPESAFE_API_KEY"] } });
const openrouter = policy("openrouter", "oauth-code", { result: "api-key" });
expect(!supportsBrowserLogin(typesafe), "A console URL and API-key prompt are not browser authorization");
expect(supportsBrowserLogin(openrouter), "Browser authorization can legitimately return a durable API key");
expect(supportsBrowserLogin(policy("device", "device-code")), "Device-code authorization remains available");
expect(!supportsBrowserLogin(undefined) && !supportsBrowserLogin({ id: "unknown" }), "Missing policy metadata never invents browser support");
expect(!supportsBrowserLogin(policy("future", "unknown")), "New flow kinds require explicit support");
expect(!supportsBrowserLogin(policy("offline", "oauth-code", { available: false })), "Native unavailability hides browser sign-in");
expect(!supportsBrowserLogin(policy("hidden", "device-code", { showInLoginList: false })), "The native login-list restriction is retained");
for (const hook of ["cursor", "openai-codex-device", "kilo"]) {
    expect(supportsBrowserLogin(policy(hook, "custom", { login: { kind: "custom", hook } })), `${hook} starts browser authorization without pre-URL input`);
}
for (const hook of ["github-copilot", "perplexity", "snowflake", "alibaba-coding-plan", "alibaba-token-plan",
    "cloudflare-ai-gateway", "cloudflare-workers-ai", "xiaomi", "unreviewed-oauth-hook"]) {
    expect(!supportsBrowserLogin(policy(hook, "custom", { login: { kind: "custom", hook } })), `${hook} must not leave the GUI waiting on an unsupported login flow`);
}

const native = {
    providerEntries: () => ({}),
    authProviders: () => [typesafe, openrouter, policy("oauth-alias", "oauth-code", { storeAs: "oauth", apiKeyFormat: "structured" })],
    listProvidersWithEnvKey: () => ["typesafe", "openrouter", "oauth-alias", "openai"],
    modelProviderIDs: () => ["typesafe", "oauth-alias", "minimax-cn"],
    hasOAuth: () => false,
};
const rows = providerRows({ value: { providers: { "owner-relay": { apiKey: "OWNER_KEY_REFERENCE" } } } }, native);
expect(rows.some(row => row.id === "typesafe"), "Key-only TypeSafe stays available in the key editor");
expect(rows.some(row => row.id === "openrouter"), "A browser-capable provider may also accept a key override");
expect(rows.some(row => row.id === "openai"), "Providers without any login flow remain configurable by API key");
expect(rows.find(row => row.id === "owner-relay")?.value === "OWNER_KEY_REFERENCE", "Custom provider key configuration remains available");
expect(!rows.some(row => row.id === "oauth-alias"), "A structured OAuth alias is not presented as an interchangeable API key");
expect(rows.some(row => row.id === "minimax-cn" && row.value === "" && row.environmentKeys.length === 0),
    "A model-only native provider remains editable under its exact ID without borrowing another region's key or environment alias");
const metadata = authenticationMetadata("/fixture/profile", [
    policy("subscription", "oauth-code"), policy("device", "device-code", { storeAs: "subscription" }),
    policy("unrelated", "oauth-code", { name: "subscription" }),
]);
expect(metadata.providers.find(row => row.id === "device").credentialProviderID === "subscription",
    "Native store-as metadata identifies two login routes to one credential source");
expect(metadata.providers.find(row => row.id === "unrelated").credentialProviderID === "unrelated",
    "Identical provider names never imply shared credentials");
expect(metadata.providers.every(row => Object.keys(row).sort().join(",") === "credentialProviderID,id,supportsBrowserLogin"),
    "Authentication discovery exposes only identity, login capability and credential namespace metadata");
console.log(`${checks} provider authentication assertions passed`);
