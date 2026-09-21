#!/usr/bin/env python3
"""dist/ の ipa を LAN と Tailscale に配る小さなサーバー。

LiveContainer は URL からの取り込みができるので、Syncthing もファイルAppも
経由せずに済む。URL は毎回同じなので、iPhone 側はブックマークしておけばよい。

    python tools/serve-ipa.py [ポート] [--dir <ipa の置き場>]

--dir を省くと ios-apps/dist を配る。別のリポジトリで作った ipa もこれで配れる。

止めるときは Ctrl+C。
"""
import http.server
import json
import os
import plistlib
import zipfile
import socket
import subprocess
import sys

DEFAULT_ROOT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "dist")
TAILSCALE = r"C:\Program Files\Tailscale\tailscale.exe"


def addresses():
    out = []
    try:
        s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        s.connect(("8.8.8.8", 80))          # 経路を引くだけ。実際には送らない
        out.append(("LAN", s.getsockname()[0]))
        s.close()
    except OSError:
        pass
    if os.path.exists(TAILSCALE):
        try:
            ip = subprocess.run([TAILSCALE, "ip", "-4"], capture_output=True, text=True,
                                timeout=5).stdout.strip().splitlines()
            if ip:
                out.append(("Tailscale", ip[0].strip()))
        except (OSError, subprocess.SubprocessError):
            pass
    return out


_manifest_cache = {}


def manifest_for(ipa_path):
    """<Name>.json: アプリ内アップデート(apps/*/Sources/Updater.swift)が読む版の情報。
    ipa の Info.plist から取るので、build.ps1 が置いた ipa と常に一致する。"""
    st = os.stat(ipa_path)
    key = (ipa_path, st.st_mtime, st.st_size)
    if key in _manifest_cache:
        return _manifest_cache[key]
    with zipfile.ZipFile(ipa_path) as z:
        info_name = next(n for n in z.namelist()
                         if n.startswith("Payload/") and n.count("/") == 2 and n.endswith("/Info.plist"))
        info = plistlib.loads(z.read(info_name))
    m = {
        "app": os.path.splitext(os.path.basename(ipa_path))[0],
        "version": info.get("CFBundleShortVersionString", "?"),
        "build": int(info.get("CFBundleVersion", "0") or 0),
        "commit": info.get("LCGitCommit", "?"),
        "size": st.st_size,
        "ipa": os.path.basename(ipa_path),
    }
    _manifest_cache.clear()
    _manifest_cache[key] = m
    return m


class Handler(http.server.SimpleHTTPRequestHandler):
    root = os.path.abspath(DEFAULT_ROOT)   # main() が --dir で差し替える

    def __init__(self, *a, **kw):
        super().__init__(*a, directory=self.root, **kw)

    def do_POST(self):
        """/upload/<名前>: アプリからのログ受け取り。dist/reports/<時刻>-<名前> に保存する。
        (Updater.swift の「ログを PC に送る」ボタン。Discord の Webhook は書く専用で受け取れない)"""
        import datetime, re
        if not self.path.startswith("/upload/"):
            self.send_error(404)
            return
        name = re.sub(r"[^A-Za-z0-9._-]", "_", os.path.basename(self.path[len("/upload/"):]))[:80] or "report"
        length = int(self.headers.get("Content-Length") or 0)
        if length <= 0 or length > 64 * 1024 * 1024:
            self.send_error(400, "bad length")
            return
        data = self.rfile.read(length)
        outdir = os.path.join(self.root, "reports")
        os.makedirs(outdir, exist_ok=True)
        stamp = datetime.datetime.now().strftime("%Y%m%d-%H%M%S")
        path = os.path.join(outdir, f"{stamp}-{name}")
        with open(path, "wb") as f:
            f.write(data)
        body = json.dumps({"saved": path, "bytes": len(data)}, ensure_ascii=False).encode("utf-8")
        self.send_response(200)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)
        if sys.stderr:
            sys.stderr.write(f"  受信: {path} ({len(data)} B)\n")

    def do_GET(self):
        # source.json は実ファイル。LiveContainer にソースとして登録するもので、
        # 下の「<Name>.json は <Name>.ipa の版情報」という扱いの例外にあたる。
        if os.path.basename(self.path.split("?")[0]) == "source.json":
            super().do_GET()
            return

        if self.path.endswith(".json"):
            ipa = os.path.join(self.root, os.path.basename(self.path)[:-5] + ".ipa")
            if not os.path.isfile(ipa):
                self.send_error(404, "no ipa for manifest")
                return
            body = json.dumps(manifest_for(ipa), ensure_ascii=False).encode("utf-8")
            self.send_response(200)
            self.send_header("Content-Type", "application/json; charset=utf-8")
            self.send_header("Content-Length", str(len(body)))
            self.send_header("Cache-Control", "no-store")
            self.end_headers()
            self.wfile.write(body)
            return
        super().do_GET()

    def end_headers(self):
        # LiveContainer に ipa だと分かるように。既定だと octet-stream になる
        if self.path.endswith(".ipa"):
            self.send_header("Content-Type", "application/octet-stream")
        super().end_headers()

    def log_message(self, fmt, *args):
        # pythonw.exe(build.ps1 が隠し起動に使う)では sys.stderr が None。ここで落ちると
        # 要求ごとにスレッドが死んで接続が切れる(2026-09-13 に発覚)
        if sys.stderr:
            sys.stderr.write("  %s\n" % (fmt % args))


def main():
    import argparse
    ap = argparse.ArgumentParser(description="ipa を LAN と Tailscale に配る")
    ap.add_argument("port", nargs="?", type=int, default=8788)
    ap.add_argument("--dir", default=DEFAULT_ROOT, help="ipa の置き場(既定: ios-apps/dist)")
    args = ap.parse_args()
    port, root = args.port, os.path.abspath(args.dir)
    if not os.path.isdir(root):
        print(f"配布元のフォルダが無い: {root}")
        return 1
    Handler.root = root
    names = sorted(n for n in os.listdir(root) if n.endswith(".ipa"))
    print(f"配るもの ({root}):")
    for n in names:
        mb = os.path.getsize(os.path.join(root, n)) / 1e6
        print(f"  {n}  {mb:.0f} MB")
    print()
    if not names:
        print(f"ipa が1つも無い: {root}")
        return 1
    for label, ip in addresses():
        for n in names:
            print(f"{label}: http://{ip}:{port}/{n}")
    print()
    print("初回は LiveContainer の + から URL を貼る。2 回目からはアプリ内の「更新」で取り込める。止めるときは Ctrl+C")
    # Tailscale の正規証明書があれば https も開く(iOS の ATS は 100.x への平文 http を拒む)。
    # 取得: tailscale cert --cert-file tools/tls/node.crt --key-file tools/tls/node.key <PC名>.<tailnet>.ts.net
    # (管理画面 DNS → HTTPS Certificates を有効にしておく)。https は port+1
    tls_dir = os.path.join(os.path.dirname(os.path.abspath(__file__)), "tls")
    crt, key = os.path.join(tls_dir, "node.crt"), os.path.join(tls_dir, "node.key")
    if os.path.isfile(crt) and os.path.isfile(key):
        import ssl, threading
        ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        ctx.load_cert_chain(crt, key)
        https = http.server.ThreadingHTTPServer(("0.0.0.0", port + 1), Handler)
        https.socket = ctx.wrap_socket(https.socket, server_side=True)
        threading.Thread(target=https.serve_forever, daemon=True).start()
        print(f"https: port {port + 1}(Tailscale 証明書 {crt})")
    http.server.ThreadingHTTPServer(("0.0.0.0", port), Handler).serve_forever()
    return 0


if __name__ == "__main__":
    sys.exit(main())
