# XiOSLite — G1: Linux ユーザー空間の実行ファイルをスレッドとして動かす

`~/.claude/plans/wobbly-noodling-pony.md` の G1 関門を確かめるためのゲストアプリ。xiOS の
.deb(Procursus rootless、`/var/jb` 前提の Mach-O)を **relink → dlopen → LC_MAIN の main() を
別スレッドで呼ぶ** ことで、fork/exec を使わずに `ls` `bash` `pkg-config` を同一プロセス内で走らせる。
GUI(iosc/foot/GTK)は G2 以降。

## 起動時に何をするか

1. `Frameworks/libLCsys.dylib` を dlopen し `lcsys_init(bundle, HOME, TMPDIR, log_fd)` を呼ぶ
   (この中で `lcsys_install_xpc_shim()` = metal-event-broker の肩代わりも入る。後述)
2. パイプを 1 本作り、その書き込み側を **fd 1 と 2 に dup2**(プロセス全体)。読み取り側を
   バックグラウンドスレッドで読んでコンソールに流す
3. G1 テスト列を順に `lcsys_spawn` → `lcsys_wait`:
   1. `/var/jb/usr/bin/ls -la /var/jb/usr/bin`
   2. `/var/jb/usr/bin/bash -c "echo hello from bash; echo HOME=$HOME; cd /var/jb/usr/share && echo cwd ok"`
   3. `/var/jb/usr/bin/cat /var/jb/usr/lib/pkgconfig/wayland-server.pc`
   4. `/var/jb/usr/bin/ls -la /var/jb/usr/bin`(1 と同一 = 静的状態の回帰テスト)
   5. `/var/jb/usr/bin/ls /var/jb/usr/lib/gdk-pixbuf-2.0/2.10.0/loaders`(readdir の `.lc` 剥がし)
   6. `/var/jb/usr/bin/pkg-config --list-all`(libpcre2 が読めるか)
4. テキスト欄に任意のコマンド行を打って Run できる(空白区切り、`"..."` `'...'` のみ対応。
   先頭語にスラッシュが無ければ `/var/jb/usr/bin:/var/jb/usr/local/bin:/var/jb/bin` を探す)
5. 「iosc を起動」= 戻ってこないゲスト(Wayland コンポジタ)を wait せずに起こす(下記)。
   「状態」= 起こしたゲストの生死と footprint と作業ディレクトリの中身

ログは画面の他に `Documents/xioslite.log` に fsync 付きで残る(Copy / Share log ボタン)。
各コマンドの前後に `footprint`(phys_footprint、MB)と所要 ms を出す。

## 仕組み: libSystem の「前面」ライブラリ(reexport トリック)

xiOS の Mach-O は全部 `/usr/lib/libSystem.B.dylib` を `LC_LOAD_DYLIB` している。
`tools/xios/relink.py --libsystem-shim libLCsys.dylib`(stage.py が全 Mach-O に適用)で
その 1 行を `@rpath/libLCsys.dylib` に書き換える(cmdsize 内、32 バイト枠に収まる)。

`libLCsys.dylib` は `apps/XiOSLite/native/*.c` + `native/*.m` から postbuild.sh が macOS ランナー上で

```
clang -target arm64-apple-ios16.0 -isysroot $SDK -O2 -dynamiclib \
      -install_name @rpath/libLCsys.dylib -Wl,-reexport-lSystem native/*.c native/*.m \
      -framework Foundation -framework Metal -lobjc -o Frameworks/libLCsys.dylib
```

とビルドする(失敗時は `-Wl,-reexport_library,$SDK/usr/lib/libSystem.B.tbd` を試す。
`LC_REEXPORT_DYLIB` が無ければビルド失敗扱い)。dyld の two-level namespace では
ゲストの `_open` などは「libLCsys の中 → libLCsys が再輸出する libSystem」の順で探されるので、
libLCsys が定義した関数だけが横取りされ、残りは本物の libSystem に落ちる。
LiveContainer や Swift 側は libSystem に直接束縛されたままなので影響を受けない。
`__interpose`(dlopen した像には効かない)や fishhook に依存しない。

横取りしている関数(`native/lcsys.c`):

- パス変換: `open openat stat lstat fstatat access faccessat opendir closedir readdir
  readdir_r readlink realpath(両シンボル名) mkdir rmdir unlink rename chmod chdir`
  - `/var/jb/...`, `/private/var/jb/...` → `<bundle>/jb/...`
  - `/var/mobile`, `/var/root` → HOME(`Documents/home`)
  - `/tmp`, `/var/tmp`, `/private/tmp` → TMPDIR
  - Windows で stage したときの `<path>.symlink` マーカー(リンク先の文字列)は途中の
    ディレクトリ成分も含めて解決する(最大 8 段)。`lstat`/`readlink` はマーカーをシンボリック
    リンクとして報告する
  - relink 済み Mach-O の跡地は `<元の名前>.lc` スタブ(`jb/usr/bin/ls.lc`,
    `jb/usr/lib/libglib-2.0.0.dylib.lc`、中身は `@LC:Frameworks/<flat>` の 1 行)。元の名前の
    ファイルは置かない(LiveContainer のインストーラは `*.dylib` や `.app` 内の実行ファイルを
    名前で拾って署名しようとし、テキストのスタブで「署名できない」一覧を出すため)。
    ゲストが見る `/var/jb/usr/bin/ls` は、変換先が無く `ls.lc` があればその `.lc` に解決する
    ので `stat`/`access`/`open`(`test -x`、`which`、bash の PATH 探索)は通る
- **readdir の `.lc` 剥がし**: `opendir` は変換後のホストパスが `<bundle>/jb` 配下なら
  その `DIR *` を登録し、`readdir`/`readdir_r` は登録済みディレクトリの項目だけ
  `.lc` 接尾辞を落として返す(`ls.lc` → `ls`、`libpixbufloader-svg.so.lc` →
  `libpixbufloader-svg.so`)。剥がした名前が同じディレクトリの実在項目と衝突する場合は
  その `.lc` 項目を捨てる。`d_namlen`/`d_reclen` は短くなった名前に合わせて直す。
  返すポインタは **DIR ごとの scratch**(libc の readdir と同じ寿命規則: 次の
  `readdir(d)` まで有効)、`readdir_r` は呼び出し側のバッファをその場で書き換えるので
  スレッド安全。jb 配下でないディレクトリは一切いじらない。arm64 に
  `readdir$INODE64` 系は無い(64bit inode の `struct dirent` 一種類)ので素の名前でよい。
  これが無いと `ls /var/jb/usr/bin` が `ls.lc` を並べ、GTK/glib のモジュール探索
  (gdk-pixbuf loaders / gio modules / gtk printbackends はどれも「ディレクトリを
  readdir して `*.so` を拾う」)が全滅する
- `openat`/`fstatat`/`faccessat` は、ディレクトリ fd 相対の裸の名前が ENOENT のときだけ
  `<名前>.lc` で引き直す(readdir が返した `ls` を coreutils の `ls` が
  `fstatat(dirfd, "ls", ...)` で stat しに来るため。jb 外には `.lc` が無いので無害)
- `SLJIT_UPDATE_WX_FLAGS`: 上流 `libpcre2-8.0.dylib` が未定義参照のまま出荷されていて
  (`_SLJIT_UPDATE_WX_FLAGS` はフラット名前空間、同梱 408 本のどれも輸出していない)、
  そのままだと libpcre2 と依存する libglib/GTK が `dlopen(RTLD_NOW)` で落ちる。
  sljit の W^X キャッシュフラッシュフックなので **no-op で定義**する。実機は
  `mmap(MAP_JIT)` が EPERM(G0)で pcre2 の JIT は失敗しインタプリタに落ちるため、
  このフックが本物のコードをフラッシュすることは無い。libLCsys は Runner.swift が
  `RTLD_GLOBAL` で dlopen するのでフラット検索から見つかる
- `dlopen`: `/var/jb/...` を変換し(`.lc` スタブへの解決込み)、中身が `@LC:Frameworks/<flat>`
  のスタブなら `<bundle>/Frameworks/<flat>` を開く(gdk-pixbuf などのプラグイン用:
  `/var/jb/usr/lib/gdk-pixbuf-2.0/2.10.0/loaders/libpixbufloader-svg.so` →
  `jb/.../libpixbufloader-svg.so.lc` → `Frameworks/libpixbufloader-svg.so`)
- `execve execv execvp posix_spawn posix_spawnp`: argv をログに出して `ENOSYS`
- `fork vfork`: ログして `-1 / EAGAIN`(環境変数 `LCSYS_FORK_ERRNO=<番号>` で変更可。
  bash は EAGAIN だと 1,2,4,8,16 秒スリープしながら再試行するので、bash の外部コマンドは
  1 回あたり 30 秒ほど待つ。`38`(ENOSYS)にすると即座に諦める)
- `exit _exit`: 呼び出し元がゲストスレッドなら終了コードを記録して `pthread_exit`
  (atexit ハンドラは走らない。代わりに `fflush(NULL)` する)。ホストスレッドなら本物へ

`LCSYS_TRACE=1` を設定して起動するとパス変換を全部ログする。

## procd(`native/procd.c`)

`lcsys_spawn(path, argv, envp, fd_out, fd_err)`:
`<path>.lc` スタブ(`@LC:Frameworks/<flat>`)→ `Frameworks/<flat>` を **`<TMPDIR>/procd/<n>-<名前>` に
私的コピー**してから `dlopen(RTLD_LOCAL|RTLD_NOW)` → `_dyld_image_count()` で
像を探し → ロードコマンドの `LC_MAIN.entryoff` から `entry = header + entryoff` → 8 MB スタックの
pthread で `entry(argc, argv, envp, apple)` を呼ぶ。

静的状態を新品にする二段構え(`ls` が 1 回目と 2 回目で交互に `invalid option -- ''` を
出した件への対処):

1. **私的コピー**。dyld は同じパスに同じ像を返すので、毎回パスを変えて別の像として読ませる
   (署名は付いたままコピーされるので JIT-less でも読める = G0 で実証済み)。
   コピー処理は **`lcsys_real.open/mkdir/unlink` だけ**を使う。素の `open`/`mkdir`/`unlink` は
   同じ dylib 内の自分の横取り関数に束縛され、**ホスト**パス(`<TMPDIR>` は
   `/var/mobile/Containers/...` 配下 = HOME に変換されてしまう)まで変換されて
   毎回 ENOENT になっていた。失敗時はどの段(`mkdir`/`open(src)`/`open(dst)`/`read`/`write`)の
   どのパスで落ちたかをログに出す
2. **ゲスト像側の getopt 状態のリセット**。coreutils は gnulib 自前の getopt を同梱していて、
   `optind`/`first_nonopt`/`last_nonopt`/`__getopt_initialized` は **libSystem ではなくゲスト像の
   static**。つまりスレッド側で libc の `optind` を戻しても効かない。dlopen 直後に
   `dlsym(handle, "optind"/"opterr"/"optreset"/"optarg")` を引き、見つかったものだけ
   `optind = 0`(GNU/gnulib の流儀。**1 ではなく 0** が完全再初期化)、`opterr = 1`、
   `optreset = 1`、`optarg = NULL` にする。各実行ファイルの初回 spawn のとき、
   4 つそれぞれが「ゲスト像自前(own)/libc(libc)/無し(-)」のどれだったかをログに出す。
   libc 側に当たった場合も、この後に走るゲストスレッドが `optind=1; optreset=1;` に
   戻すので害は無い
戻り値は擬似 pid(1000 から)。`lcsys_wait(pid, &status)` は join。`dlclose` はしない。
`lcsys_alive(pid, &status)` は **join も回収もしない**生死の確認(`1` 実行中 / `0` 終了済み
(`status` に終了コード)/ `-1` 知らない pid = ECHILD)。リストから外すのは `lcsys_wait` だけなので
同じ pid を何度でも聞ける。戻ってこないゲスト(iosc)用。
`argv[0]` はゲストの元パス(`/var/jb/usr/bin/ls`)のまま渡す(coreutils の multi-call と bash が見る)。

relink.py は元が実行ファイルだった Mach-O に `LC_ID_DYLIB @rpath/<flat>` を追記する
(dyld は `LC_ID_DYLIB` の無い MH_DYLIB を拒む。LiveContainer もゲスト本体に同じ処置をする)。

## G1 でプロセス全体に 1 つしかないもの(G3 で分離予定)

| もの | 状態 |
|---|---|
| 環境変数 | Swift 側が `setenv` した値をゲスト全員が `getenv` で見る。`envp` も同じ内容 |
| カレントディレクトリ | `chdir` は本物に流す。ゲストの cwd は共有 |
| fd 0/1/2 | 1 本のパイプ。`fd_out`/`fd_err` 引数は受け取るだけ |
| シグナル | `SIGPIPE` は `lcsys_init` で無視。ほかは素通し |
| getopt 状態 | dlopen 直後にゲスト像の分を、スレッド開始時に libc の分をリセット |
| atexit | ゲストの登録は溜まるだけで走らない |
| fork/exec | 無い(ログのみ) |

環境変数: `HOME TMPDIR PATH XDG_RUNTIME_DIR WAYLAND_DISPLAY=wayland-0 IOSC_DEBUG=1 XDG_DATA_DIRS
PKG_CONFIG_PATH TERM=dumb LANG=C.UTF-8 LC_ALL=C SHELL USER=mobile`。

## G1 関門の読み方(コンソールで確認すること)

1. `lcsys_init -> 0` と `Frameworks/ entries 400+`、`jb/usr/bin/ls.lc stub present true`
2. `private copy failed` の行が **出ない**こと(出たらどの段で落ちたかがその行に書いてある)。
   各実行ファイルの初回に `guest getopt state optind=... opterr=... optreset=... optarg=...`
   が 1 行出る
3. test 1: `pid 1000: /var/jb/usr/bin/ls -> <TMPDIR>/procd/1-ls.exe.dylib (header ..., entryoff ...)`
   の後に `ls -la` の一覧、`exit=0`。実行ファイルは `ls` のように **`.lc` の付かない名前**で
   十数バイトのサイズで並ぶ
4. test 2: `hello from bash` `HOME=...` `cwd ok` が出て `exit=0`
5. test 3: `cat` が wayland-server.pc の中身を出して `exit=0`
6. test 4: 2 回目の `ls` が test 1 と**同じ出力・同じ書式**で `exit=0`
   (出力が変わる / `invalid option` が出る = 静的状態の再利用バグ)
7. test 5: gdk-pixbuf の loaders が **`.so` で終わる名前**で並ぶこと(`.so.lc` なら readdir の
   剥がしが効いていない)
8. test 6: `pkg-config --list-all` が .pc を列挙して `exit=0`
   (`symbol not found in flat namespace '_SLJIT_UPDATE_WX_FLAGS'` が出たら libpcre2 対処が効いていない)
9. 各行の footprint が単調に増えすぎていないこと

## iosc を起こす(G2 の最初の一歩)

`iosc` は `wl_display_run()` で止まるので **戻ってこない**。そのため `Runner.start(argv, label:)` を
使う: spawn したら pid を返すだけで join せず、`[pid: ラベル]` の表に控える。`Runner.lock`
(コマンドを 1 本ずつに直列化している錠)は **spawn の一瞬しか握らない**。握ったままにすると
iosc が生きている間ほかのコマンドが一切動かなくなる。

`Runner.startIosc()`(「iosc を起動」ボタン)がやること。2 秒眠るので必ず別スレッドから呼ぶ。

1. `<TMPDIR>/xdg-runtime` と `<TMPDIR>/xios` を作る(無ければ)
2. `XDG_RUNTIME_DIR=<TMPDIR>/xdg-runtime`、`WAYLAND_DISPLAY=wayland-0`、`IOSC_DEBUG=1` を
   `environment()` 経由で設定してログに出す(G1 では環境変数はプロセス全体で 1 つ)
3. `/var/jb/usr/local/bin/iosc` を起こす。フラグは全部 upstream の `wayland/iosc_options.c` 由来で、
   ソケットの既定値(`/var/jb/tmp/...` = 読み取り専用の bundle 配下)を避けるため明示する:

   ```
   -g 1170x2532 -logical 585x1266 -scale 2 -s wayland-0
   -ddx-sock <TMPDIR>/xios/iosc-ddx.sock   -json <TMPDIR>/xios/xios.json
   -input-sock <TMPDIR>/xios/iosc-input.sock
   -clipboard-sock <TMPDIR>/xios/iosc-clipboard.sock
   -wm-sock <TMPDIR>/xios/iosc-wm.sock
   ```

4. 2 秒後に pid がまだ生きているか(`lcsys_alive`)と、2 つのディレクトリに何ができたか
   (名前 + サイズ、ソケットは `(socket)`)を出す

**ソケットのパスはホスト側の実パスで渡す**。`bind`/`connect` は横取りしていないので本物の
パスがそのまま要る(逆に `unlink`/`stat` は横取りされ `/var/mobile` → HOME に化けるが、
ソケットの後始末に失敗するだけなので無害)。ただし AF_UNIX の `sun_path` は 104 バイトで、
実機の `$TMPDIR` は 89 文字(G0)。`<TMPDIR>/xios/iosc-ddx.sock` は 108 バイトで **上限を超える**ので、
起動前に各パスの長さをログに出す(`*** sun_path の上限 104 B 超え ***`)。超えていたら
ディレクトリ名を詰める(`xios` → `x` など)必要がある。

この段階では絵も入力もまだ無い。**iosc はどこかで失敗するのが期待される結果**で、
見たいのは「どこまで進んだか」。ログは 1 行ごとに fsync しているので、iosc のスレッドが
落ちても最後の行まで残る。

## metal-event-broker の肩代わり(`native/xpcshim.m`)

iosc は起動時に、ANGLE から取った `id<MTLSharedEvent>` の `MTLSharedEventHandle` を 32 バイトの
トークン付きで **XPC サービス `com.max.xios.metal-event-broker`** に登録する。脱獄機ではこれは
root の LaunchDaemon で、こちらでは登録できない。**フェンス無しで進む経路はソースに無い**ので、
publish に失敗した時点で

```
xios_metal_sync_create_event が NULL
 → iosc_gl.c:318 "output release timeline unavailable"
 → iosc.c:6921   "FATAL: GPU compositor initialization failed" → exit 1
```

と落ちる(`tools/xios/iosc-host-protocol.md` 第 4 節)。

**全部 1 プロセスなので、イベントは直接手渡せばいい。** ただしブローカーのコードは iosc の像に
静的リンクされていて C の呼び出しは直接分岐なので、シンボル置換では横取りできない。
**サービスへ行く道だけが Objective-C で、ObjC のメッセージ送信は必ず動的解決される**ので、そこを取る。

`lcsys_init` が `lcsys_install_xpc_shim()`(`dispatch_once` で 1 回だけ)を呼び、`NSXPCConnection` の
メソッドを 3 つ入れ替える。元の実装はファイル static に保持し、ブローカー以外の接続はそのまま流す。

| 入れ替えるメソッド | すること |
|---|---|
| `initWithMachServiceName:options:` | 元を呼んでから、返ってきた接続に `objc_setAssociatedObject` でサービス名を貼る |
| `synchronousRemoteObjectProxyWithErrorHandler:` | 名前が `com.max.xios.metal-event-broker` のときだけ自前スタブを返す(**エラーハンドラは呼ばない**)。他は元へ |
| `remoteObjectProxyWithErrorHandler:` | 同上(別経路で呼ばれた場合の保険) |

`NSXPCConnection` クラス自体が無い場合(サンドボックス下の iOS アプリで有りうる)は、
`objc_allocateClassPair` でその名前の最小クラスを作る(`initWithMachServiceName:options:` /
`setRemoteObjectInterface:` / `resume` / `invalidate` / 2 つの proxy getter)。どちらの道を通ったかは
ログに 1 行出る。

スタブ `LCMetalEventBroker` は `NSData`(トークン)→ ハンドルの辞書を `NSLock` で守るだけ:

- `publishHandle:token:withReply:` → 辞書に入れて `reply(YES)`。辞書が retain するのでハンドルは
  プロセスの寿命まで生きる
- `copyHandleForToken:withReply:` → 引いて `reply(handle)`(無ければ nil)

**返答ブロックは必ずその場で(同期・戻る前に)呼ぶ**。呼び出し側は `__block` のローカルを呼び出し
直後に読み、`stored == NO` なら最大 4 回やり直す作りだから。ログには毎回トークンの先頭 4 バイトと
辞書のサイズが出る(`xpcshim: publish token=xxxxxxxx table=1`)。

`MTLSharedEventHandle` は `id` として扱い `<Metal/Metal.h>` は取り込まない。こちらは中身を一切
見ず、預かって返すだけなので、ヘッダもクラスの有無の心配も要らない。retain/release は手動(ARC 無し)。

Swift 側は `lcsys_init` のあとに `dlsym(h, "lcsys_install_xpc_shim")` を引いてログに出す。
**`無し` と出たら古い libLCsys.dylib** で、iosc はフェンスを publish できずに落ちる。

## ビルド

`apps/XiOSLite/stage.txt` があるので workflow は先に ubuntu の `stage` ジョブ
(`tools/xios/stage.py --symlinks never`)を走らせ、artifact `xios-stage` を macOS ジョブに
渡す。`postbuild.sh` が libLCsys をビルドし、`Frameworks/`(relink 済み 406 本)と `jb/`
(データ + `.lc` スタブ)を .app にコピーする。ipa は 100 MB 超。
`.\tools\build.ps1 XiOSLite` → SharedFolder → LiveContainer。
