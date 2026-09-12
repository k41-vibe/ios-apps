#!/bin/bash
# Called by the workflow after xcodebuild, before packaging.
#   $APP_DIR   = path to the built XiOSDesktop.app
#   $STAGE_DIR = output of tools/xios/stage.py (downloaded artifact "xios-stage")
# 1. builds Frameworks/libLCsys.dylib from native/*.c + native/*.m (re-exports libSystem)
# 2. copies the staged tree: Frameworks/* (relinked Mach-Os) and jb/ (data + @LC stubs)
set -euo pipefail
: "${APP_DIR:?APP_DIR not set}"
: "${STAGE_DIR:?STAGE_DIR not set (stage job artifact missing?)}"
FW="$APP_DIR/Frameworks"
mkdir -p "$FW"
SDK=$(xcrun --sdk iphoneos --show-sdk-path)
HERE=$(cd "$(dirname "$0")" && pwd)
OUT="$FW/libLCsys.dylib"

CFLAGS=(-target arm64-apple-ios16.0 -isysroot "$SDK" -O2 -Wall -Wno-deprecated-declarations
        -fvisibility=default -dynamiclib -install_name @rpath/libLCsys.dylib)
# native/xpcshim.m is Objective-C written for MANUAL retain/release: do NOT add
# -fobjc-arc (MRR is clang's default for .m, so no flag is needed either way).
# Foundation/libobjc are what the NSXPCConnection swizzle needs; Metal is there because
# the objects we shuttle are MTLSharedEventHandles (we never name the type, see the
# file header) and iosc loads Metal regardless. IOSurface + CoreFoundation are for
# native/xsurface.c (IOSurfaceLookupFromMachPort / CFRelease); both are public on iOS.
LDFLAGS=(-framework Foundation -framework Metal -framework IOSurface -framework CoreFoundation -lobjc)
shopt -s nullglob
SRCS=("$HERE"/native/*.c "$HERE"/native/*.m)
shopt -u nullglob
[ ${#SRCS[@]} -gt 0 ] || { echo "::error::no sources in $HERE/native"; exit 1; }

# The dylib must RE-EXPORT libSystem (LC_REEXPORT_DYLIB), otherwise guests bound to
# @rpath/libLCsys.dylib would miss every libc symbol. Two spellings of the flag are
# tried; a link that "succeeds" without the reexport counts as a failure.
has_reexport() { otool -l "$OUT" 2>/dev/null | grep -q LC_REEXPORT_DYLIB; }
linked=no
for attempt in 1 2; do
  if [ $attempt = 1 ]; then flag="-Wl,-reexport-lSystem"; else flag="-Wl,-reexport_library,$SDK/usr/lib/libSystem.B.tbd"; fi
  echo "== building libLCsys.dylib (attempt $attempt: $flag)"
  echo "clang ${CFLAGS[*]} $flag ${SRCS[*]} ${LDFLAGS[*]} -o $OUT"
  rm -f "$OUT"
  if clang "${CFLAGS[@]}" "$flag" "${SRCS[@]}" "${LDFLAGS[@]}" -o "$OUT"; then
    if has_reexport; then linked=yes; break; fi
    echo "== attempt $attempt linked but has no LC_REEXPORT_DYLIB:"
    otool -l "$OUT" | grep -A3 "LC_LOAD_DYLIB\|LC_REEXPORT_DYLIB" || true
  else
    echo "== attempt $attempt failed (rc=$?)"
  fi
done
if [ $linked != yes ]; then
  echo "::error::could not build libLCsys.dylib with a libSystem re-export"
  exit 1
fi

echo "== libLCsys.dylib load commands"
otool -L "$OUT"
otool -l "$OUT" | grep -A2 LC_REEXPORT_DYLIB
echo "== exported overrides (expect open/stat/statfs/exit/dlopen/lcsys_*/xs_*/xi_*):"
nm -gU "$OUT" | grep -E ' _(open|stat|lstat|exit|_exit|fork|dlopen|realpath|posix_spawn|lcsys_init|lcsys_spawn|lcsys_wait|lcsys_install_xpc_shim|lcsys_shared_event_for_token|xs_connect|xs_poll|xs_release|xs_presented|xs_surface|xs_close|xi_connect|xi_touch|xi_text|xi_key|statfs|statvfs)($|[$])' || true

echo "== copying staged tree from $STAGE_DIR"
test -d "$STAGE_DIR/Frameworks" || { echo "::error::$STAGE_DIR/Frameworks missing"; exit 1; }
test -d "$STAGE_DIR/jb" || { echo "::error::$STAGE_DIR/jb missing"; exit 1; }
cp -R "$STAGE_DIR/Frameworks/." "$FW/"
rm -rf "$APP_DIR/jb"
cp -R "$STAGE_DIR/jb" "$APP_DIR/jb"
cp "$STAGE_DIR/manifest.json" "$APP_DIR/jb/manifest.json"
[ -f "$STAGE_DIR/symlinks.json" ] && cp "$STAGE_DIR/symlinks.json" "$APP_DIR/jb/symlinks.json"

# Invariants (stage.py): jb/ holds data + @LC stubs only.
#   (a) no Mach-O content - LiveContainer would sign it as a stray dylib instead of it being
#       loaded through Frameworks/<flat>
#   (b) no name the installer picks up by NAME - *.dylib, nested *.app/, *.framework/ - those are
#       what produced the "could not sign these files" list on device (2026-09-11)
# stage.py already gates both; re-checking here catches a stale artifact or a hand-edited tree.
echo "== scanning $APP_DIR/jb (raw Mach-O content, and names the installer signs)"
python3 - "$APP_DIR/jb" <<'PY' || { echo "::error::jb/ invariant broken (see list above); stage.py must relink + stub every Mach-O and name stubs <name>.lc"; exit 1; }
import os, sys
root = sys.argv[1]
magics = {bytes.fromhex(h) for h in ("cffaedfe", "feedfacf", "cefaedfe", "feedface", "cafebabe", "bebafeca")}
raw, bait = [], []
for dp, dn, fn in os.walk(root):
    for d in dn:
        if d.endswith(".app") or d.endswith(".framework"):
            bait.append(os.path.relpath(os.path.join(dp, d), root) + "/")
    for n in fn:
        p = os.path.join(dp, n)
        if n.endswith(".dylib"):
            bait.append(os.path.relpath(p, root))
        if os.path.islink(p):
            continue
        with open(p, "rb") as f:
            if f.read(4) in magics:
                raw.append(os.path.relpath(p, root))
for r in sorted(raw):
    print("  RAW  jb/" + r)
for r in sorted(bait)[:20]:
    print("  NAME jb/" + r)
print("jb/ raw Mach-O: %d, installer-visible names: %d" % (len(raw), len(bait)))
sys.exit(1 if (raw or bait) else 0)
PY

# Darwin の libc は同じ関数を 2 つの名前で出すことがある(`_fopen` と `_fopen$DARWIN_EXTSN`)。
# 基本名しか定義していないと、もう片方で呼ぶバイナリは経路変換を素通りする。
# 2026-09-12 の実機で xkb のキーマップが読めなかったのがこれ(132 本が取りこぼし)。
echo "== auditing libc alias names (_fopen vs _fopen\$DARWIN_EXTSN)"
python3 "$HERE/../../tools/xios/audit_aliases.py" "$OUT" "$FW" || {
  echo "::error::libLCsys が別名を落としている(上の MISS 行)。lcsys.c に別名の定義を足す"
  exit 1
}

echo "Frameworks/: $(ls "$FW" | wc -l) entries"
echo "jb/ files: $(find "$APP_DIR/jb" -type f | wc -l), symlinks: $(find "$APP_DIR/jb" -type l | wc -l), .symlink markers: $(find "$APP_DIR/jb" -name '*.symlink' | wc -l)"
du -sh "$FW" "$APP_DIR/jb" "$APP_DIR"
