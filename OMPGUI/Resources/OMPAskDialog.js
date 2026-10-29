// Adapt only presentation. OMP's built-in AskTool still validates questions,
// applies its timeout policy, formats results and owns the agent lifecycle.
export const askDialogPrefix = "OMP_GUI_ASK_V1:";

export function installNativeAskDialog(ui) {
    // Native RPC may expose a read-only getter that returns undefined until
    // set_ask_dialog opts in. Its presence still belongs to OMP.
    if (!ui || "askDialog" in ui || typeof ui.input !== "function") return;
    ui.askDialog = async (questions, dialogOptions) => {
        let timedOut = false;
        const value = await ui.input(askDialogPrefix + JSON.stringify({ version: 1, questions }), undefined, {
            ...dialogOptions,
            onTimeout() {
                timedOut = true;
                dialogOptions?.onTimeout?.();
            },
        });
        if (dialogOptions?.signal?.aborted) return undefined;
        if (value === undefined) {
            if (!timedOut) return undefined;
            return { kind: "submit", results: questions.map(question => {
                const index = Number.isInteger(question.recommended) && question.recommended >= 0
                    && question.recommended < question.options.length ? question.recommended : 0;
                return { id: question.id, question: question.question, options: question.options.map(option => option.label),
                    multi: question.multi ?? false, selectedOptions: question.options[index] ? [question.options[index].label] : [],
                    ...(!question.options.length ? { customInput: "" } : {}), timedOut: true };
            }) };
        }
        const response = JSON.parse(value);
        if (response?.kind !== "submit" || !Array.isArray(response.results) || response.results.length !== questions.length) {
            throw new Error("Invalid OMP GUI ask response");
        }
        return { kind: "submit", results: questions.map((question, index) => {
            const answer = response.results[index];
            const labels = question.options.map(option => option.label);
            if (answer?.id !== question.id || !Array.isArray(answer.selectedOptions)
                || !answer.selectedOptions.every(label => typeof label === "string" && labels.includes(label))
                || new Set(answer.selectedOptions).size !== answer.selectedOptions.length
                || (!question.multi && answer.selectedOptions.length > 1)
                || (answer.customInput !== undefined && typeof answer.customInput !== "string")
                || (answer.note !== undefined && typeof answer.note !== "string")
                || (answer.customInput !== undefined && answer.selectedOptions.length > 0)) {
                throw new Error("Invalid OMP GUI ask answer");
            }
            return { id: question.id, question: question.question, options: labels, multi: question.multi ?? false,
                selectedOptions: answer.selectedOptions, customInput: answer.customInput, note: answer.note };
        }) };
    };
}
