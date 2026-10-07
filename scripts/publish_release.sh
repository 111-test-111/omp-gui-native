#!/bin/bash
# Publishes a built disk image as a GitLab release: what the in-app updater
# offers and what the website's download link resolves to.
#
#   scripts/publish_release.sh [path/to/Droppy-Code-1.2.3.dmg]
#
# The version is project.yml's MARKETING_VERSION; the disk image defaults to
# the one scripts/release.sh leaves in build.noindex. The notes are the ## [<version>] section of CHANGELOG.md, written as "### New features", "### Bug fixes" and "### Refinements" headings with a bullet per change; scripts/build_changelog.py --section extracts it with the headings promoted to "## ", which is what the app reads into its cards. A `### Thanks` heading under the version names every outside contributor whose merge request shipped in it, and publishing stops until `scripts/release_credits.py --check` finds them all named. The tag goes on HEAD, or on RELEASE_REF when
# the version bump has landed on main from elsewhere. Needs glab signed in as
# a maintainer.
# The site's changelog is rebuilt from CHANGELOG.md and deployed here too.
set -euo pipefail

cd "$(dirname "$0")/.."
PROJECT="droppyformac1/droppy-code"
ENCODED_PROJECT="${PROJECT//\//%2F}"
VERSION=$(sed -nE 's/^[[:space:]]*MARKETING_VERSION:[[:space:]]*"([^"]+)".*/\1/p' project.yml | head -1)
TAG="v$VERSION"
DMG="${1:-build.noindex/Droppy-Code-$VERSION.dmg}"
NOTES="$(mktemp -t droppy-code-notes)"
python3 scripts/build_changelog.py --section "$VERSION" > "$NOTES" || { echo "No ## [$VERSION] section in CHANGELOG.md. Add one before publishing."; exit 1; }
# Every release links its image under this path, so GitLab's
# /-/releases/permalink/latest/downloads/Droppy-Code.dmg is always the newest.
ASSET_PATH="/Droppy-Code.dmg"

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
  git tag -a "$TAG" "${RELEASE_REF:-HEAD}" -m "Droppy Code $VERSION"
fi
git push origin "$TAG"

step "Creating the release"
if glab release view "$TAG" -R "$PROJECT" > /dev/null 2>&1; then
  echo "Release $TAG already exists on GitLab."
  exit 1
fi
glab release create "$TAG" "$DMG#Droppy Code $VERSION (Apple silicon)" \
  -R "$PROJECT" \
  --name "Droppy Code $VERSION" \
  --notes-file "$NOTES"

step "Pointing the latest-download permalink at it"
LINK_ID=$(glab api "projects/$ENCODED_PROJECT/releases/$TAG/assets/links" \
  | python3 -c 'import json, sys; links = json.load(sys.stdin); print(next(l["id"] for l in links if l["url"].lower().endswith(".dmg")))')
# GitLab insists on a name or url in every link update, so the name rides along.
glab api -X PUT "projects/$ENCODED_PROJECT/releases/$TAG/assets/links/$LINK_ID" \
  -f "name=Droppy Code $VERSION (Apple silicon)" -f "direct_asset_path=$ASSET_PATH" -f link_type=package > /dev/null

step "Checking the permalink"
curl -sIL "https://gitlab.com/$PROJECT/-/releases/permalink/latest/downloads${ASSET_PATH}" | grep -i "content-disposition"

step "Rebuilding the changelog and deploying the site"
scripts/deploy_site.sh

printf '\nPublished: https://gitlab.com/%s/-/releases/%s\n' "$PROJECT" "$TAG"
