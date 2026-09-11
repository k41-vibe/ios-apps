#!/usr/bin/env python3
"""Rewrite one xiOS Mach-O so LiveContainer can dlopen it from the app bundle.

    python relink.py <in> <out> [--name NAME] [--json]

Edits only the header + load-command region (file offsets never move):
  * MH_EXECUTE -> MH_DYLIB, MH_PIE cleared, __PAGEZERO shrunk the way
    LiveContainer does it (vmaddr 0x100000000-0x4000, vmsize 0x4000).
    LC_MAIN is kept; entryoff is reported so the host can call it on a thread.
  * dylib paths under /var/jb/... -> @rpath/<basename>
  * rootful Procursus layout: /usr/lib/<b> or /usr/local/lib/<b> -> @rpath/<b>
    ONLY when <b> is in the "shipped" set (--shipped FILE, one basename per
    line; stage.py passes every dylib it stages). System libraries are never
    shipped, so /usr/lib/libSystem.B.dylib etc. stay. LC_ID_DYLIB under
    /usr/lib or /usr/local/lib is always rewritten (it names the file itself).
  * --libsystem-shim NAME: the LC_LOAD_DYLIB for /usr/lib/libSystem.B.dylib
    becomes @rpath/NAME (a "front" dylib that re-exports libSystem and
    overrides a few functions; two-level namespace binds to it first). The
    slot has 32 bytes of room, so NAME may be at most 24 chars.
  * LC_RPATH entries under /var/jb, /work/ (leaked build dir), /usr/lib or
    /usr/local/lib -> @loader_path (a second such entry is left as an
    identical, harmless duplicate; dyld just probes the same dir twice)
  * strings are rewritten inside the existing cmdsize (NUL + zero padding);
    cmdsize / sizeofcmds are never changed. A dylib path that does not fit is
    a hard error. An LC_RPATH that cannot hold "@loader_path" (rootful
    "/usr/lib": cmdsize 24, 12 bytes of room, 13 needed) is left unchanged and
    reported in "warnings"; dyld searches the rpaths of every image up the
    load chain, so a dylib/bundle still resolves when its loader has one.
    For a former executable (top of the chain) with no fitting LC_RPATH, the
    now-meaningless LC_LOAD_DYLINKER ("/usr/lib/dyld", 20 bytes of room) is
    turned in place into LC_RPATH "@loader_path" (same cmdsize; only the cmd
    field and the string change) - reported as rpath_via_dylinker.
  * a former executable gets an LC_ID_DYLIB appended (install name
    --install-name, default @rpath/<output basename>): dyld refuses to load an
    MH_DYLIB without one ("MH_DYLIB is missing LC_ID_DYLIB"); LiveContainer
    does the same to the guest main binary. The command is written into the
    zero padding between the load commands and the first section (ld leaves
    several KB there), ncmds/sizeofcmds grow accordingly. No room -> warning
    "no_id_dylib" (the image will not dlopen).
  * LC_CODE_SIGNATURE is left untouched (re-signing happens later).
Fat binaries: the arm64 slice is extracted and rewritten (output is thin).
stdlib only; importable (`relink_bytes`, `parse_macho`).
"""
import argparse
import json
import os
import struct
import sys

MH_MAGIC_64 = 0xFEEDFACF
FAT_MAGIC = 0xCAFEBABE
CPU_TYPE_ARM64 = 0x0100000C
CPU_SUBTYPE_ARM64E = 2

MH_EXECUTE = 2
MH_DYLIB = 6
MH_BUNDLE = 8
MH_PIE = 0x200000
FILETYPES = {1: "MH_OBJECT", 2: "MH_EXECUTE", 6: "MH_DYLIB", 8: "MH_BUNDLE"}

LC_SEGMENT_64 = 0x19
LC_ID_DYLIB = 0xD
LC_LOAD_DYLIB = 0xC
LC_LOAD_WEAK_DYLIB = 0x80000018
LC_REEXPORT_DYLIB = 0x1F
LC_LOAD_UPWARD_DYLIB = 0x80000023
LC_RPATH = 0x8000001C
LC_MAIN = 0x80000028
LC_CODE_SIGNATURE = 0x1D
LC_LOAD_DYLINKER = 0xE
DYLIB_CMDS = {LC_ID_DYLIB, LC_LOAD_DYLIB, LC_LOAD_WEAK_DYLIB, LC_REEXPORT_DYLIB, LC_LOAD_UPWARD_DYLIB}
LC_NAMES = {LC_ID_DYLIB: "LC_ID_DYLIB", LC_LOAD_DYLIB: "LC_LOAD_DYLIB", LC_LOAD_WEAK_DYLIB: "LC_LOAD_WEAK_DYLIB",
            LC_REEXPORT_DYLIB: "LC_REEXPORT_DYLIB", LC_LOAD_UPWARD_DYLIB: "LC_LOAD_UPWARD_DYLIB",
            LC_RPATH: "LC_RPATH", LC_MAIN: "LC_MAIN", LC_SEGMENT_64: "LC_SEGMENT_64",
            LC_CODE_SIGNATURE: "LC_CODE_SIGNATURE", LC_LOAD_DYLINKER: "LC_LOAD_DYLINKER"}
LOADER_PATH = "@loader_path"
LIBSYSTEM = "/usr/lib/libSystem.B.dylib"

JB_PREFIX = "/var/jb/"
ROOTFUL_LIB_PREFIXES = ("/usr/lib/", "/usr/local/lib/")
RPATH_PREFIXES = ("/var/jb", "/work/", "/usr/lib", "/usr/local/lib")
HEADER_SIZE = 32


class RelinkError(Exception):
    pass


# ---------------------------------------------------------------- parsing

def is_macho(head):
    """True for a thin arm64 Mach-O or a fat binary (first bytes of a file)."""
    if len(head) < 8:
        return False
    if struct.unpack("<I", head[:4])[0] == MH_MAGIC_64:
        return True
    return struct.unpack(">I", head[:4])[0] == FAT_MAGIC


def thin_arm64(data):
    """Return the arm64 (non-arm64e) slice of `data` (thin input is returned as is)."""
    if len(data) >= 8 and struct.unpack(">I", data[:4])[0] == FAT_MAGIC:
        n = struct.unpack(">I", data[4:8])[0]
        slices = []
        for i in range(n):
            ct, cst, off, size, _align = struct.unpack(">IIIII", data[8 + 20 * i:28 + 20 * i])
            slices.append((ct, cst & 0x00FFFFFF, off, size))
        for ct, cst, off, size in slices:
            if ct == CPU_TYPE_ARM64 and cst != CPU_SUBTYPE_ARM64E:
                return data[off:off + size]
        raise RelinkError("fat binary has no arm64 slice (slices: %s)" %
                          ", ".join("cputype=%#x subtype=%#x" % (ct, cst) for ct, cst, _, _ in slices))
    if len(data) < HEADER_SIZE or struct.unpack("<I", data[:4])[0] != MH_MAGIC_64:
        raise RelinkError("not a 64-bit little-endian Mach-O (magic %s)" % data[:4].hex())
    return data


def _lc_str(buf, off, cmdsize):
    stroff = struct.unpack("<I", buf[off + 8:off + 12])[0]
    raw = buf[off + stroff:off + cmdsize]
    return stroff, raw.split(b"\0")[0].decode("utf-8", errors="replace")


def parse_macho(buf):
    """Parse header + load commands of a thin 64-bit Mach-O. Returns a dict."""
    magic, cputype, cpusub, filetype, ncmds, sizeofcmds, flags, _res = struct.unpack("<IiIIIIII", buf[:HEADER_SIZE])
    if magic != MH_MAGIC_64:
        raise RelinkError("bad magic %#x" % magic)
    info = {"cputype": cputype, "cpusubtype": cpusub & 0x00FFFFFF, "filetype": filetype,
            "filetype_name": FILETYPES.get(filetype, str(filetype)), "ncmds": ncmds,
            "sizeofcmds": sizeofcmds, "flags": flags, "cmds": [], "segments": [],
            "id": None, "deps": [], "rpaths": [], "entryoff": None, "codesig": False}
    off = HEADER_SIZE
    end = HEADER_SIZE + sizeofcmds
    for i in range(ncmds):
        if off + 8 > end:
            raise RelinkError("load command %d runs past sizeofcmds" % i)
        cmd, cmdsize = struct.unpack("<II", buf[off:off + 8])
        if cmdsize < 8 or off + cmdsize > end:
            raise RelinkError("load command %d has bad cmdsize %d" % (i, cmdsize))
        entry = {"index": i, "off": off, "cmd": cmd, "cmdsize": cmdsize, "name": LC_NAMES.get(cmd, "%#x" % cmd)}
        if cmd == LC_SEGMENT_64:
            segname = buf[off + 8:off + 24].split(b"\0")[0].decode("ascii", errors="replace")
            vmaddr, vmsize, fileoff, filesize = struct.unpack("<QQQQ", buf[off + 24:off + 56])
            entry.update(segname=segname, vmaddr=vmaddr, vmsize=vmsize, fileoff=fileoff, filesize=filesize)
            info["segments"].append(entry)
        elif cmd in DYLIB_CMDS:
            stroff, path = _lc_str(buf, off, cmdsize)
            entry.update(stroff=stroff, path=path)
            if cmd == LC_ID_DYLIB:
                info["id"] = path
            else:
                info["deps"].append(path)
        elif cmd == LC_RPATH:
            stroff, path = _lc_str(buf, off, cmdsize)
            entry.update(stroff=stroff, path=path)
            info["rpaths"].append(path)
        elif cmd == LC_LOAD_DYLINKER:
            stroff, path = _lc_str(buf, off, cmdsize)
            entry.update(stroff=stroff, path=path)
        elif cmd == LC_MAIN:
            entryoff, stacksize = struct.unpack("<QQ", buf[off + 8:off + 24])
            entry.update(entryoff=entryoff, stacksize=stacksize)
            info["entryoff"] = entryoff
        elif cmd == LC_CODE_SIGNATURE:
            info["codesig"] = True
        info["cmds"].append(entry)
        off += cmdsize
    return info


# --------------------------------------------------------------- rewriting

def _write_lc_str(buf, off, cmdsize, stroff, new_path, what):
    avail = cmdsize - stroff
    raw = new_path.encode("utf-8")
    if len(raw) + 1 > avail:
        raise RelinkError("%s: new string %r (%d bytes + NUL) does not fit in cmdsize %d (offset %d, %d available)"
                          % (what, new_path, len(raw), cmdsize, stroff, avail))
    buf[off + stroff:off + cmdsize] = raw + b"\0" * (avail - len(raw))


def map_dylib_path(path, shipped=None, is_id=False, libsystem_shim=None):
    base = path.rsplit("/", 1)[-1]
    if libsystem_shim and not is_id and path == LIBSYSTEM:
        return "@rpath/" + libsystem_shim
    if path.startswith(JB_PREFIX):
        return "@rpath/" + base
    if path.startswith(ROOTFUL_LIB_PREFIXES) and (is_id or (shipped and base in shipped)):
        return "@rpath/" + base
    return path


def map_rpath(path):
    if path.startswith(RPATH_PREFIXES):
        return LOADER_PATH
    return path


def _fits(e, new_path):
    return len(new_path.encode("utf-8")) + 1 <= e["cmdsize"] - e["stroff"]


def first_content_offset(buf, info):
    """Lowest file offset of any section/segment content after the header: the load-command area may grow up to it."""
    lowest = None
    for seg in info["segments"]:
        off = seg["off"]
        nsects = struct.unpack("<I", buf[off + 64:off + 68])[0]
        for k in range(nsects):
            so = off + 72 + 80 * k
            size = struct.unpack("<Q", buf[so + 40:so + 48])[0]
            secoff = struct.unpack("<I", buf[so + 48:so + 52])[0]
            if size and secoff and (lowest is None or secoff < lowest):
                lowest = secoff
        if seg["filesize"] and seg["fileoff"] and (lowest is None or seg["fileoff"] < lowest):
            lowest = seg["fileoff"]
    return lowest if lowest is not None else len(buf)


def build_id_dylib(install_name):
    """Bytes of an LC_ID_DYLIB (dylib_command: cmd, cmdsize, name.offset, timestamp, current, compat + string)."""
    raw = install_name.encode("utf-8") + b"\0"
    cmdsize = 24 + (len(raw) + 7) // 8 * 8
    body = struct.pack("<IIIIII", LC_ID_DYLIB, cmdsize, 24, 2, 0x10000, 0x10000) + raw
    return body + b"\0" * (cmdsize - len(body))


def relink_bytes(data, shipped=None, libsystem_shim=None, install_name=None):
    """Rewrite a Mach-O image (bytes). Returns (new_bytes, summary_dict).

    shipped: set of dylib basenames provided by the bundle (enables the rootful
    /usr/lib/<b> -> @rpath/<b> rewrite for those names only).
    libsystem_shim: dylib basename; LC_LOAD_DYLIB /usr/lib/libSystem.B.dylib
    -> @rpath/<libsystem_shim> (must fit the 32-byte string slot).
    install_name: LC_ID_DYLIB to append when the input is an executable (dyld
    needs one on every MH_DYLIB); None leaves the image without one."""
    shipped = set(shipped or ())
    if libsystem_shim and ("/" in libsystem_shim or not libsystem_shim):
        raise RelinkError("--libsystem-shim must be a bare file name, got %r" % libsystem_shim)
    thin = thin_arm64(data)
    before = parse_macho(thin)
    if before["filetype"] not in (MH_EXECUTE, MH_DYLIB, MH_BUNDLE):
        raise RelinkError("unsupported filetype %s" % before["filetype_name"])
    if before["cputype"] != CPU_TYPE_ARM64:
        raise RelinkError("not arm64 (cputype %#x)" % before["cputype"])
    buf = bytearray(thin)
    was_exe = before["filetype"] == MH_EXECUTE
    pagezero_patched = False
    rpath_via_dylinker = False
    id_added = None
    changes, warnings = [], []

    if was_exe:
        flags = before["flags"] & ~MH_PIE
        struct.pack_into("<II", buf, 12, MH_DYLIB, before["ncmds"])
        struct.pack_into("<I", buf, 24, flags)
        changes.append("filetype MH_EXECUTE->MH_DYLIB, flags %#x->%#x" % (before["flags"], flags))
        for seg in before["segments"]:
            if seg["segname"] == "__PAGEZERO":
                off = seg["off"]
                struct.pack_into("<QQ", buf, off + 24, 0x100000000 - 0x4000, 0x4000)
                pagezero_patched = True
                changes.append("__PAGEZERO vmaddr %#x->%#x vmsize %#x->%#x"
                               % (seg["vmaddr"], 0x100000000 - 0x4000, seg["vmsize"], 0x4000))

    expected_deps = []
    for e in before["cmds"]:
        if e["cmd"] in DYLIB_CMDS:
            new = map_dylib_path(e["path"], shipped, is_id=e["cmd"] == LC_ID_DYLIB, libsystem_shim=libsystem_shim)
            if new != e["path"]:
                _write_lc_str(buf, e["off"], e["cmdsize"], e["stroff"], new, e["name"])
                changes.append("%s %s -> %s" % (e["name"], e["path"], new))
            if e["cmd"] != LC_ID_DYLIB:
                expected_deps.append(new)
    expected_rpaths = []
    for e in before["cmds"]:
        if e["cmd"] != LC_RPATH:
            continue
        new = map_rpath(e["path"])
        if new == e["path"]:
            expected_rpaths.append(e["path"])
        elif _fits(e, new):
            _write_lc_str(buf, e["off"], e["cmdsize"], e["stroff"], new, e["name"])
            changes.append("LC_RPATH %s -> %s" % (e["path"], new))
            expected_rpaths.append(new)
        else:
            warnings.append("rpath_unfit: LC_RPATH %r left as is (%d bytes of room, %d needed)"
                            % (e["path"], e["cmdsize"] - e["stroff"], len(new) + 1))
            expected_rpaths.append(e["path"])
    needs_rpath = any(d.startswith("@rpath/") for d in expected_deps)
    if needs_rpath and LOADER_PATH not in expected_rpaths:
        dylinker = [e for e in before["cmds"] if e["cmd"] == LC_LOAD_DYLINKER and _fits(e, LOADER_PATH)]
        if was_exe and dylinker:
            e = dylinker[0]
            struct.pack_into("<I", buf, e["off"], LC_RPATH)
            _write_lc_str(buf, e["off"], e["cmdsize"], e["stroff"], LOADER_PATH, "LC_LOAD_DYLINKER->LC_RPATH")
            rpath_via_dylinker = True
            changes.append("LC_LOAD_DYLINKER %s -> LC_RPATH %s (no LC_RPATH had room)" % (e["path"], LOADER_PATH))
            expected_rpaths.append(LOADER_PATH)
        else:
            warnings.append("no_loader_path_rpath: @rpath/ deps but no LC_RPATH could hold %s; "
                            "relies on the loading image's rpaths" % LOADER_PATH)

    old_end = HEADER_SIZE + before["sizeofcmds"]
    new_end = old_end
    if was_exe and before["id"] is None and install_name:
        cmd = build_id_dylib(install_name)
        limit = first_content_offset(thin, before)
        if old_end + len(cmd) > limit:
            warnings.append("no_id_dylib: %d bytes of header padding, %d needed; dyld will refuse this MH_DYLIB"
                            % (limit - old_end, len(cmd)))
        elif any(thin[old_end:old_end + len(cmd)]):
            warnings.append("no_id_dylib: header padding is not zero; left without LC_ID_DYLIB")
        else:
            buf[old_end:old_end + len(cmd)] = cmd
            new_end = old_end + len(cmd)
            struct.pack_into("<II", buf, 16, before["ncmds"] + 1, before["sizeofcmds"] + len(cmd))
            id_added = install_name
            changes.append("LC_ID_DYLIB %s appended (%d bytes, ncmds %d->%d)"
                           % (install_name, len(cmd), before["ncmds"], before["ncmds"] + 1))

    out = bytes(buf)
    after = parse_macho(out)
    # self-check: the rewrite must be confined to header + load commands (+ the zero padding an appended command took)
    if out[new_end:] != thin[new_end:]:
        raise RelinkError("internal error: bytes outside the load-command region changed")
    if after["sizeofcmds"] != new_end - HEADER_SIZE or after["ncmds"] != before["ncmds"] + (1 if id_added else 0):
        raise RelinkError("internal error: ncmds/sizeofcmds inconsistent")
    if id_added and after["id"] != id_added:
        raise RelinkError("internal error: appended LC_ID_DYLIB does not parse back")
    for a, b in zip(before["cmds"], after["cmds"]):
        if a["cmdsize"] != b["cmdsize"] or a["off"] != b["off"]:
            raise RelinkError("internal error: load command %d changed shape" % a["index"])
        if a["cmd"] != b["cmd"] and not (rpath_via_dylinker and a["cmd"] == LC_LOAD_DYLINKER and b["cmd"] == LC_RPATH):
            raise RelinkError("internal error: load command %d changed type" % a["index"])
    if after["deps"] != expected_deps or sorted(after["rpaths"]) != sorted(expected_rpaths):
        raise RelinkError("internal error: re-parsed deps/rpaths differ from the intended rewrite")
    if before["id"] is not None and after["id"] != map_dylib_path(before["id"], shipped, is_id=True,
                                                                  libsystem_shim=libsystem_shim):
        raise RelinkError("internal error: re-parsed LC_ID_DYLIB differs")
    if was_exe and (after["filetype"] != MH_DYLIB or after["flags"] & MH_PIE):
        raise RelinkError("internal error: header patch not applied")
    if any(s["segname"] == "__PAGEZERO" for s in after["segments"]) and was_exe and not pagezero_patched:
        raise RelinkError("internal error: __PAGEZERO present but not patched")

    summary = {
        "was_executable": was_exe,
        "filetype_before": before["filetype_name"],
        "filetype_after": after["filetype_name"],
        "entryoff": before["entryoff"],
        "id_before": before["id"],
        "id_after": after["id"],
        "deps_before": before["deps"],
        "deps_after": after["deps"],
        "rpaths_before": before["rpaths"],
        "rpaths_after": after["rpaths"],
        "pagezero_patched": pagezero_patched,
        "rpath_via_dylinker": rpath_via_dylinker,
        "id_added": id_added,
        "libsystem_shim": libsystem_shim if any(d == "@rpath/" + str(libsystem_shim) for d in after["deps"]) else None,
        "warnings": warnings,
        "codesig": before["codesig"],
        "was_fat": len(thin) != len(data),
        "size": len(out),
        "changes": changes,
    }
    return out, summary


def relink_file(src, dst, shipped=None, libsystem_shim=None, install_name=None):
    with open(src, "rb") as f:
        data = f.read()
    out, summary = relink_bytes(data, shipped, libsystem_shim, install_name)
    os.makedirs(os.path.dirname(os.path.abspath(dst)), exist_ok=True)
    with open(dst, "wb") as f:
        f.write(out)
    return summary


# --------------------------------------------------------------------- CLI

def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("input")
    ap.add_argument("output")
    ap.add_argument("--name", help="label recorded in the summary (default: output basename)")
    ap.add_argument("--json", action="store_true", help="print a JSON summary")
    ap.add_argument("--shipped", metavar="FILE",
                    help="file with one dylib basename per line; /usr/lib/<name> deps become @rpath/<name>")
    ap.add_argument("--libsystem-shim", metavar="NAME", default=None,
                    help="rewrite LC_LOAD_DYLIB /usr/lib/libSystem.B.dylib to @rpath/NAME (e.g. libLCsys.dylib)")
    ap.add_argument("--install-name", metavar="NAME", default=None,
                    help="LC_ID_DYLIB appended to a former executable (default @rpath/<output basename>; "
                         "an empty string appends none)")
    ap.add_argument("--strip-codesig", action="store_true",
                    help="accepted for CLI compatibility; LC_CODE_SIGNATURE is always left as is")
    args = ap.parse_args(argv)
    shipped = None
    if args.shipped:
        with open(args.shipped, encoding="utf-8") as f:
            shipped = {line.strip() for line in f if line.strip()}
    try:
        install_name = args.install_name
        if install_name is None:
            install_name = "@rpath/" + os.path.basename(args.output)
        summary = relink_file(args.input, args.output, shipped, args.libsystem_shim, install_name or None)
    except RelinkError as e:
        print("relink: %s: %s" % (args.input, e), file=sys.stderr)
        return 1
    summary = {"input": args.input, "output": args.output,
               "name": args.name or os.path.basename(args.output), **summary}
    if args.json:
        print(json.dumps(summary, indent=2))
    else:
        print("%s -> %s (%s -> %s, entryoff=%s, pagezero_patched=%s)" % (
            args.input, args.output, summary["filetype_before"], summary["filetype_after"],
            summary["entryoff"], summary["pagezero_patched"]))
        for c in summary["changes"]:
            print("  " + c)
    return 0


if __name__ == "__main__":
    sys.exit(main())
