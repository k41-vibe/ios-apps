# Changelog — XiOSLite

書式は [Keep a Changelog](https://keepachangelog.com/ja/1.1.0/)、版番号は [Semantic Versioning](https://semver.org/lang/ja/)。
リリース手順は `docs/VERSIONING.md`。実機の計測値は `tools/xios/G0-results.md`。

## [Unreleased]

### Added
- **ddx クライアント** `native/xsurface.c`。iosc の `-ddx-sock` に繋いで画面を受け取る側
  (`x11/apps/Xios/Sources/XSurface.c` の移植、`tools/xios/iosc-host-protocol.md` 2〜5 節)。
  握手は仕様どおりの順番: connect → 返信用 mach ポート → HELLO → **先に mach メッセージ**で
  主 IOSurface → ソケットのサーバー HELLO → STREAM_INFO(解放タイムラインの 32 バイト
  トークン)→ 残りのバッファごとに「mach ポート 1 通 → SURFACE レコード」→ `O_NONBLOCK`。
  `caps=STREAM_V2` で試して駄目なら `caps=0` に落とす。DIRTY 1 回につき RELEASED 1 回
  (まとめない。返さないと 3 枚とも pending になって画面が固まる)
- **フェンスの受け渡し** `lcsys_shared_event_for_token()`(`native/xpcshim.m`)。iosc が
  publish したのと同じプロセス内テーブルからトークンを引き、`newSharedEventWithHandle:` で
  `id<MTLSharedEvent>` を返す(root の XPC ブローカー `copy_event` の代わり)。Metal の
  ヘッダは取り込まず、セレクタだけを使う
- **画面** `Sources/ScreenView.swift`。`MTKView` に iosc の IOSurface を貼る
  (面 id ごとに `MTLTexture` を 1 枚だけ作って使い回す)。描く前に提示フェンスを
  `encodeWaitForEvent`、present 後の完了ハンドラで解放イベントに `encodeSignalEvent` した
  コマンドバッファを **commit してから** RELEASED を送る。`presentedTime` が取れたら
  PRESENTED も返す。60 フレームごとに fps / 面 id / footprint をログに出す
- 「画面」ボタン。iosc が居なければ起こし、ddx ソケットができるまで最大 10 秒待ってから
  全画面に切り替える。右上の「コンソール」でいつでもログに戻れる

### Fixed
- `fopen`/`freopen` を横取りしていなかった。libSystem は内部で自前の `open` を呼ぶので、
  stdio 経由でファイルを読むゲストはパス変換を素通りする。実機で xkbcommon が
  `rules/evdev` を「無い」と報告し(同梱されている)、キーボードが使えなかった
  (`iosc: keyboard unavailable (xkb keymap) -> pointer only`)。fontconfig や
  gsettings のスキーマなど、同じ経路を使うものは全部これに該当していたはず

## [0.2.1] - 2026-09-12

### Fixed
- 経路変換層がホストの実パスまで書き換えていた。iosc には `XDG_RUNTIME_DIR` とソケットのパスを
  アプリ内の実パスで渡すので、libwayland が開く `<XDG_RUNTIME_DIR>/wayland-0.lock` が
  「/var/mobile → HOME」の規則に巻き込まれて存在しない場所に化け、`wl_display_add_socket` が
  失敗していた(実機 2026-09-12。すぐ隣の ddx ソケットは bind を横取りしていないので成功していた)。
  変換の先頭で「すでにホストのパス(tmp / home / bundle 配下)なら素通し」を判定する

## [0.2.0] - 2026-09-12

### Added
- **metal-event-broker(root の XPC サービス)の肩代わり** `native/xpcshim.m`。iosc は起動時に
  Metal のフェンスをこのサービスに登録できないと `FATAL: GPU compositor initialization failed` で
  落ちる(フェンス無しの経路はソースに無い)。全部同一プロセスなので、`NSXPCConnection` の
  `initWithMachServiceName:options:` と 2 つの proxy getter を入れ替えて、サービス名が
  `com.max.xios.metal-event-broker` のときだけプロセス内のテーブル(トークン → ハンドル)を返す。
  クラス自体が無い環境では同名の最小クラスを合成する。`lcsys_init` が導入し、Swift 側は
  `dlsym(lcsys_install_xpc_shim)` の有無をログに出す(古い libLCsys の見分け)
- 戻ってこないゲストを起こす経路: `Runner.start()`(spawn したら wait しない)と
  `Runner.status()` / `lcsys_alive()`(join も回収もせずに生死と終了コードを見る)
- 「iosc を起動」ボタン。Wayland コンポジタ `iosc` を、作業ディレクトリとソケットのパスを
  全部 `$TMPDIR` 配下に明示して起こし、2 秒後の生死とできたファイルをログに出す
  (画も入力もまだ無い。どこまで進むかを見るための段)
- 「状態」ボタン。起こしたゲストの生死・footprint・`xdg-runtime` と `xios` の中身を出す

## [0.1.0] - 2026-09-12

### Added
- 版番号・ビルド番号・コミットを画面と起動ログに表示(`AppVersion`)。LiveContainer の一覧でも版が分かる
- 同梱バイナリの未定義シンボルを事前検査する `tools/xios/audit_symbols.py`
  (408 本中、実害は libpcre2 の 1 件だけと確定)

### Fixed
- procd の資源漏れ 3 件
  - 実行ファイルの私的コピーを毎回作っていた。像は解放できないので**2 回目以降だけ**作る
  - 読み込みに失敗したときにコピーが消えずに残っていた
  - 起動時に前回の残骸(`$TMPDIR/procd/`)を掃除するようにした
- 配置ツール(`stage.py`)のデータ破損: 同じパスをリンクと実ファイルで出荷するパッケージがあると、
  目印ファイルが別物に上書きされる。展開順で後勝ちに統一(人工衝突 3 ケースで検証)
- 配置ツールの検知漏れ: 未解決の `@rpath` 依存と `LC_ID_DYLIB` 欠落が警告だけで CI を素通りしていた。
  どちらも失敗扱いにし、`postbuild.sh` の検査にも名前系(`*.dylib`/`*.app`/`*.framework`)を追加

## [0.0.2] - 2026-09-12

版番号を入れる前のビルドに遡って付けた番号(tag `xioslite-v0.0.2`, commit `2957464`)。**実機未テスト**。

### Fixed
- 実行ファイルの私的コピーが毎回失敗していた(自分の横取り関数を呼んで内部パスまで変換していた)。
  これが「同じ実行ファイルの 2 回目で引数解析が壊れる」原因
- `readdir` で `.lc` を剥がして見せる(GTK のプラグイン探索が通るように)
- `libpcre2-8` の `SLJIT_UPDATE_WX_FLAGS` 欠落を libLCsys に no-op で補完。
  上流パッケージのビルド不良で、放置すると glib 経由で GTK が全滅する
- LiveContainer 導入時の「署名できないファイル」警告。stub を `<path>.lc` に改名し、
  入れ子の `.app`(com.max.xios)を閉包から除外

### Removed
- `pkg-config --list-all` を G1 の関門から外した(libpcre2 の検証用に参考実行のみ残す)

## [0.0.1] - 2026-09-12

版番号を入れる前の最初のビルド(tag `xioslite-v0.0.1`, commit `e6dbd2f`)。**G1 の初回実機テストに使用**。

### Added
- G1 の骨格: libLCsys.dylib(libSystem を再エクスポートし open/stat/readdir/exit/fork/dlopen 等を横取り)、
  procd(Linux の実行ファイルを MH_DYLIB 化して dlopen し、`LC_MAIN` をスレッドで呼ぶ)、コンソール UI
- xiOS/Procursus の 112 パッケージ(Frameworks/ 408 本 + jb/ データ 150MB)を CI の stage ジョブで同梱

### Known issues(この版の実機テストで発見し、0.0.2 で修正)
- 同じ実行ファイルの 2 回目の実行で引数解析が壊れる(`invalid option` で失敗)
- `pkg-config` が欠落シンボルで読み込めない
- 取り込み時に約 150 件の「署名できないファイル」警告が出る
