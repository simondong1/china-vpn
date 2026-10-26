# DongVPN

This repository contains an AWS Lightsail Xray server and a small macOS menu bar client.

The server uses VLESS + REALITY over TCP 443. `deploy.sh` provisions it and writes the generated connection link to `out/vpn-link.txt`.

## macOS client

Build the `XrayVPN` target in `XrayVPN/XrayVPN.xcodeproj` on macOS 12 or later. The app is named DongVPN. The GitHub Actions workflow builds an unsigned DMG on macOS 14 and bundles Xray for both Apple silicon and Intel Macs.

1. Open the app. It runs in the menu bar.
2. Open **Settings...**, paste the `vless://` link from `out/vpn-link.txt`, click **Import**, then **Save**.
3. Choose **Connect** from the menu bar item and approve the macOS administrator prompt.
4. Choose **Disconnect** to stop Xray and restore the proxy settings that were active before connecting.

The release DMG includes matching Xray binaries for Apple silicon and Intel. A locally built app downloads its matching binary on first connect. Xray validates the generated configuration before startup, and the imported link is stored in `~/Library/Application Support/XrayVPN` to preserve existing settings.

The client uses the macOS SOCKS proxy on port 10808 for each enabled network service. This covers applications that honor system proxy settings; it is not a Network Extension packet tunnel and cannot transparently route applications that ignore system proxies.

## Server scripts

```text
deploy.sh        Create or update the Lightsail server
destroy.sh       Delete the server and stop billing
server-setup.sh  Install and configure Xray on the VM
out/             Generated link, QR code, and server metadata
XrayVPN/         macOS menu bar app
```
