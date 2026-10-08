# Tivano app icon

The active release artwork is v1.2 System-Masked. The original v1, v1.1 and
v1.2 delivery packages are retained in a private archive outside this repository.

The system applies the outer icon mask. Keep the full square input; do not add
outer rounded corners or enlarge the artwork to fill the mask.

- Release resources: `Tivano/Resources/Assets.xcassets/AppIcon.appiconset/`.
- Dev resources: `AppIconDev.appiconset`, derived from the release catalog by
  `swift scripts/generate_dev_icon.swift`, adding the DEV corner badge.
- `docs/icon.png` is the Legacy presentation export for documentation.
- DMG packaging uses the built release `AppIcon.icns` as its volume icon.

Artwork versions are independent of application versions. Do not edit the
archived originals; derive new exports from them when updating the icon.
