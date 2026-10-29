import assert from "node:assert/strict";
import { mkdir, readFile } from "node:fs/promises";
import { join } from "node:path";
import { pathToFileURL } from "node:url";

/** Installed public SDK, isolated credentials/settings, no model or MCP work. */
export async function createCefBrowserSession(root, packageRoot, cdpURL) {
    const agentDir = process.env.PI_CODING_AGENT_DIR;
    assert(agentDir?.startsWith(root + "/"));
    await mkdir(agentDir, { recursive: true });
    const imp = name => import(pathToFileURL(Bun.resolveSync(name, packageRoot)).href);
    const sdk = await imp("@oh-my-pi/pi-coding-agent");
    const { getBundledModel } = await imp("@oh-my-pi/pi-catalog");
    const { ensureTheme, stopThemeWatcher } = await imp("@oh-my-pi/pi-tui/theme");
    await ensureTheme();
    const settings = sdk.Settings.isolated({ "browser.enabled": true, "browser.cdpUrl": cdpURL,
        "browser.relay": false, "browser.tern": false, "browser.cmux": false,
        "eval.js": true, "eval.py": false, "tools.approvalMode": "yolo", "tools.xdev": false,
        "memory.backend": "off", "autolearn.enabled": false, "lsp.enabled": false, "startup.quiet": true });
    const authStorage = await sdk.AuthStorage.create(join(agentDir, "auth.db"));
    let session;
    try {
        const result = await sdk.createAgentSession({ cwd: root, agentDir, settings, authStorage,
            modelRegistry: new sdk.ModelRegistry(authStorage, join(agentDir, "models.yml"), { settings }),
            model: getBundledModel("openai", "gpt-4o-mini"), sessionManager: sdk.SessionManager.inMemory(root),
            disableExtensionDiscovery: true, extensions: [], skills: [], rules: [], contextFiles: [],
            enableMCP: false, cacheWarming: false, bindProcessState: false });
        session = result.session;
        const tool = session.getToolForEvalBridge("eval");
        assert(tool, "The installed OMP exposes its real Eval tool");
        return { session, tool, version: JSON.parse(await readFile(join(packageRoot, "package.json"), "utf8")).version,
            async dispose() {
                try { await session.dispose(); } finally { authStorage.close(); stopThemeWatcher(); }
            } };
    } catch (error) {
        await session?.dispose(); authStorage.close(); stopThemeWatcher(); throw error;
    }
}
