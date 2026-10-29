import assert from "node:assert/strict";
import { mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { join, resolve } from "node:path";
import { pathToFileURL } from "node:url";

const root = resolve(process.argv[2]), packageRoot = resolve(process.argv[3]);
assert(root.includes("/build.noindex/verification/runs/"));
const sdk = await import(pathToFileURL(join(packageRoot, "src/index.ts")));
const { cfgProvidersOpenaiLiveSteering } = await import(pathToFileURL(join(packageRoot, "src/session/settings.ts")));
const { createSettingsAwareStreamFn } = await import(pathToFileURL(join(packageRoot, "src/session/settings-stream-fn.ts")));
const { Agent } = await import(pathToFileURL(Bun.resolveSync("@oh-my-pi/pi-agent-core", packageRoot)));
const { AssistantMessageEventStream } = await import(pathToFileURL(Bun.resolveSync("@oh-my-pi/pi-ai", packageRoot)));
const { getBundledModel } = await import(pathToFileURL(Bun.resolveSync("@oh-my-pi/pi-catalog", packageRoot)));
const agentDir = join(root, "isolated-agent");
mkdirSync(agentDir, { recursive: true });
const config = join(agentDir, "config.yml"), original = "providers:\n  openaiLiveSteering: true\n";
writeFileSync(config, original);
const settings = await sdk.Settings.loadReadOnly({ cwd: root, agentDir, configFiles: [join(root, "worker-overlay.json")] });
const child = sdk.createSubagentSettings(settings);
const grandchild = sdk.createSubagentSettings(child);
const restored = settings.restoreOverlay(child.overlayLayers());
let checks = 0;
function expect(value, message) { assert.ok(value, message); checks += 1; }
expect(cfgProvidersOpenaiLiveSteering.get(sdk.Settings.isolated()) === true, "Installed native default enables live steering");
for (const [name, current] of [["parent", settings], ["child", child], ["grandchild", grandchild], ["revived child", restored]]) {
    expect(cfgProvidersOpenaiLiveSteering.get(current) === false, `${name} inherits the production GUI overlay`);
}

const model = getBundledModel("openai-codex", "gpt-6.1-sol");
assert(model, "The selected installed OMP must contain the Codex model used by the reported session");
const usage = { input: 1, output: 1, cacheRead: 0, cacheWrite: 0, totalTokens: 2,
    cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0, total: 0 } };

// Exercise the installed native agent loop, with an injected stream instead of a
// model service. This verifies queue ownership/consumption, not server support.
for (const [name, current] of [["parent", settings], ["child", child], ["grandchild", grandchild]]) {
    const entered = Promise.withResolvers(), release = Promise.withResolvers();
    const contexts = [], requestOptions = [];
    let offered = 0;
    const wrapped = createSettingsAwareStreamFn(current, (_model, context, options) => {
        contexts.push(structuredClone(context.messages));
        requestOptions.push(options);
        const first = contexts.length === 1;
        const stream = new AssistantMessageEventStream();
        queueMicrotask(async () => {
            if (first) { entered.resolve(); await release.promise; }
            const message = { role: "assistant", api: model.api, provider: model.provider, model: model.id, usage,
                content: first ? [{ type: "toolCall", id: "boundary-call", name: "boundary", arguments: {} }]
                    : [{ type: "text", text: "Completed after the queued instruction" }],
                stopReason: first ? "toolUse" : "stop", timestamp: Date.now() };
            stream.push({ type: "start", partial: message });
            stream.push({ type: "done", reason: message.stopReason, message });
        });
        return stream;
    });
    const agent = new Agent({ initialState: { model, systemPrompt: ["Deterministic queue check"], tools: [{
        name: "boundary", label: "Boundary", description: "Deterministic tool boundary",
        parameters: { type: "object", properties: {}, additionalProperties: false },
        async execute() { return { content: [{ type: "text", text: "Boundary reached" }], details: {} }; },
    }] }, preferWebsockets: true, streamFn: (m, context, options) => {
        if (options?.liveSteering) offered += 1;
        return wrapped(m, context, options);
    } });
    const pendingText = `Queued instruction for ${name}`;
    let timeout;
    try {
        const run = agent.prompt("Initial assignment");
        await Promise.race([entered.promise, run.then(() => {
            if (!contexts.length) throw new Error(`Native loop ended before streaming: ${agent.state.error ?? "no error reported"}`);
        }), new Promise((_, reject) => {
            timeout = setTimeout(() => reject(new Error("Native stream did not start")), 15_000);
        })]);
        clearTimeout(timeout);
        agent.steer({ role: "user", content: [{ type: "text", text: pendingText }], timestamp: Date.now() });
        expect(!agent.state.messages.some(m => m.role === "user" && JSON.stringify(m.content).includes(pendingText)),
            `${name}: queued input is not consumed by an in-flight provider response`);
        release.resolve();
        await Promise.race([run, new Promise((_, reject) => {
            timeout = setTimeout(() => reject(new Error("Native queue did not settle")), 15_000);
        })]);
        expect(offered > 0 && requestOptions.every(options => options.liveSteering === undefined),
            `${name}: native settings suppress the offered live WebSocket steering source`);
        expect(requestOptions.every(options => options.preferWebsockets === true), `${name}: normal WebSocket transport remains enabled`);
        expect(contexts.length === 2 && contexts[1].filter(m => m.role === "user" && JSON.stringify(m.content).includes(pendingText)).length === 1,
            `${name}: the instruction reaches the next native request exactly once`);
        expect(agent.state.messages.filter(m => m.role === "user" && JSON.stringify(m.content).includes(pendingText)).length === 1,
            `${name}: native history retains one consumed instruction without loss or duplication`);
    } finally { clearTimeout(timeout); release.resolve(); agent.abort(); }
}
expect(readFileSync(config, "utf8") === original, "Session overlay and child inheritance preserve the isolated profile bytes");
writeFileSync(join(root, "summary.json"), JSON.stringify({ status: "passed", checks,
    boundary: "Installed OMP SDK and native agent loop with an injected stream; no model/network/GUI or live profile writes" }, null, 2));
console.log(`PASS native workers: ${checks} overlay, inherited settings and boundary-delivery checks`);
