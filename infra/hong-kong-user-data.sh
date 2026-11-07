#!/bin/bash
set -euo pipefail
exec > >(tee -a /var/log/dongvpn-bootstrap.log) 2>&1

XRAY_VERSION=v26.10.21
if ! command -v unzip >/dev/null 2>&1 || ! command -v openssl >/dev/null 2>&1; then
  apt-get update -qq
  apt-get install -y -qq curl unzip openssl
fi
mkdir -p /usr/local/lib/dongvpn-xray /usr/local/etc/xray
curl --fail --location --silent --show-error \
  "https://github.com/XTLS/Xray-core/releases/download/${XRAY_VERSION}/Xray-linux-64.zip" \
  --output /tmp/xray.zip
unzip -oq /tmp/xray.zip -d /usr/local/lib/dongvpn-xray
install -m 755 /usr/local/lib/dongvpn-xray/xray /usr/local/bin/xray
install -m 644 /usr/local/lib/dongvpn-xray/geoip.dat /usr/local/etc/xray/geoip.dat
install -m 644 /usr/local/lib/dongvpn-xray/geosite.dat /usr/local/etc/xray/geosite.dat
install -m 644 /usr/local/lib/dongvpn-xray/LICENSE /usr/local/etc/xray/LICENSE
rm -f /tmp/xray.zip
export XRAY_LOCATION_ASSET=/usr/local/etc/xray

STATE=/root/dongvpn-state.env
if [[ ! -s "$STATE" ]]; then
  UUID=$(xray uuid)
  KEYS=$(xray x25519)
  PRIV=$(printf '%s\n' "$KEYS" | awk -F': *' 'tolower($1) ~ /private/ {print $2; exit}')
  PUB=$(printf '%s\n' "$KEYS" | awk -F': *' 'tolower($1) ~ /public|password/ {print $2; exit}')
  SID=$(openssl rand -hex 8)
  umask 077
  printf 'UUID=%s\nPRIV=%s\nPUB=%s\nSID=%s\nSNI=aws.amazon.com\n' \
    "$UUID" "$PRIV" "$PUB" "$SID" > "$STATE"
fi
# shellcheck disable=SC1090
source "$STATE"
test -n "$UUID" && test -n "$PRIV" && test -n "$PUB" && test -n "$SID"

cat >/usr/local/etc/xray/config.json <<EOF
{
  "log": { "loglevel": "warning" },
  "inbounds": [{
    "listen": "0.0.0.0",
    "port": 443,
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

cat >/etc/systemd/system/xray.service <<'EOF'
[Unit]
Description=Xray DongVPN Hong Kong endpoint
After=network-online.target
Wants=network-online.target

[Service]
User=root
Environment=XRAY_LOCATION_ASSET=/usr/local/etc/xray
ExecStart=/usr/local/bin/xray run -config /usr/local/etc/xray/config.json
Restart=on-failure
RestartSec=2
LimitNOFILE=1048576
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=strict
ProtectHome=true
ReadWritePaths=/usr/local/etc/xray

[Install]
WantedBy=multi-user.target
EOF

cat >/etc/sysctl.d/99-dongvpn.conf <<'EOF'
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr
net.ipv4.tcp_fastopen=3
EOF
sysctl --system >/dev/null
xray run -test -config /usr/local/etc/xray/config.json
systemctl daemon-reload
systemctl enable --now xray
