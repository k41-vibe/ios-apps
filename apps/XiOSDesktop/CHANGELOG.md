# Changelog — XiOSDesktop

脱獄なしの iPhone で Linux デスクトップのユーザー空間をネイティブ速度で動かすアプリ。
実験用コンソールの [XiOSLite](../XiOSLite/CHANGELOG.md) から画面を出す段で分岐させた。
書式は [Keep a Changelog](https://keepachangelog.com/ja/1.1.0/)、版番号は [Semantic Versioning](https://semver.org/lang/ja/)。
リリース手順は `docs/VERSIONING.md`。実機の計測値は `tools/xios/G0-results.md`、
コンポジタとの通信仕様は `tools/xios/iosc-host-protocol.md`。

## [Unreleased]

## [0.1.1] - 2026-09-12

### Added
- **`ios-inputd` を土台に組み込んだ**。xiOS の設計では、アプリは iosc の入力ソケットに
  直結しない。間に `ios-inputd` が居て、そこが入力メソッドとしてコンポジタに登録され、
  文字を今選ばれている窓に流し込む(バイナリ内の
  `registered as input-method proxy` / `commit_string %zu bytes (serial %u)` /
  `%zu bytes of text with no focused field; dropped`)。実機で出ていた
  `improxy=0 (local fallback)` の improxy はこれのこと。**真ん中を飛ばして直結していたのが
  文字が出なかった理由**。iosc のソケットとは別の場所で待たせる(同じだと
  `something is already listening there` で起動を断られる)
- **「セッション開始」ボタン**。土台(iosc + 入力メソッド + 壁紙)を立てて、
  バーとドックを起こして画面へ行く。それだけ

### Changed
- **ホスト側の役割を絞った**。何を起動するか・どう並べるかは xiOS 自身のシェルの仕事で、
  こちらが SwiftUI のボタンで作るものではない。部品ごとのボタンは「診断用」の
  折りたたみに移した。ホストが受け持つのは画面・指・土台の 3 つだけにする

## [0.1.0] - 2026-09-12

### Added
- **`posix_spawn` / `posix_spawnp` を本物にした**。今までは記録して `ENOSYS` を返すだけの
  空実装だったが、procd に流してスレッドとして起こすようにした。`fork` が真似できないのは
  「1 回呼んで 2 回返る」からで、`posix_spawn` にはその問題が無いので代われる。
  `posix_spawnp` は `/var/jb/usr/local/bin` → `/var/jb/usr/bin` → `/var/jb/bin` の順に探す
- **アプリを 3 つ倉庫から足した**(112 → 124 パッケージ、約 9MB 増):
  - `gnome-text-editor` — GTK4 のテキストエディタ。**打った文字がその場に出る窓**。
    GTK4 本体は nautilus 経由ですでに入っていたので、追加は 4 本だけで済んだ
  - `mesa-demos` — `es2gears_wayland`(回る歯車)。dbus も子プロセスも要らないので、
    「動く絵が届くか」だけを見るのに一番向いている
  - `xios-fonts-noto` — **フォント**。今までアプリに 1 つも入っていなかった
- **`dbus-daemon --session --nofork`** を起こすボタン。`--nofork` があるので分身を作らず
  そのまま動く。つまり iOS が禁じている `fork` を一度も踏まない。
  `DBUS_SESSION_BUS_ADDRESS` は先に環境へ入れてある(ソケット名は `sun_path` 104 バイトに
  収めるため 1 文字)
- 「歯車」「dbus」「エディタ」のボタン。「全部」にも歯車を入れた

## [0.0.9] - 2026-09-12

### Fixed
- **自前のボタンが ioscbar の上に被っていた**(実機 2026-09-12)。コンポジタの一番上には
  バーが居るので、右下の空きに小さく置き直した(ドックは中央寄せなので右下は空いている)。
  文字のボタンからアイコンにして、半透明にした
- **同じクライアントを二重に起こさないようにした**。`iosc-client` が 2 枚重なって
  窓が斜めにずれて並び、「全部ぐちゃぐちゃ」に見えていた
- **「全部」から一覧(ioscoverview)を外した**。これは画面全体を覆う切り替え画面なので、
  出すと壁紙もバーも窓も隠れる。単体のボタンからだけ出す

## [0.0.8] - 2026-09-12

### Added
- **「全部」ボタン**。iosc を起こしてから、繋がる相手を端から全部起こして画面へ行く。
  どれが出てどれが出ないかを 1 回で見るための試験用。端末(foot)は擬似端末が開けないので
  必ず失敗するが、それも見たいので入れてある

### Fixed
- **下端も iOS に譲るようにした**。ホームインジケータ(下の横棒)が乗っている範囲は
  指で触りにくく、ドックを置いても棒と重なる。上下とも安全領域を測って `-logical` から引く
- **クライアントが iosc 無しで起動できてしまっていた**。「ソケットのファイルがある」ことを
  起動している証拠にしていたが、前回終了したときの残骸でもファイルは在る。実機 2026-09-12 で
  「窓」と「ドック」が `wl_display_connect failed` で落ちたのはこれ。iosc が生きているかを
  直接見るようにし、動いていなければ先に起こす。起動時に前回の残骸も掃除する

## [0.0.7] - 2026-09-12

### Added
- **「窓」「ドック」「一覧」**のボタン。xiOS に付いている残りのクライアント。
  `iosc-client` は xdg_toplevel を 1 枚出してフレームを commit するだけの最小の相手で、
  子プロセスも dbus も要らない。**普通のアプリの窓が出るか**を確かめるためのもの

### Changed
- タッチは TOUCH だけを送るようにした(MOTION を併せて送るのをやめた)。本物のタッチ画面も
  そうで、ポインタ側は iosc が自分で合成する(ioscdock に
  `suppress synthetic pointer after touch` という重複抑制がある)。こちらからも送ると二重になる

## [0.0.6] - 2026-09-12

### Added
- **タッチが iosc に届くようになった**(計画の G2-c)。`native/xinput.c` が入力ソケットに繋ぎ、
  画面の指を出力ピクセルに戻して TOUCH レコードとして流す(仕様 6 節)。10 本までスロットを
  割り当てて追跡する。HELLO は双方向で、`window_id==1` かつ他が全部 0 でないと切断される。
  サーバーから来る TRAITS / HAPTIC は読み捨てる専用スレッドを 1 本置いた(放置すると詰まる)
- **「キーボード」ボタン**。iOS のキーボードを出し、文字は TEXT、改行と後退は KEY(keysym
  0xff0d / 0xff08)で送る。keysym の対応表を持たずに済ませるため、普通の文字は TEXT に寄せた

### Fixed
- **ロケールを決め打ちにするのをやめた**。`en_US.UTF-8` はこのサンドボックスから引けず
  (実機: `setlocale: cannot change locale (en_US.UTF-8): No such file or directory`)、
  foot が起動直後に `setlocale() failed` で転んでいた。起動時に `en_US.UTF-8` →
  `UTF-8` → `C.UTF-8` → `C` の順に実際に `setlocale` を通して、通った名前を
  `LANG` / `LC_CTYPE` / `LC_ALL` の 3 つに揃える。ホストとゲストは同じ libSystem を
  使うので、ホストで通った名前はゲストでも通る

## [0.0.5] - 2026-09-12

### Added
- **デスクトップ部品(Storage / Memory / Load / Session)を出す**。出ていなかったのは
  故障ではなく、ioscbg が設定ファイルを読めないと 1 つも描かない作りだったから。既定の置き場
  `/var/mobile/Library/Preferences/com.max.iosc-widgets.conf` はこのサンドボックスには無い。
  書式は逆アセンブルで確かめた `名前 x y 有効` の 4 つ組(`fscanf(f, "%31s %d %d %d")` が
  4 を返したときだけ採用、3 番目は 0 以外で表示)。自前の設定を書いて `IOSC_WIDGET_CONFIG` で指す
- `statfs` / `statvfs` の横取り。Storage 部品が空き容量をこれで読むので、経路変換を
  通さないと `/var/jb` を本物の根として見に行って失敗する

### Fixed
- **上端を iOS に譲るようにした**。Dynamic Island とステータスバーが乗っている範囲に
  描いても、コンポジタの一番上に置かれる ioscbar が潜って読めない。起動時に安全領域を測り、
  `-logical` をその分だけ低くして、表示側も同じ範囲に置く(拡大縮小は 1:1 のまま)
- `LC_ALL=C` が `LANG` を上書きしていた。v0.0.4 で `LANG` を直しても効いていなかった

## [0.0.4] - 2026-09-12

### Fixed
- **`fopen` には Darwin では 2 つの名前があり、片方しか横取りしていなかった**。`<stdio.h>` が
  `__DARWIN_ALIAS_STARTING` で `_fopen` と `_fopen$DARWIN_EXTSN` を切り替えるので、
  どちらで呼ばれるかはパッケージのビルド設定次第になる。ipa 内の 308 本を走査したところ
  **132 本が `$DARWIN_EXTSN` の側**で、その中に libxkbcommon が居た。だから v0.0.2 で
  `fopen` を足してもキーボードのデータは読めないままだった
  (実機: `Couldn't find file "rules/evdev"`。ファイルは 47640 B で確かに入っている)。
  両方の名前を定義した。`realpath` は最初から両方あったので、見落としは `fopen` だけ
- 同じ取りこぼしを二度とやらないように、ビルド時の関門を足した
  (`tools/xios/audit_aliases.py`: libLCsys が基本名を定義しているのに `$` 付きの別名を
  落としていたらビルドを止める)
- **「画面」を開くと背景クライアントも自動で起こすようにした**。コンポジタは繋いでくる相手が
  居ないと描くものが無いので、「画面」→「背景」の順に押すと 1 フレームも出ない
  (実機 2026-09-12 がまさにこれで、白い背景のままだった)。順番で結果が変わる作りが悪い
- iosc が動いているのに「iosc を起動」を押しても 2 本目を起こさないようにした。2 本目は
  `wayland-0.lock` を取れずに必ず失敗するが、そこに至るまでに IOSurface 3 枚と ANGLE の
  初期化を済ませるので約 40MB を捨てていた
- ゲストの `LANG` を `C.UTF-8` から `en_US.UTF-8` に変えた。`C.UTF-8` は glibc の綴りで
  Darwin の libc には無く、`setlocale` が黙って `C` に落ちていた

### Added
- DIRTY を待たずに、握手で受け取った面を 1 枚そのまま貼っておくようにした。
  「何も出ない」と「出ているが通知が来ない」を実機で切り分けるため
- 何も描けないまま空回りしたときに理由を 1 度だけログに出す(pipeline / drawable /
  DIRTY 未着 のどれか)

## [0.0.3] - 2026-09-12

### Fixed
- **アプリが這っていた原因はログの書き方**。1 行ごとに `fsync` し、さらに画面用の文字列へ
  毎行追記していた(SwiftUI が毎回全文を描き直す)。経路変換の追跡は毎秒数千行出るので致命的だった。
  書き込みをまとめ、`fsync` は 256KB ごと、画面用の文字列は 12 万字で頭を切る
- 経路変換の追跡を既定で切った(「詳細ログ」のスイッチで入れる)

### Added
- **Wayland クライアントを起こすボタン**。コンポジタは繋いでくる相手が居ないと描くものが無いので、
  画面が黒いのは正常だった。`背景`(ioscbg)が一番軽い相手で、プロセス生成も dbus も要らない。
  `バー`(ioscbar、cairo と pango で文字を描く)、`端末`(foot。子プロセスを作れないので
  今は失敗する見込み。G3 で解決)も並べた

## [0.0.2] - 2026-09-12

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
