#!/usr/bin/env python3
"""同梱した Mach-O 群の未定義シンボルが実機で解決できるかを事前に検査する。

LiveContainer の JIT-less 運用では dlopen(RTLD_NOW) で束縛するため、解決できない
シンボルが 1 つでもあると読み込み時に失敗する(実機で libpcre2-8 がこれで落ちた)。

二段名前空間(two-level namespace)では、未定義シンボルごとに「どの依存ライブラリ
から来るはず」かが n_desc の上位 8 ビット(library ordinal)に記録されている。
  ordinal = 0      SELF_LIBRARY   自分自身
  ordinal = 0xfe   DYNAMIC_LOOKUP フラット検索(どこかの global 画像にあれば可)
  ordinal = 0xff   EXECUTABLE     実行ファイル
  それ以外          LC_LOAD_DYLIB の 1 始まりの番号
これを使って「@rpath/… から来るはずなのに Frameworks/ に無い」「フラット検索なのに
どこにも無い」を厳密に洗い出す。/usr/lib/… や *.framework は iOS 本体が持つので除外。

使い方: python audit_symbols.py <stage の Frameworks ディレクトリ>
"""
import os
import struct
import sys
from collections import defaultdict

MH_MAGIC_64 = 0xFEEDFACF
LC_SYMTAB = 0x02
LC_LOAD_DYLIB = 0x0C
LC_LOAD_WEAK_DYLIB = 0x80000018
LC_REEXPORT_DYLIB = 0x8000001F
LC_LOAD_UPWARD_DYLIB = 0x80000023
LC_ID_DYLIB = 0x0D
DYLIB_CMDS = (LC_LOAD_DYLIB, LC_LOAD_WEAK_DYLIB, LC_REEXPORT_DYLIB, LC_LOAD_UPWARD_DYLIB)

N_STAB, N_TYPE, N_EXT = 0xE0, 0x0E, 0x01
N_UNDF, N_SECT, N_ABS, N_PBUD, N_INDR = 0x0, 0xE, 0x2, 0xC, 0xA
SELF_LIBRARY, DYNAMIC_LOOKUP, EXECUTABLE = 0, 0xFE, 0xFF


def parse(path):
    """(exports, undefs, deps, install_name) を返す。undefs は (name, ordinal, weak)。"""
    with open(path, "rb") as fh:
        data = fh.read()
    if len(data) < 32 or struct.unpack_from("<I", data, 0)[0] != MH_MAGIC_64:
        return None
    ncmds = struct.unpack_from("<I", data, 16)[0]
    off, symoff, nsyms, stroff = 32, 0, 0, 0
    deps, install_name = [], None
    for _ in range(ncmds):
        cmd, cmdsize = struct.unpack_from("<II", data, off)
        if cmdsize == 0:
            break
        if cmd == LC_SYMTAB:
            symoff, nsyms, stroff, _strsize = struct.unpack_from("<IIII", data, off + 8)
        elif cmd in DYLIB_CMDS or cmd == LC_ID_DYLIB:
            nameoff = struct.unpack_from("<I", data, off + 8)[0]
            end = data.index(b"\0", off + nameoff)
            name = data[off + nameoff:end].decode("utf-8", "replace")
            if cmd == LC_ID_DYLIB:
                install_name = name
            else:
                deps.append(name)
        off += cmdsize

    exports, undefs = set(), []
    for i in range(nsyms):
        o = symoff + i * 16
        if o + 16 > len(data):
            break
        n_strx, n_type, _n_sect, n_desc, _n_value = struct.unpack_from("<IBBHQ", data, o)
        if n_type & N_STAB:
            continue
        end = data.index(b"\0", stroff + n_strx)
        name = data[stroff + n_strx:end].decode("utf-8", "replace")
        if (n_type & N_TYPE) == N_UNDF and not (n_type & N_EXT) == 0:
            undefs.append((name, (n_desc >> 8) & 0xFF, bool(n_desc & 0x40)))
        elif (n_type & N_EXT) and (n_type & N_TYPE) in (N_SECT, N_ABS, N_INDR):
            exports.add(name)
    return exports, undefs, deps, install_name


def is_system(dep):
    # libLCsys.dylib は libSystem を再エクスポートする自作の前段ライブラリで、
    # アプリのビルド時に生成されるため stage には存在しない。libc のシンボルは
    # 実機ではこれ経由で解決されるので、システム扱いにする。
    if os.path.basename(dep) == "libLCsys.dylib":
        return True
    return dep.startswith("/usr/lib/") or dep.startswith("/System/") or ".framework/" in dep


def main():
    fw = sys.argv[1] if len(sys.argv) > 1 else "stage/Frameworks"
    files = sorted(f for f in os.listdir(fw) if not f.startswith("."))
    parsed, by_install, all_exports = {}, {}, set()
    for f in files:
        r = parse(os.path.join(fw, f))
        if not r:
            continue
        exports, undefs, deps, install_name = r
        parsed[f] = (exports, undefs, deps, install_name)
        all_exports |= exports
        by_install[os.path.basename(install_name or f)] = exports
        by_install.setdefault(f, exports)

    print(f"Mach-O {len(parsed)} 本、公開シンボル合計 {len(all_exports)}")
    problems = defaultdict(list)
    for f, (_exports, undefs, deps, _install) in sorted(parsed.items()):
        for name, ordinal, weak in undefs:
            if weak:
                continue
            if ordinal == DYNAMIC_LOOKUP:
                if name not in all_exports:
                    problems[f].append((name, "flat(どこにも無い)"))
            elif ordinal in (SELF_LIBRARY, EXECUTABLE):
                continue
            elif 1 <= ordinal <= len(deps):
                dep = deps[ordinal - 1]
                if is_system(dep):
                    continue
                base = os.path.basename(dep)
                target = by_install.get(base)
                if target is None:
                    problems[f].append((name, f"依存 {base} が同梱されていない"))
                elif name not in target:
                    problems[f].append((name, f"{base} が公開していない"))
            else:
                problems[f].append((name, f"不正な ordinal {ordinal}"))

    if not problems:
        print("問題なし: すべての未定義シンボルが解決可能")
        return 0
    print(f"\n解決できないシンボルを持つファイル: {len(problems)}")
    for f in sorted(problems):
        items = problems[f]
        print(f"\n  {f}  ({len(items)} 件)")
        for name, why in items[:12]:
            print(f"    {name}  <- {why}")
        if len(items) > 12:
            print(f"    ... 他 {len(items) - 12} 件")
    return 1


if __name__ == "__main__":
    sys.exit(main())
