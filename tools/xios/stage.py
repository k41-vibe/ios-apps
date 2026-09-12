#!/usr/bin/env python3
"""Download, extract and relink the xiOS package closure into a LiveContainer staging tree.

    python stage.py --urls closure_urls.txt --sha closure_sha256.txt --cache <dir> --out <stagedir>

Output layout:
  <stagedir>/jb/...              package payloads with the leading ./var/jb/ stripped
                                 (every Mach-O removed; "<name>.lc" next to where it was holds
                                 "@LC:Frameworks/<flat>" - nothing is left at <name> itself).
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

Symlinks: a real symlink where the OS allows it (absolute /var/jb/... targets
are rewritten relative to the link so they stay valid inside the bundle);
otherwise (Windows without symlink privilege, or --symlinks never) the target
file is copied - after relinking; a link to a Mach-O becomes a "<link>.lc"
stub in either mode, never a copy - and links to directories or missing targets become
"<path>.symlink" marker files holding the link target (libLCsys resolves them
at run time). --symlinks never is what CI uses: no symlink then has to survive
upload-artifact, zip and LiveContainer's unzip.

Invariant: jb/ contains NO Mach-O file and no file NAMED like one. Every
Mach-O (plugins in subdirs such as engines-3/, ossl-modules/, gdk-pixbuf
loaders, gtk printbackends, and the executables inside nested .app dirs -
records["files"] is flat, so those dirs are nothing special) is relinked into
Frameworks/ under a unique flat name, deleted from jb/ and replaced by
"<orig>.lc" (jb/usr/lib/libglib-2.0.0.dylib.lc, jb/usr/bin/ls.lc,
jb/Applications/Xios.app/Xios.lc); a symlink that resolves to a Mach-O
becomes the same "<link>.lc" stub (never a copy of the binary, never a real
symlink). The ".lc" suffix is what keeps LiveContainer's installer - which
picks signing candidates by name (*.dylib, executables inside *.app) - away
from the stubs; libLCsys maps the guest-visible /var/jb/<orig> to the .lc file
(manifest.json orig_path stays the guest path, without .lc).
A final scan of jb/ for Mach-O magic fails the run (exit 2) listing offenders
unless --allow-raw-macho is given; files still named *.dylib are counted. Flat-name collisions (same basename in two
dirs, e.g. gtk-3.0/.../libprintbackend-file.so vs gtk-4.0/...) get a unique
name from the parent directory chain ("gtk-4.0__4.0.0__printbackends__lib...")
with the default --collide=prefix; skip/fail keep the old behaviour.

--libsystem-shim NAME (default libLCsys.dylib): every relinked Mach-O gets its
/usr/lib/libSystem.B.dylib load command rewritten to @rpath/NAME. NAME is NOT
staged here - the app's postbuild.sh builds it from apps/<app>/native/ and
drops it into Frameworks/ next to the relinked files.
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
STUB_SUFFIX = ".lc"
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
            records["seq"] += 1
            records["files"][orig] = {"package": pkgname, "dest": dest, "size": m.size, "rootful": rootful,
                                      "seq": records["seq"]}
        elif m.issym():
            target = m.linkname
            if rootful and target.startswith("/") and not target.startswith("/var/jb/"):
                target = "/var/jb" + target  # rootful deb: absolute targets are relative to the package root
            records["seq"] += 1
            records["symlinks"].append({"path": orig, "dest": dest, "target": target, "package": pkgname,
                                        "rootful": rootful, "seq": records["seq"]})
        elif m.islnk():
            # hard link: copy the already-extracted link source
            _rootful, src_rel = split_member(m.linkname)
            src = safe_join(root, src_rel)
            os.makedirs(os.path.dirname(dest), exist_ok=True)
            shutil.copyfile(src, dest)
            records["seq"] += 1
            records["files"][orig] = {"package": pkgname, "dest": dest, "size": os.path.getsize(dest),
                                      "rootful": rootful, "seq": records["seq"]}
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


MACHO_MAGICS = (b"\xcf\xfa\xed\xfe", b"\xfe\xed\xfa\xcf",  # MH_MAGIC_64 LE / BE spelling
                b"\xce\xfa\xed\xfe", b"\xfe\xed\xfa\xce",  # MH_MAGIC (32-bit)
                b"\xca\xfe\xba\xbe", b"\xbe\xba\xfe\xca")  # FAT_MAGIC / FAT_CIGAM


def has_macho_magic(path):
    try:
        with open(path, "rb") as f:
            head = f.read(4)
    except OSError:
        return False
    return len(head) == 4 and head in MACHO_MAGICS


def is_macho_file(path):
    try:
        with open(path, "rb") as f:
            head = f.read(8)
    except OSError:
        return False
    return relink.is_macho(head)


FLAT_PREFIX_STRIP = ("/var/jb/usr/local/lib/", "/var/jb/usr/lib/", "/var/jb/usr/local/bin/", "/var/jb/usr/bin/",
                     "/var/jb/bin/", "/var/jb/sbin/", "/var/jb/")


def prefixed_flat_names(orig_path, flat):
    """Candidate unique flat names for a collision, most readable first: the parent dir chain below the
    usual lib/bin roots joined with '__', then the full chain under /var/jb/, then numbered variants.
    /var/jb/usr/lib/gtk-4.0/4.0.0/printbackends/libprintbackend-file.so -> gtk-4.0__4.0.0__printbackends__<flat>
    /var/jb/bin/sync (nothing left after stripping /var/jb/bin/)         -> bin__<flat>"""
    def chain(rel):
        parts = rel.split("/")[:-1]
        parts = [p.replace(".", "_") if p.endswith((".app", ".framework")) else p for p in parts]
        return "__".join(parts + [flat]) if parts else None
    cands = []
    for pre in FLAT_PREFIX_STRIP:
        if orig_path.startswith(pre):
            c = chain(orig_path[len(pre):])
            if c:
                cands.append(c)
            break
    full = chain(orig_path[len("/var/jb/"):]) if orig_path.startswith("/var/jb/") else None
    if full and full not in cands:
        cands.append(full)
    base = cands[-1] if cands else flat
    cands += ["%d__%s" % (i, base) for i in range(2, 10)]
    return cands


def write_stub(dest, flat):
    """Replace dest (a relinked Mach-O, or the place a symlink to one would be) by "<dest>.lc" holding
    "@LC:Frameworks/<flat>". Nothing stays at dest itself: LiveContainer's installer picks its signing
    candidates by file name, and a 30-byte text file called libfoo.dylib shows up as "could not sign"."""
    if os.path.lexists(dest):
        os.remove(dest)
    with open(dest + STUB_SUFFIX, "w", encoding="utf-8", newline="") as f:
        f.write(STUB_PREFIX + flat)


def scan_signer_bait(jb_root):
    """Names under jb/ that LiveContainer's installer picks up BY NAME (not by content).

    It walks the bundle looking for *.dylib / *.framework / nested *.app and tries to
    patch or sign each one; our stubs are 30-byte text files, so every hit turns into a
    "LiveContainer could not sign these files" warning on install (seen on device
    2026-09-11 with ~150 entries). Stubs are therefore written as <name>.lc, and
    packages that ship a nested .app (com.max.xios) are kept out of the closure.
    """
    found = []
    for dp, dn, fn in os.walk(jb_root):
        for n in fn:
            if n.endswith(".dylib"):
                found.append(os.path.relpath(os.path.join(dp, n), jb_root).replace("\\", "/"))
        for d in dn:
            if d.endswith(".app") or d.endswith(".framework"):
                found.append(os.path.relpath(os.path.join(dp, d), jb_root).replace("\\", "/") + "/")
    return sorted(found)


def scan_raw_machos(jb_root):
    """Every regular file under jb/ that still starts with a Mach-O magic (the invariant says: none)."""
    found = []
    for dp, _dn, fn in os.walk(jb_root):
        for n in fn:
            path = os.path.join(dp, n)
            if os.path.islink(path):
                continue
            if has_macho_magic(path):
                found.append(os.path.relpath(path, jb_root).replace("\\", "/"))
    return sorted(found)


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


def reconcile_records(records):
    """Same guest path shipped by one package as a real file and by another as a symlink.

    records["files"] is a dict (last write wins) but records["symlinks"] is a list, and
    materialise_symlinks() runs AFTER relinking - so a stale symlink record would overwrite the
    ".lc" stub that relink_all() just wrote for the real file (or replace a real data file with a
    stub). Keep only whichever record was extracted last, by the "seq" counter, and drop the other.
    Also collapses duplicate symlink records for one path.
    """
    latest = {}
    for s in records["symlinks"]:
        cur = latest.get(s["path"])
        if cur is None or s["seq"] > cur["seq"]:
            latest[s["path"]] = s
    dropped_links, dropped_files = [], []
    keep = []
    for path, s in latest.items():
        f = records["files"].get(path)
        if f and f["seq"] > s["seq"]:
            dropped_links.append({"path": path, "symlink_from": s["package"], "file_from": f["package"]})
            continue
        if f:
            dropped_files.append({"path": path, "file_from": f["package"], "symlink_from": s["package"]})
            del records["files"][path]
        keep.append(s)
    keep.sort(key=lambda x: x["seq"])
    n_dupes = len(records["symlinks"]) - len(latest)
    records["symlinks"] = keep
    records["reconciled"] = {"dropped_symlinks": dropped_links, "dropped_files": dropped_files,
                             "duplicate_symlinks": n_dupes}
    for d in dropped_links:
        log("  RECONCILE %s: real file from %s wins over symlink from %s"
            % (d["path"], d["file_from"], d["symlink_from"]))
    for d in dropped_files:
        log("  RECONCILE %s: symlink from %s wins over real file from %s"
            % (d["path"], d["symlink_from"], d["file_from"]))
    if n_dupes:
        log("  RECONCILE %d duplicate symlink record(s) collapsed" % n_dupes)
    return records["reconciled"]


def relink_all(records, frameworks_dir, collide="prefix", libsystem_shim=None):
    manifest, failures = [], []
    seen = {}  # casefolded flat -> orig_path
    machos, shipped = classify_machos(records)
    for orig, info, kind, hdr in machos:
        dest = info["dest"]
        renamed_from = None
        try:
            if kind is None:
                raise relink.RelinkError(hdr)
            flat = flat_name(orig, kind, hdr["id"] if kind == "dylib" else None)
            key = flat.casefold()
            if key in seen and seen[key] != orig:
                msg = "flat name collision: %r <- %s and %s" % (flat, seen[key], orig)
                if collide == "fail":
                    raise SystemExit(msg)
                if collide == "skip":
                    raise relink.RelinkError(msg + " (second one skipped: --collide=skip)")
                renamed_from = flat
                free = [c for c in prefixed_flat_names(orig, flat) if c.casefold() not in seen]
                if not free:
                    raise relink.RelinkError(msg + " (every prefixed name collides too)")
                flat = free[0]
                key = flat.casefold()
            seen[key] = orig
            with open(dest, "rb") as f:
                data = f.read()
            out, summary = relink.relink_bytes(data, shipped, libsystem_shim, "@rpath/" + flat)
        except SystemExit:
            raise
        except Exception as e:  # noqa: BLE001
            failures.append({"orig_path": orig, "package": info["package"], "error": "%s: %s" % (type(e).__name__, e)})
            continue
        with open(os.path.join(frameworks_dir, flat), "wb") as f:
            f.write(out)
        write_stub(dest, flat)
        info["stub_for"] = flat
        warnings = list(summary["warnings"])
        if renamed_from:
            warnings.append("flat_renamed: %r collided, staged as %r (dlopen via its stub still works; "
                            "an @rpath/%s dependent would not find this copy)" % (renamed_from, flat, renamed_from))
        manifest.append({"orig_path": orig, "flat": flat, "kind": kind, "entryoff": summary["entryoff"],
                         "package": info["package"], "size": len(out), "rootful": info["rootful"],
                         "id": summary["id_after"], "deps": summary["deps_after"], "rpaths": summary["rpaths_after"],
                         "rpath_via_dylinker": summary["rpath_via_dylinker"], "warnings": warnings,
                         "renamed_from": renamed_from})
    return manifest, failures, shipped


def add_alias_copies(records, manifest, frameworks_dir, libsystem_shim=None):
    """Frameworks/<b> for every @rpath/<b> dep that is missing but is a staged symlink alias of a staged dylib."""
    present = {m["flat"].casefold() for m in manifest}
    if libsystem_shim:
        present.add(libsystem_shim.casefold())  # built by postbuild.sh, never staged
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
        # follow link chains within the staged tree (max 8 hops)
        cur, hops = s["path"], 0
        while hops < 8 and cur in by_path:
            cur = resolve_link_target(cur, by_path[cur]["target"])
            hops += 1
        src = records["files"].get(cur)
        if src and src.get("stub_for"):
            # target is a relinked Mach-O: "<link>.lc" with the same stub text, never the binary and
            # never a real symlink (a symlink named libfoo.dylib would still be a signing candidate)
            write_stub(dest, src["stub_for"])
            entry["resolved"] = cur
            entry["how"] = "stub"
            entry["stub_for"] = src["stub_for"]
            results.append(entry)
            continue
        if symlink_ok:
            if os.path.lexists(dest):
                os.remove(dest)
            target = s["target"]
            if target.startswith("/var/jb/") or target == "/var/jb":
                # keep the link valid inside the bundle: point at the staged file relatively
                target = os.path.relpath(os.path.join(jb_root, target[len("/var/jb/"):]),
                                         os.path.dirname(dest)).replace("\\", "/")
                entry["relative_target"] = target
            os.symlink(target, dest)
            entry["how"] = "symlink"
            results.append(entry)
            continue
        entry["resolved"] = cur
        if src and os.path.isfile(src["dest"]):
            if has_macho_magic(src["dest"]):
                entry["how"] = "marker-raw-macho"  # target failed to relink; a marker, not a copy
                with open(dest + ".symlink", "w", encoding="utf-8", newline="\n") as f:
                    f.write(s["target"] + "\n")
                results.append(entry)
                continue
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
    ap.add_argument("--collide", choices=("prefix", "skip", "fail"), default="prefix",
                    help="two Mach-Os mapping to one flat name: prefix (default) gives the later one a unique "
                         "name from its parent dirs; skip leaves it raw (the scan then fails); fail aborts. "
                         "/var/jb/usr/... paths are processed first, so they keep the plain name")
    ap.add_argument("--allow-raw-macho", action="store_true",
                    help="do not fail when a Mach-O file is left under jb/ (default: exit 2 and list them)")
    ap.add_argument("--allow-link-gaps", action="store_true",
                    help="未解決の @rpath 依存 / LC_ID_DYLIB 欠落があっても失敗させない")
    ap.add_argument("--symlinks", choices=("auto", "never"), default="auto",
                    help="auto: real symlinks when the OS allows; never: always copy/marker (CI uses never)")
    ap.add_argument("--libsystem-shim", metavar="NAME", default="libLCsys.dylib",
                    help="rewrite LC_LOAD_DYLIB /usr/lib/libSystem.B.dylib to @rpath/NAME in every relinked "
                         "Mach-O (default libLCsys.dylib; empty string disables)")
    args = ap.parse_args(argv)
    libsystem_shim = args.libsystem_shim or None

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
    symlink_ok = args.symlinks == "auto" and can_symlink(args.out)
    log("symlink support: %s" % ("yes" if symlink_ok else
                                 "no (copy/marker fallback%s)" % (", --symlinks never" if args.symlinks == "never" else "")))
    log("libSystem shim: %s" % (("@rpath/" + libsystem_shim) if libsystem_shim else "off"))

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
    records = {"files": {}, "symlinks": [], "hardlinks": [], "skipped": [], "overwritten": [], "seq": 0}
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
    reconcile_records(records)
    manifest, failures, shipped = relink_all(records, frameworks, args.collide, libsystem_shim)
    aliases, unresolved = add_alias_copies(records, manifest, frameworks, libsystem_shim)
    with open(os.path.join(args.out, "shipped_dylibs.txt"), "w", encoding="utf-8", newline="\n") as f:
        f.write("\n".join(sorted(shipped)) + "\n")
    with open(os.path.join(args.out, "manifest.json"), "w", encoding="utf-8", newline="\n") as f:
        json.dump(manifest, f, indent=1)
    with open(os.path.join(args.out, "failures.json"), "w", encoding="utf-8", newline="\n") as f:
        json.dump(failures, f, indent=1)

    # symlinks AFTER relinking: a link to a Mach-O becomes the same "<link>.lc" stub (stub_for), never a copy
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
    if libsystem_shim:
        n_shim = sum(1 for m in manifest if "@rpath/" + libsystem_shim in m["deps"])
        n_sys = sum(1 for m in manifest if relink.LIBSYSTEM in m["deps"])
        log("libSystem -> @rpath/%s: %d images rewritten, %d still on %s (should be 0), %d link neither"
            % (libsystem_shim, n_shim, n_sys, relink.LIBSYSTEM, len(manifest) - n_shim - n_sys))
    log("Frameworks/: %s in %d files (of which %d alias copies, %s)"
        % (human(fw_bytes), len(os.listdir(frameworks)), len(aliases), human(sum(a["size"] for a in aliases))))
    for a in aliases:
        log("  alias %-32s -> %s" % (a["flat"], a["alias_of"]))
    if unresolved:
        log("@rpath deps with no file in Frameworks/ (closure gap, or dyld /usr/lib fallback): %s" % " ".join(unresolved))
    n_noid = [m["flat"] for m in manifest if m["kind"] == "exe" and not m["id"]]
    log("former executables with LC_ID_DYLIB appended: %d; without (will not dlopen): %d %s"
        % (n_exe - len(n_noid), len(n_noid), " ".join(n_noid[:10])))
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
    renamed = [m for m in manifest if m.get("renamed_from")]
    if renamed:
        log("flat-name collisions resolved by prefixing: %d" % len(renamed))
        for m in renamed:
            log("  %s -> %s" % (m["orig_path"], m["flat"]))

    # 6. invariant: no Mach-O file under jb/
    n_stub_files = sum(1 for info in records["files"].values() if info.get("stub_for"))
    n_stub_links = how_counts.get("stub", 0)
    log("counts: Frameworks/ %d files (%d relinked + %d alias copies); jb/ stubs %d (%d relinked files + %d symlink stubs); "
        "relink failures %d" % (len(os.listdir(frameworks)), len(manifest) - len(aliases), len(aliases),
                                n_stub_files + n_stub_links, n_stub_files, n_stub_links, len(failures)))
    raw = scan_raw_machos(jb_root)
    log("scan jb/ for Mach-O magic: %d raw Mach-O file(s)%s" % (len(raw), "" if raw else " (OK)"))
    for r in raw:
        log("  RAW  jb/%s" % r)
    bait = scan_signer_bait(jb_root)
    log("scan jb/ for names the installer signs (*.dylib, *.app/, *.framework/): %d%s"
        % (len(bait), "" if bait else " (OK)"))
    for r in bait[:20]:
        log("  NAME jb/%s" % r)
    if raw and not args.allow_raw_macho:
        log("ERROR: jb/ must contain no Mach-O (every one is relinked into Frameworks/ + stubbed); "
            "pass --allow-raw-macho to override")
        return 2
    if bait and not args.allow_raw_macho:
        log("ERROR: jb/ must contain no *.dylib / *.app / *.framework names - LiveContainer's "
            "installer picks those up by name and reports them as unsignable; stubs must be <name>.lc "
            "and packages shipping a nested .app must be dropped from the closure")
        return 2
    # Link-time invariants. dlopen(RTLD_NOW) binds everything at load, so a missing @rpath dependency
    # or a former executable without LC_ID_DYLIB is a guaranteed run-time failure - it must not reach
    # an .ipa as a line of CI log nobody reads. --allow-link-gaps is the deliberate override.
    if unresolved and not args.allow_link_gaps:
        log("ERROR: %d @rpath dependency/ies have no file in Frameworks/: %s"
            % (len(unresolved), " ".join(unresolved)))
        log("       add the providing package to closure.py SEEDS, or pass --allow-link-gaps when iOS "
            "itself ships it in /usr/lib")
        return 2
    if n_noid and not args.allow_link_gaps:
        log("ERROR: %d former executable(s) have no LC_ID_DYLIB; dyld refuses to dlopen those: %s"
            % (len(n_noid), " ".join(n_noid[:20])))
        return 2
    return 0


if __name__ == "__main__":
    sys.exit(main())
