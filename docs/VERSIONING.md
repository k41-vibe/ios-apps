# 版管理とリリースの決まり(kioku 方式)

[k41-vibe/kioku](https://github.com/k41-vibe/kioku/releases) と同じ流儀。
違いは「1 リポジトリに複数アプリ」なので、タグにアプリ名の接頭辞が付くことだけ。

| もの | kioku | ios-apps(ここ) |
|---|---|---|
| タグ | `v0.3.0` | `xioslite-v0.1.0`(アプリ名を前に付ける) |
| リリース名 | `Kioku v0.3.0` | `XiOSLite v0.1.0` |
| 単位 | **1 版 = 1 リリース** | 同じ |
| 資産 | `Kioku.ipa`(固定名) | `XiOSLite.ipa`(固定名) |
| 本文 | 要約 + sha256 | 要約(CHANGELOG から自動) + sha256 |

**1 版 = 1 リリース**なので、リリース一覧がそのまま版の履歴になる。資産名は固定で、
どの版かはリリース名とタグで分かる。取り込んだ後は LiveContainer の一覧とアプリ画面の
`vX.Y.Z (build N) <commit>` で確認する。

## 版番号

- **Semantic Versioning** `X.Y.Z`。破壊的変更で X、機能追加で Y、修正で Z を上げる
- `CFBundleShortVersionString`(LiveContainer の一覧に出る版)= `X.Y.Z`
- `CFBundleVersion`(ビルド番号)= GitHub Actions の run 番号。同じ版でも建て直せば必ず変わる
- `LCGitCommit` = コミット番号。アプリ画面に `vX.Y.Z (build N) <commit>` として出る

## 2 種類のビルド

| 種類 | 起動方法 | 版番号 | 成果物の置き場 |
|---|---|---|---|
| **開発ビルド** | `.\tools\build.ps1 <App>` | `0.0.YYYYMMDD` (build N) | `dist/` と SharedFolder のみ。Release は作らない |
| **リリース** | `.\tools\build.ps1 <App> -Release X.Y.Z` | `X.Y.Z` (build N) | 上に加えて GitHub Release `<app>-vX.Y.Z` |

LiveContainer に入っている版が `0.0.…` なら開発ビルド、`0.1.0` のような番号ならリリース版。

## リリースの手順

1. `apps/<App>/CHANGELOG.md` の `## [Unreleased]` に変更点が書いてあることを確認する
2. `.\tools\build.ps1 <App> -Release X.Y.Z` を実行する。スクリプトが
   - CHANGELOG の `[Unreleased]` を `[X.Y.Z] - YYYY-MM-DD` に確定させてコミット
   - タグ `<app小文字>-vX.Y.Z` を打って push
   - タグ push で CI が走り、版番号を焼き込んだ `<App>.ipa` を GitHub Release に添付
     (本文 = CHANGELOG の該当節 + sha256 + build 番号 + commit)
   - 完了後、同じ ipa を `dist/` と SharedFolder にも置く
3. 瑠人さんに Release の URL と「LiveContainer で版番号 X.Y.Z を確認」と伝える

タグは消さない。資産が消えてもソースからは再現できる。

## CHANGELOG

各アプリに `apps/<App>/CHANGELOG.md`([Keep a Changelog](https://keepachangelog.com/ja/1.1.0/) 形式)。
節は `Added / Changed / Fixed / Removed`。実機で確認した事実(G0/G1 の計測値など)は
`tools/xios/*.md` に書き、CHANGELOG には「何が変わったか」だけを書く。

## これまでの版

版番号を入れる前のビルドにも遡って `0.0.n` を付け、タグ・リリース・資産名を揃えた。

| リリース | コミット | 内容 |
|---|---|---|
| `xioslite-v0.1.0` | `029410c` | **G1 関門を実機で突破した版**(6 項目すべて成功、3 周とも安定) |
| `xioslite-v0.0.2` | `2957464` | 私的コピー修正・署名エラー根絶。実機未テスト |
| `xioslite-v0.0.1` | `e6dbd2f` | G1 の骨格。**G1 初回実機テストに使用** |
| `lcprobe-v0.0.2` | `5f4a866` | dylib 100 本(当時の LCProbeS)。**G0 の計測を取った版** |
| `lcprobe-v0.0.1` | `70e28e7` | dylib 800 本。署名工程が耐えず実機で開けず |

移行中に一時的に使った `xioslite` / `lcprobe`(資産を積み上げる方式)と、
その前の `xioslite-g1` / `xioslite-g1.2` / `lcprobe-v1` / `lcprobes-v1` は削除済み。
