# ios-apps — LiveContainer 向け iOS アプリ量産リポジトリ

瑠人さんから「iOSアプリを作ってください」と言われたら、ここで作る。Windows には iOS
ビルド環境がないので、GitHub Actions の macOS ランナー(Xcode + XcodeGen)でビルドし、
未署名 .ipa を Syncthing 共有フォルダ経由で iPhone 14 Pro の LiveContainer に渡す。

## 手順(毎回これ)

1. `.\tools\new-app.ps1 <Name>` で `apps/<Name>/` を雛形から作る(PascalCase、英数字のみ)
2. `apps/<Name>/Sources/` に SwiftUI で実装する。`project.yml` は必要なときだけ触る
   (権限が要るなら `info.properties` に `NSCameraUsageDescription` 等を足す)
3. `.\tools\build.ps1 <Name>` — commit/push → workflow_dispatch → 完了待ち →
   `dist/<Name>.ipa` と `C:\Users\rutoi\SharedFolder\ios-apps\<Name>.ipa` に配置(開発ビルド、版 0.0.YYYYMMDD)
4. 瑠人さんに取り込み方を伝える。初回は `build.ps1` が出す URL(`tools/serve-ipa.py`、LAN / Tailscale)を
   LiveContainer の + に貼る。**2 回目からはアプリ内の「更新」ボタン**で取り込める(XiOSDesktop は
   `Sources/Updater.swift` で実装済み。他のアプリにも同じ仕組みを載せられる)。SharedFolder 経由は
   Syncthing(SyncTrayzor)が Windows 側で動いているときだけ
5. 実機で使ってもらう版は **リリース**として出す: `apps/<Name>/CHANGELOG.md` の `[Unreleased]` を書き、
   `.\tools\build.ps1 <Name> -Release X.Y.Z`。タグ `<name>-vX.Y.Z` push で CI が GitHub Release を発行する。
   版の決まり(kioku と同じ Semantic Versioning、ビルド番号 = run 番号、画面に `vX.Y.Z (build N) <commit>`)は
   `docs/VERSIONING.md`。LiveContainer の一覧に出る版で、どの ipa が入っているかを見分ける

## 制約

- 署名しない(LiveContainer が自分の証明書で署名し直す)。`CODE_SIGNING_ALLOWED=NO` 固定
- LiveContainer 内で動くので、通知・ウィジェット・App Extension・Sign in with Apple・
  バックグラウンド常駐は使えない。画面/通信/ファイル保存/位置情報(要 usage description)は可
- iOS 26 実機、Deployment Target 16.0。SDK はランナーの最新 Xcode に従う
- private リポジトリの macOS ランナーは無料枠 200 分/月程度(1 ビルド 3〜5 分)。
  足りなくなったら public にするか、ビルド頻度を落とす
- ビルド失敗時は `build.ps1` が `build.log` の末尾を出す。全文は Actions の artifact
  `<Name>-build.log`

## 構成

- `.github/workflows/build.yml` — list(apps/ 列挙) → build(matrix, macos-latest)
- `templates/app/` — 雛形(`__APP__` / `__APP_LOWER__` を置換)
- `tools/new-app.ps1`, `tools/build.ps1`
- `apps/<Name>/` — 各アプリ。`build/`, `*.xcodeproj`, `Payload/`, `*.ipa` は生成物で無視
