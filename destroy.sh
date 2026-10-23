#!/usr/bin/env bash
# Deletes the VPN VM, its static IP and key pair, so billing stops.
set -uo pipefail
LS="aws lightsail --region us-west-2"
$LS detach-static-ip  --static-ip-name vpn-us-ip     >/dev/null 2>&1
$LS release-static-ip --static-ip-name vpn-us-ip     >/dev/null 2>&1 && echo "Released static IP"
$LS delete-instance   --instance-name  vpn-us        >/dev/null 2>&1 && echo "Deleted instance"
$LS delete-key-pair   --key-pair-name  vpn-us-key    >/dev/null 2>&1 && echo "Deleted key pair"
echo "Done."
