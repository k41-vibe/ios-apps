# Changelog — XiOSDesktop

脱獄なしの iPhone で Linux デスクトップのユーザー空間をネイティブ速度で動かすアプリ。
実験用コンソールの [XiOSLite](../XiOSLite/CHANGELOG.md) から画面を出す段で分岐させた。
書式は [Keep a Changelog](https://keepachangelog.com/ja/1.1.0/)、版番号は [Semantic Versioning](https://semver.org/lang/ja/)。
リリース手順は `docs/VERSIONING.md`。実機の計測値は `tools/xios/G0-results.md`、
コンポジタとの通信仕様は `tools/xios/iosc-host-protocol.md`。

## [Unreleased]

`docs/review-2026-09-13.md`(xiOS のソースと設計文書との照合)に基づく一括の見直し。

### Added
- **アプリ内アップデート**(`Sources/Updater.swift`)。起動時に PC の配布サーバー
  (`tools/serve-ipa.py` の `/XiOSDesktop.json`)を見て、新しい build があれば 1 タップで
  ipa を取り、自分の .app を入れ替え、LiveContainer の台帳 `LCAppInfo.plist` の
  `LCPatchRevision` を 0 に戻す。次に LiveContainer から開くと加工と署名が自動で走る
  (LiveContainer 3.7.2 `LCAppModel.runApp` → `patchExecAndSignIfNeed`)。zip は自前で読む
  (中央ディレクトリ + Compression の生 deflate)

- 診断: main から戻ったゲストも `pid N: main returned` を記録する(ioscoverview は return 0 で
  終わるので終了が見えなかった)。「状態」ボタンで iosc-shell 部品の自前ログ
  (`$XDG_RUNTIME_DIR/ioscoverview.log` 等)の末尾をこちらのログへ写す

- **横向きに対応**。xiOS のシェルは論理幅 864 未満に組めない(iosc-shell.c pl_ui の下限 0.6)ので、
  縦 393pt では全体が 0.45 倍でドックのボタンが 18pt しかなく、タップが外れていた
  (実機 2026-09-13: `hit_at … -> -1`)。横 852pt なら等倍近く。iosc は起動時の向きで論理サイズを
  決め、回転したら XIOS_IN_OUTPUT で作り直させて ddx に繋ぎ直す(xios_surface.c の世代管理どおり)

- **ドックからのアプリ起動が dbus で止まる**(実機 2026-09-13 build 45)。(1) `waitpid` が exec の
  肩代わりで pid が付け替わる前の「抜け殻」を掴んで早戻りし、iosc-shell が共有バスの socket を
  見に行った時点でまだ無かった → 同じ pid を引き継いだ本体を待ち直す(procd.c collect_pid)。
  (2) 落ち先の dbus-run-session が既定の `/var/jb/var/run/dbus` に bind して読み取り専用で失敗
  → `/var/jb/var/run` を `<tmp>/run` に写す(pathmap.c)
- fontconfig のキャッシュ置き場 `home/cache/fontconfig` を先に作る(無いと fc-cache が諦める)
- 更新の既定サーバーを LAN 優先に(Tailscale の平文 http は ATS が拒む)

- **一覧とドックにテキストエディタが出ない**(実機 2026-09-13 build 46)。xiOS の deb には GUI アプリの
  .desktop がほぼ無く(リポジトリ索引で 5 件、全部端末系)、並んでいたのは foot 系 3 件だけ。
  foot は iOS の PTY 禁止で必ず落ちるので「タップしても何も出ない」に見えていた。
  `home/applications` に org.gnome.TextEditor / es2gears の .desktop を生成し `IOSC_APPS_DIR` で指す

### Fixed
- **起動直後に落ちる**(開発ビルド 0.0.20260913、クラッシュレポート `LiveContainer-2026-09-13-020018.ips`)。
  初回起動で生成する gdk-pixbuf の `loaders.cache` に `""` の行を置いていたが、
  `gdk_pixbuf_io_init_modules` のパーサではモジュールの終わりは空行。`""` はパターン行として
  読まれて失敗し、上流のエラー経路(`g_free(pattern)`、配列の途中)で libmalloc が abort。
  ioscbar が壁紙アイコンを読んだ瞬間にプロセスごと死んでいた。書式を直し、生成物は毎回書き直す

- **dbus が立たない**(`User "???" unknown`)。dbus は `getpwuid_r` ではなく libiosexec の
  `ie_getpwuid_r`(OpenBSD getpwent.c、`/var/jb/etc/pwd.db` を `dbopen`)を呼んでいて、
  こちらの `getpwuid_r` 横取りは届いていなかった(ipa 345 本中 295 本が libiosexec 経由)。
  DB を作る postinst(pwd_mkdb)は走らないので、`dbopen` を横取りして mobile / root の
  2 件を返す偽 DB にした。`getgrouplist` は主グループ 1 件で答える。stage.py が
  `jb/etc/{group,shells,passwd}` を置く
- **AF_UNIX の経路変換**。`bind` / `connect`(+`$NOCANCEL`)を横取りして sun_path を変換する。
  dbus-daemon の `unix:tmpdir=/var/jb/tmp` と共有バス `/var/jb/tmp/iosc-shell-bus/session-bus`
  がそのまま bind されていた。変換後が sun_path の 104 バイトを超えるとき(実機の $TMPDIR は
  88 文字)は `pthread_fchdir_np` でそのスレッドだけ親ディレクトリに移って相対名で開く

- **ドックのアイコンをタップすると落ちる**(クラッシュレポート `LiveContainer-2026-09-13-142538.ips`)。
  ドックは Exec を `sh -lc` で起こし、-l が読む /etc/profile.d/coreutils.sh の `$(dircolors -b)` で
  dash が fork する。子は exec せず dash の続きを走るので、スタックを複製しただけの子と親が
  同じ大域(メモリスタック、ジョブ表)を触り、親が SIGSEGV。対処は 2 段:
  (1) `sh [-l] -c CMD` の CMD が語と引用符だけの単純な行なら dash を通さず直接 spawn する
  (-l の効きは GSK_RENDERER=cairo で肩代わり)。複雑な行は -l だけ外して dash に渡す。
  (2) シェル(sh/dash/bash)からの fork は -1 ENOMEM で断る。"Cannot fork" で止まるだけで
  デスクトップは生き残る。**シェルスクリプトの `$(...)` とパイプはこの構成では動かない**
  (子がシェルの続きを走る fork は、本物のプロセスが無いと再現できない)

- **画面が重い**(実機 2026-09-13)。`IOSC_DEBUG=1` は iosc の「毎フレーム GPU から画素を読み戻して
  検証する」モードだった(wayland_iosc.c:1924、同期の GPU→CPU 読み戻し)。切った。
  PACING も 60 フレームに 1 回 + 半周期では 250 ms で古くなり(XIOS_VBLANK_STALE_MS)
  毎秒 event-loop に落ちていたので、毎フレーム「次の垂直同期まで 1 周期」で送る

### Removed
- **`ios-inputd`**。iosc の classic セッションでは要らない: `iosc.c in_dispatch_text()` は
  代理が居なければ自分の text-input-v3 で今選ばれている窓に文字を入れる
  (`improxy=0 (local fallback)` はその「いつもの道」)。ios-inputd は KWin などを入れ子に
  したときだけの橋渡し。文字も指も iosc の入力ソケットに直結に戻した
- 自前の `dbus-daemon` ボタン。バスはシェルが `<jbroot>/tmp/iosc-shell-bus` に 1 本立てる設計
- `XDG_RUNTIME_DIR` 差し替え対策のシンボリックリンク。`xios-session-lib.sh:1236` と同じく
  **`WAYLAND_DISPLAY` を絶対パスで渡す**ようにしたので要らない
- ロケールの探索(結果は "C" だった)。`LC_CTYPE=UTF-8` の 1 行に置き換え
  (foot の iOS パッチ 0001、wayland-apps.md、`sd_launch` の 3 箇所が一致)。`LANG`/`LC_ALL` は設定しない
- 起動のたびの G1 テスト(ボタンからだけ)
- `apps/XiOSLite`(置き換え済みの旧版 3530 行。`stage.txt` が残っていて全部ビルドが重かった)
- 閉包の種 `nautilus`(15 パッケージ 26MB を引き込み、tracker が要るので今は動かない)。
  124 → 111 パッケージ

### Added
- **`waitpid` / `wait` / `wait4` / `kill` の横取り**。擬似 pid(1000 以上)は procd の台帳で
  受け、本物には流さない。`dbus-run-session` は子を `waitpid` で待つので、これが無いと
  `ECHILD` で転ぶ。fork の子(detached)は join できないので `done` を見て待つ
- **初回起動で postinst 相当を実行**。ipa は読み取り専用なので、書ける場所に生成して
  環境変数で指す: `glib-compile-schemas --targetdir=<home>/glib-schemas`(`GSETTINGS_SCHEMA_DIR`)、
  `loaders.cache`(`GDK_PIXBUF_MODULE_FILE`。積んでいるローダーは SVG の 1 本)、
  `fc-cache -f`(`XDG_CACHE_HOME`)。これが無いと GTK4 のアプリは `g_settings_new` で abort し、
  SVG のアイコンは描けない(ドックが頭文字だった一因)
- **`execve` / `posix_spawn` がスクリプトに `ENOEXEC` を返す**。libiosexec の `ie_execve` は
  `EPERM/ENOEXEC` のときだけ `#!` を読んで `sh script` に書き換える(`execv.c:23-47`)ので、
  `ENOENT` のままではシェルスクリプトが一切動かなかった
- **TRAITS で自動キーボード**(osk-plan.md)。コンポジタが「文字を受け取る欄が選ばれた/外れた」を
  教えてくるので、enable で出し、disable は 0.2 秒待って下げる。使う人が自分で下げたものは
  その欄を離れるまで自動では出さない。Tab を `KEY 0xff09` で送るようにした
- **PACING**(`xs_pacing`)。表示の時計をコンポジタに渡し、`pacing=event-loop` から vblank へ
- 種に `gsettings-desktop-schemas`(libadwaita/GTK4 が `org.gnome.desktop.*` を参照する)
- `tools/xios/audit_symbols.py` をビルドの関門に繋いだ(G0 で libpcre2 の欠陥を見つけた検査)

### Changed
- **論理画面を 864 幅に固定し、縮小して映す**。xiOS のシェルは幅 1440 を基準に描き、縮尺を
  0.6〜2.5 に収める(`iosc-shell.c pl_ui`)。393 幅では 0.6 に切り上げられ「864 幅のつもり」で
  描いた帯の右が切れていた。xiOS 自身も iPad で 1440 論理を 2160 パネルに縮小している
  (xios-app.md "Render Scale")。`-scale 2`、`IOSC_PANEL_SCALE=2`。タッチの逆変換は
  ビューポート基準なのでそのまま
- 「エディタ」は `dbus-run-session -- gnome-text-editor` で起こす(run-kgx.sh と同じ形)
- `posix_spawnp` は `getenv("PATH")` を順に探す(libiosexec の `ie_posix_spawnp` と同じ)
- `xinput.c` に `SO_NOSIGPIPE`(IoscInput.c と同じ)
- `XDG_DATA_DIRS` に `/var/jb/usr/local/share` を足した(iosc-shell のアイコン探索先)
- ドックの部品の配置は初回だけ書く(ioscbg が動かした位置を書き戻すので、毎回上書きすると消える)
- セッション開始は run-shell.sh と同じ順(壁紙 → 0.3 秒 → 帯 → ドック)
- 文書の誤りを直した(`task_for_pid` は自分自身でも失敗する / 記録は 32 バイト)

## [0.2.6] - 2026-09-12

### Fixed
- **dbus が二重に起きていた本当の理由**。xiOS のソース(`apps/iosc-shell/shell-draw.h`
  の `sd_launch`)を読んだところ、設計はこうだった:

  ```c
  int have_bus = sd_shared_session_bus(root, busdir, ...);   /* <jbroot>/tmp/iosc-shell-bus */
  if (!have_bus)
      execl(dbus_run, "dbus-run-session", "--", sh_bin, "-lc", cmd, NULL);
  execl(sh_bin, "sh", "-lc", cmd, NULL);
  ```

  **共有バスが 1 本立てば `dbus-run-session` は使わない**。立てられなかったときだけ、
  1 起動ごとに使い捨てのバスを作る道へ落ちる。実機で 2 本走っていたのは、
  共有バスを作れずに落ちた先だった。作れなかったのは `/var/jb/tmp` を
  アプリの中(読み取り専用)に写していたからで、こちらの経路変換の誤り。
  `/var/jb/tmp` と `/var/jb/var/tmp` は書ける場所へ写すようにした
- `sd_launch` は起動するアプリの `XDG_RUNTIME_DIR` を共有バスの置き場へ差し替える。
  Wayland のクライアントは `XDG_RUNTIME_DIR/WAYLAND_DISPLAY` を見るので、
  そのままだとコンポジタを見失う。置き場を先に作って、そこからも同じソケットが
  見えるように印を張っておく
- `DBUS_SESSION_BUS_ADDRESS` を既定の環境から外した。バスの場所は向こうが決める設計で、
  こちらが先に別の場所を指すと二重に立てる道へ迷い込む。自分で起こすとき
  (「エディタ」ボタン)だけ、その場で教える

## [0.2.5] - 2026-09-12

### Fixed
- **ドックからアプリが起動するようになった**。v0.2.4 の実機で
  `ioscoverview 0.9.7: 4 app(s)` / `layer_surface created ns="overview"` まで到達し、
  **xiOS 側を 1 行も改変せずにランチャーが通った**。残っていたのは dbus で転ぶ 2 点:
  - **利用者の台帳が引けない**。`getpwuid` がサンドボックスから通らず、dbus が
    `Could not get password database information for UID of current process: User "???" unknown`
    → `Failed to start message bus` で落ちていた。中身は「mobile / uid 501」で決まっているので、
    `getpwuid` / `getpwnam` / それぞれの `_r` / `getlogin` を自前で返す
  - **fork の子が親の fd を閉じていた**。本物の fork なら親子で fd の表が分かれるが、
    ここでは 1 つしか無い。`dbus-run-session` は pipe を作って fork し、子が
    「親の分はもう要らない」と閉じるので、親の読み口まで消えて
    `error reading address from bus daemon: Bad file descriptor` になっていた。
    fork の子からの `close` は全部見送る(子は exec して消えるだけなので、
    閉じ損ねても行儀の悪さで済む)

## [0.2.4] - 2026-09-12

### Added
- **`execve` / `execv` / `execvp` を本物にした**。v0.2.3 の実機で `fork` の再現は
  通っていて(`fork() -> 1011(スタック 6 KB を複製した子)` のあと子が正しく走り、
  `exit(127)` できれいに終わっていた)、止まっていたのは exec が空実装だったことだけだった。

  exec は「同じプロセスのまま中身が別のプログラムになる」操作で、成功したら戻らない。
  こちらでは「新しいプログラムをスレッドとして起こし、呼んだ側のスレッドを終える」で
  置き換える。呼んだ側は fork の子(化けるためだけに居る)なので、これがそのまま
  正しい意味になる。**擬似 pid は新しい方へ引き継ぐ**ので、親の `waitpid` も合う。
  見つからないときは `-1` を返して次の候補を試させる(libiosexec の `ie_execl` は
  `/usr/local/bin` → `/usr/bin` の順に試す)

## [0.2.3] - 2026-09-12

### Fixed
- **入力の口を 2 つに分けた**。`ios-inputd` を通したら、最初のタッチで
  `app input client disconnected` と言われて切られていた(実機 2026-09-12)。
  逆アセンブルで数えたところ、ios-inputd が知っている記録は
  **MOTION(0x100)/ KEY(0x102)/ TEXT(0x103)の 3 つだけ**で、TOUCH(0x105)は
  語彙に無い。入力メソッドの係であって指の係ではないので当然だった。
  指は今までどおり iosc の入力ソケットへ、文字だけ ios-inputd へ流す
- **壁紙が起きなくなっていた**。`ios-inputd` を「クライアント 1 本」と数えてしまい、
  「もう居るから背景は要らない」と判断していた。画面に描かないもの
  (iosc / ios-inputd / dbus-daemon)は数に入れない。セッションでは壁紙を明示的に起こす

## [0.2.2] - 2026-09-12

## [0.2.1] - 2026-09-12

## [0.2.0] - 2026-09-12

### Added
- **`fork()` を、プロセスを作らずに再現するようにした**(`native/lcfork.c` +
  `native/lcfork_ctx.S`)。これで xiOS 側のソースを一切改変せずにアプリが起動できる。

  やり方: fork の中で呼び出し元へ戻るための文脈(x19-x28/x29/x30/sp/d8-d15)を保存し、
  いま使っているスタックを sp から上端まで控える。新しいスレッドを立てて、その
  スタックの空きに控えを書き戻し、番地の差分だけ「スタックを指している値」を全部ずらす
  (保存したレジスタも、書き戻した中身も)。最後に保存した文脈へ戻り値 0 で戻る。
  呼んだ側からは「親では正の pid、子では 0 が返った」ように見える。

  成り立つ理由: xiOS のプログラムは `fork` の直後に `ie_execl`(= libiosexec、中身は
  `posix_spawn`)を呼ぶだけで、その `posix_spawn` はすでに procd に流してある。
  **出口は繋がっていて入口だけが塞がっていた**ので、入口を開ければ通る。

  危ないところ: スタックを指す値かどうかを「値が元のスタックの範囲に入っているか」で
  見分けるので、同じ範囲の整数があると誤ってずらす(実際の番地は飛び飛びなのでまず
  当たらない)。暴れたときのために `LCSYS_FORK=fail` と画面の「fork 再現」スイッチで
  従来どおり `-1` に戻せる
- `vfork` も同じ扱いにした(出口が同じ exec なので分ける意味が無い)

### Fixed
- ゲストのスレッドからの `dup2` / `close` を、fd 0/1/2 に対してだけ空振りさせる。
  標準入出力はプロセス全体で 1 組しかないので、fork の子が `/dev/null` を被せると
  こちらのログの通り道まで巻き込まれる

## [0.1.1] - 2026-09-12

### Added
- **`ios-inputd` を土台に組み込んだ**。xiOS の設計では、アプリは iosc の入力ソケットに
  直結しない。間に `ios-inputd` が居て、そこが入力メソッドとしてコンポジタに登録され、
  文字を今選ばれている窓に流し込む(バイナリ内の
  `registered as input-method proxy` / `commit_string %zu bytes (serial %u)` /
  `%zu bytes of text with no focused field; dropped`)。実機で出ていた
  `improxy=0 (local fallback)` の improxy はこれのこと。**真ん中を飛ばして直結していたのが
  文字が出なかった理由**。iosc のソケットとは別の場所で待たせる(同じだと
  `something is already listening there` で起動を断られる)
- **「セッション開始」ボタン**。土台(iosc + 入力メソッド + 壁紙)を立てて、
  バーとドックを起こして画面へ行く。それだけ

### Changed
- **ホスト側の役割を絞った**。何を起動するか・どう並べるかは xiOS 自身のシェルの仕事で、
  こちらが SwiftUI のボタンで作るものではない。部品ごとのボタンは「診断用」の
  折りたたみに移した。ホストが受け持つのは画面・指・土台の 3 つだけにする

## [0.1.0] - 2026-09-12

### Added
- **`posix_spawn` / `posix_spawnp` を本物にした**。今までは記録して `ENOSYS` を返すだけの
  空実装だったが、procd に流してスレッドとして起こすようにした。`fork` が真似できないのは
  「1 回呼んで 2 回返る」からで、`posix_spawn` にはその問題が無いので代われる。
  `posix_spawnp` は `/var/jb/usr/local/bin` → `/var/jb/usr/bin` → `/var/jb/bin` の順に探す
- **アプリを 3 つ倉庫から足した**(112 → 124 パッケージ、約 9MB 増):
  - `gnome-text-editor` — GTK4 のテキストエディタ。**打った文字がその場に出る窓**。
    GTK4 本体は nautilus 経由ですでに入っていたので、追加は 4 本だけで済んだ
  - `mesa-demos` — `es2gears_wayland`(回る歯車)。dbus も子プロセスも要らないので、
    「動く絵が届くか」だけを見るのに一番向いている
  - `xios-fonts-noto` — **フォント**。今までアプリに 1 つも入っていなかった
- **`dbus-daemon --session --nofork`** を起こすボタン。`--nofork` があるので分身を作らず
  そのまま動く。つまり iOS が禁じている `fork` を一度も踏まない。
  `DBUS_SESSION_BUS_ADDRESS` は先に環境へ入れてある(ソケット名は `sun_path` 104 バイトに
  収めるため 1 文字)
- 「歯車」「dbus」「エディタ」のボタン。「全部」にも歯車を入れた

## [0.0.9] - 2026-09-12

### Fixed
- **自前のボタンが ioscbar の上に被っていた**(実機 2026-09-12)。コンポジタの一番上には
  バーが居るので、右下の空きに小さく置き直した(ドックは中央寄せなので右下は空いている)。
  文字のボタンからアイコンにして、半透明にした
- **同じクライアントを二重に起こさないようにした**。`iosc-client` が 2 枚重なって
  窓が斜めにずれて並び、「全部ぐちゃぐちゃ」に見えていた
- **「全部」から一覧(ioscoverview)を外した**。これは画面全体を覆う切り替え画面なので、
  出すと壁紙もバーも窓も隠れる。単体のボタンからだけ出す

## [0.0.8] - 2026-09-12

### Added
- **「全部」ボタン**。iosc を起こしてから、繋がる相手を端から全部起こして画面へ行く。
  どれが出てどれが出ないかを 1 回で見るための試験用。端末(foot)は擬似端末が開けないので
  必ず失敗するが、それも見たいので入れてある

### Fixed
- **下端も iOS に譲るようにした**。ホームインジケータ(下の横棒)が乗っている範囲は
  指で触りにくく、ドックを置いても棒と重なる。上下とも安全領域を測って `-logical` から引く
- **クライアントが iosc 無しで起動できてしまっていた**。「ソケットのファイルがある」ことを
  起動している証拠にしていたが、前回終了したときの残骸でもファイルは在る。実機 2026-09-12 で
  「窓」と「ドック」が `wl_display_connect failed` で落ちたのはこれ。iosc が生きているかを
  直接見るようにし、動いていなければ先に起こす。起動時に前回の残骸も掃除する

## [0.0.7] - 2026-09-12

### Added
- **「窓」「ドック」「一覧」**のボタン。xiOS に付いている残りのクライアント。
  `iosc-client` は xdg_toplevel を 1 枚出してフレームを commit するだけの最小の相手で、
  子プロセスも dbus も要らない。**普通のアプリの窓が出るか**を確かめるためのもの

### Changed
- タッチは TOUCH だけを送るようにした(MOTION を併せて送るのをやめた)。本物のタッチ画面も
  そうで、ポインタ側は iosc が自分で合成する(ioscdock に
  `suppress synthetic pointer after touch` という重複抑制がある)。こちらからも送ると二重になる

## [0.0.6] - 2026-09-12

### Added
- **タッチが iosc に届くようになった**(計画の G2-c)。`native/xinput.c` が入力ソケットに繋ぎ、
  画面の指を出力ピクセルに戻して TOUCH レコードとして流す(仕様 6 節)。10 本までスロットを
  割り当てて追跡する。HELLO は双方向で、`window_id==1` かつ他が全部 0 でないと切断される。
  サーバーから来る TRAITS / HAPTIC は読み捨てる専用スレッドを 1 本置いた(放置すると詰まる)
- **「キーボード」ボタン**。iOS のキーボードを出し、文字は TEXT、改行と後退は KEY(keysym
  0xff0d / 0xff08)で送る。keysym の対応表を持たずに済ませるため、普通の文字は TEXT に寄せた

### Fixed
- **ロケールを決め打ちにするのをやめた**。`en_US.UTF-8` はこのサンドボックスから引けず
  (実機: `setlocale: cannot change locale (en_US.UTF-8): No such file or directory`)、
  foot が起動直後に `setlocale() failed` で転んでいた。起動時に `en_US.UTF-8` →
  `UTF-8` → `C.UTF-8` → `C` の順に実際に `setlocale` を通して、通った名前を
  `LANG` / `LC_CTYPE` / `LC_ALL` の 3 つに揃える。ホストとゲストは同じ libSystem を
  使うので、ホストで通った名前はゲストでも通る

## [0.0.5] - 2026-09-12

### Added
- **デスクトップ部品(Storage / Memory / Load / Session)を出す**。出ていなかったのは
  故障ではなく、ioscbg が設定ファイルを読めないと 1 つも描かない作りだったから。既定の置き場
  `/var/mobile/Library/Preferences/com.max.iosc-widgets.conf` はこのサンドボックスには無い。
  書式は逆アセンブルで確かめた `名前 x y 有効` の 4 つ組(`fscanf(f, "%31s %d %d %d")` が
  4 を返したときだけ採用、3 番目は 0 以外で表示)。自前の設定を書いて `IOSC_WIDGET_CONFIG` で指す
- `statfs` / `statvfs` の横取り。Storage 部品が空き容量をこれで読むので、経路変換を
  通さないと `/var/jb` を本物の根として見に行って失敗する

### Fixed
- **上端を iOS に譲るようにした**。Dynamic Island とステータスバーが乗っている範囲に
  描いても、コンポジタの一番上に置かれる ioscbar が潜って読めない。起動時に安全領域を測り、
  `-logical` をその分だけ低くして、表示側も同じ範囲に置く(拡大縮小は 1:1 のまま)
- `LC_ALL=C` が `LANG` を上書きしていた。v0.0.4 で `LANG` を直しても効いていなかった

## [0.0.4] - 2026-09-12

### Fixed
- **`fopen` には Darwin では 2 つの名前があり、片方しか横取りしていなかった**。`<stdio.h>` が
  `__DARWIN_ALIAS_STARTING` で `_fopen` と `_fopen$DARWIN_EXTSN` を切り替えるので、
  どちらで呼ばれるかはパッケージのビルド設定次第になる。ipa 内の 308 本を走査したところ
  **132 本が `$DARWIN_EXTSN` の側**で、その中に libxkbcommon が居た。だから v0.0.2 で
  `fopen` を足してもキーボードのデータは読めないままだった
  (実機: `Couldn't find file "rules/evdev"`。ファイルは 47640 B で確かに入っている)。
  両方の名前を定義した。`realpath` は最初から両方あったので、見落としは `fopen` だけ
- 同じ取りこぼしを二度とやらないように、ビルド時の関門を足した
  (`tools/xios/audit_aliases.py`: libLCsys が基本名を定義しているのに `$` 付きの別名を
  落としていたらビルドを止める)
- **「画面」を開くと背景クライアントも自動で起こすようにした**。コンポジタは繋いでくる相手が
  居ないと描くものが無いので、「画面」→「背景」の順に押すと 1 フレームも出ない
  (実機 2026-09-12 がまさにこれで、白い背景のままだった)。順番で結果が変わる作りが悪い
- iosc が動いているのに「iosc を起動」を押しても 2 本目を起こさないようにした。2 本目は
  `wayland-0.lock` を取れずに必ず失敗するが、そこに至るまでに IOSurface 3 枚と ANGLE の
  初期化を済ませるので約 40MB を捨てていた
- ゲストの `LANG` を `C.UTF-8` から `en_US.UTF-8` に変えた。`C.UTF-8` は glibc の綴りで
  Darwin の libc には無く、`setlocale` が黙って `C` に落ちていた

### Added
- DIRTY を待たずに、握手で受け取った面を 1 枚そのまま貼っておくようにした。
  「何も出ない」と「出ているが通知が来ない」を実機で切り分けるため
- 何も描けないまま空回りしたときに理由を 1 度だけログに出す(pipeline / drawable /
  DIRTY 未着 のどれか)

## [0.0.3] - 2026-09-12

### Fixed
- **アプリが這っていた原因はログの書き方**。1 行ごとに `fsync` し、さらに画面用の文字列へ
  毎行追記していた(SwiftUI が毎回全文を描き直す)。経路変換の追跡は毎秒数千行出るので致命的だった。
  書き込みをまとめ、`fsync` は 256KB ごと、画面用の文字列は 12 万字で頭を切る
- 経路変換の追跡を既定で切った(「詳細ログ」のスイッチで入れる)

### Added
- **Wayland クライアントを起こすボタン**。コンポジタは繋いでくる相手が居ないと描くものが無いので、
  画面が黒いのは正常だった。`背景`(ioscbg)が一番軽い相手で、プロセス生成も dbus も要らない。
  `バー`(ioscbar、cairo と pango で文字を描く)、`端末`(foot。子プロセスを作れないので
  今は失敗する見込み。G3 で解決)も並べた

## [0.0.2] - 2026-09-12

### Fixed
- **iOS では `task_for_pid()` が自分自身の pid に対しても通らない**(実機 2026-09-12:
  `xios: task_for_pid(1199) failed: 0x5 ((os/kern) failure)`)。macOS とは違う点で、
  「同一プロセスなら権限なしで成立する」という当初の読みが外れていた。iosc は相手の
  task port を取ってから IOSurface のポートを送るので、これが画面の出ない直接の原因だった。
  `task_for_pid` を横取りし、自分の pid なら `mach_task_self()` を返す
  (iosc の libSystem 依存は relink 済みなので、この定義が割り当たる)
- コンポジタが bind してから listen するまでに GPU 初期化が挟まり、ソケットが見えていても
  少しの間 `ECONNREFUSED` が返る。繋がるまで 200ms 間隔で最大 10 秒待つようにした

### Added
- `LCSYS_TRACE=1` を既定で有効化。経路変換を 1 件ずつログに出す
  (xkb がどのパスを要求して失敗しているかを実機で見るための診断)

## [0.0.1] - 2026-09-12

XiOSLite v0.2.1 を土台に、**画面を出す部分**を足した最初の版。`com.rutoi.xiosdesktop` として
XiOSLite とは別に入る(両方を同時に iPhone へ入れられる)。

### Added
- **ddx クライアント** `native/xsurface.c`。コンポジタ `iosc` に繋いで画面を受け取る側
  (`tools/xios/iosc-host-protocol.md` 2〜5 節の実装)。握手は仕様どおりの順番で、
  **mach メッセージをソケットの返事より先に**受ける。`caps=STREAM_V2` で試し、駄目なら `caps=0`。
  DIRTY 1 回につき RELEASED 1 回(まとめない。返さないと 3 枚とも塞がって画面が固まる)
- **フェンスの受け渡し** `lcsys_shared_event_for_token()`。iosc が登録したのと同じプロセス内
  テーブルからトークンを引いて `id<MTLSharedEvent>` を返す(root の XPC ブローカーの代わり)
- **画面** `Sources/ScreenView.swift`。`MTKView` にコンポジタの IOSurface を貼る
  (面 id ごとにテクスチャを 1 枚だけ作って使い回す)。描く前に提示フェンスを待ち、
  present 後に解放イベントへ署名したコマンドバッファを **commit してから** RELEASED を送る
- 「画面」ボタン。コンポジタが居なければ起こし、ソケットができるまで最大 10 秒待って全画面へ。
  右上の「コンソール」でいつでもログに戻れる

### 土台(XiOSLite から引き継いだもの)
- Linux の実行ファイルをアプリ内スレッドとして走らせる `procd`(G1 実機突破済み)
- `/var/jb` をアプリ内に読み替える経路変換層 `pathmap`(`fopen` の穴を塞いだ版)
- `metal-event-broker` の肩代わり `xpcshim.m`(これが無いとコンポジタは起動時に落ちる)
- xiOS/Procursus の 112 パッケージ(Frameworks 408 本 + データ 150MB)

### Known issues
- タッチとキーボードはまだコンポジタに届かない(次の段)
- 画面に出るのはコンポジタの背景だけ。アプリを載せるのはその次の段
- 実行ファイルの像は解放できないので、コマンドを起こすたび約 3MB 増える
