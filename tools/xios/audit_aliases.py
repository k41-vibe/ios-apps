#!/usr/bin/env python3
"""横取りした関数の「別名」を取りこぼしていないか調べる。

Darwin の libc は同じ関数を 2 つの名前で出していることがある。<stdio.h> などが
`__DARWIN_ALIAS_STARTING` で切り替えるので、どちらの名前で呼ばれるかは
そのパッケージのビルド設定次第になる。

    _fopen              ... iosc など
    _fopen$DARWIN_EXTSN ... libxkbcommon を含む 132 本

片方しか定義していないと、もう片方の名前で呼ぶバイナリは私たちの経路変換を
素通りして本物の libSystem に行き、`/var/jb/...` が見つからない。
2026-09-12 の実機で xkb のキーマップが読めなかったのがこれ。

使い方: python3 audit_aliases.py <libLCsys.dylib> <Frameworks ディレクトリ>
libLCsys が基本名を出しているのに別名を出していない組があれば exit 2。
"""
import os
import re
import subprocess
import sys
from collections import defaultdict

ALIAS = re.compile(r"^_([A-Za-z_][A-Za-z0-9_]*)\$([A-Za-z0-9_$]+)$")


def nm(args, path):
    try:
        out = subprocess.run(["nm", *args, path], capture_output=True, text=True)
    except OSError as e:
        print(f"::error::nm が動かない: {e}")
        sys.exit(3)
    return out.stdout.splitlines()


def exported(lib):
    """libLCsys 自身が定義している名前(先頭の _ 込み)。"""
    names = set()
    for line in nm(["-gU"], lib):
        parts = line.split()
        if len(parts) >= 3 and parts[1] in ("T", "D", "S", "B"):
            names.add(parts[2])
    return names


def main(argv):
    if len(argv) != 2:
        print(__doc__)
        return 1
    lib, fw = argv
    ours = exported(lib)
    base_names = {n for n in ours if "$" not in n}
    if not base_names:
        print(f"::error::{lib} から定義済みシンボルが 1 つも読めない(nm の出力が空)")
        return 3

    users = defaultdict(set)   # (基本名, 接尾辞) -> それを使っている dylib 名
    scanned = 0
    for name in sorted(os.listdir(fw)):
        path = os.path.join(fw, name)
        if not name.endswith(".dylib") or os.path.islink(path) or os.path.samefile(path, lib):
            continue
        scanned += 1
        for line in nm(["-u"], path):
            # `nm -u` の行は環境によって "_foo" だけのことも "  U _foo" のこともある
            parts = line.split()
            if not parts:
                continue
            m = ALIAS.match(parts[-1])
            if m and "_" + m.group(1) in base_names:
                users[(m.group(1), m.group(2))].add(name)

    missing = []
    for (base, suffix), who in sorted(users.items()):
        full = f"_{base}${suffix}"
        ok = full in ours
        mark = "ok  " if ok else "MISS"
        w = sorted(who)
        print(f"  {mark} {full}: {len(who)} 本  {', '.join(w[:5])}{' …' if len(w) > 5 else ''}")
        if not ok:
            missing.append((full, len(who)))

    print(f"{scanned} 本を走査、横取り対象の基本名 {len(base_names)} 個、別名の組 {len(users)} 個")
    if missing:
        print("::error::libLCsys が基本名だけを定義していて別名を落としている:")
        for full, n in missing:
            print(f"::error::  {full} ({n} 本が使用)。lcsys.c に __asm__(\"{full}\") の定義を足す")
        return 2
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
