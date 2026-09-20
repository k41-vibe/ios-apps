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
| `Sources/Relay.swift` | 127.0.0.1 の HTTP 受け口。中身を URLSession で x.com から取って返す |
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

## 中継(スクリーンタイムの時間制限を外す)

スクリーンタイムの Web 判定は WebKit の読み込み処理の中で呼ばれ、判定そのものは
ScreenTimeAgent が持つ。`x.com` を直接開くとここで拒否が返る。

中継を入にすると、WKWebView は `http://127.0.0.1:<port>/…` を開く。中身は `Relay` が
URLSession で `https://x.com/…` から取って返す。URLSession は CFNetwork へ直接入るので、
WebKit の判定を通らない。

| 場所 | 扱い |
|---|---|
| 相対 URL(`/i/api/…`) | 127.0.0.1 に解決するので中継を通る |
| JS 内の絶対 URL(`https://x.com/…`) | `Relay.patchScript` が `fetch` / `XHR` / `sendBeacon` を差し替えて向け直す |
| ページ内の絶対リンク | `WebModel.decidePolicyFor` が手前で止めて 127.0.0.1 に入れ替える |
| 3xx の `Location` | `Relay.toLocal` が 127.0.0.1 に書き換える(リダイレクトは追わない) |
| `abs.twimg.com` 等 | 遮断対象でないので素通しする |
| cookie | WKWebView が 127.0.0.1 のものとして持つ。`Domain` と `Secure` を外して返す |

待ち受けは 127.0.0.1 だけに縛ってある。同じ Wi-Fi の他の機械から使われると、この端末を
経由した x.com への出口になるため。認証情報は中継側に持たず、cookie は WKWebView から
転送するだけなので、同じ端末の別アプリがこのポートを叩いてもログイン済みの応答は取れない。

### 未確認

iOS の Web フィルターには、URL の照合だけでなく応答の中身を見て遮断する経路が歴史的にあった。
これが今も動いていれば、中継を通しても遮断される。実機で開いて確かめる。

### 通らないもの

- WebSocket(`wss://x.com`)。中継は HTTP だけを扱う
- `Content-Security-Policy` を落としている。`upgrade-insecure-requests` が入ると
  127.0.0.1 へ繋がらなくなるため(`Relay.dropFromResponse`)
- Service Worker は登録させない。中継と噛み合わないため
- `Transfer-Encoding: chunked` の本文は 411 を返す

## 既知の弱点

- X が画面を改装すると `data-testid` が変わり、掃除が効かなくなる。設定の「追加 CSS」で足す
- 通知・共有シートなど、iOS の機能が要るところは web の範囲でしか動かない
