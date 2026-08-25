#!/bin/zsh
set -euo pipefail

cd "$(dirname "$0")/.."
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"

VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' AppSupport/Info.plist)"
TAG="v${VERSION}"
NOTES="${1:-PasteHub ${VERSION}}"

SKIP_INSTALL=1 zsh Scripts/build-app.sh release
ZIP="dist/PasteHub.app.zip"
rm -f "$ZIP"
ditto -c -k --keepParent dist/PasteHub.app "$ZIP"

if git rev-parse "$TAG" >/dev/null 2>&1; then
  echo "Tag $TAG already exists"
else
  git tag -a "$TAG" -m "$NOTES"
  git push origin "$TAG"
fi

gh release create "$TAG" "$ZIP" \
  --title "PasteHub $VERSION" \
  --notes "$NOTES" \
  --verify-tag

echo "Published $TAG with $ZIP"
