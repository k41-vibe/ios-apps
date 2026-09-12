/* fork を自前で再現するための、文脈の保存と復元(arm64)。
 *
 * setjmp/longjmp を使わないのは、jmp_buf の中身が非公開で、どの位置に sp が
 * 入っているかに頼れないから。ここでは自分で並びを決める。
 *
 * struct lc_ctx の並び(native/lcfork.c と一致させること):
 *     0  x19, x20
 *    16  x21, x22
 *    32  x23, x24
 *    48  x25, x26
 *    64  x27, x28
 *    80  x29(フレームポインタ), x30(戻り先)
 *    96  sp
 *   104  (空き)
 *   112  d8..d15
 *
 * AAPCS で呼ばれた側が保存する義務のあるレジスタはこれで全部。呼んだ側が
 * 保存するレジスタ(x0-x18, d0-d7 など)は、関数呼び出しをまたいだ時点で
 * 中身を保証されないので、保存する必要がない。
 *
 * 注意: このアプリは arm64(arm64e ではない)なので、x30 にポインタ認証の
 * 署名は付かない。素直に保存して素直に戻せる。
 */

    .text
    .align 2

/* int lc_savectx(struct lc_ctx *c) -- 普通に呼ぶと 0 を返す */
    .globl _lc_savectx
_lc_savectx:
    stp     x19, x20, [x0, #0]
    stp     x21, x22, [x0, #16]
    stp     x23, x24, [x0, #32]
    stp     x25, x26, [x0, #48]
    stp     x27, x28, [x0, #64]
    stp     x29, x30, [x0, #80]
    mov     x9, sp
    str     x9, [x0, #96]
    stp     d8,  d9,  [x0, #112]
    stp     d10, d11, [x0, #128]
    stp     d12, d13, [x0, #144]
    stp     d14, d15, [x0, #160]
    mov     w0, #0
    ret

/* void lc_restorectx(struct lc_ctx *c, int ret) -- lc_savectx の場所に
 * ret を返り値として「戻る」。戻ってこない。 */
    .globl _lc_restorectx
_lc_restorectx:
    ldp     x19, x20, [x0, #0]
    ldp     x21, x22, [x0, #16]
    ldp     x23, x24, [x0, #32]
    ldp     x25, x26, [x0, #48]
    ldp     x27, x28, [x0, #64]
    ldp     d8,  d9,  [x0, #112]
    ldp     d10, d11, [x0, #128]
    ldp     d12, d13, [x0, #144]
    ldp     d14, d15, [x0, #160]
    ldr     x9, [x0, #96]
    mov     sp, x9
    ldp     x29, x30, [x0, #80]
    mov     w0, w1
    ret
