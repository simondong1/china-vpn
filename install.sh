#!/bin/bash
# Installs or updates DongVPN. Downloads made with curl are not quarantined,
# so macOS opens the app without a Gatekeeper prompt.
# Run beside a downloaded DongVPN.dmg, or pass its local path as the first argument.
set -euo pipefail

DMG_SOURCE="${1:-DongVPN.dmg}"
if [[ ! -f "$DMG_SOURCE" ]]; then
  echo "DongVPN.dmg was not found. Download it from the authorized distribution page first." >&2
  exit 1
fi
DMG_SOURCE="$(cd "$(dirname "$DMG_SOURCE")" && pwd)/$(basename "$DMG_SOURCE")"
WORK=$(mktemp -d)
MOUNT="$WORK/mnt"
cleanup() {
  hdiutil detach "$MOUNT" -quiet 2>/dev/null || true
  rm -rf "$WORK"
}
trap cleanup EXIT

echo "Downloading DongVPN... / 正在下载 DongVPN…"
mkdir -p "$MOUNT"
hdiutil attach "$DMG_SOURCE" -nobrowse -readonly -mountpoint "$MOUNT" -quiet

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
echo "DongVPN 已安装，正在连接。请在菜单栏中查找网络图标。"
