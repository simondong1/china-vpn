#!/usr/bin/env bash
# Run locally (Git Bash). Creates a Lightsail VM in Oregon and installs the VPN.
# Re-runnable: skips anything that already exists.
set -euo pipefail
cd "$(dirname "$0")"

REGION=us-west-2          # Oregon: closest AWS US region to China
AZ=us-west-2a
NAME=vpn-us
KEY_NAME=vpn-us-key
BUNDLE=nano_3_0           # $5/mo: 2 vCPU burst, 0.5 GB RAM, 1 TB transfer, IPv4
BLUEPRINT=ubuntu_24_04
STATIC_IP=vpn-us-ip
KEY=keys/vpn_key
LS="aws lightsail --region $REGION"

mkdir -p keys out
[[ -f $KEY ]] || ssh-keygen -q -t rsa -b 4096 -N "" -C "$NAME" -f "$KEY"

if ! $LS get-key-pair --key-pair-name "$KEY_NAME" >/dev/null 2>&1; then
  echo "Importing SSH key..."
  $LS import-key-pair --key-pair-name "$KEY_NAME" --public-key-base64 "$(cat "$KEY.pub")" >/dev/null
fi

if ! $LS get-instance --instance-name "$NAME" >/dev/null 2>&1; then
  echo "Creating instance $NAME ($BUNDLE)..."
  $LS create-instances --instance-names "$NAME" --availability-zone "$AZ" \
    --blueprint-id "$BLUEPRINT" --bundle-id "$BUNDLE" --key-pair-name "$KEY_NAME" \
    --tags key=project,value=vpn >/dev/null
fi

echo -n "Waiting for instance to run"
until [[ $($LS get-instance --instance-name "$NAME" --query 'instance.state.name' --output text | tr -d '\r') == running ]]; do
  echo -n .; sleep 5
done; echo

# Static IP is free while attached; keeps the address stable across reboots
if ! $LS get-static-ip --static-ip-name "$STATIC_IP" >/dev/null 2>&1; then
  $LS allocate-static-ip --static-ip-name "$STATIC_IP" >/dev/null
fi
ATTACHED=$($LS get-static-ip --static-ip-name "$STATIC_IP" --query 'staticIp.attachedTo' --output text | tr -d '\r')
[[ $ATTACHED == "$NAME" ]] || $LS attach-static-ip --static-ip-name "$STATIC_IP" --instance-name "$NAME" >/dev/null
IP=$($LS get-static-ip --static-ip-name "$STATIC_IP" --query 'staticIp.ipAddress' --output text | tr -d '\r')
echo "Public IP: $IP"

# Firewall: only SSH and the VPN port
$LS put-instance-public-ports --instance-name "$NAME" --port-infos \
  fromPort=22,toPort=22,protocol=tcp fromPort=443,toPort=443,protocol=tcp >/dev/null

SSH_OPTS=(-i "$KEY" -o StrictHostKeyChecking=accept-new -o UserKnownHostsFile=keys/known_hosts -o ConnectTimeout=10)
echo -n "Waiting for SSH"
until ssh "${SSH_OPTS[@]}" ubuntu@"$IP" true 2>/dev/null; do echo -n .; sleep 5; done; echo

echo "Installing Xray on server..."
scp -q "${SSH_OPTS[@]}" server-setup.sh ubuntu@"$IP":/tmp/server-setup.sh
ssh "${SSH_OPTS[@]}" ubuntu@"$IP" "sudo SNI='${SNI:-}' bash /tmp/server-setup.sh" | tee out/setup.log
ssh "${SSH_OPTS[@]}" ubuntu@"$IP" "sudo cat /root/vpn-link.txt" | tr -d '\r' >out/vpn-link.txt
ssh "${SSH_OPTS[@]}" ubuntu@"$IP" "sudo base64 -w0 /root/vpn-qr.png" | base64 -d >out/vpn-qr.png
echo "IP=$IP" >out/server.env

echo
echo "Done. Import link (also in out/vpn-link.txt, QR in out/vpn-qr.png):"
cat out/vpn-link.txt
