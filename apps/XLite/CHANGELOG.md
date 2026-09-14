# XLite の変更履歴

[Keep a Changelog](https://keepachangelog.com/ja/1.1.0/) 形式。版の決まりは `docs/VERSIONING.md`。

## [Unreleased]

### Added

- x.com をそのまま開く WKWebView の殻。cookie は残るのでログインは保たれる
- 画面の掃除(設定で個別に切れる): プロモーション投稿、右の段、Grok の導線、
  Premium 勧誘、「アプリで開く」の帯。起動後の最初の1回だけ「フォロー中」に寄せる
- 追加 CSS の欄。実機で画面を見ながら隠す対象を足せる
- cookie の取り込み(auth_token / ct0)。web のログイン画面が弾かれたときの逃げ道
- User-Agent の差し替え。既定は実機と同じ iOS 26 の Safari
- アプリ内アップデートとログ送信(XiOSDesktop と同じ仕組み)
