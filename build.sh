#!/bin/bash
# Build clawbridge, wrap in a .app bundle so TCC sees it as a real app,
# sign it with a STABLE identity, and install to ~/Applications/Clawbridge.app
# with a CLI symlink at ~/.local/bin/clawbridge.
#
# Signing identity matters for TCC: macOS keys Calendar/Reminders/Automation
# grants to the app's designated requirement. Ad-hoc signing (`--sign -`)
# produces a fresh cdhash on every rebuild, so each rebuild looked like a
# brand-new app and silently invalidated the grant — the next unattended
# cron call then blocked on a consent dialog with no GUI to answer it,
# hanging the session lock for ~35 min. Signing with a real Developer ID
# (stable Team ID) makes the grant survive rebuilds. Switching identity is
# a one-time re-grant; same identity thereafter = no re-grant.
#
# Override the identity via CLAWBRIDGE_SIGN_ID if needed.
set -euo pipefail

SIGN_ID="${CLAWBRIDGE_SIGN_ID:-Developer ID Application: Theodorus Jansen (SCP9WFJV88)}"

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

echo "==> Signing with: $SIGN_ID"
if ! security find-identity -p codesigning -v | grep -qF "$SIGN_ID"; then
  echo "ERROR: signing identity not found in keychain: $SIGN_ID" >&2
  echo "       Available identities:" >&2
  security find-identity -p codesigning -v >&2
  exit 1
fi
codesign --force --deep --sign "$SIGN_ID" "$APP_STAGING"
codesign --verify --verbose "$APP_STAGING" 2>&1 | head -5
echo "==> Designated requirement (TCC keys on this):"
codesign -d -r- "$APP_STAGING" 2>&1 | grep -i 'designated' || true

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
echo "  1. ONE-TIME re-grant (identity changed from ad-hoc to Developer ID):"
echo "     run from a GUI terminal:  clawbridge permissions"
echo "     and click Allow on each system dialog (Calendar, Reminders, Mail)."
echo "  2. Verify:  clawbridge permissions --check --domain calendar"
echo "  3. Future rebuilds with the same identity need NO re-grant."
