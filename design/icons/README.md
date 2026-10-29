# Application and Hydra artwork

## Approved application icons

OMP GUI retains Tivano's approved release artwork, v1.4 System-Masked. Original delivery packages are held outside this repository. Product and artwork version numbers are independent.

- Release: [AppIcon.appiconset](../../OMPGUI/Resources/Assets.xcassets/AppIcon.appiconset).
- Dev: [AppIconDev.appiconset](../../OMPGUI/Resources/Assets.xcassets/AppIconDev.appiconset), derived by [generate_dev_icon.swift](../../scripts/generate_dev_icon.swift) with a DEV badge.
- [docs/icon.png](../../docs/icon.png) is the legacy documentation presentation export.
- The system applies the outer mask; preserve full-square input without adding rounded corners or enlarging the artwork.

Do not alter approved upstream icons as part of routine UI or documentation work. A generator is a maintenance tool, not permission to regenerate assets. Current local packaging produces app bundles/ZIPs; the retained [DMG artwork](../../release/dmg/README.md) is historical and has no active packaging entry point.

Provider marks retained for fixture/archive decoding do not make their runtimes selectable. Preserve [trademark policy](../../TRADEMARK.md) and [third-party attribution](../../THIRD_PARTY_NOTICES.md).

## OMP browser mark

The new-tab page uses [BrowserMarkImage](../../OMPGUI/App/Browser/BrowserWorkspacePane.swift),
a compact 56 pt composition of the existing
[OMP π mark](../../OMPGUI/Resources/Assets.xcassets/provider-omp.imageset) and a small
SF Symbols globe at the lower right. The OMP artwork remains unchanged and follows
the theme accent; the noninteractive globe has a plain background matching the
page canvas. No application, provider or Hydra artwork is replaced.

## Native provider logos

The native model rail, configured/login provider settings and API-key editor share
[NativeProviderIcon](../../OMPGUI/UI/Common/NativeProviderIcon.swift). Its exact native-ID mapping
retains **74** monochrome SVGs, with **72** active marks for **96** provider/login IDs, from
[`@lobehub/icons-static-svg` 1.101.0](https://www.npmjs.com/package/@lobehub/icons-static-svg/v/1.101.0),
[Lobe Icons revision aea0ecb0](https://github.com/lobehub/lobe-icons/tree/aea0ecb0fe1439467219197c52ffaeb579dfe33f).
The single [runtime manifest](../../OMPGUI/Resources/ProviderLogos.json) records every original
and normalized SHA-256 hash, source version and explicit alias. [The design entry point](provider-logos.json)
is a relative symlink to that resource, preserving existing links without a second table.
The original [MIT license](lobe-icons-LICENSE.txt), © 2023 LobeHub,
is also retained in the app-bundled [third-party notices](../../THIRD_PARTY_NOTICES.md).

Original paths and viewBoxes are preserved. Only `currentColor` is normalized to
`#000000`, intrinsic `1em` dimensions are expressed in viewBox units, and browser-only
root flex styling is omitted. Xcode compiles these as preserved-vector native templates;
the app has no added package, runtime SVG parser or CDN dependency. The 20 pt rail and
settings marks follow native text tint; key-editor marks are 18 pt. Brands retain their
owners' trademarks. Existing approved app, provider and Hydra assets remain unchanged.

ChatGPT Codex browser and device-code login IDs share the recognizable OpenAI knot.
The original terminal-in-knot Codex artwork remains unmodified as a retained asset;
its empty alias list in the manifest distinguishes retention from active display.
OpenRouter uses an owner-selected uppercase **O** in every surface. Its original
artwork also remains retained; `initialOnlyProviders` makes this an explicit style
choice. Initials render at 125% of the nominal 20/18 pt image slot, keeping the slot
and click target fixed while making capital letters visually closer to the SVG marks.
Known region, plan and login IDs are listed explicitly: Z.ai API keys, Z.ai sign-in
and Zhipu Coding Plan share Z.ai; Xiaomi's three regional Token Plans share MiMo;
Azure, Fire Pass, OpenCode Zen and Qwen Portal have reviewed assignments. Alibaba
Coding Plan uses Alibaba Cloud rather than inferring a brand from the offered models.
Branding never changes provider IDs, endpoints, credentials or account grouping.
Unlisted/custom IDs use the uppercase first letter of their display name, without
substring brand guesses. Unicode names retain their first glyph.
The `omp` group keeps the existing OMP asset. An icon mapping is presentation only and
never adds a runtime adapter. [Provider-logo checks](../../tests/functional/appearance/provider_logo_tests.swift)
verify aliases, checksums, bundle images, visible pixels and transparent canvases.
The [public native-identity audit](../../docs/evaluations/2026-10-26-provider-brand-audit/native-identities.json)
also covers all 99 model/catalog/authentication IDs inspected in OMP 18.12.5: 76 branded
IDs, OpenRouter's chosen initial, and 22 explained initial fallbacks. New native versions require another public
identity audit; neither display names, endpoints nor credential aliases dynamically
assign a logo. A missing dedicated mark is preferable to an unrelated brand match.

The same manifest provides reviewed fallback display names. Live native names remain
authoritative; model-only IDs such as `minimax-cn` use **MiniMax (China)**, with zh-Hans
translation for app-authored labels. Configured providers, model lists, key editing
and image-backend labels share this presentation path. Search keeps the native ID,
readable/localized names and declared environment-key names; the display name never
rewrites the credential identity.

## Hydra: π 小队 / Pi Crew

Hydra uses the original Tivano team mark and 25 subagent avatars. The existing roster supplies each avatar's name, order and colour; status badges, breathing rings, layout and interactions are unchanged.

- Current mark: [hydra-mark.imageset](../../OMPGUI/Resources/Assets.xcassets/hydra-mark.imageset).
- Current avatars: `hydra-head-01` through `hydra-head-25` in the [asset catalog](../../OMPGUI/Resources/Assets.xcassets), matching Hank through Gus in [HydraRoster](../../OMPGUI/Core/Models/Hydra.swift).
- Shared selection: `HydraArtwork.current` in that same model selects `.legacyHydra`. The mark, SwiftUI avatars and native Markdown mention attachments all resolve through this selection; no new preference or runtime migration is involved.
- Preserved custom artwork: [pi-crew-mark.imageset](../../OMPGUI/Resources/Assets.xcassets/pi-crew-mark.imageset) and all 25 `pi-crew-head-*` image sets remain bundled and unmodified. Change the selector to `.piCrew` and rebuild to use them again. The inherited [Hydra generator](../../scripts/hydra_heads.py) continues to target only the original Hydra assets.

The preserved Pi Crew design has a compact team mark and 25 individual π-shaped avatars, redrawn as editable, single-colour SVG templates. The 100 × 100 canvases share capsule eye cutouts and an open space between the legs. Their perimeters use tangent-continuous quadratic curves, removing sharp steps and small notches at the cap, shoulder and leg joins. Legs are reduced 12% vertically below the shoulder line relative to the original rounded design, while cap and eye positions stay fixed. Broad cap shapes, width, height and asymmetry distinguish the avatars in monochrome; eye placement stays consistent. Transparent eyes reveal the actual light or dark surface.

Pi Crew is original GUI artwork derived from the approved conversation concept, inspired by OMP's π geometry. It does not replace the approved application icons or provider marks. Its single-colour rendering follows the existing Hydra tint and status system without the concept board's large presentation gradient on compact controls.

## Custom tool SF Symbols

The editable custom symbols use native paths exported from Apple's **SF Symbols
27.0** app, with **Xcode 26 and later** compatibility; the deployment target
remains macOS 26.

| Asset | Body | Filled circular badge | Position |
| --- | --- | --- | --- |
| [tool-find-folder](../../OMPGUI/Resources/Assets.xcassets/tool-find-folder.symbolset) | `folder` | `magnifyingglass.circle.fill` | Upper right |
| [tool-glob-folder](../../OMPGUI/Resources/Assets.xcassets/tool-glob-folder.symbolset) | `folder` | `asterisk.circle.fill` | Upper right |
| [tool-analyze-files](../../OMPGUI/Resources/Assets.xcassets/tool-analyze-files.symbolset) | `text.menu` | `magnifyingglass.circle.fill` | Lower right |

The folder compositions retain the native circle centre of
`folder.badge.questionmark`. Circle diameter and its surrounding erase path are
**130%** of the original badge size, across all three masters. The bodies remain
unchanged. Analyze-files uses that same enlarged circle, reflecting the native
vertical overlap to the lower right of `text.menu`. Trailing margins include
the additional badge width. The asterisk is a reversed contour inside the filled
circle; all internal cutouts and surrounding gaps remain transparent.

Custom combinations follow the owner-selected rule: **outline body + filled
circular badge**, with a transparent symbol cutout and surrounding gap. Badges
normally sit at the upper right; analyze-files explicitly uses the lower right.
Use native `*.circle.fill` paths, such as `magnifyingglass.circle.fill`,
`asterisk.circle.fill` or `pencil.circle.fill`, retaining their compound-path
cutouts. Candidate combinations in the audit follow this same rule.

The SVG retains Ultralight-S, Regular-S and Black-S masters, native margins,
baseline/capline guides, layer annotations and `-sfsymbols-clear-behind` paths.
Xcode compiles the Symbol Image Set; SwiftUI loads it by asset name through
`SFSymbolResource.custom`, without resizing a bitmap or overlaying a background
colour. Native symbol font configuration supplies the other weights/scales.
Monochrome tint, the 12 pt font / 16 pt slot and existing failure/refusal states
remain shared with system symbols.

To revise it, edit the SVG paths, import and validate in SF Symbols, then export
the symbol and replace this SVG. Keep the Symbol Image Set and erase annotations. This
Apple-derived artwork follows the SF Symbols license distributed with Apple's
tool; it is not part of the retained MIT Tabler set. See Apple's
[custom-symbol guide](https://developer.apple.com/documentation/technologyoverviews/custom-sf-symbols)
and [symbol-component workflow](https://developer.apple.com/videos/play/wwdc2023/10257/).
The [2026-10-28 audit](../../docs/archive/tool-symbol-audit-2026-10-28.md) records
the original preview and candidates. The [four-tool refinement record](../../docs/archive/tool-symbol-refinements-2026-10-28.md)
shows the enlarged badges, new glob/analyze-files compositions and native `text.menu`
read glyph. Other candidates remain proposals.

## Tool-row Tabler artwork

Transcript, thinking, notice, plan and Hydra detail rows now use native SF Symbols
from [OMPToolSymbols.swift](../../OMPGUI/UI/Common/OMPToolSymbols.swift) and the
shared [TimelineRowIcon.swift](../../OMPGUI/UI/Common/TimelineRowIcon.swift) style:
a 12 pt symbol font in a 16 pt slot. The [tool catalog](../../docs/OMP_TOOLS.md)
lists all 63 native tool/action mappings. Native tool records in session history
share the same glyphs and sizing. Hydra avatars and existing MCP asset overrides
remain intact.

The former 67 `tool-tabler-*` image sets remain preserved and inactive in the
[asset catalog](../../OMPGUI/Resources/Assets.xcassets), including category,
unknown-extension, MCP, image-preview, notice and plan artwork. Each remains an
unaltered preserved-vector monochrome template.

Source: [Tabler Icons revision a4ce1404](https://github.com/tabler/tabler-icons/tree/a4ce1404bc6d24d3c365afe7b258d6bf6f48d62d),
`icons/outline/<name>.svg`, MIT © 2020–2026 Paweł Kuna. Original 24 × 24 paths,
2-unit strokes, round caps and joins are retained. Only `stroke="currentColor"` is
normalized to `stroke="#000000"`; Xcode compiles the SVGs into native template images.
No icon package or runtime SVG parser is added. The full original MIT license is
in [THIRD_PARTY_NOTICES.md](../../THIRD_PARTY_NOTICES.md#tabler-icons), which is bundled with the app.

Active row glyphs keep semantic foreground colours and failure/refusal behaviour.
Controls, disclosure arrows and status overlays retain their own SF Symbol sizing.
