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
mkdir -p "$APP_DIR/Watch"
cp -R "$watch_app" "$APP_DIR/Watch/"
find "$APP_DIR/Watch" -maxdepth 2
