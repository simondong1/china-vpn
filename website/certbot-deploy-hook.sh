#!/usr/bin/env bash
set -euo pipefail

CERT_DIR="${RENEWED_LINEAGE:?Certbot must provide RENEWED_LINEAGE}"
TLS_DIR=/etc/dongvpn-download/tls
install -d -o root -g ssl-cert -m 0750 "$TLS_DIR"
install -o root -g ssl-cert -m 0644 "$CERT_DIR/fullchain.pem" "$TLS_DIR/fullchain.pem"
install -o root -g ssl-cert -m 0640 "$CERT_DIR/privkey.pem" "$TLS_DIR/privkey.pem"
systemctl restart dongvpn-download.service
