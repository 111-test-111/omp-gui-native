#!/bin/bash
#
# Publishes a release on GitHub: tags the version, uploads the notarized disk
# image and posts the notes from CHANGELOG.md. This is what the app's About
# page update check reads (api.github.com/repos/elijah7x/tivano/releases).
#
#   scripts/publish_release.sh [path/to/Tivano-1.2.3.dmg]
#
# The version is config/release.xcconfig's MARKETING_VERSION; the disk image defaults to
# the one scripts/release.sh leaves in build.noindex. The notes are the ## [<version>] section of CHANGELOG.md, written as "### New features", "### Bug fixes" and "### Refinements" headings with a bullet per change; scripts/build_changelog.py --section extracts it with the headings promoted to "## ", which is what the app reads into its cards. A `### Thanks` heading under the version names every outside contributor whose merge request shipped in it, and publishing stops until `scripts/release_credits.py --check` finds them all named. The tag goes on HEAD, or on RELEASE_REF when
# the version bump has landed on main from elsewhere. Needs gh signed in with
# write access to the repository.
set -euo pipefail

cd "$(dirname "$0")/.."
PROJECT="elijah7x/tivano"
VERSION=$(scripts/version.sh release)
TAG="v$VERSION"
DMG="${1:-build.noindex/Tivano-$VERSION.dmg}"
NOTES="$(mktemp -t tivano-notes)"
python3 scripts/build_changelog.py --section "$VERSION" > "$NOTES" || { echo "No ## [$VERSION] section in CHANGELOG.md. Add one before publishing."; exit 1; }

step() { printf '\n==> %s\n' "$1"; }

[ -f "$DMG" ] || { echo "No disk image at $DMG. Run scripts/release.sh first."; exit 1; }
[ -f "$NOTES" ] || { echo "No release notes at $NOTES."; exit 1; }
if ! grep -qE '^## (New features|Bug fixes|Refinements)' "$NOTES"; then
  echo "$NOTES needs at least one of the three headings: ## New features, ## Bug fixes, ## Refinements."
  exit 1
fi

step "Checking every contributor is thanked"
if ! python3 scripts/release_credits.py --check "$NOTES"; then
  echo "Add a ### Thanks section to the ## [$VERSION] entry in CHANGELOG.md naming them (python3 scripts/release_credits.py prints it), then publish again."
  exit 1
fi

step "Checking the disk image is notarized"
xcrun stapler validate "$DMG" > /dev/null

step "Tagging $TAG"
if ! git rev-parse -q --verify "refs/tags/$TAG" > /dev/null; then
  git tag -a "$TAG" "${RELEASE_REF:-HEAD}" -m "Tivano $VERSION"
fi
git push origin "$TAG"

step "Creating the release"
if gh release view "$TAG" -R "$PROJECT" > /dev/null 2>&1; then
  echo "Release $TAG already exists on GitHub."
  exit 1
fi
gh release create "$TAG" "$DMG#Tivano $VERSION (Apple silicon)" \
  -R "$PROJECT" \
  --name "Tivano $VERSION" \
  --notes-file "$NOTES"

printf '\nPublished: https://github.com/%s/releases/tag/%s\n' "$PROJECT" "$TAG"
