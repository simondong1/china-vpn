# DongVPN

This repository contains an AWS Lightsail Xray server and a small macOS menu bar client.

The server uses VLESS + REALITY over TCP 443. `deploy.sh` provisions it and writes the generated connection link to `out/vpn-link.txt`.

## macOS client

Build the `XrayVPN` target in `XrayVPN/XrayVPN.xcodeproj` on macOS 12 or later. The app is named DongVPN. The GitHub Actions workflow builds an unsigned DMG on macOS 14 and bundles Xray for both Apple silicon and Intel Macs. The DMG contains only `DongVPN.app`; its Xray executables are packaged inside the app bundle.

The workflow embeds the server link from the `DONGVPN_VLESS_LINK` repository secret as `Resources/default.vless`, so users never paste a link. `deploy.sh` updates that secret when the GitHub CLI is installed; otherwise set it with `gh secret set DONGVPN_VLESS_LINK < out/vpn-link.txt`. Tagged releases fail if the secret is missing. Anyone with the DMG can read the embedded link, so share releases only with people who should use the server.

1. Open DongVPN. The first time, macOS blocks the unsigned app: open **System Settings > Privacy & Security** and choose **Open Anyway** (on macOS 14 and earlier, Control-click the app and choose **Open**). This is needed only once.
2. On first launch, DongVPN offers to connect. Choose **Connect**. Later, use **Connect** from the menu bar item. On administrator accounts, connecting and disconnecting never ask for a password. If macOS refuses the change (for example on a standard account), DongVPN asks for administrator approval instead.
3. DongVPN tests the tunnel by requesting a public IP through it and shows the routed IP when the test succeeds.
4. Choose **Disconnect** to stop Xray and restore the proxy settings that were active before connecting. Use **Change VPN Configuration...** in the menu to use a different `vless://` link instead of the built-in one.

If DongVPN cannot connect or verify the tunnel, it offers to open an email to `simondong0919@gmail.com`. The email is not sent automatically.

A link entered with **Change VPN Configuration...** is stored in `~/Library/Application Support/XrayVPN` and takes priority over the built-in link. This app does not create a native macOS Network Extension VPN profile; it uses the macOS SOCKS proxy on port 10808 for enabled network services. Apps that ignore system proxy settings may bypass it.

## Server scripts

```text
deploy.sh        Create or update the Lightsail server
destroy.sh       Delete the server and stop billing
server-setup.sh  Install and configure Xray on the VM
out/             Generated link, QR code, and server metadata
XrayVPN/         DongVPN macOS menu bar app project
```
