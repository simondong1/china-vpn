# China VPN Setup

Personal VPN infrastructure for bypassing the Great Firewall.

## Components

- **AWS Lightsail server** in Oregon running Xray with VLESS+REALITY
- **macOS client** (menu bar app) in `vpn-client/`
- **Deployment scripts** for server provisioning

## Server

The server is already running:
- IP: See `out/server.env`
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

## macOS Client

Download the latest DMG from [Releases](../../releases).

### Installation

1. Download `VPN.dmg`
2. Open and drag to Applications
3. Launch VPN from menu bar
4. Settings → paste your vless:// link from `out/vpn-link.txt`
5. Click Connect

**Note:** Requires a paid Apple Developer account ($99/yr) for signed builds, or SIP disabled for unsigned builds.

### Build from source

See `vpn-client/README.md` for build instructions.

## Files

```
deploy.sh              Create/update server
destroy.sh             Delete server and stop billing
server-setup.sh        Server configuration (runs on VM)
vpn-client/            macOS menu bar VPN app
out/                   Generated: connection link, QR code, server IP
```
