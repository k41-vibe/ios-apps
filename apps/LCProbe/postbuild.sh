#!/bin/bash
# Called by the workflow after xcodebuild, before packaging.
# $APP_DIR = path to the built LCProbe.app
# Generates N tiny dylibs into Frameworks/ for the dlopen-count probe (N は下で決める)。
set -euo pipefail
FW="$APP_DIR/Frameworks"
mkdir -p "$FW"
SDK=$(xcrun --sdk iphoneos --show-sdk-path)
WORK=$(mktemp -d)
# 本数は LCPROBE_DYLIBS で変えられる。既定 100 は実機で LiveContainer の署名工程が
# 耐えると確認できた本数(800 本は署名中にクラッシュした。tools/xios/G0-results.md)
N=${LCPROBE_DYLIBS:-100}
cat > "$WORK/gen.sh" <<EOF
#!/bin/sh
i=\$1
src="$WORK/p\$i.c"
printf 'int probe_%d(void){return %d;}\n' "\$i" "\$i" > "\$src"
clang -target arm64-apple-ios16.0 -isysroot "$SDK" -dynamiclib -Os \\
  -install_name "@rpath/libprobe\$i.dylib" -o "$FW/libprobe\$i.dylib" "\$src"
EOF
chmod +x "$WORK/gen.sh"
echo "generating $N probe dylibs..."
seq 1 $N | xargs -P 8 -n 1 "$WORK/gen.sh"
echo "dylibs: $(ls "$FW" | wc -l)"
du -sh "$FW"
