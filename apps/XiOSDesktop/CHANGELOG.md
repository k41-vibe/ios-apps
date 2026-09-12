# Changelog — XiOSDesktop

脱獄なしの iPhone で Linux デスクトップのユーザー空間をネイティブ速度で動かすアプリ。
実験用コンソールの [XiOSLite](../XiOSLite/CHANGELOG.md) から画面を出す段で分岐させた。
書式は [Keep a Changelog](https://keepachangelog.com/ja/1.1.0/)、版番号は [Semantic Versioning](https://semver.org/lang/ja/)。
リリース手順は `docs/VERSIONING.md`。実機の計測値は `tools/xios/G0-results.md`、
コンポジタとの通信仕様は `tools/xios/iosc-host-protocol.md`。

## [Unreleased]

### Fixed
- **iOS では `task_for_pid()` が自分自身の pid に対しても通らない**(実機 2026-09-12:
  `xios: task_for_pid(1199) failed: 0x5 ((os/kern) failure)`)。macOS とは違う点で、
  「同一プロセスなら権限なしで成立する」という当初の読みが外れていた。iosc は相手の
  task port を取ってから IOSurface のポートを送るので、これが画面の出ない直接の原因だった。
  `task_for_pid` を横取りし、自分の pid なら `mach_task_self()` を返す
  (iosc の libSystem 依存は relink 済みなので、この定義が割り当たる)
- コンポジタが bind してから listen するまでに GPU 初期化が挟まり、ソケットが見えていても
  少しの間 `ECONNREFUSED` が返る。繋がるまで 200ms 間隔で最大 10 秒待つようにした

### Added
- `LCSYS_TRACE=1` を既定で有効化。経路変換を 1 件ずつログに出す
  (xkb がどのパスを要求して失敗しているかを実機で見るための診断)

## [0.0.1] - 2026-09-12

XiOSLite v0.2.1 を土台に、**画面を出す部分**を足した最初の版。`com.rutoi.xiosdesktop` として
XiOSLite とは別に入る(両方を同時に iPhone へ入れられる)。

### Added
- **ddx クライアント** `native/xsurface.c`。コンポジタ `iosc` に繋いで画面を受け取る側
  (`tools/xios/iosc-host-protocol.md` 2〜5 節の実装)。握手は仕様どおりの順番で、
  **mach メッセージをソケットの返事より先に**受ける。`caps=STREAM_V2` で試し、駄目なら `caps=0`。
  DIRTY 1 回につき RELEASED 1 回(まとめない。返さないと 3 枚とも塞がって画面が固まる)
- **フェンスの受け渡し** `lcsys_shared_event_for_token()`。iosc が登録したのと同じプロセス内
  テーブルからトークンを引いて `id<MTLSharedEvent>` を返す(root の XPC ブローカーの代わり)
- **画面** `Sources/ScreenView.swift`。`MTKView` にコンポジタの IOSurface を貼る
  (面 id ごとにテクスチャを 1 枚だけ作って使い回す)。描く前に提示フェンスを待ち、
  present 後に解放イベントへ署名したコマンドバッファを **commit してから** RELEASED を送る
- 「画面」ボタン。コンポジタが居なければ起こし、ソケットができるまで最大 10 秒待って全画面へ。
  右上の「コンソール」でいつでもログに戻れる

### 土台(XiOSLite から引き継いだもの)
- Linux の実行ファイルをアプリ内スレッドとして走らせる `procd`(G1 実機突破済み)
- `/var/jb` をアプリ内に読み替える経路変換層 `pathmap`(`fopen` の穴を塞いだ版)
- `metal-event-broker` の肩代わり `xpcshim.m`(これが無いとコンポジタは起動時に落ちる)
- xiOS/Procursus の 112 パッケージ(Frameworks 408 本 + データ 150MB)

### Known issues
- タッチとキーボードはまだコンポジタに届かない(次の段)
- 画面に出るのはコンポジタの背景だけ。アプリを載せるのはその次の段
- 実行ファイルの像は解放できないので、コマンドを起こすたび約 3MB 増える
