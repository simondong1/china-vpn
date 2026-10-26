#!/bin/bash
# Installs or updates DongVPN. Downloads made with curl are not quarantined,
# so macOS opens the app without a Gatekeeper prompt.
#   curl -fsSL https://github.com/simondong1/china-vpn/releases/latest/download/install.sh | bash
set -euo pipefail

DMG_URL="${DONGVPN_DMG_URL:-https://github.com/simondong1/china-vpn/releases/latest/download/DongVPN.dmg}"
WORK=$(mktemp -d)
MOUNT="$WORK/mnt"
cleanup() {
  hdiutil detach "$MOUNT" -quiet 2>/dev/null || true
  rm -rf "$WORK"
}
trap cleanup EXIT

echo "Downloading DongVPN..."
curl -fL --progress-bar -o "$WORK/DongVPN.dmg" "$DMG_URL"
mkdir -p "$MOUNT"
hdiutil attach "$WORK/DongVPN.dmg" -nobrowse -readonly -mountpoint "$MOUNT" -quiet

DEST=/Applications
if [[ ! -w $DEST ]]; then
  DEST="$HOME/Applications"
  mkdir -p "$DEST"
fi

# DongVPN restores the previous proxy settings when it receives SIGTERM
if pkill -TERM -x DongVPN 2>/dev/null; then
  for _ in $(seq 50); do pgrep -x DongVPN >/dev/null || break; sleep 0.1; done
fi

rm -rf "$DEST/DongVPN.app"
ditto "$MOUNT/DongVPN.app" "$DEST/DongVPN.app"
xattr -d -r com.apple.quarantine "$DEST/DongVPN.app" 2>/dev/null || true
open "$DEST/DongVPN.app"

echo "DongVPN is installed and connecting. Look for the network icon in the menu bar."
