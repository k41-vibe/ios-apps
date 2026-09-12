# XiOSLite — G1: Linux ユーザー空間の実行ファイルをスレッドとして動かす

`~/.claude/plans/wobbly-noodling-pony.md` の G1 関門を確かめるためのゲストアプリ。xiOS の
.deb(Procursus rootless、`/var/jb` 前提の Mach-O)を **relink → dlopen → LC_MAIN の main() を
別スレッドで呼ぶ** ことで、fork/exec を使わずに `ls` `bash` `pkg-config` を同一プロセス内で走らせる。
GUI(iosc/foot/GTK)は G2 以降。

## 起動時に何をするか

1. `Frameworks/libLCsys.dylib` を dlopen し `lcsys_init(bundle, HOME, TMPDIR, log_fd)` を呼ぶ
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

ログは画面の他に `Documents/xioslite.log` に fsync 付きで残る(Copy / Share log ボタン)。
各コマンドの前後に `footprint`(phys_footprint、MB)と所要 ms を出す。

## 仕組み: libSystem の「前面」ライブラリ(reexport トリック)

xiOS の Mach-O は全部 `/usr/lib/libSystem.B.dylib` を `LC_LOAD_DYLIB` している。
`tools/xios/relink.py --libsystem-shim libLCsys.dylib`(stage.py が全 Mach-O に適用)で
その 1 行を `@rpath/libLCsys.dylib` に書き換える(cmdsize 内、32 バイト枠に収まる)。

`libLCsys.dylib` は `apps/XiOSLite/native/*.c` から postbuild.sh が macOS ランナー上で

```
clang -target arm64-apple-ios16.0 -isysroot $SDK -O2 -dynamiclib \
      -install_name @rpath/libLCsys.dylib -Wl,-reexport-lSystem native/*.c -o Frameworks/libLCsys.dylib
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

環境変数: `HOME TMPDIR PATH XDG_RUNTIME_DIR XDG_DATA_DIRS PKG_CONFIG_PATH TERM=dumb LANG=C.UTF-8
LC_ALL=C SHELL USER=mobile`。

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

## ビルド

`apps/XiOSLite/stage.txt` があるので workflow は先に ubuntu の `stage` ジョブ
(`tools/xios/stage.py --symlinks never`)を走らせ、artifact `xios-stage` を macOS ジョブに
渡す。`postbuild.sh` が libLCsys をビルドし、`Frameworks/`(relink 済み 406 本)と `jb/`
(データ + `.lc` スタブ)を .app にコピーする。ipa は 100 MB 超。
`.\tools\build.ps1 XiOSLite` → SharedFolder → LiveContainer。
