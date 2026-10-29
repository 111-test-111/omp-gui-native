import assert from "node:assert/strict";
import { contextComposition } from "../../../OMPGUI/Resources/OMPContextComposition.js";
import { installContextCommands, installNativeContextInspection, contextResultPrefix } from "../../../OMPGUI/Resources/OMPContextControl.js";

const tokenizer = {
    countTokens: text => Array.from(typeof text === "string" ? text : text.join("")).length,
    countMessage(message) {
        const parts = typeof message.content === "string" ? [{ type: "text", text: message.content }] : message.content ?? [];
        return parts.reduce((n, p) => n + (p.type === "image" ? 1200 : p.type === "text" ? this.countTokens(p.text)
            : p.type === "thinking" ? this.countTokens(p.thinking) + (p.thinkingSignature ? 10 : 0)
                : p.type === "toolCall" ? this.countTokens(p.name) + this.countTokens(JSON.stringify(p.arguments)) : 0), 0);
    },
};
const convert = messages => messages.map(message => ["compactionSummary", "branchSummary", "custom"].includes(message.role)
    ? { role: "user", content: [{ type: "text", text: message.summary ?? message.content }], timestamp: message.timestamp } : message);
const projection = [
    { role: "compactionSummary", summary: "摘要", timestamp: 1 },
    { role: "custom", content: "扩展", timestamp: 2 },
    { role: "user", content: "original", timestamp: 3 },
    { role: "user", content: "duplicate", timestamp: 4 },
];
const context = { systemPrompt: ["系统指令🦋"], tools: [{ name: "read", description: "读取", parameters: { type: "object" }, execute() { throw Error("Must not execute"); } }],
    messages: [...convert(projection.slice(0, 2)), { role: "user", content: "changed", timestamp: 3 },
        projection[3], { ...projection[3] }, { role: "assistant", content: [{ type: "thinking", thinking: "reason", thinkingSignature: "opaque-secret" },
            { type: "text", text: "reply" }, { type: "toolCall", name: "read", arguments: { path: "file" } }] },
        { role: "toolResult", toolName: "read", content: [{ type: "text", text: "result" }, { type: "image", data: "unbounded-binary-is-not-text" }] }] };
const composition = contextComposition(context, tokenizer, projection, convert);
const category = kind => composition.categories.find(row => row.kind === kind);
assert.equal(composition.total, composition.categories.reduce((sum, row) => sum + row.tokens, 0));
assert.equal(category("summaries").tokens, 2);
assert.equal(category("extensions").tokens, 2);
assert.equal(category("requestOnly").tokens, "changedduplicate".length, "Edited content and a consumed duplicate cannot inherit saved provenance");
assert.equal(category("userText").tokens, 9);
assert.equal(category("images").tokens, 1200, "Image bytes never become text tokens");
assert.equal(category("other").tokens, 10, "Opaque native replay tokens stay separate from visible reasoning and system text");
assert.equal(category("thinking").tokens, 6);
assert.equal(category("toolResults").items[0].name, "read");
assert(!JSON.stringify(composition).includes("opaque-secret"));
assert(!JSON.stringify(composition).includes("unbounded-binary"));
assert.equal(contextComposition(context, null), null, "No native tokenizer must remain unavailable");
const names = contextComposition({ tools: Array.from({ length: 200 }, (_, i) => ({ name: "tool-" + i, description: "x", parameters: {} })) }, tokenizer);
assert.equal(names.categories[0].items.length, 8);
assert(names.categories[0].omittedItems > 0);
assert(names.total > names.categories[0].items.reduce((n, item) => n + item.tokens, 0), "Omitted names retain their category tokens");
const limited = contextComposition({ messages: Array.from({ length: 50001 }, () => ({ role: "user", content: "x" })) }, tokenizer);
assert.equal(limited.limited, true);
const empty = contextComposition({}, tokenizer); assert.equal(empty.total, 0);
const callable = { name: "native", description: "declared tool", parameters() {} };
assert.equal(contextComposition({ tools: [callable] }, tokenizer).limited, true, "Unavailable native schema conversion cannot claim complete coverage");
const normalized = contextComposition({ tools: [callable] }, tokenizer, [], undefined, () => ({ type: "object", properties: { path: { type: "string" } } }));
assert.equal(normalized.limited, false);
assert(normalized.total > contextComposition({ tools: [callable] }, tokenizer).total, "Callable native schemas must use the public wire-schema converter");

let command, listener, disposed = false;
installContextCommands({ registerCommand(name, definition) { assert.equal(name, "omp-gui-context"); command = definition; }, events: { emit(_, call) { listener?.(call); } } });
const notifications = [];
const ctx = { agent: { kind: "main" }, sessionManager: { getSessionId: () => "one" }, ui: { notify: text => notifications.push(JSON.parse(text.slice(contextResultPrefix.length))) } };
await command.handler('{"requestID":"unsupported"}', ctx);
assert.equal(notifications.at(-1).error, "unsupported");
const session = { sessionManager: { getSessionId: () => "one", getLeafId: () => "leaf" }, sessionFile: "/owned.jsonl", sessionId: "one", model: { id: "model" },
    agent: { tokenizer, state: { tools: [] } }, messages: [{ role: "user", content: "hello" }], systemPrompt: ["system"], autoCompactionEnabled: true,
    getContextBreakdown: () => ({ usedTokens: 123, anchored: true }), addDisposer: dispose => { session.dispose = dispose; } };
installNativeContextInspection(session, { on(_, handler) { listener = handler; return () => { disposed = true; listener = null; }; } }, convert);
await command.handler('{"requestID":"read"}', ctx);
assert.equal(notifications.at(-1).native.usedTokens, 123);
assert.equal(notifications.at(-1).sessionFile, "/owned.jsonl");
assert.equal(session.messages.length, 1, "Inspection cannot append to history");
await command.handler('{"requestID":"wrong"}', { ...ctx, sessionManager: { getSessionId: () => "other" } });
assert.equal(notifications.at(-1).error, "unsupported");
const before = notifications.length; await command.handler("malformed", ctx); assert.equal(notifications.length, before);
session.dispose(); assert.equal(disposed, true);
console.log("PASS context composition: native tokenizer, Unicode, exact provenance, images, opaque content, bounded names, category totals and read-only session fencing");
