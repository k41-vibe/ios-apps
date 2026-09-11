# iosc をアプリ内スレッドで動かすための設計メモ(2026-09-11 調査)

出典: https://github.com/MaxLeiter/jailbreak/tree/main/x11 (MIT)。行番号は調査時点。

## 結論
iosc 本体(`wayland/iosc.c`)には fork/exec/daemon/setsid/chdir/setuid/signal() が無い。exit は main からの return のみ。
置き換えが必要なのは「別プロセスへ絵と入力を渡す配管」= `xios_surface.c` / `xios_metal_sync.m` / `xios_input_socket.c` に集中。

## 1. エントリ
- `int main(int argc, char **argv)` (iosc.c:6857)。順: options → `xios_surface_create`(出力 IOSurface, classic=3枚/native=1枚)→ `iosc_gl_init`
  → `xios_server_start`(ホストへの配管)→ `wl_display_create/add_socket/init_shm` → globals 登録 → `iosc_input_init` → 入力/クリップボード/WM ソケット → `wl_display_run`。
- フラグ: `-g WxH -logical WxH -dpi N -scale N -s <wayland socket名> -ddx-sock -json -input-sock -clipboard-sock -wm-sock -native -classic`。
  既定パスは `/var/jb/tmp/{iosc-ddx.sock,xios.json,iosc-input.sock,iosc-clipboard.sock,iosc-wm.sock}`。既定 2880x2160, dpi96, scale2。
- 環境変数: `XDG_RUNTIME_DIR`(Wayland ソケット置き場、keymap 一時ファイル)、`IOSC_NATIVE`、`IOSC_DEBUG` ほか。
- グローバル状態は 1 プロセス 1 インスタンス前提(static ~492 個)。スレッド起動は 1 回だけ。

## 2. 出力
- IOSurface: `xios_surface.c:276 make_surface()`: BGRA(0x42475241)、BytesPerRow は `IOSurfaceAlignProperty`。
- 描画: ANGLE-Metal GLES2。出力 IOSurface を `eglCreatePbufferFromClientBuffer(EGL_IOSURFACE_ANGLE)` で FBO に。pixman は使わない。
- フレーム: `recomposite_now`(iosc.c:2280-2410)→ `xios_output_acquire` → 描画 → `iosc_gl_end`(MTLSharedEvent を NSXPC ブローカー経由で共有)
  → `xios_notify_surface_with_fence` が 32B の `XIOS_MSG_DIRTY` をホストのソケットへ。
- ホスト受け渡しは `task_for_pid` + `mach_port_extract_right` + `IOSurfaceCreateMachPort`(root 必須)。**同一プロセスなら不要**。

### 置き換え最小集合(iosc.c は無改造)
- `xios_server_start` → コールバック登録 `xios_server_set_host(cb)`
- `accept_loop/handle_client/extract_reply_port/deliver_surface_port/write_json/chown` → 削除
- `notify_dirty_internal` → `host->frame_ready(IOSurfaceRef, surface_id, seq, fence_event, value)`
- 解放: `xios_host_released(surface_id, seq)` を `xios_output_queue` に流す(`XIOS_MSG_RELEASED` の代替)
- `xios_metal_sync.m` / `XiosMetalEventBroker.m`: NSXPC を通さず `id<MTLSharedEvent>` をプロセス内テーブルで受け渡し
- 3 枚スワップチェーンはそのまま

## 3. 入力
- レコード: `apps/shared/XiosProtocol.h` `xios_msg` = 32 バイト LE `{magic 'XMS1', type, window_id/state, length, a/x, b/y, c/code, d/mods}`。最初に HELLO。
- 種類: MOTION 0x100 {x,y} / BUTTON 0x101 {x,y,code=1|2|3,state} / KEY 0x102 {code=X keysym,state,mods bit0 shift 1 ctrl 2 alt}
  / TEXT 0x103 {length}+payload / TOUCH 0x105 {x,y,code=slot0-9,state=0 up 1 down 2 motion 3 cancel} / AXIS 0x108 / OUTPUT 0x109(回転)。
  サーバー→ホスト: TRAITS 0x104, HAPTIC 0x10a。座標は出力 IOSurface のピクセル。
- 受け口: `xios_input_socket.c:66`(AF_UNIX)→ `iosc.c:6256 input_socket_start` → `iosc_input_record()`。
- ホスト側実装の手本: `apps/Xios/Sources/IoscInput.c`, `XScreen.swift:2744 touchesBegan`(アスペクトフィット逆変換→`iosc_input_touch`)。
- 最小変更: 私設 AF_UNIX パスにそのまま bind し、ホストスレッドから connect して 32B レコードを書く(コード変更ほぼゼロ)。

## 4. クライアント側(GPU)
- `libiosc_egl.dylib`(ANGLE の `libEGL.dylib` として設置、本物は `libEGL.angle.dylib`)が eglGetDisplay/CreateWindowSurface/MakeCurrent/SwapBuffers を横取り。
  窓ごとに IOSurface 3 枚 → `iosc_iosurface.create_buffer(mach_port_name, w, h, format)` で mach ポート名を送る。
- サーバー側 `xios_import_client_iosurface(pid, port)`(xios_surface.c:1450)が `task_for_pid` する。
  **同一プロセスなら `IOSurfaceLookupFromMachPort(name)` を直接呼ぶか、シム側で IOSurfaceRef をプロセス内レジストリに登録して整数キーで渡す**。変更はこの 1 関数のみ。

## 5. iosc-shell
- 純 C の layer-shell クライアント群: `ioscbar/ioscdock`(iosc-shell.c)、`ioscoverview.c`、`ioscbg.c`。
- 依存: wayland-client cairo pangocairo gdk-pixbuf-2.0(+CoreGraphics/ImageIO)。プロトコル: wlr-layer-shell v4, foreign-toplevel v3, screencopy v1。
- アプリ起動は `shell-draw.h:388 sd_launch` の `fork()+setsid()+execl(dbus-run-session|sh -lc <Exec>)`、`dbus-daemon --fork`(:87)。→ procd へ横取りする対象。
- 設定: `.desktop` 走査(`IOSC_APPS_DIR`)、`/var/mobile/Library/Preferences/com.max.iosc-*.conf`、`IOSC_WALLPAPER` ほか。

## 6. ビルド(`wayland/build-iosc.sh`)
- CFLAGS `-arch arm64 -isysroot iPhoneOS.sdk -miphoneos-version-min=16.0 -O2 -fblocks`。
- iosc ソース: iosc.c + iosc_{text_input,kde_output,pointer_ext,tablet,activation,screencopy,idle,wm_socket,foreign_toplevel,viewport,session_lock,options,render_plan,util,iosurface,gl,input}.c
  + iosc-clipboard-bridge.c + xios_egl.c + xios_metal_sync.m + XiosMetalEventBroker.m + iosc_status.c + xios_canvas.c + xios_input_socket.c + xios_surface.c + wayland-scanner 生成 ~30 本。
- リンク: `-lwayland-server -lxkbcommon -lEGL -lGLESv2 -framework IOSurface CoreFoundation Foundation Metal`。
- iosc は **dylib として自前ビルドする**(deb の実行ファイルを使わない): main を `iosc_main` に改名しスレッドで呼ぶため。

## 7. 固定パス(pathshim または改修対象)
- `/var/jb/tmp/*`(iosc_options.c 既定)、`/var/jb/tmp/xios-active-session`(iosc.c:1937、削除)、keymap fallback(:6273)、
  `XKB_CONFIG_ROOT=/var/jb/usr/share/X11/xkb`(iosc_input.c:49)、`iosc_status.c runtime_tmp()`、シム `/var/jb/lib/angle/libEGL*.dylib`。
- `getpwnam("mobile")+chown/chmod`(xios_input_socket.c:47, xios_surface.c:1023, clipboard:398)→ 削除。
- `IOSC_ENABLE_XWM` は無効でビルド(Xwayland の posix_spawn を避ける)。
- アプリ全体で SIGPIPE を無視する(libwayland の write は MSG_NOSIGNAL 無し)。
