import assert from "node:assert/strict";
import { mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { join, resolve } from "node:path";
import { pathToFileURL } from "node:url";
import { askDialogPrefix, installNativeAskDialog } from "../../OMPGUI/Resources/OMPAskDialog.js";

const root = resolve(process.argv[2]), packageRoot = resolve(process.argv[3]);
assert(root.includes("/build.noindex/verification/runs/"));
const { AskTool } = await import(pathToFileURL(join(packageRoot, "src/tools/ask.ts")));
const { Settings } = await import(pathToFileURL(join(packageRoot, "src/config/settings.ts")));
const { ensureTheme, stopThemeWatcher } = await import(pathToFileURL(Bun.resolveSync("@oh-my-pi/pi-tui/theme", packageRoot)));
await ensureTheme();
const fixtures = JSON.parse(readFileSync(join(root, "responses.json"), "utf8"));
const settings = Settings.isolated({ "ask.timeout": 0, "ask.notify": "off", "speech.enabled": false });
let checks = 0;
function expect(value, message) { assert.ok(value, message); checks += 1; }

// Feed Swift's actual serialized responses into the installed OMP AskTool.
// No model, provider request or GUI process participates.
for (const fixture of fixtures) {
    let requests = 0, aborts = 0;
    const ui = {
        async input(title) {
            requests += 1;
            expect(title.startsWith(askDialogPrefix), "Native ask uses the rich presentation envelope");
            const request = JSON.parse(title.slice(askDialogPrefix.length));
            assert.equal(request.questions.length, fixture.questions.length);
            return fixture.response.value;
        },
        select() { throw new Error("Ask must not fall back to repeated single-choice dialogs"); },
        editor() { throw new Error("Custom answers must remain in the same form"); },
    };
    installNativeAskDialog(ui);
    const result = await new AskTool({ hasUI: true, settings }).execute(fixture.name,
        { questions: fixture.questions }, undefined, undefined, { hasUI: true, ui, abort() { aborts += 1; } });
    expect(aborts === 0 && requests === 1 && !result.isError, "One whole form returns without aborting the turn");
    if (fixture.name === "mixed") {
        assert.deepEqual(result.details.results[1].selectedOptions, ["A", "B"]);
        assert.equal(result.details.results[0].customInput, "B");
        expect(result.details.results[3].note.includes("skipped") || result.details.results[3].note.includes("跳过"),
            "Native tool output tells the model that the user skipped a question");
    } else {
        const rows = result.details.results ?? [result.details];
        expect(rows.every(row => row.selectedOptions.length === 0 && row.customInput === "" && row.note),
            "Single-choice, multi-choice and free-input skips do not invent an answer");
    }
}

const timedUI = { async input(_title, _placeholder, options) { options.onTimeout(); return undefined; } };
installNativeAskDialog(timedUI);
const timed = await timedUI.askDialog(fixtures[0].questions, { timeout: 5 });
expect(timed.results.every(row => row.timedOut), "Native timeout is distinct from an explicit skip");
assert.deepEqual(timed.results[0].selectedOptions, ["B"]);
assert.deepEqual(timed.results[1].selectedOptions, ["A"]);
expect(timed.results[2].customInput === "", "An optionless timeout is a valid native result");
const cancelledUI = { async input() { return undefined; } };
installNativeAskDialog(cancelledUI);
expect(await cancelledUI.askDialog(fixtures[0].questions) === undefined, "Actual native cancellation remains cancellation");
const nativeAsk = async () => ({ kind: "chat" });
const futureUI = { askDialog: nativeAsk, input() { throw new Error("Native rich UI must take precedence"); } };
installNativeAskDialog(futureUI);
expect(futureUI.askDialog === nativeAsk, "A future native ask implementation is preserved");
let enabledNativeAsk;
const nativePrototype = Object.defineProperty({}, "askDialog", { get() { return enabledNativeAsk; } });
const getterUI = Object.assign(Object.create(nativePrototype), {
    input() { throw new Error("A native read-only ask getter must never acquire a shim"); },
});
const nativeGetter = Object.getOwnPropertyDescriptor(nativePrototype, "askDialog").get;
assert.doesNotThrow(() => installNativeAskDialog(getterUI));
expect(getterUI.askDialog === undefined && !Object.hasOwn(getterUI, "askDialog"),
    "A disabled native prototype getter stays undefined without assignment or shadowing");
expect(Object.getOwnPropertyDescriptor(nativePrototype, "askDialog").get === nativeGetter,
    "Installing presentation support preserves the native read-only getter itself");
enabledNativeAsk = nativeAsk;
installNativeAskDialog(getterUI);
expect(getterUI.askDialog === nativeAsk && !Object.hasOwn(getterUI, "askDialog"),
    "Native opt-in exposes its original function after the disabled getter was observed");
const malformed = { async input() { return '{"kind":"submit","results":[]}'; } };
installNativeAskDialog(malformed);
await assert.rejects(malformed.askDialog(fixtures[0].questions), /Invalid OMP GUI ask response/);

// Also start the shipped SDK host against an isolated native CLI profile. Its
// public UI callback must enrich the very context used by extension commands.
// A synthetic provider only satisfies native startup; commands never call it.
mkdirSync(join(root, "config/agent"), { recursive: true });
const extension = join(root, "native-check.ts");
writeFileSync(extension, `
import { readFileSync } from "node:fs";
import { AskTool } from ${JSON.stringify(join(packageRoot, "src/tools/ask.ts"))};
import { Settings } from ${JSON.stringify(join(packageRoot, "src/config/settings.ts"))};
const fixtures = JSON.parse(readFileSync(${JSON.stringify(join(root, "responses.json"))}, "utf8"));
export default function(omp) {
    omp.registerProvider("omp-gui-ask-check", {
        baseUrl: "https://example.invalid/no-model-calls", api: "openai-completions", apiKey: "synthetic-only",
        models: [{ id: "fixture", name: "Local fixture", reasoning: false, input: ["text"],
            cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 }, contextWindow: 8192, maxTokens: 128 }],
    });
    omp.registerCommand("omp-gui-ask-check", {
        description: "Local native ask verification",
        async handler(args, ctx) {
            if (args.trim() === "generic") {
                const selected = await ctx.ui.select("Regular selection", ["A", "B"]);
                const confirmed = await ctx.ui.confirm("Regular confirmation", "Continue?");
                const text = await ctx.ui.input("Regular input");
                const edited = await ctx.ui.editor("Regular editor", "  before\\nafter\\n");
                ctx.ui.notify("OMP_GUI_ASK_CHECK:" + JSON.stringify({ name: "generic", selected, confirmed, text, edited }));
                return;
            }
            if (args.trim() === "abort") {
                const value = await ctx.ui.askDialog(fixtures[0].questions, { signal: AbortSignal.timeout(30) });
                ctx.ui.notify("OMP_GUI_ASK_CHECK:" + JSON.stringify({ name: "abort", aborted: value === undefined }));
                return;
            }
            const fixture = fixtures[Number(args.trim())];
            let aborts = 0;
            const settings = Settings.isolated({ "ask.timeout": 0, "ask.notify": "off", "speech.enabled": false });
            const result = await new AskTool({ hasUI: true, settings }).execute(fixture.name,
                { questions: fixture.questions }, undefined, undefined,
                { hasUI: true, ui: ctx.ui, abort() { aborts += 1; } });
            ctx.ui.notify("OMP_GUI_ASK_CHECK:" + JSON.stringify({ name: fixture.name, aborts, result }));
        },
    });
}
`);
const environment = { ...process.env, OMP_GUI_NATIVE_EXECUTABLE: join(packageRoot, "dist/cli.js"),
    PI_CONFIG_DIR: join(root, "config"), PI_CODING_AGENT_DIR: join(root, "config/agent"),
    OMP_PROFILE: "default", PI_PROFILE: "default" };
delete environment.PI_CONFIG_FILES;
// The runner passes the worktree's built host explicitly; fixture outputs may
// move independently of development products.
const host = resolve(process.argv[4]);
const child = Bun.spawn(["bun", host, "--mode", "rpc-ui", "--no-title", "--model", "omp-gui-ask-check/fixture",
    "--session-dir", join(root, "sessions"), "--extension", extension],
    { cwd: root, env: environment, stdin: "pipe", stdout: "pipe", stderr: "pipe" });
const frames = [];
let current, nativeAskEnabled = false;
const askRequests = { ask: 0, input: 0 }, fixtureTransports = new Map();
const send = frame => child.stdin.write(JSON.stringify(frame) + "\n");
let readerError;
const stderr = new Response(child.stderr).text();
const reader = (async () => {
    let buffer = "";
    const decoder = new TextDecoder();
    for await (const chunk of child.stdout) {
        buffer += decoder.decode(chunk, { stream: true });
        for (;;) {
            const end = buffer.indexOf("\n");
            if (end < 0) break;
            const line = buffer.slice(0, end); buffer = buffer.slice(end + 1);
            if (!line.trim()) continue;
            const frame = JSON.parse(line);
            frames.push(frame);
            if (frame.type !== "extension_ui_request") continue;
            if (frame.method === "ask" || (frame.method === "input" && frame.title?.startsWith(askDialogPrefix))) {
                if (current === "abort") continue;
                const fixture = fixtures[current];
                assert.ok(fixture, "A rich request belongs to the currently running fixture");
                const questions = frame.method === "ask" ? frame.questions
                    : JSON.parse(frame.title.slice(askDialogPrefix.length)).questions;
                assert.deepEqual(questions.map(question => question.id), fixture.questions.map(question => question.id));
                assert.ok(!fixtureTransports.has(current), "Each fixture emits only one whole-form request");
                fixtureTransports.set(current, frame.method);
                askRequests[frame.method] += 1;
                const response = frame.method === "ask" ? fixture.nativeResponse : fixture.response;
                assert.ok(response, "Use Swift's actual response for the native request shape");
                if (frame.method === "ask") assert.equal(response.answers.length, fixture.questions.length);
                send({ ...response, id: frame.id });
            } else if (["select", "confirm", "input", "editor"].includes(frame.method)) {
                assert.equal(current, "generic", "Rich ask must never produce legacy select/editor requests");
                send({ type: "extension_ui_response", id: frame.id,
                    ...(frame.method === "confirm" ? { confirmed: true }
                        : { value: frame.method === "select" ? "B" : frame.method === "editor" ? "  kept\n最后一行\n" : "typed" }) });
            }
        }
    }
})().catch(error => { readerError = error; });
async function waitFor(predicate) {
    const deadline = Date.now() + 30000;
    while (Date.now() < deadline) {
        if (readerError) throw readerError;
        const result = frames.find(predicate);
        if (result) return result;
        if (child.exitCode !== null) throw new Error("Native CLI exited: " + await stderr);
        await Bun.sleep(10);
    }
    throw new Error("Native CLI verification timed out");
}
try {
    send({ type: "get_state", id: "ready" });
    expect((await waitFor(frame => frame.type === "response" && frame.id === "ready")).success,
        "The actual SDK host reaches native RPC startup");
    send({ type: "set_ask_dialog", id: "enable-native-ask", enabled: true });
    const enabled = await waitFor(frame => frame.type === "response" && frame.id === "enable-native-ask");
    if (enabled.success) {
        expect(enabled.data?.enabled === true, "The actual native RPC confirms whole-form ask opt-in");
        nativeAskEnabled = true;
    } else {
        expect(enabled.success === false && ["Unknown command: set_ask_dialog", "Unknown command"].includes(enabled.error),
            "An explicitly older runtime retains the rich input-envelope compatibility path");
    }
    for (const index of [...fixtures.keys(), "generic", "abort"]) {
        current = index;
        const name = typeof index === "number" ? fixtures[index].name : index;
        send({ type: "prompt", id: "check-" + index, message: "/omp-gui-ask-check " + index });
        const frame = await waitFor(frame => frame.method === "notify" && frame.message?.startsWith("OMP_GUI_ASK_CHECK:")
            && JSON.parse(frame.message.slice("OMP_GUI_ASK_CHECK:".length)).name === name);
        const value = JSON.parse(frame.message.slice("OMP_GUI_ASK_CHECK:".length));
        if (index === "generic") {
            assert.deepEqual(value, { name: "generic", selected: "B", confirmed: true, text: "typed", edited: "  kept\n最后一行\n" });
        } else if (index === "abort") {
            expect(value.aborted && frames.some(frame => frame.method === "cancel"), "Native signals cancel the pending remote card");
        } else {
            expect(value.aborts === 0 && !value.result.isError, "Skipped native asks return normally and later commands still work");
            const fixture = fixtures[index], transport = fixtureTransports.get(index);
            const expected = transport === "ask" ? fixture.nativeResponse.answers : JSON.parse(fixture.response.value).results;
            const rows = value.result.details.results ?? [value.result.details];
            assert.equal(rows.length, fixture.questions.length);
            for (const [answerIndex, answer] of expected.entries()) {
                assert.deepEqual(rows[answerIndex].selectedOptions, answer.selectedOptions);
                assert.equal(rows[answerIndex].customInput,
                    transport === "ask" ? answer.customInput?.trim() || undefined : answer.customInput);
            }
            const skipped = JSON.parse(fixture.response.value).results.filter(answer => answer.note);
            expect(skipped.every(answer => transport === "ask"
                ? rows.some(row => row.customInput === answer.note)
                    && value.result.content.some(block => block.type === "text" && block.text.includes(answer.note))
                : rows.some(row => row.note === answer.note)),
                "The actual native tool preserves Swift's explicit non-answer marker without cancellation");
        }
    }
    expect(askRequests.ask + askRequests.input === fixtures.length, "Exactly one native dialog is emitted for each question batch");
    expect(nativeAskEnabled ? askRequests.ask === fixtures.length : askRequests.input === fixtures.length,
        "Native opt-in uses structured ask frames while older runtimes retain rich input frames");
} finally {
    child.kill("SIGTERM");
    await child.exited;
    await reader;
}
console.log(`Installed OMP AskTool and real SDK/RPC checks passed: ${checks}`);
stopThemeWatcher();
process.exit(0);
