# macOS VPN Client

Clean, minimal VPN client for connecting to your VLESS+REALITY server from macOS.

## Features

- **Menu bar app** with connection toggle
- **Real-time metrics**: upload/download speed, total data transferred, connection duration
- **Connection diagnostics**: pre-flight checks, detailed error messages
- **Editable server config**: paste vless:// links or enter manually
- **Supports VLESS+REALITY** protocol via Xray-core

## Requirements

- macOS 12.0 or later
- Apple Developer account ($99/year) for signed build, or SIP disabled for unsigned

## Installation

### Option 1: Download pre-built DMG (if available)

1. Download `VPN.dmg` from Releases
2. Open the DMG and drag VPN.app to Applications
3. If unsigned: disable SIP in Recovery Mode (`csrutil disable`), then right-click → Open

### Option 2: Build yourself

**On this Windows PC:**

The build script requires macOS. Push this repo to GitHub, then:

```bash
# On your Mac in China:
git clone <your-repo-url>
cd macos-vpn
python3 build.py
```

**Requirements on Mac:**
```bash
brew install xcodegen create-dmg go
```

**For signed build,** export your Apple Developer credentials:
```bash
export APPLE_TEAM_ID="YOUR_TEAM_ID"
export APPLE_CERT_NAME="Developer ID Application: Your Name (TEAMID)"
python3 build.py
```

This produces `VPN.dmg`.

## Usage

1. **Open the app** — menu bar icon appears (shield)
2. **Click the icon** → Settings (gear icon)
3. **Import server**: paste the vless:// link from `../out/vpn-link.txt`
4. **Click Connect**

The app shows:
- Connection status with icon (green=connected, red=disconnected, orange=connecting)
- Real-time upload/download speed
- Total data sent/received
- Connection duration
- Error details if connection fails

## How it works

- **VPN.app**: SwiftUI menu bar app for UI and connection management
- **VPNExtension.systemextension**: Network System Extension that routes traffic
- **Xray-core**: Embedded binary handling VLESS+REALITY protocol
- **Tun2socks**: Bridges macOS packet tunnel to Xray's SOCKS5 proxy

## Signing requirements

macOS System Extensions need either:
- **Signed with Developer ID**: requires paid Apple Developer account
- **SIP disabled**: `csrutil disable` in Recovery Mode (less secure)

Without signing, macOS blocks the system extension from loading.

## GitHub Actions

The workflow in `.github/workflows/build.yml` builds the DMG on every push. To enable signing:

1. Go to repo Settings → Secrets → Actions
2. Add:
   - `APPLE_TEAM_ID`: your 10-character team ID
   - `APPLE_CERT_NAME`: certificate name from Keychain

## Files

```
VPN/                     Main app (SwiftUI)
VPNExtension/            System Extension (packet tunnel provider)
build.py                 Build script
project.yml              XcodeGen spec
.github/workflows/       CI/CD pipeline
```

## Troubleshooting

**"System Extension Blocked"**: Go to System Settings → Privacy & Security → Allow

**"Cannot verify developer"**: Right-click app → Open (first launch only)

**Connection fails**: Check Settings → server IP and credentials match your server

**No internet after disconnect**: System should auto-restore routes. If not, run:
```bash
sudo route flush
sudo networksetup -setdnsservers Wi-Fi Empty
```

## Cost comparison

- **Shadowrocket** (iOS/Mac App Store): $2.99 one-time
- **This custom app**: $99/year Apple Developer account (or free with SIP disabled)

Unless you need custom features or already have a developer account, Shadowrocket is more practical.
