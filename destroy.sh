#!/usr/bin/env bash
# Deletes the VPN VM, its static IP and key pair, so billing stops.
set -uo pipefail
REGION="${DONGVPN_AWS_REGION:-${AWS_REGION:-us-west-2}}"
NAME="${DONGVPN_INSTANCE_NAME:-dongvpn-server}"
KEY_NAME="${DONGVPN_KEY_NAME:-dongvpn-server-key}"
STATIC_IP="${DONGVPN_STATIC_IP_NAME:-dongvpn-server-ip}"
LS="aws lightsail --region $REGION"
$LS detach-static-ip  --static-ip-name "$STATIC_IP" >/dev/null 2>&1
$LS release-static-ip --static-ip-name "$STATIC_IP" >/dev/null 2>&1 && echo "Released static IP"
$LS delete-instance   --instance-name "$NAME"      >/dev/null 2>&1 && echo "Deleted instance"
$LS delete-key-pair   --key-pair-name "$KEY_NAME"  >/dev/null 2>&1 && echo "Deleted key pair"
echo "Done."
