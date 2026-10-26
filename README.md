# DongVPN

This repository contains an AWS Lightsail Xray server and a small macOS menu bar client.

The server uses VLESS + REALITY over TCP 443. `deploy.sh` provisions it and writes the generated connection link to `out/vpn-link.txt`.

## macOS client

Build the `XrayVPN` target in `XrayVPN/XrayVPN.xcodeproj` on macOS 12 or later. The app is named DongVPN. The GitHub Actions workflow builds an unsigned DMG on macOS 14 and bundles Xray for both Apple silicon and Intel Macs. The DMG contains only `DongVPN.app`; its Xray executables are packaged inside the app bundle.

1. Open DongVPN. On first launch, paste the `vless://` link provided for your VPN and choose **Add Configuration**. DongVPN saves the configuration automatically.
2. Choose **Connect** from the menu bar item and approve the macOS administrator prompt to apply the system proxy.
3. DongVPN tests the tunnel by requesting a public IP through it and shows the routed IP when the test succeeds.
4. Choose **Disconnect** to stop Xray and restore the proxy settings that were active before connecting. Use **Change VPN Configuration...** in the menu to replace the saved link.

If DongVPN cannot connect or verify the tunnel, it offers to open an email to `simondong0919@gmail.com`. The email is not sent automatically.

The VLESS link is stored in `~/Library/Application Support/XrayVPN` to preserve existing settings. This app does not create a native macOS Network Extension VPN profile; it uses the macOS SOCKS proxy on port 10808 for enabled network services. Apps that ignore system proxy settings may bypass it.

## Server scripts

```text
deploy.sh        Create or update the Lightsail server
destroy.sh       Delete the server and stop billing
server-setup.sh  Install and configure Xray on the VM
out/             Generated link, QR code, and server metadata
XrayVPN/         DongVPN macOS menu bar app project
```
