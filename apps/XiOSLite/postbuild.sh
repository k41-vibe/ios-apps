#!/bin/bash
# Called by the workflow after xcodebuild, before packaging.
#   $APP_DIR   = path to the built XiOSLite.app
#   $STAGE_DIR = output of tools/xios/stage.py (downloaded artifact "xios-stage")
# 1. builds Frameworks/libLCsys.dylib from native/*.c (re-exports libSystem)
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
SRCS=("$HERE"/native/*.c)

# The dylib must RE-EXPORT libSystem (LC_REEXPORT_DYLIB), otherwise guests bound to
# @rpath/libLCsys.dylib would miss every libc symbol. Two spellings of the flag are
# tried; a link that "succeeds" without the reexport counts as a failure.
has_reexport() { otool -l "$OUT" 2>/dev/null | grep -q LC_REEXPORT_DYLIB; }
linked=no
for attempt in 1 2; do
  if [ $attempt = 1 ]; then flag="-Wl,-reexport-lSystem"; else flag="-Wl,-reexport_library,$SDK/usr/lib/libSystem.B.tbd"; fi
  echo "== building libLCsys.dylib (attempt $attempt: $flag)"
  echo "clang ${CFLAGS[*]} $flag ${SRCS[*]} -o $OUT"
  rm -f "$OUT"
  if clang "${CFLAGS[@]}" "$flag" "${SRCS[@]}" -o "$OUT"; then
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
echo "== exported overrides (expect open/stat/exit/dlopen/lcsys_*):"
nm -gU "$OUT" | grep -E ' _(open|stat|lstat|exit|_exit|fork|dlopen|realpath|posix_spawn|lcsys_init|lcsys_spawn|lcsys_wait)($|[$])' || true

echo "== copying staged tree from $STAGE_DIR"
test -d "$STAGE_DIR/Frameworks" || { echo "::error::$STAGE_DIR/Frameworks missing"; exit 1; }
test -d "$STAGE_DIR/jb" || { echo "::error::$STAGE_DIR/jb missing"; exit 1; }
cp -R "$STAGE_DIR/Frameworks/." "$FW/"
rm -rf "$APP_DIR/jb"
cp -R "$STAGE_DIR/jb" "$APP_DIR/jb"
cp "$STAGE_DIR/manifest.json" "$APP_DIR/jb/manifest.json"
[ -f "$STAGE_DIR/symlinks.json" ] && cp "$STAGE_DIR/symlinks.json" "$APP_DIR/jb/symlinks.json"

# Invariant (stage.py): jb/ holds data + @LC stubs only. A raw Mach-O here would be signed by
# LiveContainer as a stray dylib instead of being loaded via Frameworks/<flat>; fail the build.
echo "== scanning $APP_DIR/jb for raw Mach-O files"
python3 - "$APP_DIR/jb" <<'PY' || { echo "::error::raw Mach-O file(s) under jb/ (see list above); stage.py must relink + stub every Mach-O"; exit 1; }
import os, sys
root = sys.argv[1]
magics = {bytes.fromhex(h) for h in ("cffaedfe", "feedfacf", "cefaedfe", "feedface", "cafebabe", "bebafeca")}
raw = []
for dp, _dn, fn in os.walk(root):
    for n in fn:
        p = os.path.join(dp, n)
        if os.path.islink(p):
            continue
        with open(p, "rb") as f:
            if f.read(4) in magics:
                raw.append(os.path.relpath(p, root))
for r in sorted(raw):
    print("  RAW jb/" + r)
print("jb/ raw Mach-O files: %d" % len(raw))
sys.exit(1 if raw else 0)
PY

echo "Frameworks/: $(ls "$FW" | wc -l) entries"
echo "jb/ files: $(find "$APP_DIR/jb" -type f | wc -l), symlinks: $(find "$APP_DIR/jb" -type l | wc -l), .symlink markers: $(find "$APP_DIR/jb" -name '*.symlink' | wc -l)"
du -sh "$FW" "$APP_DIR/jb" "$APP_DIR"
