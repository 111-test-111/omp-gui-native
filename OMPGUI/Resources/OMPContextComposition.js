// Metadata only, measured before capture redaction/clipping. Native tokenizer
// counts are estimates of SDK content, never provider billing or wire tokens.
export const compositionLimits = Object.freeze({ messages: 50000, parts: 100000, items: 8, name: 160 });
const count = value => Number.isSafeInteger(value) && value >= 0 ? value : undefined;
export function contextComposition(context, tokenizer, projection = [], convertToLlm, toolWireSchema) {
    if (!context || typeof tokenizer?.countTokens !== "function" || typeof tokenizer?.countMessage !== "function") return null;
    const categories = new Map();
    let visited = 0, limited = false;
    const add = (kind, tokens, name) => {
        if (!tokens) return;
        if (count(tokens) === undefined) throw new Error("Invalid native token count");
        let row = categories.get(kind);
        if (!row) categories.set(kind, row = { kind, tokens: 0, items: new Map(), omittedItems: 0 });
        row.tokens += tokens;
        if (name) {
            name = String(name).slice(0, compositionLimits.name);
            if (row.items.has(name) || row.items.size < 128) row.items.set(name, (row.items.get(name) ?? 0) + tokens);
            else row.omittedItems++;
        }
    };
    const textTokens = text => typeof text === "string" ? tokenizer.countTokens(text) : 0;
    // Exact converted content + timestamp, consuming duplicates once. A changed
    // request message cannot inherit the saved original's provenance.
    const origins = new Map();
    if (typeof convertToLlm === "function") for (const message of projection.slice(0, compositionLimits.messages)) {
        for (const converted of convertToLlm([message])) {
            if (converted.role !== "user") continue;
            const candidates = origins.get(converted.timestamp) ?? [];
            candidates.push({ content: converted.content, role: message.role });
            origins.set(converted.timestamp, candidates);
        }
    }
    const equal = (a, b) => typeof a === "string" || typeof b === "string" ? a === b
        : Array.isArray(a) && Array.isArray(b) && a.length === b.length && a.every((part, i) =>
            part.type === b[i]?.type && (part.type === "text" ? part.text === b[i].text
                : part.type === "image" && part.mimeType === b[i].mimeType && part.data === b[i].data));
    const system = Array.isArray(context.systemPrompt) ? context.systemPrompt : [context.systemPrompt ?? ""];
    system.forEach((block, index) => add("system", textTokens(block), `#${index + 1}`));
    for (const tool of context.tools ?? []) {
        if (++visited > compositionLimits.parts) { limited = true; break; }
        // Count only the provider-facing declaration. Functions and runtime
        // metadata on live native tool objects are never serialized.
        const parameters = typeof toolWireSchema === "function" ? toolWireSchema(tool) : tool.parameters;
        if (typeof parameters === "function") limited = true;
        const schema = { name: tool.name, description: tool.description, parameters,
            ...(tool.examples ? { examples: tool.examples } : {}) };
        add("toolSchemas", textTokens(JSON.stringify(schema)), tool.name);
    }
    const messages = context.messages ?? [];
    if (messages.length > compositionLimits.messages) limited = true;
    for (const message of messages.slice(0, compositionLimits.messages)) {
        if (++visited > compositionLimits.parts) { limited = true; break; }
        if (message.excludeFromContext === true) continue;
        let role = message.role;
        if (role === "user" && typeof convertToLlm === "function") {
            const candidates = origins.get(message.timestamp);
            const index = candidates?.findIndex(candidate => equal(candidate.content, message.content)) ?? -1;
            role = index < 0 ? "requestOnly" : candidates.splice(index, 1)[0].role;
        }
        const textKind = role === "assistant" ? "assistantText" : role === "toolResult" ? "toolResults"
            : ["compactionSummary", "branchSummary"].includes(role) ? "summaries"
            : ["custom", "hookMessage", "fileMention"].includes(role) ? "extensions"
            : ["bashExecution", "pythonExecution"].includes(role) ? "shell"
            : role === "requestOnly" ? "requestOnly" : role === "user" ? "userText" : "other";
        const parts = [];
        const content = typeof message.content === "string" ? [{ type: "text", text: message.content }] : message.content ?? [];
        for (const part of content) {
            if (++visited > compositionLimits.parts) { limited = true; break; }
            if (part.type === "text") parts.push({ kind: textKind, tokens: textTokens(part.text), name: role === "toolResult" ? message.toolName : undefined });
            else if (part.type === "thinking") parts.push({ kind: "thinking", tokens: textTokens(part.thinking) });
            else if (part.type === "toolCall") parts.push({ kind: "toolCalls", tokens: textTokens(part.name) + textTokens(JSON.stringify(part.arguments)), name: part.name });
            else if (part.type === "image") parts.push({ kind: "images", tokens: tokenizer.countMessage({ role: "user", content: [part], timestamp: 0 }) });
        }
        const total = count(tokenizer.countMessage(message));
        if (total === undefined) throw new Error("Invalid native message count");
        const sum = parts.reduce((n, part) => n + part.tokens, 0);
        // Native message framing/opaque reasoning stays separate. If token
        // boundaries make parts exceed the native count, apportion that count.
        if (sum > total) {
            const assigned = parts.map(part => Math.floor(part.tokens * total / sum));
            let remainder = total - assigned.reduce((a, b) => a + b, 0);
            const order = parts.map((part, i) => ({ i, fraction: part.tokens * total / sum - assigned[i] }))
                .sort((a, b) => b.fraction - a.fraction || a.i - b.i);
            for (let i = 0; i < remainder; i++) assigned[order[i].i]++;
            parts.forEach((part, i) => add(part.kind, assigned[i], part.name));
        } else {
            parts.forEach(part => add(part.kind, part.tokens, part.name));
            add("other", total - sum);
        }
    }
    const rows = [...categories.values()].map(row => {
        const items = [...row.items].sort((a, b) => b[1] - a[1] || a[0].localeCompare(b[0]));
        return { kind: row.kind, tokens: row.tokens, items: items.slice(0, compositionLimits.items).map(([name, tokens]) => ({ name, tokens })),
            omittedItems: row.omittedItems + Math.max(0, items.length - compositionLimits.items) };
    });
    return { total: rows.reduce((n, row) => n + row.tokens, 0), categories: rows, limited };
}
