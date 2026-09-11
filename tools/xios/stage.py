#!/usr/bin/env python3
"""Download, extract and relink the xiOS package closure into a LiveContainer staging tree.

    python stage.py --urls closure_urls.txt --sha closure_sha256.txt --cache <dir> --out <stagedir>

Output layout:
  <stagedir>/jb/...              package payloads with the leading ./var/jb/ stripped
                                 (Mach-O files replaced by "@LC:Frameworks/<flat>" stubs).
                                 Rootful debs (payload at ./usr/..., ./bin/...; the Procursus
                                 iphoneos-arm64/1800 pool) are merged here as if rooted at
                                 /var/jb and flagged rootful=true in packages.json/manifest.json.
  <stagedir>/Frameworks/<flat>   relinked Mach-Os. exe: <basename>.exe.dylib. dylib: basename of
                                 LC_ID_DYLIB (what dependents ask dyld for), falling back to the file
                                 name; e.g. libicuuc.74.2.dylib is staged as libicuuc.74.dylib.
                                 A symlink alias that some dep still references and that is not
                                 already present is materialised as a copy (manifest: alias_of).
  <stagedir>/meta/<pkg>.scripts.txt   maintainer scripts (preinst/postinst/prerm/postrm/triggers)
  <stagedir>/meta/<pkg>.control       the control file
  <stagedir>/manifest.json       [{orig_path, flat, kind, entryoff, package, size, rootful, deps, rpaths}]
  <stagedir>/packages.json       per package: deb, rootful, file/symlink counts, scripts
  <stagedir>/shipped_dylibs.txt  dylib basenames we ship (drives the /usr/lib/<b> -> @rpath rewrite)
  <stagedir>/symlinks.json       every tar symlink and how it was materialised
  <stagedir>/failures.json       Mach-Os that could not be relinked (also printed)

Symlinks: a real symlink where the OS allows it; otherwise (Windows without
symlink privilege) the target file is copied - after relinking, so a link to a
Mach-O copies the small @LC stub, not the binary - and links to directories or
missing targets become "<path>.symlink" marker files holding the link target.
stdlib + zstandard only.
"""
import argparse
import hashlib
import json
import os
import shutil
import sys
import time
import urllib.request

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import inspect_deb  # noqa: E402  (ar + tar.zst readers)
import relink  # noqa: E402

JB_TAR_PREFIX = "./var/jb/"
SCRIPT_NAMES = ("preinst", "postinst", "prerm", "postrm", "triggers", "config")
STUB_PREFIX = "@LC:Frameworks/"
USER_AGENT = "xios-stage/1.0 (+python-urllib)"


def log(msg):
    print(msg, flush=True)


# ---------------------------------------------------------------- download

def read_urls(path):
    urls = []
    with open(path, encoding="utf-8") as f:
        for line in f:
            line = line.strip()
            if line and not line.startswith("#"):
                urls.append(line)
    return urls


def read_sha(path):
    sums = {}
    with open(path, encoding="utf-8") as f:
        for line in f:
            parts = line.split()
            if len(parts) >= 2 and not line.startswith("#"):
                sums[parts[1].lstrip("*")] = parts[0].lower()
    return sums


def sha256_file(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def download(url, dest, expected_sha, retries=3):
    """Fetch url into dest unless a cached copy already matches expected_sha. Returns 'cached'|'downloaded'."""
    if os.path.exists(dest) and sha256_file(dest) == expected_sha:
        return "cached"
    tmp = dest + ".part"
    last = None
    for attempt in range(1, retries + 1):
        try:
            req = urllib.request.Request(url, headers={"User-Agent": USER_AGENT})
            with urllib.request.urlopen(req, timeout=60) as resp, open(tmp, "wb") as out:
                shutil.copyfileobj(resp, out, 1 << 20)
            got = sha256_file(tmp)
            if got != expected_sha:
                raise ValueError("sha256 mismatch: expected %s got %s" % (expected_sha, got))
            os.replace(tmp, dest)
            return "downloaded"
        except Exception as e:  # noqa: BLE001
            last = e
            if os.path.exists(tmp):
                os.remove(tmp)
            if attempt < retries:
                time.sleep(2 * attempt)
    raise RuntimeError("download failed after %d attempts: %s (%s)" % (retries, url, last))


# ----------------------------------------------------------------- extract

def parse_control(text):
    fields = {}
    for line in text.splitlines():
        if line and not line[0].isspace() and ":" in line:
            k, v = line.split(":", 1)
            fields[k.strip()] = v.strip()
    return fields


def read_deb(path):
    """Return (control_fields, {script_name: text}, control_text, data_tarfile)."""
    with open(path, "rb") as f:
        data = f.read()
    control, scripts, control_text, data_tar = {}, {}, "", None
    for name, body in inspect_deb.ar_members(data):
        if name.startswith("control.tar"):
            t = inspect_deb.open_tar(name, body)
            for m in t.getmembers():
                if not m.isfile():
                    continue
                base = m.name[2:] if m.name.startswith("./") else m.name
                txt = t.extractfile(m).read().decode("utf-8", errors="replace")
                if base == "control":
                    control_text = txt
                    control = parse_control(txt)
                elif base in SCRIPT_NAMES:
                    scripts[base] = txt
        elif name.startswith("data.tar"):
            data_tar = inspect_deb.open_tar(name, body)
    if data_tar is None:
        raise RuntimeError("no data.tar member in %s" % path)
    return control, scripts, control_text, data_tar


def can_symlink(probe_dir):
    try:
        os.makedirs(probe_dir, exist_ok=True)
        link = os.path.join(probe_dir, ".symlink-probe")
        if os.path.lexists(link):
            os.remove(link)
        os.symlink("probe-target", link)
        os.remove(link)
        return True
    except (OSError, NotImplementedError, AttributeError):
        return False


def split_member(name):
    """Map a tar member name to (rootful, relpath-under-jb).

    ./var/jb/X -> (False, X); anything else (rootful deb) -> (True, X), i.e. merged
    into jb/ as if the package had been rooted at /var/jb."""
    n = name
    if n.startswith("./"):
        n = n[2:]
    n = n.strip("/")
    if n == ".":
        n = ""
    if n.startswith("var/jb/"):
        return False, n[len("var/jb/"):]
    if n in ("", "var", "var/jb"):
        return False, ""
    return True, n


def safe_join(root, rel):
    dest = os.path.normpath(os.path.join(root, rel))
    if os.path.commonpath([os.path.abspath(root), os.path.abspath(dest)]) != os.path.abspath(root):
        raise RuntimeError("path escapes staging root: %r" % rel)
    return dest


def extract_deb(deb_path, root, pkg, records):
    """Extract payload into root (the jb/ dir). Fills records (files, symlinks, hardlinks).
    Returns (pkgname, control_text, scripts, rootful_member_count)."""
    control, scripts, control_text, tar = read_deb(deb_path)
    pkgname = control.get("Package") or pkg
    n_rootful = 0
    for m in tar.getmembers():
        rootful, rel = split_member(m.name)
        if rel == "":
            continue
        n_rootful += rootful
        dest = safe_join(root, rel)
        orig = "/var/jb/" + rel
        if m.isdir():
            os.makedirs(dest, exist_ok=True)
        elif m.isfile():
            os.makedirs(os.path.dirname(dest), exist_ok=True)
            with tar.extractfile(m) as src, open(dest, "wb") as out:
                shutil.copyfileobj(src, out, 1 << 20)
            if orig in records["files"] and records["files"][orig]["package"] != pkgname:
                records["overwritten"].append({"path": orig, "first": records["files"][orig]["package"], "then": pkgname})
            records["files"][orig] = {"package": pkgname, "dest": dest, "size": m.size, "rootful": rootful}
        elif m.issym():
            target = m.linkname
            if rootful and target.startswith("/") and not target.startswith("/var/jb/"):
                target = "/var/jb" + target  # rootful deb: absolute targets are relative to the package root
            records["symlinks"].append({"path": orig, "dest": dest, "target": target, "package": pkgname,
                                        "rootful": rootful})
        elif m.islnk():
            # hard link: copy the already-extracted link source
            _rootful, src_rel = split_member(m.linkname)
            src = safe_join(root, src_rel)
            os.makedirs(os.path.dirname(dest), exist_ok=True)
            shutil.copyfile(src, dest)
            records["files"][orig] = {"package": pkgname, "dest": dest, "size": os.path.getsize(dest), "rootful": rootful}
            records["hardlinks"].append({"path": orig, "source": m.linkname, "package": pkgname})
        else:
            records["skipped"].append({"package": pkgname, "path": m.name, "type": str(m.type)})
    return pkgname, control_text, scripts, n_rootful


# ------------------------------------------------------------------ relink

def flat_name(orig_path, kind, install_name=None):
    base = orig_path.rsplit("/", 1)[1]
    if kind != "dylib":
        return base + ".exe.dylib"
    if install_name:
        idb = install_name.rsplit("/", 1)[-1]
        if idb and "/" not in idb and idb not in (".", ".."):
            return idb
    return base


def is_macho_file(path):
    try:
        with open(path, "rb") as f:
            head = f.read(8)
    except OSError:
        return False
    return relink.is_macho(head)


def classify_machos(records):
    """Parse every Mach-O under jb/. Returns [(orig, info, kind|None, header|error)] and the shipped basename set."""
    found, shipped = [], set()
    # /var/jb/usr/... first so that on a flat-name collision the /usr/bin copy wins (e.g. /bin/sync vs /usr/bin/sync)
    for orig, info in sorted(records["files"].items(), key=lambda kv: (not kv[0].startswith("/var/jb/usr/"), kv[0])):
        if not is_macho_file(info["dest"]):
            continue
        try:
            with open(info["dest"], "rb") as f:
                hdr = relink.parse_macho(relink.thin_arm64(f.read()))
        except Exception as e:  # noqa: BLE001
            found.append((orig, info, None, "%s: %s" % (type(e).__name__, e)))
            continue
        if hdr["filetype"] == relink.MH_EXECUTE:
            kind = "exe"
        elif hdr["filetype"] in (relink.MH_DYLIB, relink.MH_BUNDLE):
            kind = "dylib"
            shipped.add(orig.rsplit("/", 1)[1])
            if hdr["id"]:
                shipped.add(hdr["id"].rsplit("/", 1)[-1])
        else:
            kind, hdr = None, "skipped: filetype %s" % hdr["filetype_name"]
        found.append((orig, info, kind, hdr))
    return found, shipped


def relink_all(records, frameworks_dir, collide="fail"):
    manifest, failures = [], []
    seen = {}  # casefolded flat -> orig_path
    machos, shipped = classify_machos(records)
    for orig, info, kind, hdr in machos:
        dest = info["dest"]
        try:
            if kind is None:
                raise relink.RelinkError(hdr)
            flat = flat_name(orig, kind, hdr["id"] if kind == "dylib" else None)
            key = flat.casefold()
            if key in seen and seen[key] != orig:
                msg = "flat name collision: %r <- %s and %s" % (flat, seen[key], orig)
                if collide == "fail":
                    raise SystemExit(msg)
                raise relink.RelinkError(msg + " (second one skipped: --collide=skip)")
            seen[key] = orig
            with open(dest, "rb") as f:
                data = f.read()
            out, summary = relink.relink_bytes(data, shipped)
        except SystemExit:
            raise
        except Exception as e:  # noqa: BLE001
            failures.append({"orig_path": orig, "package": info["package"], "error": "%s: %s" % (type(e).__name__, e)})
            continue
        with open(os.path.join(frameworks_dir, flat), "wb") as f:
            f.write(out)
        with open(dest, "w", encoding="utf-8", newline="") as f:
            f.write(STUB_PREFIX + flat)
        info["stub_for"] = flat
        manifest.append({"orig_path": orig, "flat": flat, "kind": kind, "entryoff": summary["entryoff"],
                         "package": info["package"], "size": len(out), "rootful": info["rootful"],
                         "deps": summary["deps_after"], "rpaths": summary["rpaths_after"],
                         "rpath_via_dylinker": summary["rpath_via_dylinker"], "warnings": summary["warnings"]})
    return manifest, failures, shipped


def add_alias_copies(records, manifest, frameworks_dir):
    """Frameworks/<b> for every @rpath/<b> dep that is missing but is a staged symlink alias of a staged dylib."""
    present = {m["flat"].casefold() for m in manifest}
    needed = {d[len("@rpath/"):] for m in manifest for d in m["deps"] if d.startswith("@rpath/")}
    missing = {b for b in needed if b.casefold() not in present}
    by_flat = {m["flat"]: m for m in manifest}
    stub_for = {orig: info["stub_for"] for orig, info in records["files"].items() if info.get("stub_for")}
    by_path = {l["path"]: l for l in records["symlinks"]}
    added, unresolved = [], sorted(missing)
    for l in records["symlinks"]:
        b = l["path"].rsplit("/", 1)[1]
        if b not in missing:
            continue
        cur, hops = l["path"], 0
        while hops < 8 and cur in by_path:
            cur = resolve_link_target(cur, by_path[cur]["target"])
            hops += 1
        flat = stub_for.get(cur)
        if not flat or flat not in by_flat:
            continue
        src = by_flat[flat]
        shutil.copyfile(os.path.join(frameworks_dir, flat), os.path.join(frameworks_dir, b))
        entry = dict(src, orig_path=l["path"], flat=b, alias_of=flat, package=l["package"])
        manifest.append(entry)
        added.append(entry)
        missing.discard(b)
        unresolved = sorted(missing)
    return added, unresolved


# ---------------------------------------------------------------- symlinks

def resolve_link_target(link_orig, target):
    """Absolute (/var/jb/...) path a symlink points at, POSIX semantics."""
    if target.startswith("/"):
        return os.path.normpath(target).replace("\\", "/")
    base = link_orig.rsplit("/", 1)[0]
    return os.path.normpath(base + "/" + target).replace("\\", "/")


def materialise_symlinks(records, symlink_ok, jb_root):
    by_path = {s["path"]: s for s in records["symlinks"]}
    results = []
    for s in records["symlinks"]:
        dest = s["dest"]
        os.makedirs(os.path.dirname(dest), exist_ok=True)
        entry = {"path": s["path"], "target": s["target"], "package": s["package"]}
        if symlink_ok:
            if os.path.lexists(dest):
                os.remove(dest)
            os.symlink(s["target"], dest)
            entry["how"] = "symlink"
            results.append(entry)
            continue
        # follow link chains within the staged tree (max 8 hops)
        cur, hops = s["path"], 0
        while hops < 8 and cur in by_path:
            cur = resolve_link_target(cur, by_path[cur]["target"])
            hops += 1
        entry["resolved"] = cur
        src = records["files"].get(cur)
        if src and os.path.isfile(src["dest"]):
            shutil.copyfile(src["dest"], dest)
            entry["how"] = "copied"
            entry["copied_bytes"] = os.path.getsize(dest)
        else:
            if cur.startswith("/var/jb/"):
                cand = os.path.join(jb_root, cur[len("/var/jb/"):])
            else:
                cand = None
            entry["how"] = "marker-dir" if cand and os.path.isdir(cand) else "marker-missing"
            with open(dest + ".symlink", "w", encoding="utf-8", newline="\n") as f:
                f.write(s["target"] + "\n")
        results.append(entry)
    return results


# ----------------------------------------------------------------- summary

def dir_bytes(root):
    total = 0
    for dp, _dn, fn in os.walk(root):
        for n in fn:
            p = os.path.join(dp, n)
            if not os.path.islink(p):
                total += os.path.getsize(p)
    return total


def human(n):
    for unit in ("B", "KB", "MB", "GB"):
        if n < 1024 or unit == "GB":
            return "%.1f %s" % (n, unit) if unit != "B" else "%d B" % n
        n /= 1024.0


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--urls", required=True)
    ap.add_argument("--sha", required=True)
    ap.add_argument("--cache", required=True)
    ap.add_argument("--out", required=True)
    ap.add_argument("--clean", action="store_true", help="delete <out> before staging")
    ap.add_argument("--collide", choices=("fail", "skip"), default="fail",
                    help="two Mach-Os mapping to one flat name: abort (default) or skip the later one "
                         "(/var/jb/usr/... paths are processed first, so they win) and report it")
    args = ap.parse_args(argv)

    urls = read_urls(args.urls)
    sums = read_sha(args.sha)
    os.makedirs(args.cache, exist_ok=True)
    if args.clean and os.path.isdir(args.out):
        shutil.rmtree(args.out)
    jb_root = os.path.join(args.out, "jb")
    frameworks = os.path.join(args.out, "Frameworks")
    meta = os.path.join(args.out, "meta")
    for d in (jb_root, frameworks, meta):
        os.makedirs(d, exist_ok=True)
    symlink_ok = can_symlink(args.out)
    log("symlink support: %s" % ("yes" if symlink_ok else "no (copy/marker fallback)"))

    # 1. download
    debs = []
    t0 = time.time()
    n_cached = n_dl = 0
    for url in urls:
        fname = url.rsplit("/", 1)[1]
        if fname not in sums:
            raise SystemExit("no sha256 entry for %s" % fname)
        dest = os.path.join(args.cache, fname)
        how = download(url, dest, sums[fname])
        n_cached += how == "cached"
        n_dl += how == "downloaded"
        debs.append(dest)
    log("download: %d debs (%d cached, %d downloaded) in %.1fs" % (len(debs), n_cached, n_dl, time.time() - t0))

    # 2. extract
    records = {"files": {}, "symlinks": [], "hardlinks": [], "skipped": [], "overwritten": []}
    packages = []
    scripts_written = 0
    for deb in debs:
        n_files, n_links = len(records["files"]), len(records["symlinks"])
        pkgname, control_text, scripts, n_rootful = extract_deb(deb, jb_root, os.path.basename(deb), records)
        packages.append({"package": pkgname, "deb": os.path.basename(deb), "rootful": n_rootful > 0,
                         "files": len(records["files"]) - n_files, "symlinks": len(records["symlinks"]) - n_links,
                         "scripts": sorted(scripts)})
        with open(os.path.join(meta, pkgname + ".control"), "w", encoding="utf-8", newline="\n") as f:
            f.write(control_text)
        if scripts:
            with open(os.path.join(meta, pkgname + ".scripts.txt"), "w", encoding="utf-8", newline="\n") as f:
                for name in SCRIPT_NAMES:
                    if name in scripts:
                        f.write("===== %s: %s =====\n%s\n\n" % (pkgname, name, scripts[name].rstrip("\n")))
            scripts_written += 1
    log("extract: %d packages, %d files, %d symlinks, %d hardlinks, %d maintainer-script sets -> meta/"
        % (len(packages), len(records["files"]), len(records["symlinks"]), len(records["hardlinks"]), scripts_written))
    rootful_pkgs = [p["package"] for p in packages if p["rootful"]]
    if rootful_pkgs:
        log("  NOTE %d rootful packages (payload not under ./var/jb/) merged into jb/ as if rooted at /var/jb: %s"
            % (len(rootful_pkgs), " ".join(rootful_pkgs)))
    with open(os.path.join(args.out, "packages.json"), "w", encoding="utf-8", newline="\n") as f:
        json.dump(packages, f, indent=1)
    if records["overwritten"]:
        log("  NOTE %d files shipped by two packages (last wins): %s"
            % (len(records["overwritten"]), records["overwritten"][:5]))
    if records["skipped"]:
        log("  NOTE skipped %d unsupported tar entries: %s" % (len(records["skipped"]), records["skipped"][:5]))

    # 3+4. relink Mach-Os, write stubs + manifest
    manifest, failures, shipped = relink_all(records, frameworks, args.collide)
    aliases, unresolved = add_alias_copies(records, manifest, frameworks)
    with open(os.path.join(args.out, "shipped_dylibs.txt"), "w", encoding="utf-8", newline="\n") as f:
        f.write("\n".join(sorted(shipped)) + "\n")
    with open(os.path.join(args.out, "manifest.json"), "w", encoding="utf-8", newline="\n") as f:
        json.dump(manifest, f, indent=1)
    with open(os.path.join(args.out, "failures.json"), "w", encoding="utf-8", newline="\n") as f:
        json.dump(failures, f, indent=1)

    # symlinks last so copies of Mach-O links pick up the @LC stub
    links = materialise_symlinks(records, symlink_ok, jb_root)
    with open(os.path.join(args.out, "symlinks.json"), "w", encoding="utf-8", newline="\n") as f:
        json.dump(links, f, indent=1)

    # 5. summary
    n_exe = sum(1 for m in manifest if m["kind"] == "exe")
    n_dylib = len(manifest) - n_exe
    fw_bytes = dir_bytes(frameworks)
    jb_bytes = dir_bytes(jb_root)
    log("")
    log("== stage summary: %s" % os.path.abspath(args.out))
    log("Mach-O relinked: %d (exe %d, dylib %d); failed: %d; rootful: %d"
        % (len(manifest), n_exe, n_dylib, len(failures), sum(1 for m in manifest if m["rootful"])))
    log("Frameworks/: %s in %d files (of which %d alias copies, %s)"
        % (human(fw_bytes), len(os.listdir(frameworks)), len(aliases), human(sum(a["size"] for a in aliases))))
    for a in aliases:
        log("  alias %-32s -> %s" % (a["flat"], a["alias_of"]))
    if unresolved:
        log("@rpath deps with no file in Frameworks/ (closure gap, or dyld /usr/lib fallback): %s" % " ".join(unresolved))
    n_dyl = sum(1 for m in manifest if m["rpath_via_dylinker"])
    warned = [m for m in manifest if m["warnings"]]
    log("rpath via LC_LOAD_DYLINKER slot: %d; entries with warnings: %d (see manifest.json 'warnings')" % (n_dyl, len(warned)))
    kinds = {}
    for m in warned:
        for w in m["warnings"]:
            k = w.split(":", 1)[0]
            kinds[k] = kinds.get(k, 0) + 1
    for k, v in sorted(kinds.items()):
        log("  %s: %d" % (k, v))
    log("jb/ (data only, stubs included): %s" % human(jb_bytes))
    how_counts = {}
    for l in links:
        how_counts[l["how"]] = how_counts.get(l["how"], 0) + 1
    log("symlinks: %s" % (", ".join("%s=%d" % kv for kv in sorted(how_counts.items())) or "none"))
    log("largest Frameworks entries:")
    for m in sorted(manifest, key=lambda m: -m["size"])[:15]:
        log("  %10s  %-40s %-5s %s" % (human(m["size"]), m["flat"], m["kind"], m["package"]))
    if failures:
        log("FAILED to relink (left as raw Mach-O in jb/):")
        for fl in failures:
            log("  %s (%s): %s" % (fl["orig_path"], fl["package"], fl["error"]))
    return 0


if __name__ == "__main__":
    sys.exit(main())
