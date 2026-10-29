// Self-authored native OMP acceptance plugin. No network or real credentials.
import { writeFileSync } from "node:fs";

export default function (pi: any) {
  const save = (key: string, value: unknown) => {
    writeFileSync(`${process.env.OMP_GUI_ACCEPTANCE_RESULTS}/${key}.json`, JSON.stringify(value));
  };
  // Native noninteractive mode requires one authenticated model before RPC starts.
  // This key cannot access any service; extension commands never call the model.
  pi.registerProvider("omp-gui-bootstrap", {
    baseUrl: "https://example.invalid/acceptance-only",
    api: "openai-completions",
    apiKey: "synthetic-bootstrap",
    models: [{ id: "acceptance", name: "Local bootstrap only", reasoning: false, input: ["text"],
      cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 }, contextWindow: 8192, maxTokens: 128 }],
  });
  pi.registerProvider("omp-gui-acceptance", {
    baseUrl: "https://example.invalid/acceptance-only",
    api: "openai-completions",
    models: [{ id: "acceptance", name: "Local acceptance only", reasoning: false, input: ["text"],
      cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 }, contextWindow: 8192, maxTokens: 128 }],
    oauth: {
      name: "OMP GUI synthetic acceptance",
      async login(callbacks: any) {
        callbacks.onAuth({ url: "http://127.0.0.1:1/synthetic-acceptance", instructions: "Local synthetic provider. No real account or browser is required." });
        callbacks.onProgress("Synthetic native login callback ready");
        const code = await callbacks.onPrompt({ message: "Type ACCEPTANCE_OK (synthetic test only)", placeholder: "ACCEPTANCE_OK" });
        if (code !== "ACCEPTANCE_OK") throw new Error("Synthetic acceptance code did not match");
        save("login", { completed: true, synthetic: true });
        return { refresh: "synthetic-refresh", access: "synthetic-access", expires: Date.now() + 3600000 };
      },
      getApiKey() { return "synthetic-access"; },
    },
  });
  pi.registerCommand("omp-gui-acceptance", {
    description: "Local P3 native UI acceptance; never calls a model",
    getArgumentCompletions(prefix: string) {
      return ["dialogs", "timeout", "cancel"].filter(x => x.startsWith(prefix)).map(value => ({ value, label: value }));
    },
    async handler(args: string, ctx: any) {
      if (args.trim() === "timeout") {
        const value = await ctx.ui.input("Native timeout acceptance", "Leave unanswered", { timeout: 500 });
        save("timeout", { cancelled: value === undefined });
        return;
      }
      if (args.trim() === "cancel") {
        const value = await ctx.ui.input("Native cancellation acceptance", "Native aborts this dialog", { signal: AbortSignal.timeout(500) });
        save("cancel", { cancelled: value === undefined });
        return;
      }
      ctx.ui.setStatus("acceptance", "NATIVE_STATUS_OK");
      ctx.ui.setWidget("above", ["NATIVE_WIDGET_ABOVE", "Unicode 上下文🙂"], { placement: "aboveEditor" });
      ctx.ui.setWidget("below", ["NATIVE_WIDGET_BELOW"], { placement: "belowEditor" });
      const selected = await ctx.ui.select("Native rich selection", [
        { label: "Continue", description: "Native option description · 保留选项说明" },
        { label: "Stop", description: "Does not complete this acceptance" },
      ], { timeout: 600000 });
      save("select", { selected });
      const edited = await ctx.ui.editor("Native multiline editor", "  first line\n第二行🙂\n", { timeout: 600000 });
      save("editor", { edited });
      ctx.ui.setEditorText("NATIVE_PREPARED_TEXT");
      ctx.ui.notify("NATIVE_EXTENSION_COMPLETE", "info");
    },
  });
}
