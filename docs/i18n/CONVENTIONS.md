# Localization conventions

- Reuse existing Chrome components; keep their String parameter types. Pass exact English literals, e.g. `ChromeRow(title: "App language")`.
- Shared Chrome text uses `Text(verbatim: Chrome.localized(title))`. `Chrome.localized` calls `Bundle.main.localizedString(forKey: key, value: key, table: "Localizable")`; the compiled catalog supplies translations, and missing keys remain unchanged. Plain text avoids interpreting user data as Markdown.
- Outside Chrome, use `Text("English literal")` for SwiftUI literals, or `Text(verbatim: Chrome.localized("English literal"))` for plain text. Never use bare `Text(stringVariable)` for translatable UI text.
- Enum titles/details stay exact English String keys; Chrome looks them up at rendering time. Native language names (English, 简体中文) stay native. Keep raw values, identifiers and stored data untranslated.
- For interpolation, localize the complete template before inserting values: `String(format: Chrome.localized("Project: %@"), projectName)`. Add that exact format key and matching placeholders to the catalog; never build a key from an already-interpolated String or translate fragments separately. User data, paths and model/provider names are values, not keys.
- Add entries manually to `Tivano/Resources/Localizable.xcstrings` (sourceLanguage en), with `extractionState: "manual"` and `localizations.zh-Hans.stringUnit` containing `state: "translated"` and `value`. Dynamic String keys are not automatically extracted.
- Translate faithfully, clearly and naturally. Preserve product/provider/model names, MCP, Git, worktree, token and terms that read worse translated. Native names may have identity translations.
- Later workers deliver UTF-8 JSON fragments: `{"English key": "中文"}`. Keys must match English text exactly (including punctuation); preserve format placeholders. The integrating lead merges fragments into the catalog, not into source code.
- Language selection persists appLanguage and sets/removes the app-domain AppleLanguages override. Changes apply after the app restarts; do not add automatic relaunch behavior.

API reference: [Bundle.localizedString(forKey:value:table:)](https://developer.apple.com/documentation/foundation/bundle/localizedstring(forkey:value:table:)).
