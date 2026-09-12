# Changelog — XiOSLite

書式は [Keep a Changelog](https://keepachangelog.com/ja/1.1.0/)、版番号は [Semantic Versioning](https://semver.org/lang/ja/)。
リリース手順は `docs/VERSIONING.md`。実機の計測値は `tools/xios/G0-results.md`。

## [Unreleased]

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
