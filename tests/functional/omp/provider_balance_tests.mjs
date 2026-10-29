import assert from "node:assert/strict";
import register, { deepSeekUsageProvider as usage, balancesFromPayload, decimalText, supportsDeepSeek } from "../../../OMPGUI/Resources/OMPProviderUsage.js";

let checks = 0;
const expect = (value, message) => { assert.ok(value, message); checks++; };
const params = { provider: "deepseek", credential: { type: "api_key", apiKey: "fixture-key" }, baseUrl: "https://api.deepseek.com/v1" };
const payload = { is_available: true, balance_infos: [
  { currency: "CNY", total_balance: "123456789012345678.123456789012", granted_balance: "0.00", topped_up_balance: "7.20" },
  { currency: "USD", total_balance: "0.00" },
] };
let registration;
register({ registerProvider: (id, configuration) => { registration = { id, configuration }; } });
expect(registration.id === "deepseek" && Object.keys(registration.configuration).join() === "usage",
  "The extension contributes usage only, without changing models or key configuration");
expect(usage.retainLastGoodOnFailure === false, "A failed refresh cannot replay old balance as a fresh response");
for (const value of ["0", "0.00", "-1.50", "123456789012345678.123456789012"]) expect(decimalText(value) === value, "Decimal text remains exact");
for (const value of [undefined, null, 0, "NaN", "Infinity", "1e2", "1.00\n", "", "9".repeat(40)]) expect(decimalText(value) === undefined, "Unknown or malformed money is omitted");
for (const baseUrl of ["https://relay.invalid/v1", "http://api.deepseek.com", "https://api.deepseek.com.evil.invalid",
  "https://owner:secret@api.deepseek.com", "https://api.deepseek.com:444/v1", "https://api.deepseek.com?v=key"]) {
  expect(!supportsDeepSeek({ ...params, baseUrl }), "Keys configured for other endpoints cannot be sent to DeepSeek");
}
expect(!supportsDeepSeek({ ...params, credential: { type: "oauth", accessToken: "fixture" } }), "OAuth is not assumed to be a DeepSeek key");
expect(!supportsDeepSeek({ ...params, credential: { type: "api_key", apiKey: "line\nbreak" } }), "Header injection is rejected");
const rows = balancesFromPayload(payload);
expect(rows.length === 2 && rows[0].total === payload.balance_infos[0].total_balance && rows[0].granted === "0.00",
  "Both currencies and explicit zero remain exact without binary floating point");
expect(rows[1].granted === undefined, "Missing amounts never become zero");
expect(balancesFromPayload({ ...payload, balance_infos: [{ currency: "EUR", total_balance: "5.00" }] }).length === 0,
  "An unsupported currency is hidden instead of relabeled");
expect(balancesFromPayload({ ...payload, balance_infos: [payload.balance_infos[0], payload.balance_infos[0]] }).length === 0,
  "Conflicting currency entries are not selected arbitrarily");
expect(balancesFromPayload({ balance_infos: payload.balance_infos }).length === 0, "An unrecognized response shape fails closed");
expect(balancesFromPayload({ ...payload, balance_infos: Array(9).fill(payload.balance_infos[0]) }).length === 0, "The projection stays bounded");

let calls = 0;
const report = await usage.fetchUsage(params, { fetch: async (url, options) => {
  calls++;
  expect(url === "https://api.deepseek.com/user/balance" && options.method === "GET" && options.redirect === "error", "Only the official read-only endpoint is used and redirects are blocked");
  expect(options.headers.Authorization === "Bearer fixture-key" && options.signal instanceof AbortSignal, "OMP supplies the key and cancellation remains bounded");
  return Response.json(payload);
} });
expect(calls === 1 && report.limits.length === 0 && report.metadata.ompGuiBalances.items[0].total === rows[0].total,
  "A successful read carries native report time and a separate exact monetary projection");
expect(!JSON.stringify(report).includes("fixture-key"), "Neither secret nor raw response reaches the GUI report");
for (const response of [new Response("unauthorized", { status: 401 }), new Response("forbidden", { status: 403 }),
  new Response("not json"), new Response("x".repeat(65537)), new Response("x", { headers: { "content-length": "65537" } })]) {
  expect(await usage.fetchUsage(params, { fetch: async () => response }) === null, "HTTP, parse and size failures do not create balances");
}
expect(await usage.fetchUsage(params, { fetch: async () => { throw Error("fixture secret must not escape"); } }) === null,
  "Transport errors remain private and cannot manufacture balance");
const controller = new AbortController(); controller.abort();
expect(await usage.fetchUsage({ ...params, signal: controller.signal }, { fetch: async () => Response.json(payload) }) === null,
  "A late completion after cancellation cannot publish money");
expect(await usage.fetchUsage({ ...params, baseUrl: "https://relay.invalid" }, { fetch: () => { throw Error("must not query"); } }) === null,
  "Unsupported endpoint ownership has no network side effect");
console.log(`Provider balance checks passed: ${checks}`);
