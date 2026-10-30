#!/usr/bin/env python3
import getpass
import hashlib
import json
import os
import secrets
import sys
from pathlib import Path


def main():
    output = Path(sys.argv[1] if len(sys.argv) > 1 else "website/server-config.json")
    password = getpass.getpass("Download password: ")
    confirmation = getpass.getpass("Confirm password: ")
    if not password or password != confirmation:
        raise SystemExit("Passwords were empty or did not match.")
    salt = secrets.token_bytes(16)
    rounds = 600_000
    digest = hashlib.pbkdf2_hmac("sha256", password.encode(), salt, rounds).hex()
    tls_directory = Path(os.environ.get("DONGVPN_TLS_DIRECTORY", "/etc/dongvpn-download/tls"))
    config = {
        "password_hash": f"pbkdf2_sha256${rounds}${salt.hex()}${digest}",
        "session_secret": secrets.token_urlsafe(48),
        "certificate": str(tls_directory / "fullchain.pem"),
        "private_key": str(tls_directory / "privkey.pem"),
    }
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text(json.dumps(config) + "\n", encoding="utf-8")
    output.chmod(0o600)
    print(f"Wrote protected config to {output}; the password itself was not stored.")


if __name__ == "__main__":
    main()
