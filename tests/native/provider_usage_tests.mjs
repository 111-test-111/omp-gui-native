import assert from "node:assert/strict";
import { mkdirSync, writeFileSync, readFileSync, unlinkSync } from "node:fs";
import { join, resolve } from "node:path";
import { pathToFileURL } from "node:url";

const output = resolve(process.argv[2]), packageRoot = resolve(process.argv[3]);
const agent = process.env.PI_CODING_AGENT_DIR;
assert(output.includes("/build.noindex/verification/runs/") && agent.startsWith(output + "/"));
mkdirSync(agent, { recursive: true });
globalThis.fetch = async () => { throw Error("External network disabled for native usage check"); };
const load = name => import(pathToFileURL(Bun.resolveSync(name, packageRoot)));
const { AuthStorage } = await load("@oh-my-pi/pi-ai");
const { ModelsConfigFile } = await load("@oh-my-pi/pi-coding-agent/config/models-config");
const { nativeConfiguration } = await import("../../OMPGUI/Resources/OMPModelConfiguration.js");
const executable = join(packageRoot, "dist/cli.js");
let checks = 0, calls = 0;
const expect = (value, message) => { assert.ok(value, message); checks++; };
const db = await AuthStorage.create(join(agent, "agent.db"));
await db.credentials.set("deepseek", { type: "api_key", key: "fixture-stored-key" });
db.close();
let expected = "fixture-stored-key";
const fetch = async (url, options) => {
  calls++;
  expect(url === "https://api.deepseek.com/user/balance" && options.headers.Authorization === "Bearer " + expected,
    "The public native cascade selects the intended account key");
  return Response.json({ is_available: true, balance_infos: [{ currency: "CNY", total_balance: "1.2300", granted_balance: "0.0000" }] });
};
async function read() {
  // GUI calls use a new helper process. This fixture reuses one process while editing files.
  ModelsConfigFile.invalidate();
  const native = await nativeConfiguration(executable, agent);
  try { return await native.balances(fetch); } finally { native.close(); }
}
expect((await read()).reports[0]?.metadata.ompGuiBalances.items[0].total === "1.2300", "Stored native keys return exact monetary fields only");
const file = join(agent, "models.yml");
const original = "providers:\n  deepseek:\n    apiKey: OMP_GUI_FIXTURE_DEEPSEEK\n";
process.env.OMP_GUI_FIXTURE_DEEPSEEK = "fixture-config-key";
writeFileSync(file, original);
expected = "fixture-config-key";
expect((await read()).reports.length === 1 && readFileSync(file, "utf8") === original, "models.yml overrides stored auth through OMP without a configuration write");
writeFileSync(file, original + "    baseUrl: https://relay.invalid/v1\n");
const before = calls;
expect((await read()).reports.length === 0 && calls === before, "A custom relay does not receive or trigger official balance requests");
writeFileSync(file, original);
const extension = join(agent, "extensions", "provider.js"); mkdirSync(join(agent, "extensions"), { recursive: true });
writeFileSync(extension, 'export default function(pi) { pi.registerProvider("deepseek", { baseUrl: "https://extension-relay.invalid/v1" }); }');
expect((await read()).reports.length === 0 && calls === before, "Native extension endpoint overrides are honored before resolving a balance key");
unlinkSync(extension);
const accounts = await AuthStorage.create(join(agent, "agent.db"));
await accounts.credentials.remove("deepseek"); accounts.close();
writeFileSync(file, "{}\n");
process.env.DEEPSEEK_API_KEY = "fixture-environment-key"; expected = "fixture-environment-key";
expect((await read()).reports.length === 1, "Native environment credentials remain supported");
delete process.env.DEEPSEEK_API_KEY; delete process.env.OMP_GUI_FIXTURE_DEEPSEEK;
expect((await read()).reports.length === 0, "Missing credentials stay absent instead of becoming a zero balance");
console.log(`Native provider usage checks passed: ${checks}`);
