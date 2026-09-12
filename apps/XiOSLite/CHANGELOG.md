# Changelog — XiOSLite

書式は [Keep a Changelog](https://keepachangelog.com/ja/1.1.0/)、版番号は [Semantic Versioning](https://semver.org/lang/ja/)。
リリース手順は `docs/VERSIONING.md`。実機の計測値は `tools/xios/G0-results.md`。

## [Unreleased]

### Added
- G1 の骨格: libLCsys.dylib(libSystem を再エクスポートし open/stat/readdir/exit/fork/dlopen 等を横取り)、
  procd(Linux の実行ファイルを MH_DYLIB 化して dlopen し、LC_MAIN をスレッドで呼ぶ)、コンソール UI
- xiOS/Procursus の 112 パッケージ(Frameworks/ 408 本 + jb/ データ 150MB)を CI の stage ジョブで同梱
- 版番号・ビルド番号・コミットを画面と起動ログに表示(`AppVersion`)

### Fixed
- 同じ実行ファイルの 2 回目の実行で引数解析が壊れる(dyld が同じ像を返し、gnulib getopt の静的状態が残る)
  → 起動ごとに実行ファイルの私的コピーを `$TMPDIR/procd/` に作って dlopen。ゲスト自身の `optind` も 0 に戻す
- 私的コピーが毎回失敗していた(自分の横取り関数を呼んで内部パスまで変換していた)→ 実関数を直接呼ぶ
- `libpcre2-8` の `SLJIT_UPDATE_WX_FLAGS` 欠落(上流の不良。glib 経由で GTK が全滅する)→ libLCsys に no-op で補完
- LiveContainer 導入時の「署名できないファイル」警告 → 目印ファイルを `<path>.lc` に改名し、入れ子の
  `.app`(com.max.xios)を閉包から除外。`readdir` で `.lc` を剥がして見せる

### Removed
- `pkg-config --list-all` を G1 の関門から外した(libpcre2 の版ずれ検証用に参考実行のみ残す)
