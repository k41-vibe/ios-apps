#!/usr/bin/env python3
"""dist/ の ipa を LAN と Tailscale に配る小さなサーバー。

LiveContainer は URL からの取り込みができるので、Syncthing もファイルAppも
経由せずに済む。URL は毎回同じなので、iPhone 側はブックマークしておけばよい。

    python tools/serve-ipa.py [ポート]

止めるときは Ctrl+C。
"""
import http.server
import os
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


class Handler(http.server.SimpleHTTPRequestHandler):
    def __init__(self, *a, **kw):
        super().__init__(*a, directory=os.path.abspath(ROOT), **kw)

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
    print("LiveContainer の + から URL を貼る。止めるときは Ctrl+C")
    http.server.ThreadingHTTPServer(("0.0.0.0", port), Handler).serve_forever()
    return 0


if __name__ == "__main__":
    sys.exit(main())
