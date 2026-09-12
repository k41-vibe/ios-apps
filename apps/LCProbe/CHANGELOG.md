# Changelog — LCProbe

LiveContainer(JIT-less)の実機能力を測る計測アプリ。結果は `tools/xios/G0-results.md`。
書式は Keep a Changelog、手順は `docs/VERSIONING.md`。

## [Unreleased]

### Added
- 版番号・ビルド番号・コミットを画面に表示(`AppVersion`)

### Changed
- **LCProbeS を統合して廃止**。dylib の本数は `postbuild.sh` の `LCPROBE_DYLIBS`(既定 100)で変える。
  段階(tier)も実際に入っている本数から自動で決める
- 旧タグ `lcprobe-v1`(dylib 800 本)は LiveContainer の署名工程が耐えず実機で開けなかったため、既定を 100 にした。
  旧タグ `lcprobes-v1`(LCProbeS、100 本)が G0 の計測に使った版

### Fixed
- 「runtime dlopen OK」を「JIT が有効」と読める文言にしていた。実際は署名済み dylib のコピーが読めただけで、
  JIT の有無とは無関係(実機で確認済み)。文言と注記を修正

### Known issues
- 「JIT/W^X」は JIT 無しの環境では、書いたコードの実行でプロセスごと落ちる(設計どおり。ログは直前まで残る)
- 「runtime dlopen」は署名済み dylib をコピーするため、JIT-less でも成功する(JIT の有無の判定には使えない)
