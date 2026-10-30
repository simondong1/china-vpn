#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"

: "${DONGVPN_SSH_TARGET:?Set this to the authorized SSH target, such as ubuntu@server}"
: "${DONGVPN_SSH_KEY:?Set this to the path of an authorized private SSH key}"
: "${DONGVPN_PUBLIC_URL:?Set this to the public HTTPS URL of the download site}"

case "$DONGVPN_PUBLIC_URL" in
  https://*) ;;
  *) echo "DONGVPN_PUBLIC_URL must use HTTPS." >&2; exit 1 ;;
esac

SSH=(ssh -i "$DONGVPN_SSH_KEY" -o BatchMode=yes)
SCP=(scp -i "$DONGVPN_SSH_KEY" -o BatchMode=yes)
REMOTE_DIR="/tmp/dongvpn-deploy-$(date -u +%Y%m%dT%H%M%SZ)-$$"

"${SSH[@]}" "$DONGVPN_SSH_TARGET" "mkdir -m 700 '$REMOTE_DIR'"
cleanup() {
  "${SSH[@]}" "$DONGVPN_SSH_TARGET" "rm -rf '$REMOTE_DIR'" >/dev/null 2>&1 || true
}
trap cleanup EXIT

FILES=(server.py provision_config.py dongvpn-download.service certbot-deploy-hook.sh dongvpn-icon.png)
if [[ -n "${DONGVPN_DMG_PATH:-}" ]]; then
  test -f "$DONGVPN_DMG_PATH"
  FILES+=("$DONGVPN_DMG_PATH")
fi
"${SCP[@]}" "${FILES[@]}" "$DONGVPN_SSH_TARGET:$REMOTE_DIR/"

"${SSH[@]}" "$DONGVPN_SSH_TARGET" "sudo cp -a /opt/dongvpn-download/server.py /opt/dongvpn-download/server.py.pre-deploy && sudo cp -a /etc/systemd/system/dongvpn-download.service /etc/systemd/system/dongvpn-download.service.pre-deploy && sudo install -o root -g root -m 0644 '$REMOTE_DIR/server.py' /opt/dongvpn-download/server.py && sudo install -o root -g root -m 0644 '$REMOTE_DIR/provision_config.py' /opt/dongvpn-download/provision_config.py && sudo install -o root -g root -m 0644 '$REMOTE_DIR/dongvpn-icon.png' /opt/dongvpn-download/dongvpn-icon.png && sudo install -o root -g root -m 0644 '$REMOTE_DIR/dongvpn-download.service' /etc/systemd/system/dongvpn-download.service && sudo install -o root -g root -m 0755 '$REMOTE_DIR/certbot-deploy-hook.sh' /etc/letsencrypt/renewal-hooks/deploy/50-dongvpn-download"

if ! "${SSH[@]}" "$DONGVPN_SSH_TARGET" "sudo test -f /etc/dongvpn-download.env"; then
  printf 'DONGVPN_PUBLIC_URL=%s\n' "$DONGVPN_PUBLIC_URL" | "${SSH[@]}" "$DONGVPN_SSH_TARGET" "sudo tee /etc/dongvpn-download.env >/dev/null"
  "${SSH[@]}" "$DONGVPN_SSH_TARGET" "sudo chown root:root /etc/dongvpn-download.env && sudo chmod 0640 /etc/dongvpn-download.env"
fi

if [[ -n "${DONGVPN_DMG_PATH:-}" ]]; then
  "${SSH[@]}" "$DONGVPN_SSH_TARGET" "sudo install -o root -g root -m 0644 '$REMOTE_DIR/$(basename "$DONGVPN_DMG_PATH")' /srv/dongvpn/DongVPN.dmg.next && sudo mv /srv/dongvpn/DongVPN.dmg.next /srv/dongvpn/DongVPN.dmg"
fi

"${SSH[@]}" "$DONGVPN_SSH_TARGET" "sudo systemctl daemon-reload && sudo systemctl restart dongvpn-download.service && sudo systemctl is-active dongvpn-download.service"
HEALTHCHECK_CURL=curl
if [[ "$(uname -s)" == MINGW* ]] && command -v cygpath >/dev/null 2>&1; then
  WINDOWS_CURL="$(cygpath -u "${SYSTEMROOT:-C:/Windows}")/System32/curl.exe"
  if [[ -x "$WINDOWS_CURL" ]]; then
    HEALTHCHECK_CURL="$WINDOWS_CURL"
  fi
fi
"$HEALTHCHECK_CURL" --fail --silent --show-error --connect-timeout 5 --max-time 20 --output /dev/null "$DONGVPN_PUBLIC_URL/"
echo "Dong VPN website deployed and responding at $DONGVPN_PUBLIC_URL"
