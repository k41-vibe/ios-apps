/*
 * libLCsys - libSystem "front" library for XiOSDesktop (G1).
 *
 * Built by postbuild.sh as a dylib that RE-EXPORTS /usr/lib/libSystem.B.dylib.
 * Every relinked guest Mach-O has its LC_LOAD_DYLIB for libSystem rewritten to
 * @rpath/libLCsys.dylib (tools/xios/relink.py --libsystem-shim), so with the
 * two-level namespace dyld binds a guest's `open`, `stat`, `exit`, ... to the
 * definitions in THIS library first and everything we do not define falls
 * through to the real libSystem. Host code (Swift, LiveContainer) still binds
 * to libSystem directly and is unaffected.
 *
 * Two halves:
 *   pathmap.c  /var/jb/... -> <bundle>/jb/...   (+ .symlink markers, "<name>.lc" @LC: stubs)
 *   lcsys.c    the overridden libc entry points + init/logging
 *   procd.c    "processes" as threads: dlopen(flat dylib) + call LC_MAIN entry
 *   xpcshim.m  the in-process stand-in for the metal-event-broker XPC service
 *   xsurface.c the ddx client: iosc's IOSurfaces + fences, for the Swift screen
 *
 * G1 limits (documented in README.md): environ, cwd, fd 0/1/2 and signal
 * dispositions are process-global; exec/spawn/fork are stubs that only log.
 */
#ifndef LCSYS_H
#define LCSYS_H

#include <stddef.h>
#include <stdint.h>
#include <stdio.h>
#include <stdarg.h>
#include <sys/types.h>
#include <sys/stat.h>
#include <sys/mount.h>
#include <sys/statvfs.h>
#include <dirent.h>
#include <spawn.h>

#ifdef __cplusplus
extern "C" {
#endif

#define LCSYS_PATH_MAX 1024
#define LCSYS_STUB_PREFIX "@LC:Frameworks/"
#define LCSYS_STUB_SUFFIX ".lc" /* stage.py: jb/usr/bin/ls -> jb/usr/bin/ls.lc (text "@LC:Frameworks/ls.exe.dylib") */

/* ---- public API (dlsym'd from Swift) ---- */

/* Must be called once before anything else. Copies its arguments.
 * log_fd: where lcsys_log() writes (the console pipe). Returns 0. */
int lcsys_spawn(const char *path, char *const argv[], char *const envp[], int fd_out, int fd_err);
int lcsys_wait(int pid, int *status);
/* waitpid 相当: 0 = まだ動いている(nohang のとき), pid = 回収した(*status は終了コード),
 * -1 = 知らない pid(errno ECHILD)。nohang=0 なら終わるまで待つ。 */
int lcsys_waitpid(int pid, int *status, int nohang);
/* kill 相当。擬似 pid を知っていれば 0(スレッドは止められないので記録だけ)、知らなければ -1。 */
int lcsys_kill(int pid, int sig);
/* Poll a pid without reaping it (for guests that never return, e.g. iosc):
 * 1 = running, 0 = finished (*status = exit code), -1 = unknown pid (ECHILD).
 * `status` may be NULL. lcsys_wait stays the only thing that frees a proc. */
int lcsys_alive(int pid, int *status);

/* いま動いているのがゲスト(procd が起こした)のスレッドか。
 * fork の再現(native/lcfork.c)と、標準入出力を守る判断に使う。 */
int lcsys_is_guest_thread(void);

/* fork の子(まだ exec していない短命なスレッド)か。fd の表が 1 つしか無いので、
 * 子からの close は見送る必要がある。 */
int lcsys_is_fork_child(void);
/* 今のスレッドのゲストのプログラム(argv[0] 風のパス)。ゲストでなければ NULL */
const char *lcsys_guest_program(void);
/* sh / dash / bash か(fork を断る相手) */
int lcsys_is_shell_program(const char *path);

/* fork() の子として、procd の台帳に載ったスレッドを 1 本立てる。
 * fn は複製したスタックへ飛ぶので普通は戻ってこない。返り値は擬似 pid。 */
int lcsys_fork_child(void (*fn)(void *), void *arg);

/* exec の肩代わり。新しいプログラムをスレッドで起こし、呼んだ側の擬似 pid を
 * そちらへ引き継ぐ。成功したら呼んだ側は自分のスレッドを終えること。
 * 見つからなければ -1(次の候補を試させるため)。 */
int lcsys_exec_handover(const char *path, char *const argv[], char *const envp[]);
int lcsys_init(const char *bundle_path, const char *home, const char *tmp, int log_fd);
void lcsys_log(const char *fmt, ...) __attribute__((format(printf, 1, 2)));
/* xpcshim.m: replace the com.max.xios.metal-event-broker XPC service (a root
 * LaunchDaemon we cannot register) with an in-process table, by swizzling
 * NSXPCConnection. Idempotent; lcsys_init calls it, so iosc always finds it in
 * place. Without it iosc dies at startup (iosc.c:6921 "FATAL: GPU compositor
 * initialization failed"); see tools/xios/iosc-host-protocol.md section 4. */
void lcsys_install_xpc_shim(void);
/* xpcshim.m: token -> id<MTLSharedEvent> for `mtl_device`, the in-process replacement
 * for xios_metal_event_broker_copy_event(). Looks the 32-byte token up in the same
 * table iosc publishes into and returns -newSharedEventWithHandle: (+1 RETAINED, the
 * caller owns it), or NULL when the token is unknown (logged as a miss).
 * `mtl_device` is an id<MTLDevice> and the result an id<MTLSharedEvent>; both are
 * typed void * so that no Metal header is needed on either side. */
void *lcsys_shared_event_for_token(void *mtl_device, const unsigned char *token, size_t len);

/* ---- xsurface.c: the ddx (display) client ----
 * Our side of iosc's -ddx-sock. See tools/xios/iosc-host-protocol.md sections 2-5;
 * the ordering rules there (mach message before the socket HELLO, one RELEASED per
 * DIRTY, the release-event signal committed BEFORE the RELEASED goes out) are part of
 * the contract, not implementation detail. */
#define XS_TOKEN_BYTES 32
#define XS_HELLO_CAP_STREAM_V2 (1u << 0)

typedef struct xs_conn xs_conn;

/* Connect, do the HELLO + mach handshake, learn every output surface. STREAM_V2 is
 * tried first and caps=0 second. NULL + errno on failure. */
xs_conn *xs_connect(const char *ddx_sock_path);
/* Non-blocking drain. 1 = a DIRTY arrived (*surface_id, *seq, *fence_value filled),
 * 0 = nothing pending, -1 = error/disconnected. Returns as soon as one DIRTY is ready,
 * so the caller can ack exactly one frame per call. */
int xs_poll(xs_conn *c, uint32_t *surface_id, uint64_t *seq, uint64_t *fence_value);
/* The IOSurfaceRef for a surface id learned during the handshake (NULL if unknown).
 * Owned by the connection; do not release it. */
void *xs_surface(xs_conn *c, uint32_t surface_id);
int xs_count(xs_conn *c);
void xs_info(xs_conn *c, int *w, int *h, int *stride);
/* Tell iosc the buffer is free again. MUST follow a committed signal of the release
 * event with this same seq. One RELEASED per DIRTY, never coalesced. */
int xs_release(xs_conn *c, uint32_t surface_id, uint64_t seq);
int xs_presented(xs_conn *c, uint64_t seq, uint32_t us_since_present, int measured);
int xs_pacing(xs_conn *c, int32_t until_deadline_us, uint32_t interval_us, int32_t min_mfps, int32_t max_mfps);
void xs_close(xs_conn *c);
/* The 32-byte tokens, raw: the release timeline arrives once in STREAM_INFO, the
 * presentation fence with every DIRTY (so read it right after xs_poll returned 1).
 * The storage belongs to the connection. */
const unsigned char *xs_release_token(xs_conn *c);
const unsigned char *xs_last_fence_token(xs_conn *c);

/* Guest path -> host path. Pure string mapping, no filesystem access.
 * Returns out (always NUL-terminated; truncated silently at cap). */
char *lcsys_map_path(const char *in, char *out, size_t cap);
/* Guest path -> host path that exists: map, then follow ".symlink" marker
 * files on any component (up to 8 hops); a missing leaf whose "<leaf>.lc"
 * stub exists resolves to the stub (so stat/access/open of /var/jb/usr/bin/ls
 * see jb/usr/bin/ls.lc). Falls back to the plain mapping. */
char *lcsys_resolve_path(const char *in, char *out, size_t cap);
/* Guest executable/dylib path -> the file to dlopen. Checks <mapped>, then
 * <mapped>.lc; if the file is an "@LC:Frameworks/<flat>" stub, returns
 * <bundle>/Frameworks/<flat>; otherwise the resolved path. Returns NULL
 * (errno set) when neither can be read. */
char *lcsys_resolve_macho(const char *in, char *out, size_t cap);

/* ---- internal (shared between the .c files) ---- */

struct lcsys_config {
    char bundle[LCSYS_PATH_MAX];
    char jb[LCSYS_PATH_MAX];          /* <bundle>/jb            */
    char frameworks[LCSYS_PATH_MAX];  /* <bundle>/Frameworks    */
    char home[LCSYS_PATH_MAX];
    char tmp[LCSYS_PATH_MAX];
    int log_fd;
    int trace;                        /* LCSYS_TRACE=1: log every path mapping */
    int fork_errno;                   /* LCSYS_FORK_ERRNO=n (default EAGAIN)   */
};
extern struct lcsys_config lcsys_cfg;
extern int lcsys_ready;

/* Real libSystem entry points, resolved once (lcsys.c). Internal code must
 * call these, never the bare names (those bind to our own overrides). */
struct lcsys_real {
    int (*open)(const char *, int, ...);
    int (*openat)(int, const char *, int, ...);
    int (*stat)(const char *, struct stat *);
    int (*lstat)(const char *, struct stat *);
    int (*fstatat)(int, const char *, struct stat *, int);
    int (*statfs)(const char *, struct statfs *);
    int (*statvfs)(const char *, struct statvfs *);
    int (*access)(const char *, int);
    int (*faccessat)(int, const char *, int, int);
    DIR *(*opendir)(const char *);
    int (*closedir)(DIR *);
    struct dirent *(*readdir)(DIR *);
    int (*readdir_r)(DIR *, struct dirent *, struct dirent **);
    ssize_t (*readlink)(const char *, char *, size_t);
    char *(*realpath)(const char *, char *);
    int (*mkdir)(const char *, mode_t);
    int (*rmdir)(const char *);
    int (*unlink)(const char *);
    int (*rename)(const char *, const char *);
    int (*chmod)(const char *, mode_t);
    int (*chdir)(const char *);
    void (*exit)(int);
    void (*_exit)(int);
    void *(*dlopen)(const char *, int);
    /* fopen/freopen open a path INSIDE libSystem, so a guest calling fopen() never reaches
     * our open() override and the /var/jb mapping is skipped (device 2026-09-12: xkbcommon
     * reads rules/evdev with fopen and reported the file missing although it is there). */
    FILE *(*fopen)(const char *, const char *);
    FILE *(*freopen)(const char *, const char *, FILE *);
};
extern struct lcsys_real lcsys_real;
void lcsys_resolve_real(void);

/* Open-directory registry (pathmap.c), used by the readdir overrides in lcsys.c.
 * Only directories whose HOST path is under <bundle>/jb are registered; readdir on
 * anything else must be passed through untouched. */
struct lc_dir;
void lcsys_dir_register(DIR *d, const char *host_path);
void lcsys_dir_forget(DIR *d);
struct lc_dir *lcsys_dir_find(DIR *d);
/* Per-DIR scratch entry, same ownership rule as libc's own readdir buffer:
 * valid until the next readdir() on that DIR. */
struct dirent *lcsys_dir_scratch(struct lc_dir *ld);
/* Rewrite one entry of a jb directory. dst may alias src (readdir_r).
 *    0 = use src unchanged,  1 = dst was filled,  -1 = skip this entry */
int lcsys_dir_filter(struct lc_dir *ld, const struct dirent *src, struct dirent *dst);

/* procd hooks used by the exit() override (procd.c) */
int lcsys_guest_exit(int status);   /* returns only if the caller is not a guest thread */

#ifdef __cplusplus
}
#endif
#endif /* LCSYS_H */
