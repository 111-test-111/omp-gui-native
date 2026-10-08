# Local development signing

Debug and locally packaged Release use the persistent **Tivano Local Development**
self-signed identity. It is for this Mac only, not Developer ID or notarized
public distribution. See [packaging](packaging.md) for the package-and-install
contract and independently versioned Release / Dev editions.

## One-time setup

```bash
scripts/setup_local_signing.sh
```

The script reuses an existing certificate rather than regenerating it. If absent,
it creates a ten-year RSA code-signing certificate and imports the identity into
the user's login keychain. Trust is scoped to code signing in the user domain;
it does not modify the System keychain, Gatekeeper settings or the TCC database.
Only `/usr/bin/codesign` gets private-key access. Temporary keys and PKCS#12 files
are removed; no credentials belong in this repository. macOS may request a
one-time Keychain authorization.

Do not delete/recreate the identity between builds. If its private key is missing,
restore it from your own secure Keychain backup rather than making a different
certificate with the same name. Each Mac has its own identity and local grants.

## Build without launching

```bash
xcodebuild -project Tivano.xcodeproj -scheme Tivano -configuration Debug \
  -destination 'platform=macOS' -derivedDataPath build.noindex/dev \
  -skipPackagePluginValidation build
```

Debug is manually signed and has hardened runtime disabled for local development
with a non-Apple identity. Release retains hardened runtime and Developer ID
signing. Do not use the local certificate for public releases or weaken the
updater's production signature verification to accept it.

## Install and run (only when explicitly requested)

```bash
scripts/quick_run.sh
```

This quits Dev if it is running, packages and verifies the new app, then
installs/relaunches `/Applications/Tivano Dev.app`. It is only for an explicitly
requested run/relaunch. Packaging alone uses `scripts/package_local.sh` and
never launches or quits apps. Both refuse a missing/ambiguous identity and never
fall back to ad-hoc signing. Keep using the stable install paths and bundle IDs;
switching to Release creates a different privacy identity but uses the same
[real session store](shared-library.md).

A stable certificate and designated requirement let subsystems recognize an
updated build as the same application. Changing from the old/ad-hoc identity
may still require granting permissions once. This is **not** a bypass of macOS
privacy controls: accessibility, screen recording, automation and other grants
remain subject to their own policies. Actual permission persistence must be
checked by the owner across explicitly authorized installs/relaunches.

When Developer ID is available, configure the Release team/certificate, release
script and updater's expected team together. Existing upstream release team
placeholders are not credentials and are not usable for this fork's release.

## Verification

```bash
codesign --verify --deep --strict --verbose=2 \
  'build.noindex/dev/Build/Products/Debug/Tivano Dev.app'
codesign -d -r- 'build.noindex/dev/Build/Products/Debug/Tivano Dev.app'
```

The designated requirement must pin `dev.tivano.Tivano.dev` and the persistent
certificate, not a build-dependent `cdhash`. This setup was checked with two
builds carrying different build numbers: their content hashes differed while
the designated requirements were identical. No application relaunch or TCC
permission test was performed by that build-only check.

Source: [Apple TN2206 — macOS Code Signing In Depth](https://developer.apple.com/library/archive/technotes/tn2206/_index.html),
particularly Code Designated Requirement and Self-signed Identities.
