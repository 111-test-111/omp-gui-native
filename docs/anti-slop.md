# Anti-slop guidance

Droppy Code ships a short, built-in block of guidance that asks the model for the shortest complete answer: leading with the result, skipping filler and hype, keeping comments only where they explain a non-obvious reason, and making focused edits instead of unrelated cleanup. The same block asks for product-fitting UI structure and for evidence to be reused rather than re-read.

## Default on, and what the setting does

The guidance is on by default. It is exposed in **Settings › General › Conversation** as **Concise AI replies**; when the switch is off, Droppy Code sends the matching "off" block instead, which tells the model to disregard the earlier app-provided guidance and to keep following user requests and project requirements.

The setting takes effect on the next message. A message already in flight is not changed, and toggling the switch does not rewrite the current conversation or thread history.

Providers with system-instruction support receive the guidance when their session starts or resumes. Other providers receive it with the first ordinary message of a session, and again after explicit compaction; slash commands defer delivery until that ordinary message. Automatic history changes inside those providers are not observable by the app.

Nothing is promised about token savings. Shorter replies and fewer redundant reads usually use fewer tokens, but the model, the task and the provider's own behavior all vary, so no fixed saving is guaranteed and no such claim is made in the UI.

## All providers, including Hydra heads

The guidance is attached to the provider request, so it reaches every provider Droppy Code runs, not just one. Delegated work — Hydra heads — is covered too: the block itself asks that the guidance apply to delegated work, and the intent is that a head answers under the same policy as its lead.

## A compact authored adaptation, not upstream tooling

The guidance in `DroppyCode/Core/Models/AntiSlopPolicy.swift` is a compact adaptation authored for Droppy Code. It is not an installation of the upstream anti-slop project, and it does not run any of its tooling.

Upstream inspiration: [miqdadbadjuber/anti-slop](https://github.com/miqdadbadjuber/anti-slop) at revision [`743735248fbaefd76bb56619615687dfa8b3bc1e`](https://github.com/miqdadbadjuber/anti-slop/tree/743735248fbaefd76bb56619615687dfa8b3bc1e), MIT licensed, copyright 2026 Miqdad Badjuber. The upstream [LICENSE](https://github.com/miqdadbadjuber/anti-slop/blob/743735248fbaefd76bb56619615687dfa8b3bc1e/LICENSE) applies to that work.

What is intentionally left out of Droppy Code:

- The upstream wizard and its interactive setup.
- Mandatory audit reports.
- External executables or scripts the upstream project may invoke.

Droppy Code carries only the guidance text, as a value it can hand to a provider. It installs nothing, runs no audit, and requires no external binary.
