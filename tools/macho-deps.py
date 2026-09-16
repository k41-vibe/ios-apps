#!/usr/bin/env python3
"""Mach-O の依存(LC_LOAD_DYLIB)と探索路(LC_RPATH)を並べる。

tweak の .dylib が LiveContainer で開けるかは「何を要求するか」で決まる。
LiveContainer は自分の束に入れた CydiaSubstrate(ElleKit)を先に読ませるので、
要求名がそれと一致すれば解決する。libroot.dylib 等は用意が無いので落ちる。

    python tools/macho-deps.py <file...>
"""
import struct
import sys

MH_MAGIC_64 = 0xFEEDFACF
MH_CIGAM_64 = 0xCFFAEDFE
FAT_MAGIC = 0xCAFEBABE
FAT_CIGAM = 0xBEBAFECA
LC_LOAD_DYLIB = 0x0C
LC_ID_DYLIB = 0x0D
LC_LOAD_WEAK_DYLIB = 0x80000018
LC_REEXPORT_DYLIB = 0x8000001F
LC_RPATH = 0x8000001C
CPU_NAMES = {0x0100000C: "arm64", 0x0000000C: "arm"}


def slices(data):
    magic = struct.unpack(">I", data[:4])[0]
    if magic in (FAT_MAGIC, FAT_CIGAM):
        n = struct.unpack(">I", data[4:8])[0]
        for i in range(n):
            off = 8 + i * 20
            cputype, _sub, offset, size, _align = struct.unpack(">iiIII", data[off:off + 20])
            yield CPU_NAMES.get(cputype & 0xFFFFFFFF, hex(cputype)), data[offset:offset + size]
    else:
        cputype = struct.unpack("<i", data[4:8])[0]
        yield CPU_NAMES.get(cputype & 0xFFFFFFFF, hex(cputype)), data


def commands(sl):
    magic = struct.unpack("<I", sl[:4])[0]
    if magic not in (MH_MAGIC_64, MH_CIGAM_64):
        return
    ncmds = struct.unpack("<I", sl[16:20])[0]
    pos = 32
    for _ in range(ncmds):
        cmd, size = struct.unpack("<II", sl[pos:pos + 8])
        yield cmd, sl[pos:pos + size]
        pos += size


def text(body, offset):
    s = body[offset:]
    end = s.find(b"\x00")
    return s[:end if end >= 0 else len(s)].decode("utf-8", "replace")


def main():
    for path in sys.argv[1:]:
        data = open(path, "rb").read()
        print(f"\n=== {path}  ({len(data) / 1048576:.1f} MB)")
        for arch, sl in slices(data):
            deps, rpaths, own = [], [], None
            for cmd, body in commands(sl):
                if cmd in (LC_LOAD_DYLIB, LC_LOAD_WEAK_DYLIB, LC_REEXPORT_DYLIB):
                    off = struct.unpack("<I", body[8:12])[0]
                    weak = " (weak)" if cmd == LC_LOAD_WEAK_DYLIB else ""
                    deps.append(text(body, off) + weak)
                elif cmd == LC_ID_DYLIB:
                    own = text(body, struct.unpack("<I", body[8:12])[0])
                elif cmd == LC_RPATH:
                    rpaths.append(text(body, struct.unpack("<I", body[8:12])[0]))
            print(f"  [{arch}] 自分の名前: {own}")
            for r in rpaths:
                print(f"    rpath : {r}")
            for d in deps:
                print(f"    依存  : {d}")


if __name__ == "__main__":
    main()
