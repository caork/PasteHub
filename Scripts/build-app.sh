#!/bin/zsh
set -euo pipefail

cd "$(dirname "$0")/.."
CONFIG="${1:-debug}"
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"

swift build -c "$CONFIG" --product PasteHub
BIN="$(swift build -c "$CONFIG" --show-bin-path)/PasteHub"
APP="dist/PasteHub.app"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/PasteHub"
cp AppSupport/Info.plist "$APP/Contents/Info.plist"
echo -n "APPL????" > "$APP/Contents/PkgInfo"

IDENTITY="${CODESIGN_IDENTITY:-Apple Development: caorunkai@qq.com (3S8J4T3HQ7)}"
if codesign --force --sign "$IDENTITY" --entitlements AppSupport/PasteHub.entitlements --identifier com.kaitaocao.PasteHub "$APP" >/dev/null 2>&1; then
  echo "Signed with $IDENTITY"
else
  echo "Falling back to ad-hoc signature"
  codesign --force --sign - --entitlements AppSupport/PasteHub.entitlements "$APP" >/dev/null
fi

if [[ "${SKIP_INSTALL:-}" != "1" ]]; then
  INSTALL="${INSTALL_APP:-/Applications/PasteHub.app}"
  rm -rf "$INSTALL"
  cp -R "$APP" "$INSTALL"
  echo "Installed $INSTALL"
fi
echo "Built $APP"
