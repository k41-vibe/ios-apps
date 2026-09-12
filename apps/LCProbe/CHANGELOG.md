# Changelog — LCProbe

LiveContainer(JIT-less)の実機能力を測る計測アプリ。結果は `tools/xios/G0-results.md`。
書式は Keep a Changelog、手順は `docs/VERSIONING.md`。

## [Unreleased]

### Added
- 版番号・ビルド番号・コミットを画面に表示(`AppVersion`)

### Changed
- **LCProbeS を統合して廃止**。dylib の本数は `postbuild.sh` の `LCPROBE_DYLIBS`(既定 100)で変える。
  段階(tier)も実際に入っている本数から自動で決める

### Fixed
- 「runtime dlopen OK」を「JIT が有効」と読める文言にしていた。実際は署名済み dylib のコピーが
  読めただけで、JIT の有無とは無関係(実機で確認済み)。文言と注記を修正

### Known issues
- 「JIT/W^X」は JIT 無しの環境では、書いたコードの実行でプロセスごと落ちる(設計どおり。ログは直前まで残る)
- 「メモリ上限」はアプリを強制終了させる計測(設計どおり。ログはファイルに残る)

## [0.0.2] - 2026-09-11

dylib 100 本版(当時は LCProbeS という別アプリ。tag `lcprobe-v0.0.2`, commit `5f4a866`)。
**G0 の計測を取った版**。メモリ上限 4080MB / dlopen 約 12ms 本 / IOSurface→Metal 60fps /
スレッド上限 1015 / JIT 不可を実測。

## [0.0.1] - 2026-09-11

dylib 800 本版(tag `lcprobe-v0.0.1`, commit `70e28e7`)。LiveContainer の署名工程が耐えられず
実機で開けなかった。この失敗自体が「署名は本数に上限がある」という G0 の結果になった。
既定を 100 本にした根拠。
