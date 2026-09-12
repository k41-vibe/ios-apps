#!/usr/bin/env python3
"""Compute transitive Depends/Pre-Depends closure over Debian Packages indexes.

Sources:
  Packages           -> https://repo.maxleiter.com/  (flat repo, suite "./")
  Packages.procursus -> https://apt.procurs.us/ dists/iphoneos-arm64-rootless/1800 main
                        (index: main/binary-iphoneos-arm64/Packages{,.xz,.zst})

The ROOTLESS pool is required: the maxleiter debs are rootless (/var/jb prefix)
and the rootful pool (dists/iphoneos-arm64/1800) ships payloads at / with
/usr/lib install names and LC_RPATH /usr/lib, which cannot be relinked in place
(stage run of 2026-09-11: 41 rootful packages, 265 rpath_unfit warnings).
"""
import re, sys, os
from collections import OrderedDict

HERE = os.path.dirname(os.path.abspath(__file__))
SOURCES = [
    ("maxleiter", os.path.join(HERE, "Packages"), "https://repo.maxleiter.com/"),
    ("procursus", os.path.join(HERE, "Packages.procursus"), "https://apt.procurs.us/"),
]
SEEDS = ["iosc", "iosc-shell", "foot", "nautilus", "bash", "coreutils",
         "pkg-config", "dbus", "angle", "wayland", "libwayland0", "libwayland-dev",
         # extra seeds closing @rpath deps that Depends fields miss (found by stage.py, 2026-09-11):
         "libgtk-3-0",                   # libgtk-3.0.dylib   <- libgnome-autoar-gtk (maxleiter only)
         "libcurl4",                     # libcurl.4.dylib    <- libappstream (maxleiter 8.20 > procursus 8.7)
         "libcairo-script-interpreter2", # libcairo-script-interpreter.2.dylib <- libgtk-4 (both repos)
         "libintl-dev",                  # unversioned libintl.dylib <- librsvg-2 / libpixbufloader-svg; only libintl-dev ships it
         ]
# NOT seeded: com.max.xios (脱獄機用の表示アプリ Xios.app)。XiOSLite の Swift ホストが同じ役目を果たすので不要。
#   同梱すると jb/Applications/Xios.app という入れ子の .app ができ、LiveContainer の署名器が
#   名前で拾って「署名できないファイル」警告を出す。leaf パッケージなので落として安全。
# NOT seeded: @rpath/libz.1.dylib (freetype/png/xml2) -- no zlib1g in either repo; iOS ships /usr/lib/libz.1.dylib.
# libexpat1 / libexpat1-dev exist only in the rootful pool; iOS ships /usr/lib/libexpat.1.dylib (fontconfig's alternative is `firmware`).
GTK4_FALLBACKS = ["nautilus", "gtk4-demo", "gtk4-examples", "gnome-console", "gnome-text-editor"]
# Virtual packages that the on-device package manager synthesises (never a .deb)
DEVICE_VIRTUAL = {"firmware"}
SUSPECT_RE = re.compile(r"(daemon|launchd|systemd|polkit|logind|upower|elogind|udev|seat|session|dbus|pulseaudio|pipewire|cron|sshd|openssh-server)", re.I)

# ---------------- dpkg version compare ----------------
def _order(c):
    if c == "~": return -1
    if c.isdigit(): return 0
    if c.isalpha(): return ord(c)
    return ord(c) + 256

def _verrevcmp(a, b):
    i = j = 0
    while i < len(a) or j < len(b):
        first_diff = 0
        while (i < len(a) and not a[i].isdigit()) or (j < len(b) and not b[j].isdigit()):
            ac = _order(a[i]) if i < len(a) else 0
            bc = _order(b[j]) if j < len(b) else 0
            if ac != bc: return ac - bc
            i += 1; j += 1
        while i < len(a) and a[i] == "0": i += 1
        while j < len(b) and b[j] == "0": j += 1
        while i < len(a) and a[i].isdigit() and j < len(b) and b[j].isdigit():
            if first_diff == 0: first_diff = ord(a[i]) - ord(b[j])
            i += 1; j += 1
        if i < len(a) and a[i].isdigit(): return 1
        if j < len(b) and b[j].isdigit(): return -1
        if first_diff: return first_diff
    return 0

def _split(v):
    epoch = 0
    if ":" in v:
        e, v = v.split(":", 1); epoch = int(e)
    if "-" in v:
        up, rev = v.rsplit("-", 1)
    else:
        up, rev = v, "0"
    return epoch, up, rev

def vercmp(a, b):
    ea, ua, ra = _split(a); eb, ub, rb = _split(b)
    if ea != eb: return ea - eb
    r = _verrevcmp(ua, ub)
    if r: return r
    return _verrevcmp(ra, rb)

def satisfies(ver, op, want):
    if not op: return True
    c = vercmp(ver, want)
    return {"<<": c < 0, "<=": c <= 0, "=": c == 0, ">=": c >= 0, ">>": c > 0,
            "<": c <= 0, ">": c >= 0}[op]

# ---------------- parsing ----------------
def parse_packages(path):
    out = []
    with open(path, encoding="utf-8", errors="replace") as f:
        stanza = OrderedDict(); key = None
        for line in f:
            line = line.rstrip("\n")
            if not line.strip():
                if stanza: out.append(stanza); stanza = OrderedDict(); key = None
                continue
            if line[0] in " \t" and key:
                stanza[key] += "\n" + line.strip()
            else:
                k, _, v = line.partition(":")
                key = k.strip(); stanza[key] = v.strip()
        if stanza: out.append(stanza)
    return out

DEP_RE = re.compile(r"^\s*([A-Za-z0-9][A-Za-z0-9+.\-]*)(?::[a-z0-9-]+)?\s*(?:\(\s*(<<|<=|=|>=|>>|<|>)\s*([^)]+?)\s*\))?\s*(?:\[[^\]]*\])?\s*$")

def parse_depfield(s):
    """-> list of alternatives-lists: [[(name, op, ver), ...], ...]"""
    groups = []
    for grp in s.replace("\n", " ").split(","):
        grp = grp.strip()
        if not grp: continue
        alts = []
        for alt in grp.split("|"):
            m = DEP_RE.match(alt)
            if not m:
                alts.append((alt.strip(), None, None)); continue
            alts.append((m.group(1), m.group(2), m.group(3)))
        groups.append(alts)
    return groups

# ---------------- index ----------------
by_name = {}      # name -> list of (stanza, source, baseurl)
provides = {}     # virtual -> list of (provider name, version-or-None)
for src, path, base in SOURCES:
    for st in parse_packages(path):
        if "Package" not in st: continue
        by_name.setdefault(st["Package"], []).append((st, src, base))
        if "Provides" in st:
            for alts in parse_depfield(st["Provides"]):
                for (n, op, v) in alts:
                    provides.setdefault(n, []).append((st["Package"], v))

def best(name):
    """highest version across sources (apt default policy, equal priorities)."""
    cands = by_name.get(name)
    if not cands: return None
    cands = sorted(cands, key=lambda c: c[0].get("Version", "0"), reverse=False)
    top = cands[0]
    for c in cands[1:]:
        if vercmp(c[0].get("Version", "0"), top[0].get("Version", "0")) > 0:
            top = c
    return top

def resolve_alt(name, op, ver):
    """Return (real package name, note) or (None, reason)."""
    if name in DEVICE_VIRTUAL:
        return None, "device-virtual"
    b = best(name)
    if b:
        st = b[0]
        if satisfies(st["Version"], op, ver):
            return name, None
        return name, f"version-unsatisfied: have {st['Version']}, need {op} {ver}"
    if name in provides:
        for prov, pv in provides[name]:
            if op and pv is not None and not satisfies(pv, op, ver):
                continue
            if op and pv is None:
                continue
            return prov, f"via Provides of {prov}"
        if provides[name]:
            prov = provides[name][0][0]
            return prov, f"via Provides of {prov} (version constraint not checkable)"
    return None, "not-found"

# ---------------- seeds ----------------
seed_report = []
seeds = []
for s in SEEDS:
    if by_name.get(s):
        seeds.append(s); seed_report.append((s, s, "found"))
    elif s == "nautilus":
        for fb in GTK4_FALLBACKS:
            if by_name.get(fb):
                seeds.append(fb); seed_report.append((s, fb, "substituted")); break
        else:
            seed_report.append((s, None, "no GTK4 app found"))
    elif s == "wayland":
        subs = sorted(n for n in by_name if n.startswith("libwayland"))
        for n in subs:
            if n not in seeds and n not in SEEDS: seeds.append(n)
        seed_report.append((s, ",".join(subs), "no package 'wayland'; substituted libwayland*"))
    else:
        seed_report.append((s, None, "NOT FOUND in either index"))

# ---------------- closure ----------------
closure = OrderedDict()   # name -> (stanza, src, base)
unsat = []                # (pkg, depstring, reason)
edges = {}                # name -> list of resolved dep names
queue = list(seeds)
while queue:
    n = queue.pop(0)
    if n in closure: continue
    b = best(n)
    if not b:
        unsat.append((n, n, "seed not found")); continue
    closure[n] = b
    st = b[0]
    deps = []
    for field in ("Pre-Depends", "Depends"):
        if field in st:
            for alts in parse_depfield(st[field]):
                chosen = None; reasons = []
                for (dn, op, dv) in alts:
                    real, note = resolve_alt(dn, op, dv)
                    if real and not (note and note.startswith("version-unsatisfied")):
                        chosen = real
                        if note: reasons.append(f"{dn}: {note}")
                        break
                    reasons.append(f"{dn}: {note}")
                depstr = " | ".join(f"{dn}{' ('+op+' '+dv+')' if op else ''}" for dn, op, dv in alts)
                if chosen:
                    deps.append(chosen)
                    if chosen not in closure: queue.append(chosen)
                    if reasons and any("Provides" in r for r in reasons):
                        pass
                else:
                    # tolerate version-unsatisfied by taking first existing anyway, but record
                    fallback = None
                    for (dn, op, dv) in alts:
                        if best(dn): fallback = dn; break
                    if fallback:
                        deps.append(fallback)
                        if fallback not in closure: queue.append(fallback)
                    if all("device-virtual" in r for r in reasons):
                        unsat.append((n, depstr, "device-virtual (synthesised by dpkg/apt on device: 'firmware')"))
                    else:
                        unsat.append((n, depstr, "; ".join(reasons)))
    edges[n] = list(OrderedDict.fromkeys(deps))

# ---------------- outputs ----------------
def isize(st):
    try: return int(st.get("Installed-Size", "0"))
    except ValueError: return 0
def dsize(st):
    try: return int(st.get("Size", "0"))
    except ValueError: return 0

rows = []
for n, (st, src, base) in closure.items():
    rows.append((n, st["Version"], isize(st), dsize(st), base + st["Filename"], src, st.get("Architecture", "")))

with open(os.path.join(HERE, "closure.txt"), "w", encoding="utf-8") as f:
    f.write("# package\tversion\tInstalled-Size(KiB)\tSize(bytes)\tsource\tFilename-URL\n")
    for r in sorted(rows):
        f.write(f"{r[0]}\t{r[1]}\t{r[2]}\t{r[3]}\t{r[5]}\t{r[4]}\n")

with open(os.path.join(HERE, "closure_urls.txt"), "w", encoding="utf-8") as f:
    for r in sorted(rows):
        f.write(r[4] + "\n")

# also a sha256 list for CI verification
with open(os.path.join(HERE, "closure_sha256.txt"), "w", encoding="utf-8") as f:
    for n, (st, src, base) in sorted(closure.items()):
        f.write(f"{st.get('SHA256','')}  {os.path.basename(st['Filename'])}\n")

total_dl = sum(r[3] for r in rows)
total_inst = sum(r[2] for r in rows)
from_max = sum(1 for r in rows if r[5] == "maxleiter")
from_proc = sum(1 for r in rows if r[5] == "procursus")

# packages present in BOTH indexes where the chosen one differs from Max's repo version
overlaps = []
for n in closure:
    srcs = {c[1]: c[0]["Version"] for c in by_name[n]}
    if len(srcs) > 1:
        overlaps.append((n, srcs, closure[n][1]))

suspects = [r for r in rows if SUSPECT_RE.search(r[0])]

# reverse edges for "why is this here"
rev = {}
for a, ds in edges.items():
    for d in ds: rev.setdefault(d, []).append(a)

md = []
md.append("# xiOS MVP package closure summary\n")
md.append("Generated by closure.py from:\n")
md.append("- `https://repo.maxleiter.com/` -- flat repo: `deb [trusted=yes] https://repo.maxleiter.com ./` (Release: Suite stable, Codename ios, Components main, Architectures iphoneos-arm64; indexes at `/Packages`, `/Packages.gz`, `/Release`; debs under `/debs/`)")
md.append("- `https://apt.procurs.us/` -- `dists/iphoneos-arm64-rootless/1800` (**rootless** pool; Release lists components `main`, `testing`), component `main`, index `main/binary-iphoneos-arm64/Packages{,.xz,.zst}`; stanzas say `Architecture: iphoneos-arm64`, files live under `pool/main/iphoneos-arm64-rootless/1800/...`. The rootful pool `dists/iphoneos-arm64/1800` (used until 2026-09-11) ships payloads at `/` with `/usr/lib` install names and `LC_RPATH /usr/lib`, which the in-place relink cannot fix (no room for `@loader_path`); rootless was required.")
md.append("- extra seeds `libgtk-3-0`, `libcurl4`, `libcairo-script-interpreter2`, `libintl-dev` close `@rpath` deps missing from Depends (libgtk-3.0 / libcurl.4 / libcairo-script-interpreter.2 / unversioned libintl.dylib; the last is only shipped by libintl-dev). `@rpath/libz.1.dylib` (freetype, png, xml2) has no package in either repo; iOS provides `/usr/lib/libz.1.dylib`. `libexpat1` exists only in the rootful pool; iOS provides `/usr/lib/libexpat.1.dylib`.\n")
md.append("## Seeds\n")
md.append("| requested | used | note |\n|---|---|---|")
for s, u, note in seed_report:
    md.append(f"| {s} | {u or '-'} | {note} |")
md.append("")
md.append("## Totals\n")
md.append(f"- packages in closure: **{len(rows)}** ({from_max} from repo.maxleiter.com, {from_proc} from Procursus)")
md.append(f"- total download size (sum of `Size`): **{total_dl/1024/1024:.1f} MiB** ({total_dl:,} bytes)")
md.append(f"- total Installed-Size: **{total_inst/1024:.1f} MiB** ({total_inst:,} KiB)")
md.append("")
md.append("## 20 largest packages (by Installed-Size)\n")
md.append("| package | version | Installed-Size (KiB) | Size (bytes) | source |\n|---|---|---|---|---|")
for r in sorted(rows, key=lambda r: -r[2])[:20]:
    md.append(f"| {r[0]} | {r[1]} | {r[2]:,} | {r[3]:,} | {r[5]} |")
md.append("")
md.append("## Unsatisfied / special dependencies\n")
if unsat:
    md.append("| package | dependency | reason |\n|---|---|---|")
    seen = set()
    for p, d, why in unsat:
        if (p, d) in seen: continue
        seen.add((p, d))
        md.append(f"| {p} | `{d}` | {why} |")
else:
    md.append("none")
md.append("")
md.append("## Packages present in both indexes (apt picks highest version)\n")
if overlaps:
    md.append("| package | maxleiter | procursus | chosen |\n|---|---|---|---|")
    for n, srcs, chosen in sorted(overlaps):
        md.append(f"| {n} | {srcs.get('maxleiter','-')} | {srcs.get('procursus','-')} | {chosen} |")
else:
    md.append("none")
md.append("")
md.append("## Packages that smell like root/launchd/daemon (candidates for stubbing)\n")
md.append("| package | version | source | required by |\n|---|---|---|---|")
for r in sorted(suspects):
    md.append(f"| {r[0]} | {r[1]} | {r[5]} | {', '.join(sorted(rev.get(r[0], []))) or 'seed'} |")
md.append("")
md.append("## Procursus base packages pulled in (non-Max)\n")
md.append(", ".join(sorted(r[0] for r in rows if r[5] == "procursus")))
md.append("")
md.append("## Max repo packages pulled in\n")
md.append(", ".join(sorted(r[0] for r in rows if r[5] == "maxleiter")))
md.append("")
md.append("## Why-chains for the seeds (direct deps)\n")
for s in seeds:
    md.append(f"- **{s}** -> {', '.join(edges.get(s, [])) or '(none)'}")
md.append("")

notes = os.path.join(HERE, "inspection_notes.md")
if os.path.exists(notes):
    md.append(open(notes, encoding="utf-8").read())
with open(os.path.join(HERE, "summary.md"), "w", encoding="utf-8") as f:
    f.write("\n".join(md))
print("\n".join(md))
