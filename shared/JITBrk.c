/*
 * JITBrk.S の呼び出し口。SIGTRAP の始末と、書き込み用の別名を作るところを受け持つ。
 *
 * StikDebug が用意する領域は実行できるが書けない。そこへ機械語を置くには、同じ物理
 * ページを指す書き込み可能な別の address を vm_remap で作り、そちら経由で書く。
 * 書き込みは自分のプロセス内で完結するので、StikDebug を切ったあとも使える。
 */

#include "JITBrk.h"

#include <mach/mach.h>
#include <mach/vm_map.h>
#include <signal.h>
#include <string.h>
#include <stdbool.h>
#include <unistd.h>

extern void    *JITBrkGetMapping(void *addr, size_t len);
extern void     JITBrkDetach(void);
extern uint64_t JITBrkProbe(void);

/* brk を実行している間だけ立てる。これが立っていない SIGTRAP は本物なので素通しする */
static _Thread_local bool g_expecting_trap;

static struct sigaction g_prev_sigtrap;
static struct sigaction g_prev_sigbus;
static bool g_handler_installed;

static void jitbrk_trap_handler(int sig, siginfo_t *info, void *ctx)
{
    (void)info;
    if (g_expecting_trap && ctx != NULL) {
        ucontext_t *uc = (ucontext_t *)ctx;
        /* brk を飛ばして、StikDebug が書き戻すはずだった場所に失敗を表す 0 を入れる */
        uc->uc_mcontext->__ss.__pc += 4;
        uc->uc_mcontext->__ss.__x[0] = 0;
        return;
    }
    /* 自分宛てではない。元の処理に戻してから上げ直す */
    struct sigaction *prev = (sig == SIGTRAP) ? &g_prev_sigtrap : &g_prev_sigbus;
    sigaction(sig, prev, NULL);
    raise(sig);
}

void JITBrkInstallTrapHandler(void)
{
    if (g_handler_installed) return;
    struct sigaction sa;
    memset(&sa, 0, sizeof(sa));
    sa.sa_flags = SA_SIGINFO;
    sa.sa_sigaction = jitbrk_trap_handler;
    sigemptyset(&sa.sa_mask);
    sigaction(SIGTRAP, &sa, &g_prev_sigtrap);
    sigaction(SIGBUS, &sa, &g_prev_sigbus);
    g_handler_installed = true;
}

int JITBrkIsAttached(void)
{
    JITBrkInstallTrapHandler();
    g_expecting_trap = true;
    uint64_t r = JITBrkProbe();
    g_expecting_trap = false;
    return r != 0;
}

JITBrkRegion JITBrkAllocate(size_t bytes)
{
    JITBrkRegion region = { NULL, NULL, 0 };
    JITBrkInstallTrapHandler();

    g_expecting_trap = true;
    void *rx = JITBrkGetMapping(NULL, bytes);
    g_expecting_trap = false;
    if (rx == NULL) return region;

    vm_address_t rw = 0;
    vm_prot_t cur = VM_PROT_NONE, max = VM_PROT_NONE;
    kern_return_t kr = vm_remap(mach_task_self(), &rw, (vm_size_t)bytes, 0, VM_FLAGS_ANYWHERE,
                                mach_task_self(), (vm_address_t)rx, FALSE, &cur, &max, VM_INHERIT_NONE);
    if (kr != KERN_SUCCESS) return region;

    kr = vm_protect(mach_task_self(), rw, (vm_size_t)bytes, FALSE, VM_PROT_READ | VM_PROT_WRITE);
    if (kr != KERN_SUCCESS) {
        vm_deallocate(mach_task_self(), rw, (vm_size_t)bytes);
        return region;
    }

    region.rw = (void *)rw;
    region.rx = rx;
    region.size = bytes;
    return region;
}

void JITBrkRelease(JITBrkRegion *region)
{
    if (region == NULL || region->rw == NULL) return;
    vm_deallocate(mach_task_self(), (vm_address_t)region->rw, (vm_size_t)region->size);
    region->rw = NULL;
    region->rx = NULL;
    region->size = 0;
}

void JITBrkDetachDebugger(void)
{
    JITBrkInstallTrapHandler();
    g_expecting_trap = true;
    JITBrkDetach();
    g_expecting_trap = false;
}
