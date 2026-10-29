# Retained Tivano DMG artwork

These are inherited Tivano installer assets. OMP GUI currently packages local app bundles and ZIPs through [package_local.sh](../../scripts/package_local.sh); it has no active DMG workflow or public release feed. The old `scripts/package_dmg.sh` is absent, and release/publication scripts are disabled. Follow the [current package contract](../../docs/packaging.md).

| Asset | Historical purpose |
| --- | --- |
| `installer-background.tiff` | HiDPI 1x/2x Finder window background |
| `installer-DS_Store.base64` | Encoded Finder geometry and name-based aliases |
| `dmgbuild_settings.py` | Historical Tivano bake layout |
| `generate_installer_background.swift` | Artwork generator, not a package entry point |

The baked alias expects volume `Tivano`, app `Tivano.app`, link `Applications` and background `/.background.tiff`. Its composition is 660×400 with icon centers (165, 200)/(495, 200) and 660×480 window bounds. Those names are part of the old asset, **not** OMP GUI's bundle identity.

Do not reuse the baked asset by merely renaming the volume or app. Any future DMG work needs its own authorized design, alias/geometry verification, fork bundle checks and signed/notarized distribution plan. Prior procedures remain in Git and the [retired public release record](../../docs/archive/tivano-public-release.md); they are not executable setup instructions for this fork. Preserve the [approved icons](../../design/icons/README.md).
