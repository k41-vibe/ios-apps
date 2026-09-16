#!/usr/bin/env python3
"""Mach-O の記号表を読んで、クラッシュログのアドレスがどの関数かを言い当てる。

iOS のクラッシュログは tweak の中を `Foo + 78068` のように、たまたま近い
公開記号からの差で書く。実際の関数は記号表(LC_SYMTAB。静的関数も載る)を
アドレス順に並べて、その手前で一番近いものを見る。

    python tools/macho-symbolicate.py <dylib> <記号名+差分 または 0x生オフセット> ...

例:
    python tools/macho-symbolicate.py YouMod.dylib YMOrderedOverlayButtons+78068
    python tools/macho-symbolicate.py YTMusicUltimate.dylib 108508
"""
import struct
import sys

MH_MAGIC_64 = 0xFEEDFACF
LC_SYMTAB = 0x02
LC_SEGMENT_64 = 0x19
N_STAB = 0xE0
N_TYPE = 0x0E
N_SECT = 0x0E


def load_symbols(path):
    data = open(path, "rb").read()
    magic = struct.unpack("<I", data[:4])[0]
    if magic != MH_MAGIC_64:
        raise SystemExit("arm64 の Mach-O ではありません(fat なら slice を切り出してください)")
    ncmds = struct.unpack("<I", data[16:20])[0]
    pos = 32
    syms = []
    text_base = None
    for _ in range(ncmds):
        cmd, size = struct.unpack("<II", data[pos:pos + 8])
        if cmd == LC_SEGMENT_64:
            name = data[pos + 8:pos + 24].rstrip(b"\x00").decode()
            vmaddr = struct.unpack("<Q", data[pos + 24:pos + 32])[0]
            if name == "__TEXT":
                text_base = vmaddr
        elif cmd == LC_SYMTAB:
            symoff, nsyms, stroff, strsize = struct.unpack("<IIII", data[pos + 8:pos + 24])
            strtab = data[stroff:stroff + strsize]
            for i in range(nsyms):
                off = symoff + i * 16
                n_strx, n_type, n_sect, n_desc, n_value = struct.unpack("<IBBHQ", data[off:off + 16])
                if n_type & N_STAB:
                    continue
                if (n_type & N_TYPE) != N_SECT or n_value == 0:
                    continue
                end = strtab.find(b"\x00", n_strx)
                nm = strtab[n_strx:end].decode("utf-8", "replace")
                if nm:
                    syms.append((n_value, nm))
        pos += size
    syms.sort()
    return syms, (text_base or 0)


def main():
    path = sys.argv[1]
    syms, base = load_symbols(path)
    by_name = {n: a for a, n in syms}
    print(f"{path}: 記号 {len(syms)} 個, __TEXT base {hex(base)}")

    for target in sys.argv[2:]:
        if "+" in target:
            name, _, delta = target.partition("+")
            name = name.strip()
            if name not in by_name and "_" + name in by_name:
                name = "_" + name
            if name not in by_name:
                print(f"\n{target}: 記号 {name} が見つかりません")
                continue
            addr = by_name[name] + int(delta)
        else:
            addr = base + int(target, 0)

        print(f"\n{target}  ->  {hex(addr)}")
        prev = None
        for a, n in syms:
            if a > addr:
                break
            prev = (a, n)
        if prev:
            print(f"  含む関数: {prev[1]}  (先頭 {hex(prev[0])}, +{addr - prev[0]} バイト)")
        # 前後も出す。記号が剥がされていると手前が遠くなるので、目安として
        idx = [i for i, (a, _) in enumerate(syms) if a <= addr]
        if idx:
            i = idx[-1]
            for j in range(max(0, i - 2), min(len(syms), i + 3)):
                a, n = syms[j]
                mark = " <<<" if j == i else ""
                print(f"    {hex(a)}  {n}{mark}")


if __name__ == "__main__":
    main()
