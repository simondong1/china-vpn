# Simple macOS VPN Client

Command-line VPN client for macOS. Uses Xray-core directly without System Extensions.

## Quick Start

Download the binary from [Releases](../../releases) and run:

```bash
./vpn connect
```

## What it does

- Downloads and runs Xray-core in the background
- Routes traffic through SOCKS5 proxy
- Shows connection status and metrics
- No System Extension, no code signing, no SIP disable needed

## Installation

1. Download `vpn-macos.zip` from Releases
2. Extract: `unzip vpn-macos.zip`
3. Make executable: `chmod +x vpn`
4. Import config: `./vpn import < ../out/vpn-link.txt`
5. Connect: `./vpn connect`

## Usage

```bash
./vpn import < vless-link.txt   # Import server config
./vpn connect                    # Start VPN
./vpn status                     # Show connection status
./vpn disconnect                 # Stop VPN
```

## How it works

Uses Xray-core as a SOCKS5 proxy on localhost:10808, then configures macOS network settings to route through it. No VPN APIs, no entitlements needed.
