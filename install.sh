#!/bin/bash
# Build Universe and install it into /Applications.
#
# The app is ad-hoc signed (CODE_SIGN_IDENTITY "-"), which is fine for running on
# the machine that built it. It is deliberately not a .dmg: distributing to other
# Macs needs a Developer ID certificate and notarization, which we do not have.
set -euo pipefail

cd "$(dirname "$0")"

CONFIGURATION="${1:-Release}"
DEST="/Applications/Universe.app"

command -v xcodebuild >/dev/null || { echo "xcodebuild not found. Install Xcode."; exit 1; }

if command -v xcodegen >/dev/null; then
  echo "==> Regenerating the Xcode project"
  xcodegen generate >/dev/null
fi

echo "==> Running the offline self-test"
swift build >/dev/null
./.build/debug/Universe --selftest

echo "==> Building ($CONFIGURATION)"
xcodebuild -project Universe.xcodeproj -scheme Universe -configuration "$CONFIGURATION" build >/dev/null

APP=$(xcodebuild -project Universe.xcodeproj -scheme Universe -configuration "$CONFIGURATION" \
  -showBuildSettings 2>/dev/null \
  | awk -F' = ' '/ BUILT_PRODUCTS_DIR/{d=$2} / FULL_PRODUCT_NAME/{n=$2} END{print d"/"n}')

[ -d "$APP" ] || { echo "Build produced no app bundle at: $APP"; exit 1; }

# Quit a running copy first, or the replace below leaves a half-updated bundle.
if pgrep -x Universe >/dev/null; then
  echo "==> Quitting the running copy"
  osascript -e 'tell application id "com.universe.app" to quit' 2>/dev/null || pkill -x Universe || true
  sleep 2
fi

echo "==> Installing to $DEST"
rm -rf "$DEST"
cp -R "$APP" "$DEST"

echo
echo "Installed: $DEST"
echo "Open it with:  open -a Universe"
echo "Then sign in:  menubar icon (speech bubbles) -> Settings -> Sign in with Claude"
echo "Global hotkey: Option-Space"
