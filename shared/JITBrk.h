#ifndef JITBRK_H
#define JITBRK_H

#include <stddef.h>
#include <stdint.h>

/* StikDebug から受け取った領域。同じ物理ページを 2 つの address から見ている。
 * rw に機械語を書き、rx を関数として呼ぶ。 */
typedef struct {
    void  *rw;     /* 書き込み用 */
    void  *rx;     /* 実行用 */
    size_t size;
} JITBrkRegion;

/* brk が本物の SIGTRAP になったときに落ちないようにする。下の 3 つが内部で呼ぶので、
 * 普通は自分で呼ばなくてよい */
void JITBrkInstallTrapHandler(void);

/* StikDebug が接続しているか。0 なら接続なし */
int JITBrkIsAttached(void);

/* 領域をもらう。失敗すると rw も rx も NULL */
JITBrkRegion JITBrkAllocate(size_t bytes);

void JITBrkRelease(JITBrkRegion *region);

/* StikDebug との接続を切る。領域は切ったあとも使える */
void JITBrkDetachDebugger(void);

#endif /* JITBRK_H */
