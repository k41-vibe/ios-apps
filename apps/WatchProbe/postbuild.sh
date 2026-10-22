# 時計アプリを watchos SDK で建てて iOS アプリの Watch/ に入れる。APP_DIR は build.yml が渡す
set -euo pipefail
xcodebuild \
  -project WatchProbe.xcodeproj \
  -scheme WatchProbeWatch \
  -configuration Release \
  -sdk watchos \
  -destination "generic/platform=watchOS" \
  -derivedDataPath build-watch \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY="" \
  2>&1 | tee build-watch.log | (grep -E "error:|\*\* BUILD" || true)
watch_app="build-watch/Build/Products/Release-watchos/WatchProbeWatch.app"
test -x "$watch_app/WatchProbeWatch" || { echo "::error::watch executable missing"; exit 1; }
lipo -info "$watch_app/WatchProbeWatch"
# dlopen 試験用の dylib。時計アプリと同じ 2 アーキテクチャで作り、リンクはせず Frameworks/ に置くだけにする
SDK=$(xcrun --sdk watchos --show-sdk-path)
printf 'int probe_1(void){return 1;}\n' > build-watch/probe.c
for arch in arm64 arm64_32; do
  clang -target $arch-apple-watchos10.0 -isysroot "$SDK" -dynamiclib -Os \
    -install_name "@rpath/libprobe1.dylib" -o "build-watch/probe-$arch.dylib" build-watch/probe.c
done
mkdir -p "$watch_app/Frameworks"
lipo -create build-watch/probe-arm64.dylib build-watch/probe-arm64_32.dylib -output "$watch_app/Frameworks/libprobe1.dylib"
lipo -info "$watch_app/Frameworks/libprobe1.dylib"
mkdir -p "$APP_DIR/Watch"
cp -R "$watch_app" "$APP_DIR/Watch/"
find "$APP_DIR/Watch" -maxdepth 2
