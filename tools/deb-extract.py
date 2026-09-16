#!/usr/bin/env python3
"""脱獄用の .deb から中身(.dylib と資材)を取り出す。

LiveContainer の Tweaks は .dylib と .framework しか受け取らない
(LCTweaksView.swift の importer は `.deb` が無効化されている)。
tweak の配布は .deb しか無いことが多いので、ここで開いて中身だけ取り出す。

    python tools/deb-extract.py <URL または .deb のパス> [出し先]

.deb は ar 書庫。中の data.tar.{gz,xz,lzma,bz2,zst} を展開する。
"""
import io
import os
import sys
import tarfile
import urllib.request


def ar_members(data: bytes):
    """ar 書庫を読んで (名前, 中身) を返す。"""
    if not data.startswith(b"!<arch>\n"):
        raise SystemExit("ar 書庫ではありません(.deb が壊れている?)")
    pos = 8
    while pos + 60 <= len(data):
        header = data[pos:pos + 60]
        name = header[0:16].decode("utf-8", "replace").strip()
        size = int(header[48:58].decode().strip() or 0)
        pos += 60
        body = data[pos:pos + size]
        pos += size + (size % 2)          # 2 バイト境界に揃う
        yield name.rstrip("/"), body


def decompress(name: str, body: bytes) -> bytes:
    if name.endswith(".gz"):
        import gzip
        return gzip.decompress(body)
    if name.endswith((".xz", ".lzma")):
        import lzma
        return lzma.decompress(body)
    if name.endswith(".bz2"):
        import bz2
        return bz2.decompress(body)
    if name.endswith(".zst"):
        try:
            import zstandard
        except ImportError:
            raise SystemExit("zstd 圧縮です。`pip install zstandard` を先に実行してください")
        return zstandard.ZstdDecompressor().stream_reader(io.BytesIO(body)).read()
    return body


def main():
    if len(sys.argv) < 2:
        raise SystemExit(__doc__)
    src = sys.argv[1]
    out = sys.argv[2] if len(sys.argv) > 2 else "deb-out"

    if src.startswith("http"):
        print(f"取得中: {src}")
        req = urllib.request.Request(src, headers={"User-Agent": "deb-extract"})
        with urllib.request.urlopen(req, timeout=120) as r:
            raw = r.read()
    else:
        raw = open(src, "rb").read()
    print(f"{len(raw) / 1048576:.1f} MB")

    data_tar = None
    for name, body in ar_members(raw):
        print(f"  ar: {name} ({len(body)} B)")
        if name.startswith("data.tar"):
            data_tar = decompress(name, body)
    if data_tar is None:
        raise SystemExit("data.tar が見つかりません")

    os.makedirs(out, exist_ok=True)
    with tarfile.open(fileobj=io.BytesIO(data_tar)) as tf:
        names = tf.getnames()
        # 展開先の外に出る名前は捨てる(tar の素性は信用しない)
        safe = [m for m in tf.getmembers()
                if not (m.name.startswith("/") or ".." in m.name.split("/"))]
        tf.extractall(out, members=safe)
    print(f"\n展開先: {os.path.abspath(out)}  ({len(names)} 件)")
    for n in sorted(names):
        if n.endswith((".dylib", ".bundle", ".framework", ".plist")):
            print(f"  {n}")


if __name__ == "__main__":
    main()
