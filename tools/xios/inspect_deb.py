#!/usr/bin/env python3
"""Extract a .deb (ar + tar) without external tools and dump Mach-O load commands."""
import sys, os, io, struct, tarfile

def ar_members(data):
    assert data[:8] == b"!<arch>\n", "not an ar archive"
    off = 8
    while off + 60 <= len(data):
        hdr = data[off:off+60]
        name = hdr[0:16].decode().strip().rstrip("/")
        size = int(hdr[48:58].decode().strip())
        body = data[off+60:off+60+size]
        yield name, body
        off += 60 + size + (size & 1)

def open_tar(name, body):
    if name.endswith(".zst"):
        try:
            import zstandard
        except ImportError:
            raise SystemExit("data.tar.zst needs `pip install zstandard`")
        body = zstandard.ZstdDecompressor().stream_reader(io.BytesIO(body)).read()
        return tarfile.open(fileobj=io.BytesIO(body), mode="r:")
    return tarfile.open(fileobj=io.BytesIO(body), mode="r:*")

MH_MAGIC_64 = 0xfeedfacf
FAT_MAGIC = 0xcafebabe
FILETYPES = {2: "MH_EXECUTE", 6: "MH_DYLIB", 8: "MH_BUNDLE", 1: "MH_OBJECT"}
LC = {0xc: "LC_LOAD_DYLIB", 0xd: "LC_ID_DYLIB", 0x80000018: "LC_LOAD_WEAK_DYLIB", 0x1f: "LC_REEXPORT_DYLIB",
      0x80000028: "LC_MAIN", 0xe: "LC_LOAD_DYLINKER", 0x8000001c: "LC_RPATH", 0x1d: "LC_CODE_SIGNATURE",
      0x32: "LC_BUILD_VERSION", 0x25: "LC_VERSION_MIN_IPHONEOS", 0x19: "LC_SEGMENT_64"}
PLATFORMS = {1: "macOS", 2: "iOS", 3: "tvOS", 4: "watchOS", 6: "iOS-simulator", 11: "xrOS"}

def macho_info(buf):
    if len(buf) < 32: return None
    magic = struct.unpack(">I", buf[:4])[0]
    if magic == FAT_MAGIC:
        n = struct.unpack(">I", buf[4:8])[0]
        res = []
        for i in range(n):
            ct, cst, off, size, align = struct.unpack(">IIIII", buf[8+20*i:28+20*i])
            r = macho_info(buf[off:off+size])
            if r: r["slice"] = f"cputype=0x{ct:x} subtype=0x{cst:x}"; res.append(r)
        return {"fat": res}
    magic = struct.unpack("<I", buf[:4])[0]
    if magic != MH_MAGIC_64: return None
    cputype, cpusub, filetype, ncmds, sizeofcmds, flags = struct.unpack("<iIIIII", buf[4:28])
    info = {"cputype": hex(cputype), "cpusubtype": hex(cpusub & 0xffffff), "filetype": FILETYPES.get(filetype, filetype),
            "dylibs": [], "rpaths": [], "other": []}
    off = 32
    for _ in range(ncmds):
        cmd, cmdsize = struct.unpack("<II", buf[off:off+8])
        name = LC.get(cmd, hex(cmd))
        if cmd in (0xc, 0x80000018, 0x1f, 0xd):
            stroff = struct.unpack("<I", buf[off+8:off+12])[0]
            s = buf[off+stroff:off+cmdsize].split(b"\0")[0].decode(errors="replace")
            if cmd == 0xd: info["id"] = s
            else: info["dylibs"].append((name, s))
        elif cmd == 0x8000001c:
            stroff = struct.unpack("<I", buf[off+8:off+12])[0]
            info["rpaths"].append(buf[off+stroff:off+cmdsize].split(b"\0")[0].decode(errors="replace"))
        elif cmd == 0xe:
            stroff = struct.unpack("<I", buf[off+8:off+12])[0]
            info["dylinker"] = buf[off+stroff:off+cmdsize].split(b"\0")[0].decode(errors="replace")
        elif cmd == 0x32:
            plat, minos, sdk, ntools = struct.unpack("<IIII", buf[off+8:off+24])
            v = lambda x: f"{x>>16}.{(x>>8)&0xff}.{x&0xff}"
            info["build_version"] = f"platform={PLATFORMS.get(plat, plat)} minos={v(minos)} sdk={v(sdk)}"
        elif cmd == 0x25:
            minos, sdk = struct.unpack("<II", buf[off+8:off+16])
            v = lambda x: f"{x>>16}.{(x>>8)&0xff}.{x&0xff}"
            info["version_min_iphoneos"] = f"minos={v(minos)} sdk={v(sdk)}"
        elif cmd == 0x1d:
            info["codesig"] = True
        elif cmd == 0x80000028:
            info["lc_main"] = True
        off += cmdsize
    return info

def main(path):
    data = open(path, "rb").read()
    outdir = os.path.splitext(path)[0] + ".extracted"
    os.makedirs(outdir, exist_ok=True)
    print(f"== {os.path.basename(path)} ({len(data):,} bytes)")
    for name, body in ar_members(data):
        print(f"ar member: {name} ({len(body):,} bytes)")
        if name.startswith("control.tar"):
            t = open_tar(name, body)
            for m in t.getmembers():
                print(f"  control: {m.name} ({m.size} bytes)")
                if m.isfile():
                    txt = t.extractfile(m).read().decode(errors="replace")
                    print("  ----"); print("  " + txt.replace("\n", "\n  ").rstrip()); print("  ----")
        elif name.startswith("data.tar"):
            t = open_tar(name, body)
            members = t.getmembers()
            print(f"  data.tar entries: {len(members)}")
            for m in members:
                kind = "d" if m.isdir() else ("l->" + m.linkname if m.issym() else "f")
                print(f"  {kind:>4} {m.mode:o} {m.size:>9} {m.name}")
            t.extractall(outdir, filter="fully_trusted") if hasattr(tarfile, "data_filter") else t.extractall(outdir)
            print(f"\n  extracted to {outdir}\n")
            for m in members:
                if not m.isfile(): continue
                fp = os.path.join(outdir, m.name)
                with open(fp, "rb") as f: head = f.read()
                mi = macho_info(head)
                if not mi: continue
                print(f"  MACH-O {m.name}")
                if "fat" in mi:
                    for s in mi["fat"]: print("    fat slice", s.get("slice"), s.get("filetype"))
                    continue
                for k in ("filetype", "cputype", "cpusubtype", "id", "dylinker", "build_version", "version_min_iphoneos", "lc_main", "codesig"):
                    if k in mi: print(f"    {k}: {mi[k]}")
                for r in mi["rpaths"]: print(f"    LC_RPATH: {r}")
                for lc, d in mi["dylibs"]: print(f"    {lc}: {d}")

if __name__ == "__main__":
    for p in sys.argv[1:]: main(p)
