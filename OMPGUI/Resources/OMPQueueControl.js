// The GUI only admits/removes messages. OMP's AgentSession owns preprocessing,
// queue ordering, continuation, tools and the actual agent loop.
export const queueControlCommand = "omp-gui-queue";
export const queueControlChannel = "omp-gui:queue-control";
export const queueControlResultPrefix = "OMP_GUI_QUEUE_RESULT:";

// OMP's queuedMessageCount also includes nextTurn context (for example a
// todo-error reminder). That context waits for the next explicit prompt and
// is not itself a running job. Observe native idle through the public SDK,
// without draining, deleting or persisting any of OMP's queues ourselves.
export function installNativeIdleObserver(session, output) {
    if (![session?.subscribe, session?.waitForIdle, session?.hasPendingAsyncWork,
        session?.agent?.peekSteeringQueue, session?.agent?.peekFollowUpQueue].every(value => typeof value === "function")) return () => {};
    let revision = 0;
    const sample = async (expected, file) => {
        try {
            // Run outside the subscription callback: OMP's idle barrier waits
            // for event handlers, recovery and native post-prompt continuations.
            await session.waitForIdle();
            await new Promise(resolve => setImmediate(resolve));
            if (revision !== expected || session.sessionFile !== file || !file) return;
            // Require positive evidence for every public busy flag. An older
            // SDK with missing fields must keep the ordinary RPC protection.
            if (![session.isStreaming, session.isCompacting, session.isRetrying,
                session.hasAdmittedSubmission, session.hasPostPromptWork,
                session.hasPendingAsyncWork()].every(value => value === false)) return;
            if (session.agent.peekSteeringQueue().length || session.agent.peekFollowUpQueue().length) return;
            const count = session.queuedMessageCount;
            if (!Number.isSafeInteger(count) || count <= 0) return;
            output({ type: "omp_gui_deferred_context", sessionFile: file, queuedMessageCount: count });
        } catch {
            // Unknown idle state never releases work or process protection.
        }
    };
    const unsubscribe = session.subscribe(event => {
        if (["agent_start", "auto_compaction_start", "manual_compaction_start", "auto_retry_start"].includes(event.type)) revision += 1;
        else if ((event.type === "agent_end" && event.isTerminal !== false)
            || ["auto_compaction_end", "manual_compaction_end", "auto_retry_end"].includes(event.type)) {
            const expected = ++revision;
            const file = session.sessionFile;
            void Promise.resolve().then(() => sample(expected, file));
        }
    });
    return () => { revision += 1; unsubscribe(); };
}

// Check and replace happen synchronously in the native agent's event loop. In
// particular, a message already committed to delivery cannot be recalled.
export function removeQueuedFollowUp(agent, target, companions = []) {
    const followUp = agent.peekFollowUpQueue();
    if (!target || !followUp.includes(target)) return false;
    const removed = new Set([target, ...companions]);
    const steering = agent.peekSteeringQueue();
    agent.replaceQueues(steering.slice(), followUp.filter(message => !removed.has(message)));
    return true;
}

function messageText(message) {
    if (typeof message.content === "string") return message.content;
    return message.content?.filter(part => part.type === "text").map(part => part.text).join("") ?? "";
}

// Deliberately retain object identities, never a text-match removal rule. An
// ambiguous admission remains accepted but cannot remove some other message.
export function identifyQueuedFollowUp(agent, before, expectedText, isCompanion) {
    const queue = agent.peekFollowUpQueue();
    const matches = queue.filter(message => !before.has(message) && message.role === "user" && messageText(message) === expectedText);
    if (matches.length !== 1) return { target: undefined, companions: [], ambiguous: matches.length > 1 };
    const target = matches[0];
    const companions = [];
    for (let index = queue.indexOf(target) - 1; index >= 0; index--) {
        const message = queue[index];
        if (before.has(message) || !isCompanion(message)) break;
        companions.push(message);
    }
    return { target, companions, ambiguous: false };
}

export function installNativeQueueControls(session, eventBus, expandPromptTemplate, isHiddenUserCompanion) {
    if (![session?.followUp, session?.agent?.peekFollowUpQueue, session?.agent?.peekSteeringQueue,
        session?.agent?.replaceQueues, session?.sessionManager?.getSessionId, eventBus?.on,
        expandPromptTemplate, isHiddenUserCompanion].every(value => typeof value === "function")
        || !session.promptTemplates?.[Symbol.iterator]) return () => {};
    const submissions = new Map();
    const removedSubmissions = new Map();
    const sessionID = () => session.sessionManager.getSessionId();
    const isCompanion = message => isHiddenUserCompanion(message)
        || (message.role === "custom" && message.attribution === "user" && message.display === false
            && ["image-attachment", "video-attachment"].includes(message.customType));
    const prune = () => {
        const pending = new Set(session.agent.peekFollowUpQueue());
        for (const [id, value] of submissions) {
            if (value.sessionID !== sessionID() || (value.target && !pending.has(value.target))) submissions.delete(id);
        }
    };
    return eventBus.on(queueControlChannel, async request => {
        if (!request || typeof request.respond !== "function" || request.sessionID !== sessionID()) return;
        request.handled = true;
        const { requestID, operation } = request;
        const reply = fields => request.respond({ requestID, operation, ...fields });
        try {
            if (operation === "hello") {
                reply({ success: true, protocolVersion: 1 });
                return;
            }
            if (typeof request.submissionID !== "string" || !request.submissionID) throw new Error("invalid_submission");
            prune();
            const retired = removedSubmissions.get(request.submissionID);
            if (retired === sessionID()) {
                if (operation === "remove_follow_up") reply({ success: true, removed: true });
                else throw new Error("already_submitted");
                return;
            }
            if (operation === "follow_up") {
                if (typeof request.message !== "string" || !Array.isArray(request.images ?? [])) throw new Error("invalid_message");
                if (submissions.has(request.submissionID)) throw new Error("already_submitted");
                // Reserve before awaiting native image preparation; duplicate admission
                // requests never enqueue the same GUI submission twice.
                const origin = sessionID();
                submissions.set(request.submissionID, { sessionID: origin });
                const before = new Set(session.agent.peekFollowUpQueue());
                const expectedText = expandPromptTemplate(request.message, [...session.promptTemplates]);
                try {
                    await session.followUp(request.message, request.images);
                } catch (error) {
                    submissions.delete(request.submissionID);
                    throw error;
                }
                if (origin !== sessionID()) {
                    submissions.delete(request.submissionID);
                    reply({ success: false, deliveryUnknown: true, error: "session_changed" });
                    return;
                }
                submissions.set(request.submissionID, { sessionID: origin,
                    ...identifyQueuedFollowUp(session.agent, before, expectedText, isCompanion) });
                reply({ success: true });
                return;
            }
            if (operation === "remove_follow_up") {
                const value = submissions.get(request.submissionID);
                if (value?.ambiguous) throw new Error("identity_unknown");
                const removed = value?.sessionID === sessionID()
                    && removeQueuedFollowUp(session.agent, value.target, value.companions);
                if (removed) {
                    removedSubmissions.set(request.submissionID, sessionID());
                    if (removedSubmissions.size > 512) removedSubmissions.delete(removedSubmissions.keys().next().value);
                }
                if (removed || !value?.target) submissions.delete(request.submissionID);
                reply({ success: true, removed: removed === true });
                return;
            }
            throw new Error("unsupported_operation");
        } catch (error) {
            reply({ success: false, error: error instanceof Error ? error.message : String(error) });
        }
    });
}

// Uses OMP's ordinary extension command transport. The callback is private to
// this process's event bus; only the result envelope crosses native RPC UI.
export function installQueueCommands(omp) {
    omp.registerCommand(queueControlCommand, {
        description: "OMP GUI native queue controls",
        async handler(args, ctx) {
            let request;
            try { request = JSON.parse(args); } catch { return; }
            if (typeof request?.requestID !== "string" || typeof request.operation !== "string") return;
            let respond;
            const result = new Promise(resolve => { respond = resolve; });
            const call = { ...request, sessionID: ctx.sessionManager.getSessionId(), handled: false, respond };
            if (ctx.agent.kind === "main") omp.events.emit(queueControlChannel, call);
            if (!call.handled) respond({ requestID: request.requestID, operation: request.operation, success: false, error: "unsupported" });
            ctx.ui.notify(queueControlResultPrefix + JSON.stringify(await result), "info");
        },
    });
}
