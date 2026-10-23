#!/usr/bin/env bash
# Runs ON the VM (Ubuntu 24.04). Configures Xray with VLESS + REALITY on TCP 443.
# Idempotent: re-running keeps existing keys/UUID so clients don't break.
set -euo pipefail

# REALITY decoy site. Must be reachable from China, support TLS1.3 + H2, and have a
# small cert chain (www.microsoft.com fails: its chain overflows the handshake buffer).
# An AWS-hosted site matches this server's network. Override with: SNI=example.com
SNI_ARG="${SNI:-}"
PORT=443
STATE=/usr/local/etc/xray/vpn-state.env
CONF=/usr/local/etc/xray/config.json

export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq curl qrencode unzip >/dev/null

# Xray must already be installed. Install it once, by hand, with the official installer
# (review it first: https://github.com/XTLS/Xray-install):
#   bash -c "$(curl -fsSL https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install
command -v xray >/dev/null || { echo "xray not installed; see comment above"; exit 1; }

# TCP BBR improves throughput on long, lossy China<->US paths
cat >/etc/sysctl.d/99-vpn.conf <<'EOF'
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr
net.ipv4.tcp_fastopen=3
EOF
sysctl --system >/dev/null

# Generate secrets once
if [[ ! -f $STATE ]]; then
  UUID=$(xray uuid)
  KEYS=$(xray x25519)
  # Output format differs by version: "Private key:/Public key:" or
  # "PrivateKey:/Password (PublicKey):"
  PRIV=$(echo "$KEYS" | grep -iE '^private ?key' | head -1 | awk -F': *' '{print $2}')
  PUB=$(echo "$KEYS"  | grep -iE '^(public ?key|password)' | head -1 | awk -F': *' '{print $2}')
  SID=$(openssl rand -hex 8)
  umask 077
  printf 'UUID=%s\nPRIV=%s\nPUB=%s\nSID=%s\nSNI=%s\n' "$UUID" "$PRIV" "$PUB" "$SID" "${SNI_ARG:-aws.amazon.com}" >"$STATE"
fi
# shellcheck disable=SC1090
source "$STATE"
if [[ -n $SNI_ARG && $SNI_ARG != "$SNI" ]]; then
  SNI=$SNI_ARG
  sed -i "s/^SNI=.*/SNI=$SNI/" "$STATE"
fi
[[ -n $PRIV && -n $PUB && -n $UUID ]] || { echo "key generation failed"; exit 1; }

cat >"$CONF" <<EOF
{
  "log": { "loglevel": "warning" },
  "inbounds": [{
    "listen": "0.0.0.0",
    "port": $PORT,
    "protocol": "vless",
    "settings": {
      "clients": [{ "id": "$UUID", "flow": "xtls-rprx-vision" }],
      "decryption": "none"
    },
    "streamSettings": {
      "network": "tcp",
      "security": "reality",
      "realitySettings": {
        "dest": "$SNI:443",
        "serverNames": ["$SNI"],
        "privateKey": "$PRIV",
        "shortIds": ["$SID"]
      }
    },
    "sniffing": { "enabled": true, "destOverride": ["http", "tls", "quic"] }
  }],
  "outbounds": [
    { "protocol": "freedom", "tag": "direct" },
    { "protocol": "blackhole", "tag": "block" }
  ],
  "routing": {
    "rules": [{ "type": "field", "ip": ["geoip:private"], "outboundTag": "block" }]
  }
}
EOF

xray run -test -config "$CONF" >/dev/null
systemctl enable --now xray >/dev/null 2>&1
systemctl restart xray
sleep 2
systemctl is-active --quiet xray || { journalctl -u xray -n 30 --no-pager; exit 1; }

IP=$(curl -fsS4 https://checkip.amazonaws.com)
LINK="vless://${UUID}@${IP}:${PORT}?encryption=none&flow=xtls-rprx-vision&security=reality&sni=${SNI}&fp=chrome&pbk=${PUB}&sid=${SID}&type=tcp#US-Oregon"
echo "$LINK" >/root/vpn-link.txt
qrencode -o /root/vpn-qr.png -s 8 "$LINK"
echo "VPN_LINK=$LINK"
