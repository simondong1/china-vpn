# DongVPN

This repository contains an AWS Lightsail Xray server and a small macOS menu bar client.

The server uses VLESS + REALITY over TCP 443. `deploy.sh` provisions it and writes the generated connection link to `out/vpn-link.txt`.

## Install on a Mac

Open Terminal and paste:

```bash
curl -fsSL https://github.com/simondong1/china-vpn/releases/latest/download/install.sh | bash
```

DongVPN installs into Applications, connects, and opens at login from then on. Files downloaded this way are not quarantined, so macOS shows no security prompt. Run the same command to update.

To install from the DMG instead, download `DongVPN.dmg` from the latest release, drag DongVPN to Applications, and open it. The first time, macOS blocks the unsigned app: open **System Settings > Privacy & Security** and choose **Open Anyway** (on macOS 14 and earlier, Control-click the app and choose **Open**). If DongVPN is opened from somewhere other than Applications, it moves itself there.

## Using DongVPN

- DongVPN connects on launch and at login, and shows a short confirmation under its menu bar icon the first time. If the user chose **Disconnect** before quitting, it stays disconnected until **Connect** is chosen or the app is opened again.
- It tests the tunnel by requesting a public IP through it before turning on the system proxy, and shows that IP in the menu.
- If the server is unreachable, DongVPN keeps retrying in the background without dialogs. If Xray crashes, it restarts it; after repeated crashes it restores the proxy and reconnects.
- Local network addresses and mainland China sites (`geosite:cn`, `geoip:cn`) connect directly; everything else goes through the VPN.
- On administrator accounts, connecting and disconnecting never ask for a password. If macOS refuses the change (for example on a standard account), DongVPN asks for administrator approval instead.
- **Disconnect**, **Quit**, logout, and shutdown restore the proxy settings that were active before connecting. **Open at Login** in the menu turns the login item off or on (macOS 13 and later).
- If a connection the user started fails, DongVPN offers to open an email to `simondong0919@gmail.com`. The email is not sent automatically.

This app does not create a native macOS Network Extension VPN profile; it uses the macOS SOCKS proxy on port 10808 for enabled network services. Apps that ignore system proxy settings may bypass it.

## Building

Build the `XrayVPN` target in `XrayVPN/XrayVPN.xcodeproj` on macOS 12 or later. The app is named DongVPN. The GitHub Actions workflow builds an unsigned DMG on macOS 14 and bundles Xray and its geo data files for both Apple silicon and Intel Macs. Tagged releases publish the DMG and `install.sh`.

The workflow embeds the server link from the `DONGVPN_VLESS_LINK` repository secret as `Resources/default.vless`, so users never paste a link. `deploy.sh` updates that secret when the GitHub CLI is installed; otherwise set it with `gh secret set DONGVPN_VLESS_LINK < out/vpn-link.txt`. Tagged releases fail if the secret is missing. Anyone with the DMG can read the embedded link, so share releases only with people who should use the server.

To use a different server, choose **Change VPN Configuration...** and paste its `vless://` link. That link is stored in `~/Library/Application Support/XrayVPN` and takes priority over the built-in one.

## Files

```text
deploy.sh        Create or update the Lightsail server
destroy.sh       Delete the server and stop billing
server-setup.sh  Install and configure Xray on the VM
install.sh       Install or update the macOS app without Gatekeeper prompts
out/             Generated link, QR code, and server metadata
XrayVPN/         DongVPN macOS menu bar app project
```
