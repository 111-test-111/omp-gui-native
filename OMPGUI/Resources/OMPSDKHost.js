// A thin entry into OMP's own CLI startup. All configuration, auth, history,
// extension discovery and RPC handling still run in the installed OMP SDK.
import { realpathSync } from "node:fs";
import { dirname, join } from "node:path";
import { pathToFileURL } from "node:url";
import { createRequire } from "node:module";

const nativeExecutable = process.env.OMP_GUI_NATIVE_EXECUTABLE;
if (!nativeExecutable) throw new Error("Missing native OMP executable");
const args = process.argv.slice(2);

// Resolve optional SDK facilities before any native session is created. If an
// installation changes its exports, ordinary chat still uses its own CLI.
async function originalCLI() {
    if (!Bun.isMainThread) {
        // The installed entry already implements native worker-thread reentry.
        require(nativeExecutable);
        return;
    }
    const child = Bun.spawn([nativeExecutable, ...args], { stdin: "inherit", stdout: "inherit", stderr: "inherit" });
    const terminate = () => child.kill("SIGTERM");
    const interrupt = () => child.kill("SIGINT");
    process.on("SIGTERM", terminate);
    process.on("SIGINT", interrupt);
    try { process.exit(await child.exited); }
    finally {
        process.off("SIGTERM", terminate);
        process.off("SIGINT", interrupt);
    }
}

let bootstrap;
let nativeMemoryImport;
let nativeDependencyImport;
try {
    const installedRoot = dirname(dirname(realpathSync(nativeExecutable)));
    const requireInstalled = createRequire(join(installedRoot, "package.json"));
    // This prefix must remain synchronous. Browser/Eval workers can receive
    // their first message immediately; no filesystem await may precede the
    // native worker dispatcher. Children inherit the parent's verified copy.
    const workerHost = requireInstalled("@oh-my-pi/pi-utils/worker-host.js");
    workerHost.declareWorkerHostEntry();
    const isWorker = !Bun.isMainThread || workerHost.isWorkerHostSelector(args[0]);
    let browserRoot;
    if (isWorker) {
        browserRoot = process.env.OMP_GUI_BROWSER_SDK_ROOT;
    } else {
        delete process.env.OMP_GUI_BROWSER_SDK_ROOT;
        try {
            const { prepareBrowserSDK } = await import("./OMPBrowserCompatibility.js");
            browserRoot = await prepareBrowserSDK(installedRoot, process.env.OMP_GUI_BROWSER_COMPAT_ROOT);
            if (browserRoot) process.env.OMP_GUI_BROWSER_SDK_ROOT = browserRoot;
        } catch { process.stderr.write("[OMP GUI browser] compatibility_unavailable\n"); }
    }
    const packageRoot = browserRoot ?? installedRoot;
    const requireNative = createRequire(join(packageRoot, "package.json"));
    const nativeImport = nativeMemoryImport = subpath => import(pathToFileURL(Bun.resolveSync("@oh-my-pi/pi-coding-agent/" + subpath, packageRoot)).href);
    const dependencyImport = nativeDependencyImport = specifier => import(pathToFileURL(Bun.resolveSync(specifier, packageRoot)).href);

    // Worker threads/subprocesses re-enter Bun.main. Load OMP's native
    // dispatcher synchronously: its own sync prefix installs the proper
    // inbox before Bun delivers the parent's already-posted messages.
    if (isWorker) {
        bootstrap = { worker: requireNative(Bun.resolveSync("@oh-my-pi/pi-coding-agent/cli", packageRoot)) };
    } else {
        if (Bun.isMainThread && args.includes("rpc-ui") && browserRoot) {
            process.stdout.write(JSON.stringify({ type: "omp_gui_browser_ready" }) + "\n");
        }
        const profileBootstrap = await nativeImport("cli/profile-bootstrap");
        const dirs = requireNative("@oh-my-pi/pi-utils/dirs.js");
        const extracted = profileBootstrap.extractProfileFlags(args);
        // Native .env/config modules must load only after selecting the profile.
        dirs.setProfile(extracted.profile ?? dirs.resolveProfileEnv(process.env.OMP_PROFILE, process.env.PI_PROFILE));
        const [{ parseArgs }, { runRootCommand }, { createAgentSession }, { expandPromptTemplate }, { isHiddenUserCompanion },
            { installGlobalProxyFetch }, { setProcessName }, { registerStdioDisconnectHandling },
            { registerDaemonProjectPresence }, queue, ask] = await Promise.all([
            nativeImport("cli/args"), nativeImport("main"), nativeImport("sdk"),
            nativeImport("config/prompt-templates"), nativeImport("session/queued-messages"),
            dependencyImport("@oh-my-pi/pi-ai/utils/proxy"), dependencyImport("@oh-my-pi/pi-utils/process-name"),
            dependencyImport("@oh-my-pi/pi-utils/postmortem"), nativeImport("launch/presence"), import("./OMPQueueControl.js"),
            import("./OMPAskDialog.js"),
        ]);
        if (![parseArgs, runRootCommand, createAgentSession, expandPromptTemplate, isHiddenUserCompanion,
            installGlobalProxyFetch, setProcessName, registerStdioDisconnectHandling, registerDaemonProjectPresence,
            queue.installNativeQueueControls, ask.installNativeAskDialog].every(value => typeof value === "function")) throw new Error("Unsupported native SDK");
        bootstrap = { args: extracted.argv, appName: dirs.APP_NAME, parseArgs, runRootCommand, createAgentSession,
            expandPromptTemplate, isHiddenUserCompanion, installGlobalProxyFetch, setProcessName,
            registerStdioDisconnectHandling, registerDaemonProjectPresence, queue, ask };
    }
} catch {
    // No session has begun. Fallback never retries admission or agent work.
}

try {
    delete process.env.MallocStackLogging;
    delete process.env.MallocStackLoggingNoCompact;
} catch {}

if (!bootstrap) {
    await originalCLI();
} else if (bootstrap.worker) {
    // Native cli.ts dispatches worker-thread reentry itself.
    if (Bun.isMainThread) await bootstrap.worker.runCli(args);
} else {
    // These are the same public bootstrap helpers called by native runCli.
    // There is intentionally no fallback after native startup begins.
    bootstrap.installGlobalProxyFetch();
    bootstrap.setProcessName(bootstrap.appName);
    bootstrap.registerStdioDisconnectHandling();
    const parsed = bootstrap.parseArgs(bootstrap.args);
    await bootstrap.runRootCommand(parsed, bootstrap.args, {
        async createAgentSession(options) {
            // runRootCommand omits this native presence registration only when
            // an SDK dependency override is supplied.
            await bootstrap.registerDaemonProjectPresence(options.cwd ?? process.cwd());
            try {
                const { installRequestCaptureRuntime } = await import("./OMPRequestCapture.js");
                await installRequestCaptureRuntime();
            } catch { process.stderr.write("[OMP GUI request capture] initialization_failed\n"); }
            const result = await bootstrap.createAgentSession(options);
            try {
                const { installRequestCaptureRuntime, installSessionCapture } = await import("./OMPRequestCapture.js");
                const capture = await installRequestCaptureRuntime();
                if (capture) installSessionCapture(result.session, capture);
            } catch { process.stderr.write("[OMP GUI request capture] initialization_failed\n"); }
            const memoryOptions = JSON.parse(process.env.OMP_GUI_MEMORY_CONFIG ?? '{"enabled":false}');
            if (memoryOptions.enabled) {
                try {
                const [{ installNativeMemoryControls }, memorySettings, registry, scopes, state, transcript,
                    { execFile }, { promisify }, { realpath }] = await Promise.all([
                    import("./OMPMemoryControl.js"),
                    nativeMemoryImport("memory-backend/settings"), nativeMemoryImport("config/registry"),
                    nativeMemoryImport("mnemopi/config"), nativeMemoryImport("mnemopi/state"), nativeMemoryImport("hindsight/transcript"),
                    import("node:child_process"), import("node:util"), import("node:fs/promises"),
                ]);
                await installNativeMemoryControls(result.session, result.eventBus,
                    { ...memorySettings, ...registry, ...scopes, ...state, ...transcript }, memoryOptions,
                    { execFile: promisify(execFile), realpath });
                } catch (error) {
                    await result.session.dispose();
                    throw error;
                }
            }
            bootstrap.queue.installNativeQueueControls(result.session, result.eventBus,
                bootstrap.expandPromptTemplate, bootstrap.isHiddenUserCompanion);
            bootstrap.queue.installNativeIdleObserver(result.session, frame => {
                process.stdout.write(JSON.stringify(frame) + "\n");
            });
            try {
                const [{ installNativeContextInspection }, { convertToLlm }, { toolWireSchema }] = await Promise.all([
                    import("./OMPContextControl.js"), nativeMemoryImport("session/messages"),
                    nativeDependencyImport("@oh-my-pi/pi-ai/utils/schema"),
                ]);
                installNativeContextInspection(result.session, result.eventBus, convertToLlm, toolWireSchema);
            } catch {
                // Ordinary RPC context usage remains available on older SDKs.
            }
            try {
                const [{ installNativeDebugObservation }, { dapSessionManager }] = await Promise.all([
                    import("./OMPDebugControl.js"), nativeMemoryImport("dap"),
                ]);
                installNativeDebugObservation(result.session, result.eventBus, dapSessionManager,
                    frame => process.stdout.write(JSON.stringify(frame) + "\n"));
            } catch {
                // Debug inspection is optional; tool observations still work.
            }
            return { ...result, setToolUIContext(ui, hasUI) {
                if (hasUI) bootstrap.ask.installNativeAskDialog(ui);
                result.setToolUIContext(ui, hasUI);
            } };
        },
    });
}
