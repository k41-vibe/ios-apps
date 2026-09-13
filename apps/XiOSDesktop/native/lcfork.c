/* fork() を、プロセスを作らずに再現する。
 *
 * なぜ要るか
 * ----------
 * xiOS のプログラムは「アプリを起動する」ときに Unix の教科書どおりの形を使う。
 *
 *     pid = fork();            <- 自分の分身を作る
 *     if (pid == 0) {          <- 分身の側
 *         setsid(); setenv(...);
 *         ie_execl("sh", "-lc", cmd);   <- 目的のプログラムに化ける
 *         _exit(127);
 *     }
 *
 * iOS は fork() を断る(実機 2026-09-12: errno 35)。そして fork だけは
 * 「1 回呼んで 2 回返る」ので、他のものと違って言い換えが効かない。
 *
 * ただし出口はすでに繋がっている。xiOS の `ie_execl` は libiosexec の中で
 * `posix_spawn` を呼び、その posix_spawn は私たちが procd に流している。
 * つまり塞がっているのは入口だけ。
 *
 * どうやるか
 * ----------
 * 「1 回呼んで 2 回返る」を、スタック(作業台)を複製することで作る。
 *
 *   1. fork() の中で、呼び出し元に戻るための文脈(レジスタと sp)を保存する
 *   2. いま使っているスタックを sp から上端まで丸ごと控えておく
 *   3. 新しいスレッドを立て、その新しいスタックの空いている所に控えを書き戻す
 *   4. 書き戻した先は番地が違うので、その差分だけ「スタックを指している値」を
 *      全部ずらす(保存したレジスタも、書き戻したスタックの中身も)
 *   5. 新しいスレッドで、1 で保存した文脈に戻り値 0 で「戻る」
 *
 * こうすると、呼んだ側から見ると fork() が親では正の pid を返し、子では 0 を
 * 返したように見える。子は自分のスタックの複製の上で動くので、親とぶつからない。
 *
 * 危ないところ(承知の上でやっている)
 * ------------------------------------
 * - スタックを指す値かどうかは、値が元のスタックの範囲に入っているかで見分ける。
 *   たまたま同じ範囲の整数や浮動小数点数があると、誤ってずらしてしまう。
 *   スタックの番地は 0x16xxxxxxxx 付近の飛び飛びの値なので、実際にはまず当たらない。
 * - 子が環境変数を書き換えるとプロセス全体に効く(setenv は共有)。今回の使い方では
 *   親と同じ値を入れ直すだけなので実害が無い。
 * - 子が fd 0/1/2 を差し替えるとログの通り道が壊れる。lcsys.c 側で、ゲストの
 *   スレッドからの dup2/close は 0/1/2 に対してだけ空振りさせて守っている。
 *
 * 効かなくなったときの逃げ道: 環境変数 LCSYS_FORK=fail で従来どおり -1 を返す。
 */

#include "lcsys.h"

#include <errno.h>
#include <pthread.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

/* native/lcfork_ctx.S と並びを一致させること */
struct lc_ctx {
    uint64_t x[12]; /* x19..x28, x29, x30 */
    uint64_t sp;
    uint64_t pad;
    uint64_t d[8];
};

int lc_savectx(struct lc_ctx *c);
void lc_restorectx(struct lc_ctx *c, int ret) __attribute__((noreturn));

/* 新しいスレッドの手前に空けておく余白。復元する前に使う分を踏まないため */
#define FORK_SLACK (64u << 10)
/* 控えが大きすぎるときは諦める(暴走を早く止めるため) */
#define FORK_MAX_STACK (6u << 20)

struct fork_job {
    struct lc_ctx ctx;
    uintptr_t old_lo; /* 親の sp */
    uintptr_t old_hi; /* 親のスタック上端 */
    size_t used;
    void *snapshot;
};

static void free_job(struct fork_job *j)
{
    if (!j)
        return;
    free(j->snapshot);
    free(j);
}

/* 値が親のスタックを指しているなら、複製先との差分だけずらす */
static inline uint64_t shift(uint64_t v, uintptr_t lo, uintptr_t hi, intptr_t delta)
{
    return (v >= lo && v < hi) ? (uint64_t)((intptr_t)v + delta) : v;
}

/* 子のスレッドの中身。ここに来た時点で新しいスタックの上に居る。 */
static void fork_child_entry(void *arg)
{
    struct fork_job *j = (struct fork_job *)arg;
    struct lc_ctx ctx;
    volatile char here; /* いま自分がスタックのどこに居るかの目印 */
    uintptr_t cur = (uintptr_t)&here;
    uintptr_t dest;
    intptr_t delta;
    uint64_t *w;
    size_t i;

    /* 自分の足元より FORK_SLACK 下に、控えと同じ大きさの場所を取る */
    dest = (cur - FORK_SLACK - j->used) & ~(uintptr_t)15;
    memcpy((void *)dest, j->snapshot, j->used);
    delta = (intptr_t)dest - (intptr_t)j->old_lo;

    /* 保存したレジスタのうち、親のスタックを指しているものをずらす */
    ctx = j->ctx;
    for (i = 0; i < 12; i++)
        ctx.x[i] = shift(ctx.x[i], j->old_lo, j->old_hi, delta);
    /* x[11] は戻り先(コード番地)なので触らない。x[10] はフレームポインタ */
    ctx.x[11] = j->ctx.x[11];
    ctx.sp = (uint64_t)dest;

    /* 複製したスタックの中身も同じようにずらす。フレームの繋がりと、
     * スタック上の変数を指しているポインタがこれで揃う */
    w = (uint64_t *)dest;
    for (i = 0; i < j->used / 8; i++)
        w[i] = shift(w[i], j->old_lo, j->old_hi, delta);

    lcsys_log("fork: 子を %zu KB の複製で起動(ずれ %+lld)", j->used >> 10,
              (long long)delta);
    /* snapshot はもう要らないが、ここで free すると
     * lc_restorectx の後には戻ってこないので、job ごと手放しておく */
    free(j->snapshot);
    j->snapshot = NULL;
    free(j);

    lc_restorectx(&ctx, 1); /* 戻らない。fork() の中に「子として」戻る */
}

static int fork_mode_clone(void)
{
    const char *v = getenv("LCSYS_FORK");
    return !(v && (strcmp(v, "fail") == 0 || strcmp(v, "0") == 0));
}

pid_t fork(void)
{
    struct fork_job *j;
    pthread_t self;
    uintptr_t lo, hi;
    int pid;

    if (!fork_mode_clone() || !lcsys_is_guest_thread()) {
        lcsys_log("fork() -> -1 errno=%d (%s)", lcsys_cfg.fork_errno,
                  fork_mode_clone() ? "ゲストのスレッドではない" : "LCSYS_FORK=fail");
        errno = lcsys_cfg.fork_errno ? lcsys_cfg.fork_errno : EAGAIN;
        return -1;
    }

    /* シェルの fork は断る。$(...) やパイプの子は exec せずシェルの続きを走るので、
     * スタックだけ複製しても大域(メモリスタック、ジョブ表)を親と共有して親が落ちる
     * (2026-09-13 実機: /etc/profile の $(dircolors -b) で dash が SIGSEGV)。
     * -1 なら dash は "Cannot fork" で止まるだけで、デスクトップは生き残る。
     * EAGAIN は bash が 1,2,4,8,16 秒待って再試行するので ENOMEM にする */
    if (lcsys_is_shell_program(lcsys_guest_program())) {
        lcsys_log("fork() -> -1 ENOMEM(%s はシェル。子がシェルの続きを走ると大域を共有して落ちる)",
                  lcsys_guest_program());
        errno = ENOMEM;
        return -1;
    }

    j = (struct fork_job *)calloc(1, sizeof *j);
    if (!j) {
        errno = ENOMEM;
        return -1;
    }

    if (lc_savectx(&j->ctx) != 0)
        return 0; /* ここから先は子。fork_child_entry が飛ばしてきた */

    self = pthread_self();
    hi = (uintptr_t)pthread_get_stackaddr_np(self);
    lo = (uintptr_t)j->ctx.sp;
    if (lo >= hi || hi - lo > FORK_MAX_STACK) {
        lcsys_log("fork: スタックの範囲がおかしい(lo=%p hi=%p)。-1 を返す", (void *)lo,
                  (void *)hi);
        free_job(j);
        errno = EAGAIN;
        return -1;
    }
    j->old_lo = lo;
    j->old_hi = hi;
    j->used = (size_t)(hi - lo);
    j->snapshot = malloc(j->used);
    if (!j->snapshot) {
        free_job(j);
        errno = ENOMEM;
        return -1;
    }
    memcpy(j->snapshot, (const void *)lo, j->used);

    pid = lcsys_fork_child(fork_child_entry, j);
    if (pid < 0) {
        lcsys_log("fork: 子のスレッドが作れなかった");
        free_job(j);
        errno = EAGAIN;
        return -1;
    }
    lcsys_log("fork() -> %d(スタック %zu KB を複製した子)", pid, j->used >> 10);
    return (pid_t)pid;
}

pid_t lc_vfork(void) __asm__("_vfork");
pid_t lc_vfork(void)
{
    /* vfork は「親を止めて子を先に走らせる」形だが、出口は同じ exec なので
     * fork と同じ扱いで足りる */
    return fork();
}
