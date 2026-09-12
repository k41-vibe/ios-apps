# G0 実機計測の結果(2026-09-12、iPhone 14 Pro / iOS 26.6.1 / LiveContainer JIT-less / 無料証明書)

計測アプリ: `apps/LCProbeS`(dylib 100 本版)。生ログはアプリ内 `Documents/lcprobe.log`。

## 判定: 関門突破(G1 へ進んでよい)

| 項目 | 実測 | 計画での想定 | 判定 |
|---|---|---|---|
| メモリ上限(jetsam) | **4080 MB** で強制終了 | 2000〜2500 MB | 想定より 1.6 倍良い |
| dylib の dlopen | 100 本 1237 ms(**約 12 ms/本**)、footprint 増分ほぼ 0 | 本数が上限になる懸念 | 問題なし。408 本で約 5 秒 |
| IOSurface → Metal | 512x512 生成・テクスチャ化・描画とも成功、**present 60.0 fps**(vsync 上限)、別スレッドの書き込み 95〜100 回/秒 | 未知 | iosc の出力経路が成立 |
| Unix ソケット | socketpair 往復 **5.0 us**、`$TMPDIR` 直下に bind/listen/connect/accept 成功 | 未知 | Wayland のソケットは tmp に置く |
| スレッド数上限 | **1015 本**(64KB スタック)で EAGAIN、footprint 30 MB | 未知 | デスクトップ 1 セッションには十分 |
| JIT / W^X | 実行時コード生成は**不可**(下記) | 前提どおり不可 | 設計変更なし |

## JIT の詳細(重要な落とし穴)

```
mmap RWX          : ok          <- 成功してしまう
mmap RWX|MAP_JIT  : failed errno 1 (EPERM)
mprotect RW->RX   : 成功(失敗ログが出ていない)
書いたコードを実行 : プロセスが即死(ログ行に到達せず)
```

- **`mmap(PROT_EXEC)` も `mprotect(RX)` も成功するのに、実行した瞬間に殺される**。
- したがって「RWX を mmap できたか」で JIT の有無を判定するライブラリは、判定に成功してから落ちる。
  mozjs/gjs(GNOME Shell)、WebKitGTK、libffi の一部経路が該当しうる。
  **実行時判定に任せず、ビルド時フラグや環境変数でインタプリタ専用を強制すること**(G5 のリスク項目)。

## 副産物: 署名済み dylib は実行時にコピーして dlopen できる

`Frameworks/libprobe1.dylib` を `Documents/` にコピーして dlopen → **成功**。
署名が付いたままコピーされるため、JIT なしでも読める。
これは procd の「起動のたびに実行ファイルの私的コピーを作り、静的状態を新品にする」手法の裏付け
(同一パスを再 dlopen すると dyld が同じ像を返し、getopt 等の静的状態が残る問題への対処)。

## そのほかの環境値

- iOS 26.6.1 (23G83)、CPU 6 コア、物理メモリ 5662 MB、**ページサイズ 16384**(16KB)
- `RLIMIT_NOFILE` 2560
- `$TMPDIR` のパス長 89 文字。Documents 配下は 163 文字で **Unix ソケットのパス上限 103 を超える**
- `os_proc_available_memory` が jetsam 上限とほぼ一致(残量の監視に使える)

## 追記(9/12): 同梱バイナリ 408 本のシンボル事前検査

`audit_symbols.py` で、未定義シンボルが実機で解決できるかを二段名前空間の library ordinal から厳密に検査した。
JIT-less では `dlopen(RTLD_NOW)` で束縛するため、解決できないシンボルが 1 つあれば読み込み時に失敗する。

結果: **実害のある不良は 1 件のみ**。

1. **`libpcre2-8.0.dylib` が `_SLJIT_UPDATE_WX_FLAGS` を要求するが、どこにも存在しない**(上流パッケージの
   ビルド不良)。sljit(pcre2 の JIT バックエンド)の W^X フック。**`libglib-2.0.0.dylib` がこのライブラリに
   依存しているため、放置すると GTK4 / nautilus / iosc-shell が全滅する**(iosc 本体は非依存)。
   対処: `libLCsys.dylib` に no-op として定義する。実機では `mmap(MAP_JIT)` が EPERM なので
   pcre2 の JIT コンパイルは失敗し、インタプリタに落ちる。実害なし。
2. bash のロード可能ビルトイン 26 個(`/var/jb/usr/lib/bash/` の `rm`, `mkdir`, `seq` 等)が
   `_reset_internal_getopt` 等 bash 本体のシンボルをフラット検索で要求している。
   `enable -f` で明示的に読まない限り誰も触らないので**放置でよい**(本物の `/usr/bin/rm` とは別物)。

これ以外の 380 本は完全にリンク解決可能。G2 に進んでよい。

## G2 以降への反映

1. メモリ予算は 4 GB。KDE Plasma Mobile(インストール 610 MB)も射程に入る。
2. Wayland / D-Bus のソケットは必ず `$TMPDIR` 配下に置く(`XDG_RUNTIME_DIR`)。
3. iosc の出力は IOSurface 直共有で 60 fps 出る。コピーなしの前提で設計してよい。
4. JS エンジンを載せる段では、JIT の実行時判定を信用しない。
