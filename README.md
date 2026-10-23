# China VPN Setup

Personal VPN infrastructure for bypassing the Great Firewall.

## Components

- **AWS Lightsail server** in Oregon running Xray with VLESS+REALITY
- **macOS VPN app** with menu bar UI in `macos-vpn-app/`
- **Deployment scripts** for server provisioning

## Server

The server is already running:
- IP: 52.34.245.131
- Cost: $5/month for 500 GB traffic
- Protocol: VLESS+REALITY disguised as aws.amazon.com

### Deploy new server

```bash
bash deploy.sh
```

### Destroy server

```bash
bash destroy.sh
```

## macOS VPN App

Download the latest DMG from [Releases](../../releases).

### Installation

1. Download `VPN.dmg`
2. Open and drag VPN.app to Applications
3. First launch: Right-click → Open (to bypass Gatekeeper)
4. VPN icon appears in your menu bar
5. Click icon → Settings
6. Paste your vless:// link from `out/vpn-link.txt`
7. Click Save, then Connect

**When connected:** All your Mac's traffic automatically routes through your US server. System-wide VPN like ExpressVPN.

**To disconnect:** Click the menu bar icon → Disconnect

### Features

- Menu bar icon (network icon when connected, slashed when disconnected)
- One-click connect/disconnect
- Settings window to paste vless:// links
- Automatic system proxy configuration
- Works with all apps (browsers, terminal, etc.)

## Files

```
deploy.sh              Create/update server
destroy.sh             Delete server and stop billing
server-setup.sh        Server configuration (runs on VM)
macos-vpn-app/         macOS menu bar VPN app with GUI
out/                   Generated: connection link, QR code, server IP
```
