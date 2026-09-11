#!/bin/bash
# Called by the workflow after xcodebuild, before packaging.
# $APP_DIR = path to the built LCProbe.app
# Generates 800 tiny dylibs into Frameworks/ for the dlopen-count probe.
set -euo pipefail
FW="$APP_DIR/Frameworks"
mkdir -p "$FW"
SDK=$(xcrun --sdk iphoneos --show-sdk-path)
WORK=$(mktemp -d)
N=800
echo "generating $N probe dylibs..."
seq 1 $N | xargs -P 8 -I{} sh -c '
  i={}
  src="'"$WORK"'/p$i.c"
  printf "int probe_%d(void){return %d;}\n" "$i" "$i" > "$src"
  clang -target arm64-apple-ios16.0 -isysroot "'"$SDK"'" -dynamiclib -Os \
    -install_name "@rpath/libprobe$i.dylib" -o "'"$FW"'/libprobe$i.dylib" "$src"
'
ls "$FW" | wc -l
du -sh "$FW"
