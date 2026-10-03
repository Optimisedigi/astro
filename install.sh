#!/usr/bin/env bash
# Build Astro and install it into /Applications.
#
# The app is signed with the local Apple Development certificate so macOS TCC
# (Privacy & Security permissions) recognises it. It is deliberately not a .dmg:
# distributing to other Macs needs a Developer ID certificate and notarization.
set -euo pipefail
IFS=$'\n\t'

readonly CONFIGURATION="${1:-Release}"
readonly DEST="/Applications/Astro.app"
# The app used to be called Universe. It has the same bundle ID, so leaving it
# installed would give macOS two copies of one app. It goes to the Trash (not
# deleted) so it can be restored.
readonly LEGACY="/Applications/Universe.app"
readonly LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"

prepare_research_folder() {
  local reports="$HOME/Documents/astro"
  if [[ -L "$reports" ]]; then
    printf '%s\n' "Research folder is a symbolic link: $reports. Replace it with a normal folder." >&2
    return 1
  fi
  mkdir -p "$reports"
}

main() {
  cd "$(dirname "$0")"

  command -v xcodebuild >/dev/null || { echo "xcodebuild not found. Install Xcode."; exit 1; }

  if command -v xcodegen >/dev/null; then
    echo "==> Regenerating the Xcode project"
    xcodegen generate >/dev/null
  fi

  # Self-test never touches the Keychain (see KeychainHelper.isSelfTest). Do not
  # codesign this CLI binary as com.universe.app — that made macOS treat a naked
  # `exec` as the app and popped a lock dialog that Always Allow could not settle.
  echo "==> Running the offline self-test"
  swift build >/dev/null
  ./.build/debug/Universe --selftest

  echo "==> Building ($CONFIGURATION)"
  xcodebuild -project Universe.xcodeproj -scheme Universe -configuration "$CONFIGURATION" build >/dev/null

  local app
  app=$(xcodebuild -project Universe.xcodeproj -scheme Universe -configuration "$CONFIGURATION" \
    -showBuildSettings 2>/dev/null \
    | awk -F' = ' '/ BUILT_PRODUCTS_DIR/{d=$2} / FULL_PRODUCT_NAME/{n=$2} END{print d"/"n}')

  [[ -d "$app" ]] || { echo "Build produced no app bundle at: $app"; exit 1; }

  echo "==> Preparing Documents/astro for research reports"
  prepare_research_folder

  # Quit a running copy first (under either name), or the replace below leaves a
  # half-updated bundle.
  if pgrep -x Astro >/dev/null || pgrep -x Universe >/dev/null; then
    echo "==> Quitting the running copy"
    # Fallbacks only: a copy that is not running makes pkill exit non-zero.
    osascript -e 'tell application id "com.universe.app" to quit' 2>/dev/null \
      || pkill -x Astro || pkill -x Universe || true
    sleep 2
  fi

  echo "==> Installing to $DEST"
  rm -rf "$DEST"
  # Moved, not copied: a copy left in the build folder is a second Astro that
  # Spotlight and macOS can open instead of this one. The next build remakes it.
  mv "$app" "$DEST"
  "$LSREGISTER" -f "$DEST"

  if [[ -d "$LEGACY" ]]; then
    local trashed
    trashed="$HOME/.Trash/Universe-$(date +%Y%m%d-%H%M%S).app"
    echo "==> Moving the old Universe.app to the Trash (now Astro.app)"
    mv "$LEGACY" "$trashed"
  fi

  # The Xcode build already signs the app with the Apple Development certificate,
  # so the installed copy keeps a stable identity for macOS TCC.

  echo
  echo "Installed: $DEST"
  echo "Open it with:  open /Applications/Astro.app"
  echo "Then sign in:  menubar icon -> Settings -> Sign in with Claude"
  echo "Global hotkey: Option-Space"
}

main "$@"
