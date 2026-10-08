# AGENTS.md — Tivano agent workflow

## Worktrees (mandatory for coding)

- Never code directly in the main checkout; every coding task gets its own
  worktree first.
- Setup per task:
  1. `git fetch origin --prune`
  2. `git worktree add -b <branch> <worktrees-dir>/agent-<slug> origin/main`
     (or from the agreed base branch instead of `origin/main`)
  3. Do all edits, builds and `scripts/quick_run.sh` runs inside that worktree.
- Cleanup only when the task is done/merged:
  `git worktree remove --force <worktrees-dir>/agent-<slug>` + `git worktree prune`.
- Never delete the main checkout, never touch another agent's worktree.

## Layout (four layers, one way)

- `Tivano/Core` (models, pure support) reaches into nothing else in the app.
  `Tivano/Services` (Git, Store, Providers) and `Tivano/UI` (Chrome, Common,
  Markdown, Theme, Sound) reach only into Core. `Tivano/App` (entry, model, runtime,
  windows, captures and every feature view) reaches into everything.
- New code goes in the lowest layer whose dependencies it has. A Core file that needs
  the provider registry, the settings or a view is in the wrong layer: split the part
  that needs them into an extension in the layer above (see `App/HydraCookbook+Resolve.swift`).
- There is no test target and no test scripts; the build is the check
  (`xcodebuild -project Tivano.xcodeproj -scheme Tivano -configuration Debug build`).

## Hydra heads (the chat team)

- A head never builds or otherwise verifies: no `xcodebuild`, no `scripts/quick_run.sh`, no check command. It edits the files the lead briefed it on and reports, nothing more.
- The lead runs the one build that proves the change, in the checkout, after the heads report.

## Relaunching (never unprompted)

- NEVER run `scripts/quick_run.sh` or otherwise quit/relaunch Tivano unless the owner explicitly asks for it in that moment.
- Agent-initiated build-only verification inside the worktree is fine and does not install. An explicit owner request to build/package an app also authorizes updating the requested edition(s) in `/Applications` via `scripts/package_local.sh`, unless the owner explicitly asks for build-only.
- Packaging never implies quitting or launching an app. If a target is running, stop and request an explicit quit; do not overwrite its running bundle.
- "Finish", "merge", "done" or "test it" do not imply relaunch — only an explicit request to run/relaunch the app does.

## Local packaging, editions and shared data

- Every owner-requested local build/package must produce the requested package **and** update `/Applications/Tivano.app` and/or `/Applications/Tivano Dev.app`; do not leave the new build only in DerivedData. Use `scripts/package_local.sh --release|--dev|--both`.
- The owner accepts sharing the real library between editions. Both use `~/Library/Application Support/Tivano`, `~/.tivano` and Keychain service `Tivano`; preferences and macOS privacy grants remain per bundle ID. No one-way mirror or `rsync --delete` is permitted on the shared store.
- Only one edition may write the library at a time. Keep the startup writer lease, isolated capture storage, migration backup and legacy path aliases. Never migrate while the older Droppy app is running.
- Release uses `config/release.xcconfig`; Dev uses `config/dev.xcconfig`. Both start at `0.0.1`, with Dev displaying `dev-0.0.1`. Keep Apple's bundle version numeric; Dev's prefix is presentation metadata.
- Maintain edition versions independently. Never advance/synchronize Release just because Dev is packaged. On an explicit request to catch Release up, use `scripts/set_version.py release catch-up-dev`, then build the agreed code revision and package Release. A version change alone is not a code promotion.
- The DEV badge is a derived icon; never modify the approved v1 original or the release icon.
- Local packages use the persistent `Tivano Local Development` identity. Public distribution still requires Developer ID/notarization and must not relax the updater's production verification.

## Merging (local dev, always squash)

- The history inherited from upstream is already bloated: thousands of tiny
  Hydra head commits plus one merge commit per MR. Every task integration MUST
  land as exactly one new commit on the requested target branch.
- "Merge" and "package" authorize local work only. Pushing, creating a GitHub PR
  or publishing requires a separate explicit owner instruction; never infer it
  from a local merge request.
- `dev` stays local. Squash task changes in an integration worktree based on
  `dev`, then fast-forward the local `dev` checkout to that single commit.
- Keep the local main-only pre-push guard; do not bypass it. Do not promote to
  `main` unless explicitly requested. When GitHub integration is separately
  authorized, use `gh` and squash; never push straight to `main`.
- Do not rewrite existing history (`rebase -i`, `filter-branch`,
  `filter-repo`, force-push to `main`) to "fix" the inherited commits; squash
  applies to new merges only.

## Releasing (credit every contributor)

- Every `## [x.y.z]` entry in CHANGELOG.md that ships outside work carries a `### Thanks` section, one bullet per person in the form `- Name (@github-handle): what they did (#PR).`, after Refinements.
- `python3 scripts/release_credits.py` prints the block for everything merged since the previous `v*` tag (run it while writing the entry).
- `scripts/publish_release.sh` runs `scripts/release_credits.py --check` on the notes and refuses to publish while anyone is missing.
- The app's About cards ignore the Thanks heading, so it changes nothing there.
- When a pull request from outside merges between releases, add the person to the `## [Unreleased]` entry's Thanks right away rather than at release time.

## Project contracts

- UI: always reuse ChromeSection, ChromeCard, ChromeRow, GlassPickerButton, ChromeVisualPicker and SettingsSwitch. Never invent styles, colors, fonts, spacing or custom controls.
- Localization: English text is the key in `Tivano/Resources/Localizable.xcstrings`. Every new user-facing string needs a zh-Hans entry. Translate faithfully, clearly and naturally; keep English for product names, provider/model names, MCP, Git, worktree, token and anything that reads worse translated. Native language names stay native.
- Follow `docs/i18n/CONVENTIONS.md` for catalog lookup and translation fragments.
