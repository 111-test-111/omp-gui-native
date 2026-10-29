import { contextComposition } from "./OMPContextComposition.js";
export const contextControlCommand = "omp-gui-context";
const channel = "omp-gui:context-control";
export const contextResultPrefix = "OMP_GUI_CONTEXT_RESULT:";

export function installContextCommands(omp) {
    omp.registerCommand(contextControlCommand, {
        description: "OMP GUI context inspection",
        async handler(args, ctx) {
            let request;
            try { request = JSON.parse(args); } catch { return; }
            if (typeof request?.requestID !== "string" || request.requestID.length > 128) return;
            let respond;
            const result = new Promise(resolve => { respond = resolve; });
            const call = { requestID: request.requestID, sessionID: ctx.sessionManager.getSessionId(), handled: false, respond };
            if (ctx.agent.kind === "main") omp.events.emit(channel, call);
            if (!call.handled) respond({ requestID: request.requestID, success: false, error: "unsupported" });
            ctx.ui.notify(contextResultPrefix + JSON.stringify(await result), "info");
        },
    });
}

// Read public SDK state in the existing native process. No model request,
// transcript entry, configuration change or independently scheduled worker.
export function installNativeContextInspection(session, eventBus, convertToLlm, toolWireSchema) {
    if (typeof session?.getContextBreakdown !== "function" || !eventBus?.on) return;
    const off = eventBus.on(channel, request => {
        if (request.sessionID !== session.sessionManager.getSessionId()) return;
        request.handled = true;
        try {
            const tokenizer = session.agent.tokenizer;
            const messages = session.messages;
            const composition = contextComposition({ systemPrompt: session.systemPrompt, tools: session.agent.state.tools,
                messages: typeof convertToLlm === "function" ? convertToLlm(messages) : messages }, tokenizer, messages, convertToLlm, toolWireSchema);
            request.respond({ requestID: request.requestID, success: true, protocolVersion: 1,
                sessionFile: session.sessionFile, sessionID: session.sessionId, leafID: session.sessionManager.getLeafId(),
                timestamp: Date.now(), model: session.model?.id, provider: session.model?.provider,
                native: session.getContextBreakdown(), composition, autoCompaction: session.autoCompactionEnabled });
        } catch { request.respond({ requestID: request.requestID, success: false, error: "inspection_failed" }); }
    });
    session.addDisposer?.(off);
    return off;
}
