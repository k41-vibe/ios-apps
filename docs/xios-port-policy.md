# xiOS の構造・処理の流れ・iOS(非脱獄)にそぐわない要素と、移植の方針

2026-09-14。xiOS(MaxLeiter/jailbreak `x11/`、約 2,600 ファイル)のソースと設計文書を読んで整理した。
読んだもの: `SCOPE.md`、`docs/handoff/*.md`(xios-app / iosc-compositor / iosc-shell / session-launcher /
wayland-apps)、`docs/gnome-touch-ux.md`、`docs/iosc-desktop-env.md`、`wayland/iosc*.c` と
`linux-build/patches/xios/xios_surface.c`、`apps/Xios/Sources/XScreen.swift` / `IoscInput.c`、
`apps/iosc-shell/*.c|h`、`apps/iosc-desktop/src/ioscd.c` と `xios-session-lib.sh`、
`wayland/xios-setsid.c` / `xios-sysintd.c` / `xios-a11yd.c`、`apps/shared/XiosMetalEventBroker.m`。
要素ごとの済み/未済の照合表は `xios-requirements.md`。本書は「なぜそうなっているか」と「どう移すか」。

## 1. xiOS の構造(層で見る)

xiOS は「脱獄した iPad で Linux デスクトップを動かす」ための 6 層。上ほど Linux 寄り、下ほど iOS 寄り。

| 層 | 中身 | 場所 | 規模 |
|---|---|---|---|
| A. パッケージ | Procursus(rootless、`/var/jb` 接頭)の deb 群 + 自前パッチ 70 件(`ports/`: gtk4, mutter, mesa, wayland, foot, …)+ 独自 deb 20 件(`packages/`: xios-fhs, xios-session-stubs, x11-fonts-sf, …)。Linux コンテナで quilt + クロスビルド | `x11/ports`, `x11/packages`, `x11/linux-build` | 2,000 ファイル超 |
| B. コンポジタ | **iosc**: 自作 Wayland コンポジタ(`iosc.c` 7,000 行 + 拡張: layer-shell, foreign-toplevel, text-input, screencopy, session-lock, tablet, xwm(Xwayland)…)。合成は ANGLE(GL ES → Metal)、出力は IOSurface | `x11/wayland/iosc*.c`, `iosc_gl.c`, `xios_egl.c` | 約 15,000 行 |
| C. iOS 配管 | IOSurface の受け渡しと GPU フェンス(`xios_surface.c`, `xios_metal_sync.m`, `xios-metal-event-broker.m`)、入力ソケット(`xios_input_socket.c`)、クライアント IOSurface 取り込み(`iosc_iosurface.c`) | `linux-build/patches/xios/`, `wayland/` | 約 4,000 行 |
| D. 表示アプリ | **Xios.app**(Swift): IOSurface を Metal で画面へ、UIKit のタッチ/キーボード/回転を入力ソケットへ、セッション切替 UI、クリップボード橋、a11y、カメラ | `x11/apps/Xios` | XScreen.swift 5,000 行 |
| E. デーモン/セッション | **ioscd**(root の LaunchDaemon、ソケット命令 LAUNCH/SESSION/…)、`xios-session-lib.sh`(1,400 行の bash: 後始末・ロック・状態ファイル・バス)、`xios-setsid`、`xios-sysintd`/`hwbridged`/`sensord`(電池・輝度・音量・センサー)、`xios-a11yd`(AT-SPI)、PulseAudio(`module-xios-sink`) | `x11/apps/iosc-desktop`, `x11/wayland/xios-*.c` | ioscd 1,900 行 |
| F. シェル | **iosc-shell**: `ioscbar`(帯)/`ioscdock`(ドック)/`ioscoverview`(一覧)/`ioscbg`(壁紙)。layer-shell の純 C クライアント。アプリ起動は `sd_launch`: fork → 共有 dbus → `sh -lc <Exec>` | `x11/apps/iosc-shell` | 約 4,000 行 |

代替フレーバー(GNOME: `meta-backend-ios.c` 群で Mutter を iosc の配管に載せる / KDE: iosc の上に KWin を入れ子 /
native: `iosc-host` で 1 窓 = 1 iOS シーン)は**対象外**。こちらが使うのは B〜F の classic(iosc + iosc-shell)だけ。

## 2. 処理の流れ(3 本)

### 2.1 1 フレーム(描画)

```
GTK/GL クライアント ─commit(wl_shm or IOSurface)→ iosc
  iosc: recomposite_all(合成の予約。PACING の期限 − 1/4 周期に合わせて遅延)
     → recomposite_now: ANGLE で全窓を出力 IOSurface(3 枚回し)に合成
     → xios_notify_dirty: DIRTY + GPU フェンス(MTLSharedEvent の値)を ddx ソケットで表示アプリへ
表示アプリ: DIRTY を受け、フェンスを待ってから IOSurface を Metal テクスチャとして画面へ
     → RELEASED(面を返す)と PRESENTED(表示した ack)を返す
  iosc: PRESENTED を 1ms 刻みで待ち(100ms で諦め)、それからクライアントに frame callback → 次のフレーム
```

要点: **クライアントの次のフレームは表示アプリの ack で律速される**(present_ack_timer_cb)。ack を画面に出た
瞬間に返すと 1 周が垂直同期 2 回分 + 遅延で 45〜50ms(実測: 合成 20 回/秒)。GPU の読み取り完了で返せば 1 回分縮む(build 58)。
GL クライアントが全画面 1 窓なら「直接提示」(合成を飛ばしてクライアントの IOSurface を表示アプリへ)に入る。

### 2.2 1 タップ(入力)

```
UIKit のタッチ → Xios アプリ: 指 1 本は「ポインタ」(押下は 0.55 秒遅延: 静止長押し=右クリック、動けば起点で左押下、
   静止タップは離した時に押下+解放)、指 2 本以上は TOUCH。座標は出力の物理ピクセル
 → 入力ソケット(24 バイト記録: MOTION/BUTTON/KEY/TEXT/TOUCH/AXIS/OUTPUT/TRAITS/GESTURE/TABLET/HAPTIC)
 → iosc: surface_at で当たり判定 → wl_pointer / wl_touch / wl_keyboard をクライアントへ。窓の移動・リサイズは
   MOTION でだけ進む(interactive_update)。カーソルは表示アプリ側のオーバーレイ(CURSOR/CURSOR_IMAGE 記録、再合成ゼロ)
 ← TRAITS(文字欄が選ばれた)で表示アプリが iOS キーボードを出す。TEXT は文字、KEY は Return/Tab/BackSpace
```

### 2.3 1 起動(アプリ)

```
ドックのタップ → ioscdock: sd_launch(exec): fork → setsid → setenv(XDG_RUNTIME_DIR=共有バスの置き場 …)
   → sd_shared_session_bus: 無ければ fork+exec `dbus-daemon --session --fork`、waitpid、socket の有無で判定
   → execl(`sh -lc "<Exec>"`)(有れば直接、無ければ `dbus-run-session -- sh -lc`)
   → dash: /etc/profile(profile.d の `$(dircolors -b)` で fork)→ exec <Exec>
Home 画面のアイコン(iosc-desktop-env)→ ioscd(root): 信頼済み .desktop を引き、mobile に降格して起動、
   2 回目は wm ソケット `raise\t<app_id>` で既存の窓を前へ、`uiopen -b com.max.xios` で表示アプリを前面に
```

## 3. iOS(非脱獄・LiveContainer)にそぐわない要素

「脱獄で得ているもの」を、依存の種類ごとに分ける。**◎** は同一プロセス化で消えたもの、**△** は翻訳層で埋めたもの、
**✗** は埋められない/未着手、**—** は不要。

### 3.1 特権と別プロセス(脱獄の本丸)

| 要素 | xiOS での実現 | なぜ iOS で不可か | 移植 | 状態 |
|---|---|---|---|---|
| root の LaunchDaemon(ioscd、metal-event-broker) | launchd plist、`NSXPCConnectionPrivileged` | 非脱獄アプリはデーモンを持てない、名前付き Mach サービスも作れない | ioscd の仕事(起動・raise・状態)は Runner/procd が、ブローカーは `xpcshim.m` がプロセス内の表で肩代わり | ◎ |
| `setuid`/`drop_to_mobile`、root と mobile の使い分け | ioscd は root、アプリは mobile | 単一 uid | 全部同じ uid。`getpwuid`/`getpwnam` は偽の台帳(mobile/root) | ◎ |
| `task_for_pid` + Mach port で IOSurface 受け渡し | entitlement `task_for_pid-allow`、iOS 17 で `IOSurfaceLookup` 廃止のため | private entitlement | 同一プロセスなので `mach_task_self()`、port はそのまま有効 | ◎ |
| GPU/IOSurface の IOKit entitlement(`iokit-user-client-class`) | fakesign で付与 | 非脱獄では付かない | LiveContainer 本体の entitlement で足りている(Metal も IOSurface も動く) | ◎ |
| `com.apple.security.exception.files.absolute-path.read-write`(/var/jb) | 同上 | 付かない | `/var/jb` はアプリ内 `jb/` に経路変換(読み取り専用)、書ける場所は写し先へ | ◎ |
| fork/exec/posix_spawn/setsid(ioscd, sd_launch, xios-setsid, dbus --fork) | 本物 | **iOS は fork 不可**(LiveProcess でも同じ) | procd: プログラム = dlopen + main のスレッド。fork = スタック複製の子スレッド(exec するだけ/デーモン化ならOK)、exec = pid の付け替え | △ |
| fork の子が親の続きを走る(`$(...)`、パイプ、サブシェル) | 本物 | ヒープと fd 表の共有では再現不能 | **設計上の壁**。シェルからの fork は断る。端末は a-Shell 方式(下記) | ✗ |
| プロセスグループの後始末(pgid reaper、`kill`)、`waitpid(-1)` | 本物 | スレッドは殺せない | `kill` は記録のみ、`waitpid(pid)` は擬似 pid の台帳。強制終了と `waitpid(-1)` は未着手 | △ |
| `uiopen`、`dpkg`、SSH 運用、launchd 常駐 | あり | 無い | 起動は Runner、配布は ipa + アプリ内更新 | — |

### 3.2 ファイルシステムと生成物

| 要素 | xiOS | 移植 | 状態 |
|---|---|---|---|
| `/var/jb` 固定接頭(バイナリに焼き込み) | 実在 | 経路変換層(pathmap.c)で `open/stat/opendir/dlopen/connect/bind/mkstemp…` を横取り | ◎ |
| 書ける `/var/jb/tmp`、`/var/jb/var/run`、`/var/mobile` | 実在 | `<tmp>`、`<tmp>/run`、`Documents/home` へ | ◎ |
| deb の postinst(gschemas、loaders.cache、fc-cache、mime/icon cache、uicache) | インストール時に実行 | 初回起動で生成(gschemas、loaders.cache 済。fc-cache は書けず、mime/icon は未着手) | △ |
| GUI アプリの `.desktop` | deb に**無い**(索引で 5 件、全部端末系。ioscd が独自に生成する設計) | `home/applications` に生成、`IOSC_APPS_DIR` | ◎ |
| dyld の同一像問題(2 回目の起動で静的状態が残る) | 別プロセスなので無い | 私用コピー(署名を保つ)で別像に。**GLib/GTK は例外**(型登録が 1 回きり → 最初の像で呼び直し) | ◎ |
| 未署名コードの dlopen | fakesign | LiveContainer が dylib を署名し直す。スタブは `.lc` 拡張子で署名器を避ける | ◎ |
| JIT(gjs、WebKitGTK、Java) | 脱獄で可 | mmap(MAP_JIT) は EPERM。**JIT 依存パッケージは対象外**(pcre2 は解釈実行に落ちる) | — |

### 3.3 IPC と同期

| 要素 | xiOS | 移植 | 状態 |
|---|---|---|---|
| GPU フェンス(MTLSharedEvent を XPC ブローカーで別プロセスへ) | launchd の XPC サービス | 同一プロセスなので `xpcshim.m` の表で受け渡し(token → event) | ◎ |
| ddx/入力/clip/wm の Unix ソケット | `/var/jb/tmp/*.sock` | `$TMPDIR/x/*`(sun_path 104 バイト制限のため短名) | ◎ |
| dbus セッションバス(共有 1 本、`--fork`) | 本物の fork | 複製子 + exec 引き継ぎで動く。`waitpid` は付け替え後の本体を待ち直す | ◎ |
| PulseAudio(`module-xios-sink`、音量の双方向) | あり | 未着手 | ✗ |
| クリップボード橋(clip ソケット ⇄ UIPasteboard) | Xios.app | 未着手 | ✗ |
| AT-SPI / VoiceOver(xios-a11yd) | あり | `GTK_A11Y=none`。対象外 | — |
| センサー・輝度・音量(hwbridged/sensord/sysintd) | ioscd が起動 | 未着手(帯の電池は libMobileGestalt を直接読んで動く) | △ |

### 3.4 端末(PTY)と入力の残り

| 要素 | xiOS | 移植 | 状態 |
|---|---|---|---|
| PTY(`posix_openpt`/`openpty`/`forkpty`/termios) | 本物 | iOS が拒む(EPERM)。socketpair + 行規律の再現層が要る | ✗ |
| ゲストごとの fd 0/1/2(パイプ・リダイレクト・PTY の従側) | 本物 | プロセスで 1 組。スレッド別の fd 表が要る(端末と同じ土台) | ✗ |
| シグナル(SIGCHLD/SIGWINCH/SIGHUP/SIGTERM) | 本物 | 未着手。スレッドへの擬似シグナルとして通知する形 | ✗ |
| AXIS(2 本指スクロール)、GESTURE、HAPTIC、ハードキーボード(GCKeyboard) | Xios.app | 未着手 | ✗ |
| 論理画面の大きさ(シェルの `ui` 下限 0.6 = 論理幅 864) | iPad 1440x1080 | iPhone 縦は 0.45 倍。**横向き**で等倍。縦の作り直しはシェル(UI)の改変になるのでしない | ◎ 横 |

## 4. 移植の方針(原則)

1. **UI は変えない。窓口を翻訳する。** iosc・シェル・GTK アプリは deb のバイナリのまま。合わないものは
   「Linux が OS に要求しているもの」として翻訳層(入力・表示・処理系)で答える。deb に欠けているもの
   (postinst の生成物、`.desktop`)は生成して置く。
2. **プロセス = スレッド。** dlopen + main。fork は「すぐ exec」「デーモン化」の 2 型だけ複製で再現し、
   「続きを走る」型は断る(シェル)。exec は pid の付け替え。waitpid は付け替え後の本体を待つ。
   GLib/GTK は 1 プログラム 1 実体(型登録が 1 回きり)、2 回目は最初の像で呼び直し、動いていれば `raise`。
3. **特権 IPC は関数呼び出しに落とす。** XPC、Mach port、task_for_pid は同一プロセスなのでプロセス内の表で済む。
   ソケットはそのまま使う(本家と同じ記録形式)。
4. **パスは読み取り専用の `jb/` + 書ける写し先。** `/var/jb/tmp`、`/var/jb/var/run`、`~` は必ず写す。
   雛形を書き換えて返す関数(`mkstemp` 系)は生成名を写し戻す。
5. **入力は本家 Xios アプリと同じ作法。** 指 1 本 = ポインタ(押下遅延・長押し右クリック)、2 本以上 = TOUCH、
   OUTPUT で回転、TRAITS で OSK、PACING を毎フレーム(250ms で失効)、PRESENTED は GPU 読み取り完了で早く返す。
6. **署名は LiveContainer に任せ、JIT は使わない。** 私用コピーも署名を保つ。JIT 前提のパッケージは閉包に入れない。
7. **裏取りしてから変える。** 変更前に xiOS のソースと文書で「本家はどうしているか」を読む。実機の判断は
   クラッシュレポート(.ips)と紙飛行機ログ。推測で削らない。
8. **対象外を明言する。** GNOME/KDE/native フレーバー、Xwayland、a11y、カメラ。音とクリップボードは後段。

## 5. これからの順番

1. 合成速度: ack の早期化(build 58)の効果を計測 → 足りなければ「DIRTY 到着で即描く」(垂直同期を待たない読み取り)
2. 操作の仕上げ: 長押しの閾値、AXIS スクロール、ハードキーボード、クリップボード
3. 後片付け: ゲストの強制終了(スレッド中断 + fd 掃除)、終了した像の解放
4. 生成物の残り: fc-cache(cachedir と `link()`)、mime/icon cache
5. 端末とシェル: PTY 再現層 + スレッド別 fd 表 + fork なしのパイプ/置換(a-Shell 方式)。土台は 3 と共通
6. 音・センサー(後段)
