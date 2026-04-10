#!/bin/bash
# Build clawbridge, wrap in a .app bundle so TCC sees it as a real app,
# ad-hoc sign it, and install to ~/Applications/Clawbridge.app with a
# CLI symlink at ~/.local/bin/clawbridge.
set -euo pipefail

cd "$(dirname "$0")"

echo "==> Building release binary"
swift build -c release

BIN_SRC=".build/release/clawbridge"
if [ ! -x "$BIN_SRC" ]; then
  echo "ERROR: build did not produce $BIN_SRC" >&2
  exit 1
fi

echo "==> Rendering icon"
rm -rf build/Clawbridge.iconset
swift Resources/make-icon.swift build/Clawbridge.iconset >/dev/null
iconutil -c icns build/Clawbridge.iconset -o build/Clawbridge.icns

APP_STAGING="build/Clawbridge.app"
echo "==> Assembling $APP_STAGING"
rm -rf "$APP_STAGING"
mkdir -p "$APP_STAGING/Contents/MacOS" "$APP_STAGING/Contents/Resources"
cp "$BIN_SRC" "$APP_STAGING/Contents/MacOS/clawbridge"
cp Resources/Info.plist "$APP_STAGING/Contents/Info.plist"
cp build/Clawbridge.icns "$APP_STAGING/Contents/Resources/Clawbridge.icns"
printf "APPL????" > "$APP_STAGING/Contents/PkgInfo"

echo "==> Ad-hoc signing"
codesign --force --deep --sign - "$APP_STAGING"
codesign --verify --verbose "$APP_STAGING" 2>&1 | head -5

APP_INSTALL="$HOME/Applications/Clawbridge.app"
echo "==> Installing to $APP_INSTALL"
mkdir -p "$HOME/Applications"
rm -rf "$APP_INSTALL"
cp -R "$APP_STAGING" "$APP_INSTALL"

SYMLINK="$HOME/.local/bin/clawbridge"
mkdir -p "$HOME/.local/bin"
ln -sf "$APP_INSTALL/Contents/MacOS/clawbridge" "$SYMLINK"
echo "==> CLI symlink: $SYMLINK"

echo
echo "Done. Next steps:"
echo "  1. Open $APP_INSTALL once from Finder so macOS prompts for Calendar access."
echo "  2. Grant access when prompted."
echo "  3. Run: clawbridge calendar today"
