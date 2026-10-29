#!/usr/bin/env node
import assert from "node:assert/strict";
import {
    identifyQueuedFollowUp,
    installNativeIdleObserver,
    installNativeQueueControls,
    queueControlChannel,
    removeQueuedFollowUp,
} from "../../../OMPGUI/Resources/OMPQueueControl.js";

let checks = 0;
function expect(value, message) {
    assert.ok(value, message);
    checks += 1;
}

function user(text, image = "") {
    return { role: "user", content: [{ type: "text", text }, ...(image ? [{ type: "image", data: image }] : [])] };
}
function companion(name) {
    return { role: "custom", attribution: "user", display: false, customType: "image-attachment", content: name };
}
function agent(followUp = [], steering = []) {
    return {
        followUp, steering, replacements: 0,
        peekFollowUpQueue() { return this.followUp; },
        peekSteeringQueue() { return this.steering; },
        replaceQueues(nextSteering, nextFollowUp) {
            this.replacements += 1;
            this.steering = nextSteering;
            this.followUp = nextFollowUp;
        },
    };
}

// Identical prose and image payloads do not identify a queue entry. Only the
// exact admitted object and its native hidden companions may be removed.
const old = user("same", "one"), target = user("same", "one"), twin = user("same", "one");
const targetImage = companion("target"), twinImage = companion("twin"), steering = user("steering");
const nativeAgent = agent([old, targetImage, target, twinImage, twin], [steering]);
expect(removeQueuedFollowUp(nativeAgent, target, [targetImage]), "An actual pending object can be withdrawn");
expect(nativeAgent.followUp.length === 3 && nativeAgent.followUp[0] === old
    && nativeAgent.followUp[1] === twinImage && nativeAgent.followUp[2] === twin,
    "Withdrawal preserves older and identical remaining objects and their images");
expect(nativeAgent.steering.length === 1 && nativeAgent.steering[0] === steering,
    "Steering survives native queue replacement with its object identity intact");
expect(nativeAgent.replacements === 1, "Native replacement is one synchronous operation");
expect(!removeQueuedFollowUp(nativeAgent, target, [twinImage]) && nativeAgent.replacements === 1,
    "A consumed target cannot remove remaining messages or companions");
expect(!removeQueuedFollowUp(nativeAgent, user("same", "one")) && nativeAgent.replacements === 1,
    "An equal payload is insufficient authority to remove a native message");

const admitted = identifyQueuedFollowUp(agent([old, targetImage, target]), new Set([old]), "same", message => message.role === "custom");
expect(admitted.target === target && admitted.companions.length === 1 && admitted.companions[0] === targetImage,
    "Admission identifies only the new object and its contiguous native companions");
const ambiguous = identifyQueuedFollowUp(agent([target, twin]), new Set(), "same", () => false);
expect(ambiguous.ambiguous && !ambiguous.target && ambiguous.companions.length === 0,
    "Ambiguous admission never chooses an arbitrary identical message");

// Exercise the installed native bus handler as well as the pure queue helpers.
// The fake session owns admission, image companions, session identity and races.
let sessionID = "session-one";
const session = {
    agent: agent([], [steering]),
    sessionManager: { getSessionId: () => sessionID },
    promptTemplates: [],
    async followUp(text, images = []) {
        for (const image of images) this.agent.followUp.push(companion(image.data));
        this.agent.followUp.push(user(text.replace("$template", "expanded template"), images[0]?.data));
    },
};
let handler;
const bus = { on(channel, callback) { assert.equal(channel, queueControlChannel); handler = callback; return () => {}; } };
installNativeQueueControls(session, bus, text => text.replace("$template", "expanded template"), () => false);
let sequence = 0;
async function control(operation, submissionID, extra = {}) {
    let outcome;
    const request = { operation, requestID: `request-${++sequence}`, submissionID,
        sessionID, handled: false, ...extra, respond(value) { outcome = value; } };
    await handler(request);
    expect(request.handled && outcome?.requestID === request.requestID && outcome.operation === operation,
        "Native outcome is correlated to the explicit queue operation");
    return outcome;
}

expect((await control("hello")).protocolVersion === 1, "Native handshake confirms the queue protocol");
const firstImage = { type: "image", mimeType: "image/png", data: "same-image" };
expect((await control("follow_up", "first", { message: "$template", images: [firstImage] })).success,
    "Native session admits image follow-ups using native template expansion");
const firstTarget = session.agent.followUp.at(-1), firstCompanion = session.agent.followUp.at(-2);
expect((await control("follow_up", "second", { message: "$template", images: [firstImage] })).success,
    "A later identical follow-up has its own native identity");
const secondTarget = session.agent.followUp.at(-1), secondCompanion = session.agent.followUp.at(-2);
expect((await control("follow_up", "first", { message: "duplicate" })).error === "already_submitted"
    && session.agent.followUp.length === 4, "Duplicate submission IDs cannot enqueue another native message");
expect((await control("remove_follow_up", "first")).removed === true, "The native handler confirms actual removal");
expect(!session.agent.followUp.includes(firstTarget) && !session.agent.followUp.includes(firstCompanion)
    && session.agent.followUp[0] === secondCompanion && session.agent.followUp[1] === secondTarget,
    "An identical remaining follow-up retains its own image and exact queue identity");
const afterRemoval = session.agent.replacements;
expect((await control("remove_follow_up", "first")).removed === true && session.agent.replacements === afterRemoval,
    "A retried confirmed withdrawal is idempotent and cannot remove another message");

// OMP may consume the target before the GUI's request arrives. A remaining
// identical payload must never be substituted for that consumed identity.
session.agent.followUp = [];
expect((await control("follow_up", "third", { message: "$template", images: [firstImage] })).success,
    "A new identical message can be admitted after earlier consumption");
const thirdTarget = session.agent.followUp.at(-1);
expect((await control("remove_follow_up", "second")).removed === false
    && session.agent.followUp.at(-1) === thirdTarget,
    "Consumption winning withdrawal returns false and preserves a later identical input");
sessionID = "session-two";
expect((await control("remove_follow_up", "third")).removed === false
    && session.agent.followUp.at(-1) === thirdTarget,
    "Session replacement invalidates old submission ownership");

// Native image preparation can suspend. Reservation must prevent a second
// identical submission request from entering while the first is awaiting it.
let resumeImagePreparation;
const originalFollowUp = session.followUp;
session.followUp = async function(text, images) {
    await new Promise(resolve => { resumeImagePreparation = resolve; });
    await originalFollowUp.call(this, text, images);
};
const pending = control("follow_up", "pending", { message: "after image preparation", images: [firstImage] });
expect((await control("follow_up", "pending", { message: "after image preparation", images: [firstImage] })).error === "already_submitted",
    "Native image preparation retains the submission reservation");
resumeImagePreparation();
expect((await pending).success && (await control("remove_follow_up", "pending")).removed === true,
    "The original admission remains retractable after image preparation finishes");

let unhandledResponse = false;
const wrongSession = { operation: "hello", requestID: "wrong-session", sessionID: "another-session",
    handled: false, respond() { unhandledResponse = true; } };
await handler(wrongSession);
expect(!wrongSession.handled && !unhandledResponse, "Queue controls cannot cross native session boundaries");

// A failed native todo can leave nextTurn context after the agent is done.
// Idle observation must not delete it or hide actual queued/background work.
let listener, idleBarrier = Promise.resolve(), asyncWork = false;
const idleSession = {
    agent: agent(), sessionFile: "idle-one.jsonl", queuedMessageCount: 1,
    isStreaming: false, isCompacting: false, isRetrying: false,
    hasAdmittedSubmission: false, hasPostPromptWork: false,
    hasPendingAsyncWork: () => asyncWork,
    waitForIdle: () => idleBarrier,
    subscribe(callback) { listener = callback; return () => { listener = undefined; }; },
};
const observations = [];
const unsubscribe = installNativeIdleObserver(idleSession, frame => observations.push(frame));
const flushIdle = async () => {
    await new Promise(resolve => setImmediate(resolve));
    await new Promise(resolve => setImmediate(resolve));
};
const settleIdle = async () => { listener({ type: "agent_end", isTerminal: true }); await flushIdle(); };
let releaseIdle;
idleBarrier = new Promise(resolve => { releaseIdle = resolve; });
await settleIdle();
expect(observations.length === 0, "The native idle barrier owns completion, not an agent_end alone");
releaseIdle();
await flushIdle();
expect(observations.length === 1 && observations[0].queuedMessageCount === 1
    && observations[0].sessionFile === "idle-one.jsonl", "Native idle identifies deferred next-turn context");
expect(idleSession.queuedMessageCount === 1 && idleSession.agent.replacements === 0,
    "Idle observation preserves OMP's pending context without replacing its queues");
observations.length = 0;
for (const field of ["isStreaming", "isCompacting", "isRetrying", "hasAdmittedSubmission", "hasPostPromptWork"]) {
    idleSession[field] = true;
    await settleIdle();
    expect(observations.length === 0, `${field} remains real work despite deferred context`);
    idleSession[field] = false;
}
asyncWork = true;
await settleIdle();
expect(observations.length === 0, "An unsuppressed background delivery still protects its wait");
asyncWork = false;
idleSession.agent.followUp.push(user("real follow-up"));
await settleIdle();
expect(observations.length === 0 && idleSession.agent.followUp.length === 1, "An actual user follow-up cannot be classified as idle context");
idleSession.agent.followUp = [companion("internal continuation")];
await settleIdle();
expect(observations.length === 0, "Hidden core-queue continuations still count as executing work");
idleSession.agent.followUp = [];
delete idleSession.hasPostPromptWork;
await settleIdle();
expect(observations.length === 0, "Missing SDK evidence cannot clear a waiting indicator");
idleSession.hasPostPromptWork = false;
idleBarrier = new Promise(resolve => { releaseIdle = resolve; });
await settleIdle();
listener({ type: "manual_compaction_start" });
releaseIdle();
await flushIdle();
expect(observations.length === 0, "Manual compaction fences an older idle-barrier result");
listener({ type: "manual_compaction_end" });
await flushIdle();
expect(observations.length === 1, "Manual compaction completion resamples native deferred context");
observations.length = 0;
idleBarrier = new Promise(resolve => { releaseIdle = resolve; });
await settleIdle();
listener({ type: "agent_start" });
releaseIdle();
await flushIdle();
expect(observations.length === 0, "A new native run fences an older idle-barrier result");
idleBarrier = new Promise(resolve => { releaseIdle = resolve; });
await settleIdle();
idleSession.sessionFile = "idle-two.jsonl";
releaseIdle();
await flushIdle();
expect(observations.length === 0, "Session replacement fences an older idle-barrier result");
await settleIdle();
expect(observations.length === 1 && observations[0].sessionFile === "idle-two.jsonl", "The replacement session can publish its own native idle observation");
unsubscribe();
expect(listener === undefined, "Releasing an observer retires its native subscription");

console.log(`OMP native queue identity checks passed: ${checks}`);
