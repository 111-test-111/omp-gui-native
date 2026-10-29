import assert from "node:assert/strict";
import { mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { join, resolve } from "node:path";
import { pathToFileURL } from "node:url";

const [phase, output, installation] = process.argv.slice(2);
const root = resolve(output), packageRoot = resolve(installation);
assert(root.includes("/build.noindex/verification/runs/"));
const { requestApproval } = await import(pathToFileURL(join(packageRoot, "src/tools/approval.ts")));
const targets = join(root, "targets");
mkdirSync(targets, { recursive: true });
if (phase === "export") writeFileSync(join(targets, "input.txt"), "Isolated approval target\n");
const cases = [
    { name: "single", tool: "bash", args: { command: "printf 'approval fixture'" } },
    { name: "session", tool: "bash", args: { command: "printf 'approval fixture'" }, options: { sessionSubject: "bash" } },
    { name: "cached-file", tool: "read", args: { path: join(targets, "input.txt") }, options: { grants: true } },
    { name: "cached-directory", tool: "read", args: { path: targets }, options: { grants: true } },
    { name: "cached-url", tool: "read", args: { path: "https://example.invalid/approval" }, options: { grants: true } },
];
const toolFor = fixture => ({ name: fixture.tool, approvalCacheTargets: args => args.path ? [args.path] : [] });
let checks = 0;
if (phase === "export") {
    const requests = [];
    for (const fixture of cases) {
        const answer = await requestApproval({ async select(title, options) {
            requests.push({ name: fixture.name,
                frame: { type: "extension_ui_request", id: fixture.name, method: "select", title, options, timeout: 30000 } });
        } }, toolFor(fixture), fixture.args, fixture.options);
        assert.equal(answer, "deny", "An unanswered installed approval never authorizes a tool");
    }
    writeFileSync(join(root, "approval-requests.json"), JSON.stringify(requests, null, 2));
} else {
    assert.equal(phase, "verify");
    const responses = JSON.parse(readFileSync(join(root, "approval-responses.json"), "utf8"));
    assert.equal(responses.length, cases.length);
    for (const fixture of cases) {
        const response = responses.find(row => row.name === fixture.name);
        for (const [decision, expected] of [["allow", "once"], ["deny", "deny"]]) {
            const answer = await requestApproval({ async select(_title, options) {
                assert.deepEqual(options, response.options, "Production consumes the installed runtime's actual option labels");
                const value = response[decision];
                assert.equal(value.type, "extension_ui_response");
                assert.equal(value.id, fixture.name);
                assert(options.includes(value.value));
                return value.value;
            } }, toolFor(fixture), fixture.args, fixture.options);
            assert.equal(answer, expected, "GUI decisions must never record session or persistent grants");
            checks++;
        }
    }
    writeFileSync(join(root, "summary.json"), JSON.stringify({ status: "passed", checks,
        boundary: "Installed public requestApproval + production Swift projection/serialization; no tool execution, approval-cache writes, model or GUI" }, null, 2));
    console.log(`PASS native approvals: ${checks} single-call/deny round trips including cached URL Approve versus Approve Once`);
}
process.exit(0);
