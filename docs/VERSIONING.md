# 版管理とリリースの決まり(kioku 方式)

kioku(k41-vibe/kioku)と同じ流儀に揃える。違いは「1 リポジトリに複数アプリ」なので、
タグにアプリ名の接頭辞が付くことだけ。

## 版番号

- **Semantic Versioning** `X.Y.Z`。破壊的変更で X、機能追加で Y、修正で Z を上げる
- `CFBundleShortVersionString`(LiveContainer の一覧に出る版)= `X.Y.Z`
- `CFBundleVersion`(ビルド番号)= GitHub Actions の run 番号。同じ版でも建て直せば必ず変わる
- 各アプリの画面にも `vX.Y.Z (build N) <commit>` を出す。実機でどの ipa が入っているか迷わないため

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
   - タグ `<app小文字>-vX.Y.Z`(例 `xioslite-v0.1.0`)を打って push
   - タグ push で CI が走り、版番号を焼き込んだ ipa を GitHub Release に添付(本文 = CHANGELOG の該当節 + sha256 + ソースへのリンク)
   - 完了後、同じ ipa を `dist/` と SharedFolder にも置く
3. 瑠人さんに Release の URL と「LiveContainer で版番号 X.Y.Z を確認」と伝える

## タグとリリースの命名

- タグ: `<app小文字>-vX.Y.Z`(`xioslite-v0.1.0`, `lcprobe-v1.0.0`)
- Release 名: `<App> vX.Y.Z`(`XiOSLite v0.1.0`)
- 資産: `<App>.ipa` 1 つ(版はタグと本文で分かる)。sha256 を本文に載せる

## CHANGELOG

各アプリに `apps/<App>/CHANGELOG.md`([Keep a Changelog](https://keepachangelog.com/ja/1.1.0/) 形式)。
節は `Added / Changed / Fixed / Removed`。実機で確認した事実(G0/G1 の計測値など)は
`tools/xios/*.md` に書き、CHANGELOG には「何が変わったか」だけを書く。

## 移行前の Release(2026-09-11〜12)

版番号を入れる前のビルドは、アプリごとに 1 つの「旧ビルド」リリースへ統合済み。
資産名で中身が分かるようにしてある(コミット番号、または特徴)。

| タグ | 中身 |
|---|---|
| `xioslite` | `XiOSLite-2957464.ipa`(9/12・実機未テスト)、`XiOSLite-e6dbd2f.ipa`(9/11・G1 初回テストに使用) |
| `lcprobe` | `LCProbeS-100dylibs.ipa`(**G0 の計測を取った版**)、`LCProbe-800dylibs.ipa`(署名工程が耐えず実機で開けず) |

統合前の `xioslite-g1` / `xioslite-g1.2` / `lcprobe-v1` / `lcprobes-v1` は削除済み。
以後は本書の方式(`<app>-vX.Y.Z`、1 リリース = 1 版)のみ。
