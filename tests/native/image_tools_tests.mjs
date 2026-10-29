import assert from "node:assert/strict";
import { mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { join, resolve } from "node:path";
import { pathToFileURL } from "node:url";

const root = resolve(process.argv[2]), packageRoot = resolve(process.argv[3]);
assert(root.includes("/build.noindex/verification/runs/"));
const agentDir = process.env.PI_CODING_AGENT_DIR;
assert(agentDir.startsWith(root + "/"));
const cwd = join(root, "project");
mkdirSync(agentDir, { recursive: true }); mkdirSync(cwd, { recursive: true });
const profile = join(agentDir, "config.yml");
const original = "modelRoles:\n  image: openai-codex/gpt-image-2\n";
writeFileSync(profile, original);
let networkCalls = 0;
globalThis.fetch = async () => { networkCalls++; throw new Error("Network disabled for image tool activation check"); };
const imp = name => import(pathToFileURL(Bun.resolveSync(name, packageRoot)).href);
const sdk = await imp("@oh-my-pi/pi-coding-agent");
const { ModelRegistry } = await imp("@oh-my-pi/pi-coding-agent/config/model-registry");
const { cfgGenerateImageEnabled, cfgToolsXdev } = await imp("@oh-my-pi/pi-coding-agent/tools/settings");
const { getBundledModel } = await imp("@oh-my-pi/pi-catalog");
const { ensureTheme, stopThemeWatcher } = await imp("@oh-my-pi/pi-tui/theme");
await ensureTheme();
const authStorage = await sdk.AuthStorage.create(join(agentDir, "auth.db"));
authStorage.keys.setRuntime("openai", "isolated-check");
let session;
let checks = 0;
const expect = (value, message) => { assert.ok(value, message); checks++; };
try {
    const settings = await sdk.Settings.loadReadOnly({ cwd, agentDir, overrides: {
        "generate_image.enabled": false, "tools.xdev": true, "memory.backend": "off",
        "autolearn.enabled": false, "lsp.enabled": false, "startup.quiet": true,
    } });
    const result = await sdk.createAgentSession({ cwd, agentDir, settings, authStorage,
        modelRegistry: new ModelRegistry(authStorage, join(agentDir, "models.yml"), { settings }),
        model: getBundledModel("openai", "gpt-4o-mini"), getApiKey: async () => "isolated-check",
        sessionManager: sdk.SessionManager.create(cwd, join(root, "sessions")),
        disableExtensionDiscovery: true, skills: [], rules: [], contextFiles: [], cacheWarming: false, bindProcessState: false,
    });
    session = result.session;
    expect(!session.getAllToolNames().includes("generate_image"), "Configuring an image role alone does not enable the native image tool");
    cfgGenerateImageEnabled.override(settings, true);
    await session.reconcileBuiltinTools();
    expect(session.getAllToolNames().includes("generate_image"), "Enabling the native image setting registers the real tool in an existing session");
    expect(session.getEnabledToolNames().includes("generate_image"), "The registered image tool is enabled for invocation");
    expect(session.getMountedXdevToolNames().includes("generate_image"), "With xdev enabled, image generation is mounted as an xd:// device");
    expect(session.systemPrompt.some(block => block.includes("generate_image")), "The model's actual system prompt advertises the image tool");
    cfgToolsXdev.override(settings, false);
    await session.reconcileBuiltinTools();
    expect(session.getActiveToolNames().includes("generate_image") && !session.getMountedXdevToolNames().includes("generate_image"),
        "Without xdev, the same native image tool is directly callable");
    cfgGenerateImageEnabled.override(settings, false);
    await session.reconcileBuiltinTools();
    expect(!session.getAllToolNames().includes("generate_image") && !session.getEnabledToolNames().includes("generate_image"),
        "Disabling image generation removes it from both the registry and callable set");
    expect(["read", "write"].every(name => session.getEnabledToolNames().includes(name)), "Changing image activation preserves unrelated tools");
    expect(networkCalls === 0 && session.messages.length === 0, "Activation changes issue no model/image request and send no prompt");
    expect(readFileSync(profile, "utf8") === original, "SDK session checks leave the isolated profile's saved roles unchanged");
    writeFileSync(join(root, "summary.json"), JSON.stringify({ status: "passed", checks,
        boundary: "Installed SDK tool registry, live activation and xd:// presentation; isolated profile, no image/model requests or GUI" }, null, 2));
    console.log(`PASS native image tools: ${checks} activation and model-visible tool checks`);
} finally {
    await session?.dispose();
    authStorage.close();
    stopThemeWatcher();
}
