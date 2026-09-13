#!/usr/bin/env python3
"""dist/ の ipa を LAN と Tailscale に配る小さなサーバー。

LiveContainer は URL からの取り込みができるので、Syncthing もファイルAppも
経由せずに済む。URL は毎回同じなので、iPhone 側はブックマークしておけばよい。

    python tools/serve-ipa.py [ポート]

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

ROOT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "dist")
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
    def __init__(self, *a, **kw):
        super().__init__(*a, directory=os.path.abspath(ROOT), **kw)

    def do_GET(self):
        if self.path.endswith(".json"):
            ipa = os.path.join(os.path.abspath(ROOT), os.path.basename(self.path)[:-5] + ".ipa")
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
        sys.stderr.write("  %s\n" % (fmt % args))


def main():
    port = int(sys.argv[1]) if len(sys.argv) > 1 else 8788
    root = os.path.abspath(ROOT)
    if not os.path.isdir(root):
        print(f"dist/ が無い: {root}")
        return 1
    names = sorted(n for n in os.listdir(root) if n.endswith(".ipa"))
    print(f"配るもの ({root}):")
    for n in names:
        mb = os.path.getsize(os.path.join(root, n)) / 1e6
        print(f"  {n}  {mb:.0f} MB")
    print()
    for label, ip in addresses():
        print(f"{label}: http://{ip}:{port}/XiOSDesktop.ipa")
    print()
    print("初回は LiveContainer の + から URL を貼る。2 回目からはアプリ内の「更新」で取り込める。止めるときは Ctrl+C")
    http.server.ThreadingHTTPServer(("0.0.0.0", port), Handler).serve_forever()
    return 0


if __name__ == "__main__":
    sys.exit(main())
