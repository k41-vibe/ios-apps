/*
 * libLCsys - libSystem "front" library for XiOSLite (G1).
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
 *
 * G1 limits (documented in README.md): environ, cwd, fd 0/1/2 and signal
 * dispositions are process-global; exec/spawn/fork are stubs that only log.
 */
#ifndef LCSYS_H
#define LCSYS_H

#include <stddef.h>
#include <stdarg.h>
#include <sys/types.h>
#include <sys/stat.h>
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
int lcsys_init(const char *bundle_path, const char *home, const char *tmp, int log_fd);
void lcsys_log(const char *fmt, ...) __attribute__((format(printf, 1, 2)));

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
