/*
 * iOS 26 以降で JIT を使うための、StikDebug への要求命令。
 *
 * iOS 26 より前は、デバッガが接続していればプロセス全体で JIT が許された(CS_DEBUGGED)。
 * 26 以降は、アプリが「この領域を JIT に使う」と自分で申告する方式に変わった。その申告を
 * StikDebug に伝える手段が、下の brk 命令である。StikDebug 側は接続したまま待っていて、
 * この停止を受け取ると領域を用意し、結果を x0 に書き戻してから実行を再開させる。
 *
 * 仕様(StikDebug/Scripts/universal.js):
 *   brk #0xf00d  x16 で操作を選ぶ。0 = 切断、1 = 領域の用意。引数は x0/x1、結果は x0
 *   brk #0x69    StikDebug が接続しているかを確かめるためだけのもの。x0 に定数が返る
 *
 * StikDebug が接続していない場合、これらは本物の SIGTRAP になりプロセスが終わる。
 * 呼ぶ前に JITBrkInstallTrapHandler() を済ませておくこと。処理を入れておけば x0 が 0 に
 * なって次の命令へ進むだけで済む。
 *
 * 引数と戻り値の置き場所は呼び出し規約どおりなので、C から普通の関数として呼べる。
 */

#if defined(__aarch64__) || defined(__arm64__)

.section __TEXT,__text,regular,pure_instructions

/* void *JITBrkGetMapping(void *addr, size_t len);
 * addr に NULL を渡すと新しい領域を用意してもらう。返るのは実行可能な領域の先頭。
 * 用意できなければ 0。 */
.globl _JITBrkGetMapping
.p2align 2
_JITBrkGetMapping:
    mov     x16, #1
    brk     #0xf00d
    ret

/* void JITBrkDetach(void); */
.globl _JITBrkDetach
.p2align 2
_JITBrkDetach:
    mov     x16, #0
    brk     #0xf00d
    ret

/* uint64_t JITBrkProbe(void);
 * StikDebug が応じれば 0 以外が返る。値そのものは当てにしない。
 * universal.js は P0=E0000069 というパケットで書き戻すが、レジスタは対象の
 * バイト順で解釈されるので 0x690000E0 になる。8 バイトのうち 4 バイトしか
 * 渡さないため上半分は元の値が残る。だから「0 でないこと」だけを見る。 */
.globl _JITBrkProbe
.p2align 2
_JITBrkProbe:
    brk     #0x69
    ret

#endif /* aarch64 */
