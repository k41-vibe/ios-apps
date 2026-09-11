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
   2. `/var/jb/usr/bin/bash -c "echo hello from bash; ls /var/jb/usr/share | head -5"`
   3. `/var/jb/usr/bin/pkg-config --list-all`
   4. `/var/jb/usr/bin/ls -la /var/jb/usr/bin`(2 回目 = 静的状態の回帰テスト)
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

- パス変換: `open openat stat lstat fstatat access faccessat opendir readlink realpath
  (両シンボル名) mkdir rmdir unlink rename chmod chdir`
  - `/var/jb/...`, `/private/var/jb/...` → `<bundle>/jb/...`
  - `/var/mobile`, `/var/root` → HOME(`Documents/home`)
  - `/tmp`, `/var/tmp`, `/private/tmp` → TMPDIR
  - Windows で stage したときの `<path>.symlink` マーカー(リンク先の文字列)は途中の
    ディレクトリ成分も含めて解決する(最大 8 段)。`lstat`/`readlink` はマーカーをシンボリック
    リンクとして報告する
- `dlopen`: `/var/jb/...` を変換し、中身が `@LC:Frameworks/<flat>` のスタブなら
  `<bundle>/Frameworks/<flat>` を開く(gdk-pixbuf などのプラグイン用)
- `execve execv execvp posix_spawn posix_spawnp`: argv をログに出して `ENOSYS`
- `fork vfork`: ログして `-1 / EAGAIN`(環境変数 `LCSYS_FORK_ERRNO=<番号>` で変更可。
  bash は EAGAIN だと 1,2,4,8,16 秒スリープしながら再試行するので、bash の外部コマンドは
  1 回あたり 30 秒ほど待つ。`38`(ENOSYS)にすると即座に諦める)
- `exit _exit`: 呼び出し元がゲストスレッドなら終了コードを記録して `pthread_exit`
  (atexit ハンドラは走らない。代わりに `fflush(NULL)` する)。ホストスレッドなら本物へ

`LCSYS_TRACE=1` を設定して起動するとパス変換を全部ログする。

## procd(`native/procd.c`)

`lcsys_spawn(path, argv, envp, fd_out, fd_err)`:
`@LC:` スタブ → `Frameworks/<flat>` を `dlopen(RTLD_LOCAL|RTLD_NOW)` → `_dyld_image_count()` で
像を探し → ロードコマンドの `LC_MAIN.entryoff` から `entry = header + entryoff` → 8 MB スタックの
pthread で `optind=1; optreset=1;` の後 `entry(argc, argv, envp, apple)` を呼ぶ。
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
| getopt 状態 | スレッド開始時にリセット |
| atexit | ゲストの登録は溜まるだけで走らない |
| fork/exec | 無い(ログのみ) |

環境変数: `HOME TMPDIR PATH XDG_RUNTIME_DIR XDG_DATA_DIRS PKG_CONFIG_PATH TERM=dumb LANG=C.UTF-8
LC_ALL=C SHELL USER=mobile`。

## G1 関門の読み方(コンソールで確認すること)

1. `lcsys_init -> 0` と `Frameworks/ entries 400+`、`jb/usr/bin/ls stub present true`
2. test 1: `pid 1000: /var/jb/usr/bin/ls -> .../Frameworks/ls.exe.dylib (header ..., entryoff 32768 ...)`
   の後に `ls -la` の一覧(`total`, `@LC:` スタブなので各ファイルは十数バイト)、`exit=0`
3. test 2: `hello from bash` が出ること。パイプライン部分は `fork() -> -1` のログと
   bash のエラーになる(G1 の期待値。何を spawn しようとしたかがログに残る)
4. test 3: `pkg-config --list-all` が `/var/jb/usr/lib/pkgconfig` の .pc を列挙して `exit=0`
5. test 4: 2 回目の `ls` が 1 回目と同じ出力・`exit=0`(落ちたり出力が欠けたら静的状態の再利用バグ)
6. 各行の footprint が単調に増えすぎていないこと

## ビルド

`apps/XiOSLite/stage.txt` があるので workflow は先に ubuntu の `stage` ジョブ
(`tools/xios/stage.py --symlinks never`)を走らせ、artifact `xios-stage` を macOS ジョブに
渡す。`postbuild.sh` が libLCsys をビルドし、`Frameworks/`(relink 済み 406 本)と `jb/`
(データ + スタブ)を .app にコピーする。ipa は 100 MB 超。
`.\tools\build.ps1 XiOSLite` → SharedFolder → LiveContainer。
