#!/usr/bin/env bash
# Cut a release of GcloudBar from a clean, pushed main.
#
#   release.sh 1.2.0           build + test here, then tag v1.2.0 and push the tag;
#                              GitHub Actions (release.yml) builds and publishes it
#   release.sh --local 1.2.0   build + test here, then publish this Mac's build
#                              with `gh release create` (no Actions needed)
#
# Releases are signed with a "Developer ID Application" identity when the
# keychain has one (or CODESIGN_IDENTITY names one), otherwise ad-hoc — never
# with an Apple Development certificate, whose signature carries the developer's
# personal Apple ID into every download.
set -euo pipefail

LOCAL=0
if [ "${1:-}" = "--local" ]; then
    LOCAL=1
    shift
fi
VERSION="${1:-}"
VERSION="${VERSION#v}"
TAG="v$VERSION"
cd "$(dirname "$0")/.."

die() { echo "release: $*" >&2; exit 1; }

[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.]+)?$ ]] \
    || die "give a version like 1.2.0 (got '${1:-}')"
git rev-parse --git-dir > /dev/null 2>&1 || die "not a git repository"
[ -z "$(git status --porcelain)" ] || die "uncommitted changes; commit or stash them first"
branch=$(git rev-parse --abbrev-ref HEAD)
[ "$branch" = main ] || die "on '$branch'; releases are cut from main"
git rev-parse -q --verify "refs/tags/$TAG" > /dev/null && die "tag $TAG already exists"
git fetch -q origin main
[ "$(git rev-parse HEAD)" = "$(git rev-parse origin/main)" ] \
    || die "main differs from origin/main; push or pull first"

echo "→ build and end-to-end tests"
packaging/build.sh
tests/e2e.sh

if [ "$LOCAL" = 0 ]; then
    git tag -a "$TAG" -m "GcloudBar $VERSION"
    git push origin "$TAG"
    echo "→ pushed $TAG; GitHub Actions builds and publishes the release:"
    echo "  $(gh browse --no-browser 2>/dev/null)/actions/workflows/release.yml"
    exit 0
fi

IDENTITY="${CODESIGN_IDENTITY:-$(security find-identity -v -p codesigning 2> /dev/null \
    | awk -F'"' '/Developer ID Application/ {print $2; exit}')}"
echo "→ universal build ${IDENTITY:+signed by $IDENTITY}"
rm -rf dist
VERSION="$VERSION" UNIVERSAL=1 SHARED=1 CODESIGN_IDENTITY="${IDENTITY:--}" packaging/build.sh dist/GcloudBar.app
ditto -c -k --keepParent dist/GcloudBar.app dist/GcloudBar.zip
(cd dist && shasum -a 256 GcloudBar.zip > GcloudBar.zip.sha256)

notes="Download **GcloudBar.zip**, unzip it and move **GcloudBar.app** to Applications.
Requires macOS 14 or later and the Google Cloud CLI; runs on Apple silicon and Intel.

This build is not notarized. On first launch macOS will refuse to open it: open
**System Settings → Privacy & Security** and click **Open Anyway**, or run
\`xattr -dr com.apple.quarantine /Applications/GcloudBar.app\`."

# Creating the release also creates the tag on GitHub; release.yml sees the
# existing release and stands down instead of building a second copy.
gh release create "$TAG" dist/GcloudBar.zip dist/GcloudBar.zip.sha256 \
    --target "$(git rev-parse HEAD)" --title "GcloudBar $VERSION" \
    --notes "$notes" --generate-notes
git fetch -q --tags origin
echo "→ published $TAG"
