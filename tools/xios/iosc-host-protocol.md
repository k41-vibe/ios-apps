# iosc とホスト(XiOSLite)の通信仕様(2026-09-12 調査)

出典: https://github.com/MaxLeiter/jailbreak `x11/`(MIT)。行番号は調査時点。
ddx サーバーの実体は `x11/linux-build/patches/xios/xios_surface.c`(`x11/wayland/xios_surface.c` は存在しない)。
`x11/wayland/xios_canvas.c` は **native モード用の別プロトコル**なので混同しない。

## 結論(実装方針)

1. **同一プロセスでも mach 経由の画面受け渡しはそのまま動く**。権限は一切要らない。
   クライアント側(Swift)は `x11/apps/Xios/Sources/XSurface.c` をそのまま移植すればよい。
2. **ただし metal-event-broker(root の XPC サービス)が無いと iosc は起動時に落ちる**。
   フェンス無しの代替経路はソースに存在しない。これが G2 の唯一の関門。

## 1. 共通の 32 バイトレコード

`x11/apps/shared/XiosProtocol.h:18-33`

```c
typedef struct {                 // 32 バイト、ネイティブ LE
    uint32_t magic;              // +0   0x584D5331 'XMS1'
    uint32_t type;               // +4
    union { uint32_t window_id, state; };  // +8
    uint32_t length;             // +12  このレコードの直後に続くペイロード長
    union { int32_t a, x; };     // +16
    union { int32_t b, y; };     // +20
    union { int32_t c; uint32_t code; };   // +24
    union { int32_t d; uint32_t mods; };   // +28
} xios_msg;
```

`XIOS_PROTOCOL_VERSION = 1`(`XiosProtocol.h:14`)。

## 2. ddx ソケット(`-ddx-sock`)の手順

クライアント側の順番(`x11/apps/Xios/Sources/XSurface.c:206-345`):

1. `socket(AF_UNIX, SOCK_STREAM)` → `connect()`、`SO_RCVTIMEO = 5s`(`:225-228`)
2. `mach_port_allocate(RIGHT_RECEIVE)` + `mach_port_insert_right(MAKE_SEND)`(`:232-237`)
3. HELLO 送信(`:239-249`): `magic='XMS1', type=0x01, window_id=1, length=0, a=getpid(), b=(int32)返信ポート名, c=caps, d=0`
   サーバーは `a>0 && b!=0 && (c & ~1)==0 && d==0 && length==0` でないと拒否(`xios_surface.c:812-822`)
4. **先に mach メッセージを受ける**(ソケットの返信より前)。`mach_msg(MACH_RCV_MSG, 1500ms)` で
   主 IOSurface のポートを受信(`XSurface.c:110-141, 253`)
5. ソケットでサーバー HELLO(`xios_surface.c:874-876`): `type=0x01, window_id=1, length=識別子長,
   a=幅, b=高さ, c=ストライド, d='BGRA'(0x42475241)`、続けて識別子("iosc")。
   クライアントは a/b/c が `IOSurfaceGet{Width,Height,BytesPerRow}` と一致するか検査(`XSurface.c:278-283`)
6. `caps & STREAM_V2 (1<<0)` なら `STREAM_INFO`(`type=0x0a, a=出力数 1..3, length=32`)+ 32 バイトの
   解放タイムライン用トークン。続けて `i = 1..a-1` について **mach ポート 1 通 → `SURFACE` レコード**
   (`window_id=1+i, a/b/c=w/h/stride, d=フラグ`)(`xios_surface.c:889-918`)
7. fd を `O_NONBLOCK` に(`XSurface.c:343`)。classic モードは **3 枚**要求(`iosc.c:6901`)

`xsurface_connect` は caps=STREAM_V2 で試し、駄目なら caps=0 に落とす(`XSurface.c:347-352`)。

### メッセージ種別

| type | 向き | 内容 |
|---|---|---|
| `HELLO 0x01` | 双方向 | `window_id`=版。2 通目は致命(`XSurface.c:562-564`) |
| `DIRTY 0x02` | S→C | `window_id`=面 id、`a/b`=seq 下位/上位、`c/d`=フェンス値、`length=32` + 32 バイトのトークン |
| `CURSOR 0x03` | S→C | `a/b`=x/y、`c`=形状 id、`d` bit0=可視 |
| `PRESENTED 0x05` | C→S | `a/b`=seq、`c`=実提示からの経過 µs、`d` bit0=c が実測値 |
| `PACING 0x06` | C→S | `a`=表示同期までの µs、`b`=更新間隔 µs、`c/d`=最小/最大 fps×1000 |
| `SURFACE 0x07` | S→C | 直前に mach ポート 1 通。`window_id`=id、`a/b/c`=w/h/stride、`d`=`FLIP_Y(1)` |
| `SURFACE_DROP 0x08` | S→C | 動的 id の破棄 |
| `RELEASED 0x09` | C→S | `window_id`=面 id、`a/b`=seq、`length=0` |
| `STREAM_INFO 0x0a` | S→C | `a`=バッファ数、ペイロード=解放タイムラインのトークン |
| `CURSOR_IMAGE 0x0b` | S→C | `a/b`=w/h、`c/d`=ホットスポット、`length=w*h*4` の BGRA(0 で取り下げ) |
| `0x40`〜`0x54` | — | native ソケット専用。ddx には流れない |

未知の type を受けたら再接続(`XSurface.c:565-567`)。

## 3. IOSurface の受け渡し

コンポジタ側(`xios_surface.c:435-501`):

- pid は `getsockopt(fd, SOL_LOCAL, LOCAL_PEERPID)` で取る。**HELLO の `a` は信用しない**(`:828-838`)
- `task_for_pid(mach_task_self(), peer_pid, &task)`(`:438`)
- `mach_port_extract_right(task, portname, MACH_MSG_TYPE_COPY_SEND, &dst, &acq)`(`:447`)
- `sp = IOSurfaceCreateMachPort(surf)`(`:469`)
- `mach_msg(SEND, 2000ms)` でポート記述子 1 個を送る(`xios_surface.c:36-40`):

```c
typedef struct {
    mach_msg_header_t header;        // bits = MACH_MSGH_BITS(COPY_SEND,0) | MACH_MSGH_BITS_COMPLEX
    mach_msg_body_t body;            // msgh_descriptor_count = 1
    mach_msg_port_descriptor_t port; // .disposition = COPY_SEND
} xios_port_msg;
```

クライアントは同じ構造体 + `mach_msg_trailer_t` で受け(`XSurface.c:35-40`)、
`IOSurfaceLookupFromMachPort(msg.port.name)` で IOSurfaceRef に戻す(`:132-133`)。fd 渡しは無い。

### 同一プロセスでの扱い

**全ステップがそのまま動き、権限を要求するものは 1 つも無い。**

- `task_for_pid(mach_task_self(), getpid())` は自分の task port。`task_for_pid-allow` は不要
- `mach_port_extract_right` は自分の空間内なので単なる `COPY_SEND` の複製
- 同一プロセスの AF_UNIX 対では `LOCAL_PEERPID` が自分の pid を返すので、サーバーの検査も通る
- `IOSurfaceCreateMachPort` → `IOSurfaceLookupFromMachPort` は同一 task で同じ面を返す

したがって**クライアントは仕様どおりに実装すればよい**。iosc の `xios_get_output_iosurface()` を直接
呼ぶ近道もあるが、2 枚目以降の id はソケットでしか伝わらないので、素直にプロトコルを実装する。
短縮してよいのはタイムアウト値くらい。

## 4. 【関門】フェンスと XPC

`xios_metal_sync.m:56-80` が ANGLE から `id<MTLSharedEvent>` を取り、
`xios_metal_event_broker_publish` が `MTLSharedEventHandle` を 256 ビットのトークン付きで
**NSXPC(`com.max.xios.metal-event-broker`、`NSXPCConnectionPrivileged`)**に登録する
(`XiosMetalEventBroker.m:15-41, 66-110`)。ソケットを渡るのは 32 バイトのトークンだけ。

クライアントは `xios_metal_event_broker_copy_event(device, token, 32)` →
`newSharedEventWithHandle` → `encodeWaitForEvent` で描画前に待つ(`XScreen.swift:1376-1407, 1424`)。
解放方向は STREAM_INFO のトークンから同様に取り、`encodeSignalEvent(event, value: seq)` してから
`xsurface_released`(`XScreen.swift:594-632`)。

**ブローカーが無いと iosc は起動しない。**

```
xios_metal_sync_create_event が NULL
 → iosc_gl.c:318-325 "ERROR output release timeline unavailable; GPU compositor unavailable" → -1
 → iosc.c:6921-6924 "FATAL: GPU compositor initialization failed" → return 1
```

毎フレームにも 2 つ目の致命がある(`iosc.c:2235-2243`
"FATAL: cross-process GPU presentation fence unavailable; refusing an unfenced frame" → `wl_display_terminate`)。
**フェンス無しで進む経路はソースに存在しない**。落とすのは選択肢にならない。

### 対策(同一プロセスなので簡単になる)

ブローカーの 2 つの入口をプロセス内のテーブルに置き換える。

- `publish(handle, token)` = トークンを乱数で作り、handle を辞書に入れて 1 を返す
- `copy_event(device, token, 32)` = 辞書から引いて `newSharedEventWithHandle:`(または保持している
  イベントをそのまま返す。同一プロセス・同一デバイスなので等価)

同一プロセスで `id<MTLSharedEvent>` を直接共有するのは、ここでは**まさに正しい**。

**差し替え方**: これらは iosc の像の中に静的リンクされているので、シンボル置換(二段名前空間)では
横取りできない(像内の呼び出しは直接分岐)。実現手段の候補:

1. **Objective-C のメソッド入れ替え(有力)**。ブローカーは `NSXPCConnection` を経由するので、
   ObjC のメッセージ送信は必ず動的解決される。`NSXPCConnection` の該当メソッドを入れ替えて、
   サービス名が `com.max.xios.metal-event-broker` のときだけ自前のローカル実装を返せば、
   バイナリを 1 バイトも触らずに済む。libLCsys は RTLD_GLOBAL なのでプロセス全体に効く
2. `relink.py` で当該関数の先頭を書き換える(バイナリ改変。最後の手段)
3. iosc を自前でソースからビルドする(`tools/xios/iosc-inprocess-notes.md` の最小改変一覧。最も重い)

## 5. 解放の経路

`xsurface_released(conn, surface_id, seq)` = `type=0x09, window_id=面 id, a=seq 下位, b=seq 上位, length=0`
(`XSurface.c:674-686`)。送る前に **`encodeSignalEvent(解放イベント, value: seq)` したコマンドバッファを
commit 済み**であること(`XScreen.swift:628-631`)。

サーバー(`xios_surface.c:649-676`)は `pending_clients & bit` かつ `last_seq == seq` のときだけ受理
(`xios_output_queue.h:121-134`)。取得側は `acquired || abandoned || pending_clients` のスロットを飛ばす。

**解放しないと**: 3 枚すべてが pending になり `xios_output_acquire` が 0 を返し、
`repaint_retry_soon()` で再試行し続ける(`iosc.c:2304-2311`)。落ちはしないが画面が固まる。

DIRTY 1 回につき RELEASED 1 回。`xsurface_drain` は 1 フレーム分で戻るので ack はまとめられない。

## 6. 入力ソケット(`-input-sock`)

同じ 32 バイトレコード。別名は `a=x, b=y, c=code, window_id=state, d=mods, length=ペイロード長`
(`XiosProtocol.h:138-141`)。

**双方向に HELLO が必要**。サーバーは accept 直後に送り(`xios_input_socket.c:155-159, 244`)、
クライアントも最初に送る(`IoscInput.c:44`)。サーバーは magic/type/`window_id==1` かつ
**length,a,b,c,d がすべて 0** でないと切断(`XiosProtocol.h:181-190`、`xios_input_socket.c:174-179`)。

種別(`XiosProtocol.h:142-159`): `MOTION 0x100, BUTTON 0x101, KEY 0x102, TEXT 0x103, TRAITS 0x104,
TOUCH 0x105, TABLET 0x106, BIND 0x107, AXIS 0x108, OUTPUT 0x109, HAPTIC 0x10a, VOLUME 0x10b,
APPEARANCE 0x10c, GESTURE 0x10d, BRIGHTNESS 0x10e, IMPROXY 0x10f`。

符号化(`IoscInput.c:78-135`):

- MOTION `(x, y)`
- BUTTON `(x, y, code=1/2/3, state=押下)`
- KEY `(0, 0, code=X keysym, state, mods bit0 shift / bit1 ctrl / bit2 alt)`
- TEXT `code = length = バイト数` + UTF-8 本体(4096 以下。`code != length` は拒否)
- TOUCH `(x, y, code=スロット 0..9, state=位相 0 離 1 触 2 移動 3 取消)`
- AXIS `(dx256, dy256, code=source, state=stop, mods)`
- OUTPUT `(code&3 = 回転, x/y = 論理サイズ)` はアプリ→サーバー

サーバー→アプリは `TRAITS` と `HAPTIC` のみ。それ以外を送ると切断(`IoscInput.c:155-159`)。

**座標系は出力(IOSurface)のピクセル**。UIKit のタッチからの逆変換(`XScreen.swift:258-305`):

```swift
baseScale = min(viewBounds.width / fbWidth, viewBounds.height / fbHeight)
scale     = baseScale * zoom
size      = (fbWidth * scale, fbHeight * scale)
origin    = (viewBounds.midX - size.w/2 + pan.x, viewBounds.midY - size.h/2 + pan.y)
fx = (p.x - contentRect.minX) / contentRect.width  * fbWidth
fy = (p.y - contentRect.minY) / contentRect.height * fbHeight   // 範囲外は nil、[0, fb-1] に丸める
```

## 7. 最小起動

```
iosc -classic -logical 1024x768 -scale 2 -dpi 96 -s wayland-0
     -ddx-sock       <RT>/iosc-ddx.sock
     -json           <RT>/xios.json
     -input-sock     <RT>/iosc-input.sock
     -clipboard-sock <RT>/iosc-clipboard.sock
     -wm-sock        <RT>/iosc-wm.sock
```

`-logical` × `-scale` が `-g` を上書きする(`iosc.c:6888-6891`)。

環境変数: `XDG_RUNTIME_DIR=<RT>`(必須。無いと `wl_display_add_socket` が失敗、`iosc.c:6923-6927`)、
`IOSC_IGNORE_ACTIVE_SESSION=1`、`XIOS_RUNTIME_TMP=<RT>`。任意で `IOSC_DEBUG`。

前提: `<RT>` が書き込み可能で、**すべてのソケットパスが 104 バイト未満**
(`sun_path` の上限。`xios_surface.c:965-970` で検査)。アプリのコンテナパスは長いので要注意
(G0 実測: `$TMPDIR` は 89 文字。`/iosc-clipboard.sock` を足すと 109 文字で**超える**)。

**root が無くても致命的でないもの**(いずれも警告のみ):

- `getpwnam("mobile")` + `chown` → `chmod 0600` に落ちる(`xios_surface.c:1023-1031` ほか)
- `/var/jb/tmp/xios-active-session` → 読めなければ「許可」扱い(`iosc.c:1944-1946`)

**本当に致命的なもの**: (a) metal-event-broker の XPC(第 4 節)、(b) `IOSurfaceCreate`
(ただし G0 で自前アプリからの作成に成功済み)、(c) `iosc_gl_init` の ANGLE 初期化。
