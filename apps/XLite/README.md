# XLite

x.com を LiveContainer の中で快適に読むための、薄い殻。

## なぜ web なのか

X は 2025 年 10 月から端末証明(App Attest)でログインを検査している。証明には署名の
Team ID と bundle ID が入るので、サイドロードした公式アプリや改造版は、署名を付け替えた
時点で必ず弾かれる(「公式Xアプリを使用して続行するか、しばらくしてからやりなおしてください」)。
2026 年 9 月時点で改造版の現行メンテナも「当面ログインは無理」と結論を出している。

一方 **web のログインは生きている**。だからこのアプリは API もネイティブのログインも使わず、
本物の x.com をそのまま開き、邪魔なものだけ CSS と JS で消す。

## 構成

| ファイル | 役割 |
|---|---|
| `Sources/WebModel.swift` | WKWebView を1つだけ持つ。UA、cookie、画面遷移の振り分け |
| `Sources/Cleaner.swift` | 流し込む JS。CSS を貼り、MutationObserver で広告の行を畳む |
| `Sources/ContentView.swift` | 画面と下のバー |
| `Sources/SettingsView.swift` | 掃除の切り替え、cookie、UA、更新、ログ |
| `Sources/Updater.swift` | PC の配布サーバーから ipa を取って自分を入れ替える(XiOSDesktop から流用) |

## 広告の消し方

x.com の class 名は毎回変わるので、当てにできるのは `data-testid` だけ。
`[data-testid="cellInnerDiv"]`(タイムラインの1行)ごとに、

1. 中に `[data-testid="placementTracking"]` があるか
2. 短い `span` がまるごと「プロモーション」等と一致するか

のどちらかなら畳む。文字の部分一致は本文に同じ語があると誤爆するので使わない。

## ログインが弾かれたら

設定 → ログイン に PC の Chrome から取った `auth_token` と `ct0` を貼る
(F12 → Application → Cookies → https://x.com)。これはパスワードと同じ重みの値。

## 既知の弱点

- X が画面を改装すると `data-testid` が変わり、掃除が効かなくなる。設定の「追加 CSS」で足す
- 通知・共有シートなど、iOS の機能が要るところは web の範囲でしか動かない
