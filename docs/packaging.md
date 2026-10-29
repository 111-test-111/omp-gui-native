# Local packaging and installation

This fork publishes source on GitHub, not signed binary releases. The [release](../scripts/release.sh), [ship](../scripts/ship.sh) and [publisher](../scripts/publish_release.sh) scripts exit with an error. The inherited updater is gated by `UpdateChecker.hasReleaseFeed = false`. Tivano's old release and mirror procedures are [historical records](archive/README.md), not OMP GUI operations. See the [source-release notes](source-release.md) for public history and authentication boundaries.

## Authorization and entry point

A local package request uses [scripts/package_local.sh](../scripts/package_local.sh) and also updates the requested installed edition. Build-only verification uses `make build`; the package script has no build-only option. Packaging does not authorize launching, relaunching, publication or quitting a running app. Follow the owner's explicit scope and [AGENTS.md](../AGENTS.md).

```sh
# Run only for the requested edition(s), from this task's worktree:
scripts/package_local.sh --dev
scripts/package_local.sh --release
scripts/package_local.sh --both
```

The default, if no flag is supplied, is `--both`; always pass the intended flag. The script refuses to replace a running target. Obtain the owner's authorization to quit the specific instance if necessary, and verify it exited before continuing.

| Edition | Configuration | Installed bundle | Bundle ID |
| --- | --- | --- | --- |
| Release | Release | `/Applications/OMP GUI.app` | `dev.ompgui.mac` |
| Dev | Debug, optimized for packaging | `/Applications/OMP GUI Dev.app` | `dev.ompgui.mac.dev` |

## Signing preflight and current limitation

Both editions must name the same ten-character `DEVELOPMENT_TEAM` in [release.xcconfig](../config/release.xcconfig) and [dev.xcconfig](../config/dev.xcconfig), and the build Mac must have exactly one usable matching Developer ID Application identity with its private key.

As of the documentation audit, Release defines `5WF7HRPLRX` and Dev has **no** `DEVELOPMENT_TEAM` entry. The script therefore stops with “Release and Dev must use the same Developer ID team.” even for a single-edition request. This is an unresolved configuration prerequisite, not evidence of a successful package. Reconcile it as part of an authorized packaging/configuration task; a passing unsigned development build does not resolve it.

The script passes the selected identity/team explicitly to Xcode and verifies bundle identifier, Developer ID requirement, hardened runtime, secure timestamp and numeric version. Do not bypass these checks or replace them with ad-hoc signing. Local ZIPs are not notarized distribution artifacts; this script does not submit to Apple or create a DMG.

The [browser runtime](browser.md) adds an embedded CEF framework and five helper bundles with edition-specific IDs. The Xcode embed phase signs nested dylibs, framework and helpers using the selected Developer ID, hardened runtime and timestamps before Xcode signs the main app. The main app and helpers carry the CEF JIT/unsigned executable memory entitlements. Library validation stays enabled because all embedded libraries are re-signed with the same Developer ID. The main Info.plist sets `LSEnvironment.MallocNanoZone=0`, as required by the Chromium allocator. Chromium sandbox stays enabled in both editions. The signed CEF/sandbox combination requires its own authorized package/runtime acceptance; an unsigned `make build` does not certify it.

## Outputs and replacement

Builds/logs are under `build.noindex/dev` and `build.noindex/release`. ZIPs are under `build.noindex/packages/` with the product name and display version. All requested builds are verified before installation starts.

[scripts/install_app.sh](../scripts/install_app.sh) stages a verified app before swapping the corresponding bundle and keeps prior installations under `build.noindex/install-backups/`. It rechecks that the destination is not running. Each installation has rollback handling; installing both editions is not a transaction across the two destinations. Neither script copies or deletes live application data.

## Independent versions

[config/dev.xcconfig](../config/dev.xcconfig) and [config/release.xcconfig](../config/release.xcconfig) own the numeric marketing version and internal build number. The app adds `dev-` only for Dev presentation; Apple's bundle version remains numeric.

```sh
scripts/version.sh dev display
scripts/version.sh release
```

[scripts/set_version.py](../scripts/set_version.py) changes one edition and increments its build number. Release `catch-up-dev` copies Dev's numeric version; it does not select or promote a source revision. Packaging itself does not bump versions or synchronize editions. A Release catch-up must use the owner-approved code and scope.

Edition data paths and external OMP ownership are documented once in [data and configuration](shared-library.md). Developer ID signing does not itself grant Keychain, Accessibility or Screen Recording access.
