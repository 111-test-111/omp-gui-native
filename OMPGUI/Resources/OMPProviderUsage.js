// OMP GUI's read-only usage extension. OMP resolves credentials and owns the request/cache.
// DeepSeek API contract: https://api-docs.deepseek.com/api/get-user-balance/
const source = "omp-gui-deepseek-balance-v1";
const endpoint = "https://api.deepseek.com/user/balance";
const maximumBytes = 64 * 1024;

export function decimalText(value) {
  return typeof value === "string" && value.length <= 32 &&
    value.match(/^[+-]?\d{1,18}(?:\.\d{1,12})?$/)?.[0] === value ? value : undefined;
}

export function balancesFromPayload(payload) {
  if (!payload || typeof payload !== "object" || typeof payload.is_available !== "boolean" ||
      !Array.isArray(payload.balance_infos) || payload.balance_infos.length > 8) return [];
  const rows = payload.balance_infos.filter(row => row && ["CNY", "USD"].includes(row.currency));
  return rows.filter(row => rows.filter(other => other.currency === row.currency).length === 1).flatMap(row => {
    const values = { total: decimalText(row.total_balance), granted: decimalText(row.granted_balance),
      toppedUp: decimalText(row.topped_up_balance) };
    return Object.values(values).some(value => value !== undefined) ? [{ currency: row.currency, ...values }] : [];
  });
}

export function isOfficialDeepSeekURL(baseUrl) {
  try {
    const url = new URL(baseUrl);
    return url.protocol === "https:" && url.hostname === "api.deepseek.com" &&
      (!url.port || url.port === "443") && !url.username && !url.password && !url.search && !url.hash;
  } catch { return false; }
}

export function supportsDeepSeek(params) {
  return params.provider === "deepseek" && params.credential?.type === "api_key" &&
      typeof params.credential.apiKey === "string" && !!params.credential.apiKey.trim() &&
      params.credential.apiKey.length <= 8192 && !/[\r\n]/.test(params.credential.apiKey) &&
      (!params.baseUrl || isOfficialDeepSeekURL(params.baseUrl));
}

async function boundedJSON(response) {
  if (!response.ok || !response.body || Number(response.headers.get("content-length")) > maximumBytes) {
    try { await response.body?.cancel(); } catch { /* Discard failed or oversized responses. */ }
    return undefined;
  }
  const reader = response.body.getReader(), decoder = new TextDecoder("utf-8", { fatal: true });
  let size = 0, text = "";
  try {
    for (;;) {
      const { done, value } = await reader.read();
      if (done) break;
      size += value.byteLength;
      if (size > maximumBytes) return undefined;
      text += decoder.decode(value, { stream: true });
    }
    return JSON.parse(text + decoder.decode());
  } finally {
    try { await reader.cancel(); } catch { /* No response body or errors cross into GUI logs. */ }
    reader.releaseLock();
  }
}

export const deepSeekUsageProvider = {
  id: "deepseek", cacheVersion: 1, retainLastGoodOnFailure: false,
  supports: supportsDeepSeek,
  async fetchUsage(params, context) {
    if (!supportsDeepSeek(params)) return null;
    try {
      const signal = AbortSignal.any([AbortSignal.timeout(10_000), ...(params.signal ? [params.signal] : [])]);
      const response = await context.fetch(endpoint, { method: "GET", redirect: "error", signal,
        headers: { Accept: "application/json", Authorization: "Bearer " + params.credential.apiKey.trim() } });
      const balances = balancesFromPayload(await boundedJSON(response));
      if (!balances.length || signal.aborted) return null;
      return { provider: "deepseek", fetchedAt: Date.now(), limits: [],
        metadata: { source, ompGuiBalances: { version: 1, items: balances } } };
    } catch { return null; }
  },
};

export default function registerProviderUsage(api) {
  api.registerProvider("deepseek", { usage: deepSeekUsageProvider });
}
