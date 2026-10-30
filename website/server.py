#!/usr/bin/env python3
import hashlib
import hmac
import http.server
import json
import os
import secrets
import ssl
import time
import urllib.parse
from pathlib import Path


SESSION_SECONDS = 8 * 60 * 60
FAILURE_WINDOW = 15 * 60
MAX_FAILURES = 8
FAILURES = {}
ROOT = Path(os.environ.get("DONGVPN_WEB_ROOT", "/var/www/dongvpn-acme"))
DOWNLOAD = Path(os.environ.get("DONGVPN_DOWNLOAD", "/srv/dongvpn/DongVPN.dmg"))
CONFIG = Path(os.environ.get("DONGVPN_WEB_CONFIG", "/etc/dongvpn-download.json"))
PUBLIC_URL = os.environ.get("DONGVPN_PUBLIC_URL", "")

PAGE = """<!doctype html>
<html lang="zh-CN">
<head>
<meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<meta name="color-scheme" content="light dark">
<title>DongVPN</title>
<style>
:root{font:16px -apple-system,BlinkMacSystemFont,"Segoe UI",sans-serif;color:#202124;background:#f5f7f8}
*{box-sizing:border-box}body{margin:0;min-height:100vh;display:grid;place-items:center;padding:24px}
main{width:min(100%,420px);background:white;border:1px solid #d9dfe3;border-radius:8px;padding:32px}
h1{font-size:24px;margin:0 0 8px}p{color:#53616b;line-height:1.5;margin:0 0 24px}
label{display:block;font-size:14px;font-weight:600;margin-bottom:8px}input{width:100%;height:44px;border:1px solid #9ba8b0;border-radius:5px;padding:0 12px;font:inherit;margin-bottom:14px}
button,a.button{display:flex;width:100%;height:44px;align-items:center;justify-content:center;border:0;border-radius:5px;background:#126b5b;color:white;font-family:inherit;font-size:15px;font-weight:600;text-decoration:none;cursor:pointer}
button:hover,a.button:hover{background:#0d594c}.error{color:#a12622;margin:0 0 14px;font-size:14px}
.tag{font-size:12px;font-weight:700;color:#126b5b;margin-bottom:16px;letter-spacing:.06em}
.guide{margin-top:26px;border-top:1px solid #d9dfe3;padding-top:22px}.guide h2{font-size:20px;margin:0 0 8px}.guide h3{font-size:16px;margin:0 0 6px}.guide-intro{margin:0 0 18px}.guide-step{display:grid;grid-template-columns:34px 1fr;gap:12px;padding:16px 0;border-top:1px solid #e7ebed}.guide-num{display:grid;place-items:center;width:30px;height:30px;border-radius:50%;background:#e7f3ef;color:#126b5b;font-weight:700}.guide-step p{margin:5px 0 0;font-size:14px}.mock{margin-top:10px;padding:11px 13px;border:1px solid #d9dfe3;border-radius:6px;background:#f8faf9;font-size:13px;color:#35423d}.mock-row{display:flex;align-items:center;gap:10px}.mock-row+.mock-row{margin-top:9px;padding-top:9px;border-top:1px solid #e4e9e6}.mock-app{display:grid;place-items:center;width:34px;height:34px;border-radius:7px;background:#126b5b;color:#fff;font-size:10px;font-weight:700}.mock-folder{font-size:24px}.mock-button{display:inline-block;padding:5px 10px;border-radius:4px;background:#126b5b;color:#fff;font-weight:600}.guide-note{margin-top:16px;padding:13px 14px;border-left:4px solid #d6ad43;border-radius:4px;background:#fff6df;font-size:14px;line-height:1.5}.guide-note p{margin:5px 0 0;font-size:14px}.logout{display:block;margin-top:22px;text-align:center;font-size:14px;color:#53616b}
@media(max-width:480px){main{padding:24px}.guide-step{gap:8px}.guide{margin-top:22px}}
@media(prefers-color-scheme:dark){:root{color:#f1f3f4;background:#151a1c}main{background:#202729;border-color:#394448}p{color:#bec9ce}input{color:#f1f3f4;background:#151a1c;border-color:#59676c}}
</style></head>
<body><main><div class="tag">DONGVPN · macOS</div><h1>安全下载 / Secure download</h1>
<p>输入下载密码以继续。Enter the password to continue.</p>
{content}
</main></body></html>"""


def load_config():
    with CONFIG.open("r", encoding="utf-8") as stream:
        config = json.load(stream)
    if not all(isinstance(config.get(key), str) and config[key] for key in ("password_hash", "session_secret")):
        raise RuntimeError("Download site configuration is incomplete")
    return config


def password_matches(candidate, encoded_hash):
    try:
        algorithm, rounds, salt, expected = encoded_hash.split("$", 3)
        if algorithm != "pbkdf2_sha256":
            return False
        if int(rounds) < 500_000 or int(rounds) > 1_000_000:
            return False
        calculated = hashlib.pbkdf2_hmac("sha256", candidate.encode(), bytes.fromhex(salt), int(rounds)).hex()
        return hmac.compare_digest(calculated, expected)
    except (ValueError, TypeError):
        return False


def make_cookie(config):
    issued = str(int(time.time()))
    nonce = secrets.token_urlsafe(24)
    payload = f"{issued}.{nonce}"
    signature = hmac.new(config["session_secret"].encode(), payload.encode(), hashlib.sha256).hexdigest()
    return f"{payload}.{signature}"


def valid_cookie(handler, config):
    cookie = handler.headers.get("Cookie", "")
    for item in cookie.split(";"):
        name, separator, value = item.strip().partition("=")
        if name != "dongvpn_session" or not separator:
            continue
        try:
            issued, nonce, signature = value.split(".", 2)
            age = int(time.time()) - int(issued)
        except (ValueError, TypeError):
            return False
        payload = f"{issued}.{nonce}"
        expected = hmac.new(config["session_secret"].encode(), payload.encode(), hashlib.sha256).hexdigest()
        return 0 <= age < SESSION_SECONDS and hmac.compare_digest(signature, expected)
    return False


class DownloadHandler(http.server.BaseHTTPRequestHandler):
    server_version = "DongVPNDownload"
    sys_version = ""

    def log_message(self, fmt, *args):
        message = fmt % args
        if "/login" in self.path:
            message = message.replace(self.path, "/login")
        print(f"{self.client_address[0]} {message}", flush=True)

    def send_html(self, status, content, headers=()):
        body = PAGE.replace("{content}", content).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.send_header("Content-Security-Policy", "default-src 'none'; style-src 'unsafe-inline'; form-action 'self'; base-uri 'none'; frame-ancestors 'none'")
        self.send_header("X-Content-Type-Options", "nosniff")
        self.send_header("Referrer-Policy", "no-referrer")
        for key, value in headers:
            self.send_header(key, value)
        self.end_headers()
        if self.command != "HEAD":
            self.wfile.write(body)

    def send_redirect(self, location, headers=()):
        self.send_response(303)
        self.send_header("Location", location)
        self.send_header("Cache-Control", "no-store")
        for key, value in headers:
            self.send_header(key, value)
        self.end_headers()

    def serve_challenge_or_redirect(self):
        path = urllib.parse.urlsplit(self.path).path
        prefix = "/.well-known/acme-challenge/"
        if path.startswith(prefix):
            name = path[len(prefix):]
            if not name or "/" in name or "\\" in name:
                self.send_error(404)
                return
            target = ROOT / ".well-known" / "acme-challenge" / name
            try:
                body = target.read_bytes()
            except OSError:
                self.send_error(404)
                return
            self.send_response(200)
            self.send_header("Content-Type", "text/plain")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            if self.command != "HEAD":
                self.wfile.write(body)
            return
        self.send_response(308)
        self.send_header("Location", PUBLIC_URL.rstrip("/") + "/")
        self.send_header("Content-Length", "0")
        self.end_headers()

    def do_HEAD(self):
        self.do_GET()

    def do_GET(self):
        if self.server.http_only:
            self.serve_challenge_or_redirect()
            return
        path = urllib.parse.urlsplit(self.path).path
        config = load_config()
        if path == "/logout":
            self.send_redirect("/", [("Set-Cookie", "dongvpn_session=; Path=/; Max-Age=0; Secure; HttpOnly; SameSite=Strict")])
            return
        if path not in ("/", "/login", "/download"):
            self.send_error(404)
            return
        if not valid_cookie(self, config):
            self.send_html(200, '<form method="post" action="/login"><label for="password">下载密码 / Download password</label><input id="password" name="password" type="password" autocomplete="current-password" required autofocus><button type="submit">继续 / Continue</button></form>')
            return
        if path == "/download":
            self.send_download()
            return
        self.send_html(200, '''<p>密码验证成功。先下载应用，再按下面步骤安装。Password accepted. Download the app first, then follow the steps below.</p>
<a class="button" href="/download">下载 DongVPN for Mac (.dmg) / Download</a>
<section class="guide" aria-labelledby="install-title">
<h2 id="install-title">安装教程 / Installation</h2>
<p class="guide-intro">适用于 macOS 12 或更新版本。/ For macOS 12 or later.</p>
<div class="guide-step"><span class="guide-num">1</span><div><h3>打开下载的 DMG / Open the downloaded DMG</h3><p>在 Finder 的“下载”文件夹找到 <b>DongVPN.dmg</b> 并双击。第一次打开时，macOS 可能显示下面这条安全提示。<br>In Finder, open Downloads and double-click <b>DongVPN.dmg</b>. The first attempt may show this macOS security warning.</p><div class="mock"><b>Apple 无法检查“DongVPN.dmg”是否包含可能危害 Mac 或泄露隐私的恶意软件。</b><br><span style="color:#53616b">Apple could not verify “DongVPN.dmg” is free of malware that may harm your Mac or compromise your privacy.</span><div class="mock-row" style="justify-content:flex-end"><span>移到废纸篓 / Move to Trash</span><span class="mock-button">好 / Done</span></div></div><p><b>点击“好 / Done”，不要点“移到废纸篓”。</b>这只会关闭提示并保留下载文件。然后在“下载”文件夹对 DongVPN.dmg 按住 Control 再点（或右键），选择“打开”，在确认框里再点“打开”。<br><b>Click Done, not Move to Trash.</b> This closes the warning and keeps the download. Then Control-click (or right-click) DongVPN.dmg in Downloads, choose Open, and confirm Open.</p><div class="guide-note"><b>右键菜单里没有“打开”？ / No Open option?</b><p>先选“好 / Done”关闭提示，再对原来的 DongVPN.dmg 按住 Control 点击。不要从浏览器下载列表再次双击。<br>Close the warning with Done, then Control-click the original DongVPN.dmg in Downloads. Don’t double-click it again from the browser’s download list.</p></div></div></div>
<div class="guide-step"><span class="guide-num">2</span><div><h3>拖到“应用程序” / Move to Applications</h3><p>把 DongVPN 图标拖到 Applications（应用程序）文件夹。复制完成后，从 Finder 的“应用程序”打开 DongVPN。<br>Drag DongVPN into Applications. After copying, open it from Applications in Finder.</p><div class="mock"><div class="mock-row"><span class="mock-app">Dong<br>VPN</span><b>DongVPN.app</b><span style="margin-left:auto">拖到 / Drag to →</span><span class="mock-folder">📁</span><b>Applications</b></div></div></div></div>
<div class="guide-step"><span class="guide-num">3</span><div><h3>首次打开 / Approve first launch</h3><p>在“应用程序”里对 DongVPN 点右键（或按住 Control 再点），选择“打开”，确认框里再点“打开”。以后可以正常双击启动。<br>In Applications, right-click (or Control-click) DongVPN, choose Open, then confirm Open. Future launches can use a normal double-click.</p><div class="guide-note"><b>没有“打开”按钮？ / No Open button?</b><p>点“取消”，进入  → 系统设置 → 隐私与安全性，找到 DongVPN 被阻止的提示并点“仍要打开”。然后回到“应用程序”右键 DongVPN →“打开”。<br>Click Cancel, go to Apple menu → System Settings → Privacy &amp; Security, find the DongVPN message and click Open Anyway. Then return to Applications and right-click DongVPN → Open.</p></div><p>macOS 会提示无法验证开发者，因为此版本没有 Apple Developer ID 签名。只对你信任的 DongVPN 文件执行上述操作。<br>macOS warns because this build has no Apple Developer ID signature. Only approve this DongVPN file if you trust its source.</p></div></div>
<div class="guide-step"><span class="guide-num">4</span><div><h3>连接 VPN / Connect</h3><p>启动后点屏幕右上角菜单栏里的 DongVPN 图标，选择 Connect。首次连接如询问是否允许更改网络设置，请选择允许。看到 Connected 后即可使用；断开时再点图标并选择 Disconnect。<br>Click the DongVPN menu-bar icon at the top right and choose Connect. Allow the network settings change if asked. When it shows Connected, you can browse; choose Disconnect from the same menu to stop.</p></div></div>
<div class="guide-note"><b>连接失败？ / Trouble connecting?</b><p>确认网络正常并关闭其他 VPN 后重试。此应用仅适用于 Mac，不能安装到 iPhone。<br>Check your internet connection, turn off other VPNs, and retry. This app is for Mac and cannot be installed on iPhone.</p></div>
</section><a class="logout" href="/logout">退出 / Log out</a>''')

    def do_POST(self):
        if self.server.http_only or urllib.parse.urlsplit(self.path).path != "/login":
            self.send_error(404)
            return
        address = self.client_address[0]
        now = time.monotonic()
        started, failures = FAILURES.get(address, (now, 0))
        if now - started > FAILURE_WINDOW:
            started, failures = now, 0
        if failures >= MAX_FAILURES:
            self.send_html(429, '<p class="error">尝试次数过多，请稍后重试。Too many attempts; try again later.</p><a class="button" href="/">返回 / Back</a>', [("Retry-After", str(int(FAILURE_WINDOW - (now - started))))])
            return
        try:
            length = min(int(self.headers.get("Content-Length", "0")), 4096)
            form = urllib.parse.parse_qs(self.rfile.read(length).decode("utf-8", "replace"), max_num_fields=4)
            candidate = form.get("password", [""])[0]
        except (ValueError, UnicodeError):
            candidate = ""
        config = load_config()
        if not password_matches(candidate, config["password_hash"]):
            FAILURES[address] = (started, failures + 1)
            time.sleep(0.25)
            self.send_html(401, '<p class="error">密码不正确。Incorrect password.</p><form method="post" action="/login"><label for="password">下载密码 / Download password</label><input id="password" name="password" type="password" autocomplete="current-password" required autofocus><button type="submit">重试 / Try again</button></form>')
            return
        FAILURES.pop(address, None)
        self.send_redirect("/", [("Set-Cookie", f"dongvpn_session={make_cookie(config)}; Path=/; Max-Age={SESSION_SECONDS}; Secure; HttpOnly; SameSite=Strict")])

    def send_download(self):
        try:
            size = DOWNLOAD.stat().st_size
            start, end, status = 0, size - 1, 200
            range_header = self.headers.get("Range")
            if range_header:
                unit, separator, value = range_header.partition("=")
                first, dash, last = value.partition("-")
                if unit != "bytes" or not separator or not dash:
                    self.send_error(416)
                    return
                if first:
                    start = int(first)
                    end = min(int(last), size - 1) if last else size - 1
                elif last:
                    count = int(last)
                    start = max(0, size - count)
                if start >= size or end < start:
                    self.send_error(416)
                    return
                status = 206
            length = end - start + 1
            self.send_response(status)
            self.send_header("Content-Type", "application/x-apple-diskimage")
            self.send_header("Content-Disposition", 'attachment; filename="DongVPN.dmg"')
            self.send_header("Content-Length", str(length))
            self.send_header("Accept-Ranges", "bytes")
            self.send_header("Cache-Control", "private, no-store")
            self.send_header("X-Content-Type-Options", "nosniff")
            if status == 206:
                self.send_header("Content-Range", f"bytes {start}-{end}/{size}")
            self.end_headers()
            if self.command == "HEAD":
                return
            with DOWNLOAD.open("rb") as source:
                source.seek(start)
                remaining = length
                while remaining:
                    chunk = source.read(min(1024 * 1024, remaining))
                    if not chunk:
                        break
                    self.wfile.write(chunk)
                    remaining -= len(chunk)
        except OSError:
            self.send_error(404)
        except ValueError:
            self.send_error(416)


class ThreadingHTTPServer(http.server.ThreadingHTTPServer):
    daemon_threads = True
    allow_reuse_address = True


def serve(port, http_only, tls_context=None):
    server = ThreadingHTTPServer(("0.0.0.0", port), DownloadHandler)
    server.http_only = http_only
    if tls_context:
        server.socket = tls_context.wrap_socket(server.socket, server_side=True)
    server.serve_forever()


def main():
    if not PUBLIC_URL:
        raise RuntimeError("Set DONGVPN_PUBLIC_URL to the public HTTPS site URL")
    config = load_config()
    tls = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    tls.minimum_version = ssl.TLSVersion.TLSv1_2
    tls.load_cert_chain(config["certificate"], config["private_key"])
    import threading
    threading.Thread(target=serve, args=(80, True), daemon=True).start()
    serve(8443, False, tls)


if __name__ == "__main__":
    main()
