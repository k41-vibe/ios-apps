# xiOS を iOS(非脱獄・LiveContainer)で動かすために必要な要素 — 照合表(2026-09-13)

xiOS のソース(MaxLeiter/jailbreak `x11/`)と設計文書を読み、**脱獄前提で得ているもの**を洗い出し、
こちらの置き換えと状態を突き合わせた。読んだもの: `docs/handoff/xios-app.md`、`session-launcher.md`、
`iosc-shell.md`、`iosc-desktop-env.md`、`iosc-shared-glue.md`、`gnome-touch-ux.md`、
`apps/iosc-desktop/xios-session-lib.sh`、`apps/Xios/Sources/XScreen.swift` / `IoscInput.c`、
`wayland/iosc*.c`、`apps/iosc-shell/*.c|h`。

構造・処理の流れ・移植方針の本文は `xios-port-policy.md`。

方針: **OS の見た目と振る舞い(iosc、シェル、GTK アプリ)は deb のまま**。こちらが作るのは
「入力」「表示」「処理系(OS の窓口)」の翻訳層と、パッケージに欠けている生成物だけ。

凡例: ◎ 済み(実機確認) ○ 済み(未確認) △ 一部 ✗ 未着手 — 不要

## A. 表示(Xios アプリの仕事 → ScreenView / xsurface.c)

| xiOS が要るもの | 脱獄での実現 | こちら | 状態 |
|---|---|---|---|
| コンポジタの出力 IOSurface を表示アプリへ渡す | mach port + `task_for_pid`(root) | 同一プロセスなので `mach_task_self()` | ◎ |
| GPU フェンス(MTLSharedEvent の共有) | launchd の XPC `com.max.xios.metal-event-broker` | `xpcshim.m` で NSXPCConnection を横取り、プロセス内の表で受け渡し | ◎ |
| 3 枚の出力面の DIRTY / RELEASED / PRESENTED の往復 | ddx ソケット | 同じ ddx ソケットをプロセス内で | ◎ 60fps |
| 表示の時計(PACING) | 毎フレーム送る、250ms で失効 | 毎フレーム送る(build 44) | ◎ |
| 回転(OUTPUT で論理サイズ変更 → 出力作り直し → 繋ぎ直し) | 同上 | `xi_output` + 切断時の再接続 | ◎ |
| 論理サイズ | 1440x1080(iPad) | 864 幅固定(シェルの ui 下限 0.6)。横向きで等倍 | ◎ 縦は 0.45 倍 |
| MetalFX 拡大 | 任意 | — | — |

## B. 入力(Xios アプリ → xinput.c / ScreenView)

入力ソケットの 24 バイト記録。本家アプリが送る種類と、こちらの対応:

| 記録 | 本家 | こちら | 状態 |
|---|---|---|---|
| MOTION / BUTTON(ポインタ) | 指 1 本は **ポインタ扱い**(押下遅延・長押し右クリック・静止タップでクリック) | 同じ方式(build 51) | ○ |
| TOUCH | 指 2 本以上のみ | 同じ | ○ |
| KEY / TEXT(iOS キーボード) | TEXT で文字、KEY で Return/Tab/BackSpace | 同じ | ◎ |
| TRAITS(欄が選ばれた → OSK 自動表示) | 受信して OSK 制御 | 同じ | ◎ |
| OUTPUT(回転) | 送る | 送る | ◎ |
| AXIS(2 本指スクロール、トラックパッド) | 送る | ✗(GTK アプリ内の指スクロールが無い) | ✗ |
| GESTURE(ピンチ等) | 送る | ✗ | ✗ |
| TABLET(Pencil) | 送る | — | — |
| HAPTIC(触覚) | 受信 | — | — |
| ハードウェアキーボード(GCKeyboard、修飾キー・矢印・F キー) | あり | ✗(iOS ソフトキーボードのみ) | ✗ |
| クリップボード(clip ソケット ⇄ UIPasteboard) | あり | ✗ | ✗ |
| xkb の Compose ファイル(locale "UTF-8") | 警告のみ | 警告のみ | — |

## C. 処理系(ioscd / launchd / カーネル → procd / lcsys / lcfork)

| 要素 | 脱獄 | こちら | 状態 |
|---|---|---|---|
| プロセスの起動(fork+exec、posix_spawn) | 本物 | dylib を dlopen してスレッドで main(procd) | ◎ |
| fork の子(exec するだけ、デーモン化) | 本物 | スタック複製の子スレッド(lcfork) | ◎ |
| fork の子がシェルの続きを走る(`$(...)`・パイプ・サブシェル) | 本物 | **不可能**(ヒープと fd 表の共有)。シェルの fork は断る | ✗ 設計上の壁 |
| exec(pid を保ったまま別プログラムに) | 本物 | pid の付け替え(exec handover)+ waitpid の待ち直し | ◎ |
| `sh -c "<Exec>"`(ドックの起動) | dash | 単純な行は dash を通さず直接起動、複雑な行は `-l` を外す | ◎ |
| waitpid / wait4 / kill | 本物 | 擬似 pid の台帳(kill は記録のみ) | ○ |
| 疑似端末(PTY: openpty / forkpty / termios) | 本物 | ✗(iOS が `posix_openpt` を拒む)。socketpair で再現する層が要る | ✗ |
| ゲストごとの fd 0/1/2(パイプ・リダイレクト) | 本物 | ✗(プロセスで 1 組)。スレッド別の fd 表が要る | ✗ |
| シグナル(SIGCHLD / SIGWINCH / SIGHUP) | 本物 | ✗ | ✗ |
| 同じ GTK アプリの 2 本目 | 別プロセスなので可。ioscd は `raise` で既存を前へ | 2 本目は起こさず `raise` を送る(GType が 1 つ) | ○ |
| root と mobile の使い分け(ioscd は root、アプリは mobile) | launchd | 全部同一ユーザー。`getpwuid` は偽の台帳 | ◎ |
| 動的ロードの署名 | 脱獄で任意 | LiveContainer が dylib を署名し直す。私用コピーも署名を保つ | ◎ |
| メモリ | 任意 | jetsam 上限 4GB(G0)。終了した dylib は解放していない(一覧の開閉で +23MB ずつ) | △ |

## D. ファイルシステムと生成物(deb の postinst → 初回起動の生成)

| 要素 | 脱獄 | こちら | 状態 |
|---|---|---|---|
| `/var/jb` プレフィックス(rootless) | 実在 | 経路変換で app 内 `jb/` へ(読み取り専用) | ◎ |
| 書ける `/var/jb/tmp`、`/var/jb/var/run`、`~` | 実在 | `<tmp>`、`<tmp>/run`、`Documents/home` へ写す | ◎ |
| `glib-compile-schemas`(libgtk-4 の postinst) | 実行済み | 初回起動で実行 | ◎ |
| gdk-pixbuf `loaders.cache` | 実行済み | 生成(SVG ローダー) | ◎ |
| `fc-cache`(fontconfig) | 実行済み | 実行するが書けていない(cachedir 未作成、build 46 で作成) | △ |
| `.desktop`(一覧・ドックの札) | GUI アプリ分が **deb に無い**(索引で 5 件) | `home/applications` に生成、`IOSC_APPS_DIR` で指す | ◎ |
| `update-mime-database` / `gtk-update-icon-cache` / `update-desktop-database` | 実行済み | ✗(ファイル選択ダイアログ等で要る可能性) | ✗ |
| `uicache`(Home 画面) | 要る | — | — |

## E. セッションの部品(xios-session-lib.sh の `app` 節 / run-shell.sh)

| 部品 | 役割 | こちら | 状態 |
|---|---|---|---|
| iosc + ioscbg + ioscbar + ioscdock(+ ioscoverview) | デスクトップ | 同じ順で起動 | ◎ |
| 共有セッションバス(`dbus-daemon --session --fork`) | GTK アプリと AT-SPI | 同じ(waitpid 修正後) | ○ |
| 環境変数(`GDK_BACKEND=wayland`、`GSK_RENDERER`、`GSETTINGS_BACKEND=memory`、`LC_CTYPE=UTF-8`、`GTK_A11Y=none`) | 同じ | 同じ(GSK は profile.d どおり cairo) | ◎ |
| a11y(`xios-a11yd`、AT-SPI バス、VoiceOver 連携) | 任意 | ✗(GTK_A11Y=none で無効) | — |
| native helpers(`xios-hwbridged` / `xios-sensord` / `xios-sysintd`: 電池・輝度・音量・センサー) | ioscd が起動 | ✗(バーの電池は libMobileGestalt を直接読んで動いている) | △ |
| 音(PulseAudio `xios-pulse`) | あり | ✗ | ✗ |
| クリップボード橋(iosc clip ソケット ⇄ iOS) | あり | ✗ | ✗ |
| セッションの切替・後始末・状態ファイル(ioscd、lock、status.json) | あり | Runner が起動順と生死だけ管理 | △ |
| Mutter/GNOME、KDE(入れ子コンポジタ、ios-inputd) | あり | 対象外(G4 以降) | — |

## いま効いている「壁」と、次に取るべき順

1. **GUI アプリ**: 出た(build 49)。残りは入力の質(指 = ポインタ方式、build 51)、スクロール(AXIS)、クリップボード
2. **端末とシェル**: PTY 層 + スレッド別 fd 表 + fork なしのシェル結合(パイプ・置換)。これは翻訳層の仕事で、
   a-Shell / ios_system と同じ道。**本物の fork は非脱獄 iOS では手に入らない**(LiveProcess も 1 プロセス
   くれるだけで fork 不可)
3. **生成物の残り**: fc-cache、mime / icon cache
4. **音・クリップボード・センサー**: 後段
