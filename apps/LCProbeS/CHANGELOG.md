# Changelog — LCProbeS

LCProbe の dylib 100 本版(コードは LCProbe と同一)。LCProbe に統合予定。手順は `docs/VERSIONING.md`。

## [Unreleased]

### Changed
- 2026-09-12 に一度 LCProbe へ統合して廃止したが、別アプリのまま残すことにして復元した。
  dylib 100 本の固定構成で、G0 の計測を取ったときの姿をそのまま保つ

### Fixed
- 「runtime dlopen OK」を「JIT が有効」と読める文言にしていた。実際は署名済み dylib のコピーが
  読めただけで、JIT の有無とは無関係(実機で確認済み)

### Added
- 版番号・ビルド番号・コミットを画面に表示(`AppVersion`)

### Changed
- 旧タグ `lcprobes-v1` が G0 の計測(2026-09-12)に使った版
