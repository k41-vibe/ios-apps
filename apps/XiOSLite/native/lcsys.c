/*
 * lcsys.c - init, logging, the real-libSystem table and the overridden
 * libc entry points.
 *
 * Each override maps the guest path (pathmap.c) and calls the real function
 * through lcsys_real.* - a direct call to e.g. `open` from inside this dylib
 * would bind to our own definition. The real pointers come from
 * dlsym(dlopen("/usr/lib/libSystem.B.dylib")) with dlsym(RTLD_NEXT) as the
 * fallback (RTLD_NEXT searches the images this dylib links against, i.e.
 * libSystem).
 *
 * execv/execve/execvp and posix_spawn/posix_spawnp: G1 stubs - log argv,
 * fail with ENOSYS (so the console shows what bash/ls try to run).
 * fork/vfork: log, fail with EAGAIN
 * (LCSYS_FORK_ERRNO=<n> overrides; bash retries EAGAIN with 1,2,4,8,16 s
 * sleeps, ENOSYS makes it give up at once).
 * exit/_exit on a guest thread: record the status and end the thread only.
 */
#include "lcsys.h"

#include <dlfcn.h>
#include <errno.h>
#include <fcntl.h>
#include <pthread.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

struct lcsys_config lcsys_cfg;
int lcsys_ready = 0;
struct lcsys_real lcsys_real;

/* ------------------------------------------------------------ logging */

void lcsys_log(const char *fmt, ...)
{
    char buf[2048];
    va_list ap;
    int n;
    int fd = lcsys_cfg.log_fd > 0 ? lcsys_cfg.log_fd : 2;
    memcpy(buf, "[lcsys] ", 8);
    va_start(ap, fmt);
    n = vsnprintf(buf + 8, sizeof buf - 9, fmt, ap);
    va_end(ap);
    if (n < 0)
        return;
    if (n > (int)sizeof buf - 9)
        n = (int)sizeof buf - 9;
    buf[8 + n] = '\n';
    (void)!write(fd, buf, (size_t)(9 + n));
}

/* ------------------------------------------------ real function table */

static pthread_once_t real_once = PTHREAD_ONCE_INIT;
static void *sys_handle;

static void *find_real(const char *name)
{
    void *p = NULL;
    if (sys_handle)
        p = dlsym(sys_handle, name);
    if (!p)
        p = dlsym(RTLD_NEXT, name);
    if (!p)
        lcsys_log("WARNING: real %s not found: %s", name, dlerror());
    return p;
}

static void resolve_real_once(void)
{
    void *(*real_dlopen)(const char *, int) = (void *(*)(const char *, int))dlsym(RTLD_NEXT, "dlopen");
    if (!real_dlopen)
        real_dlopen = (void *(*)(const char *, int))dlsym(RTLD_DEFAULT, "dlopen");
    lcsys_real.dlopen = real_dlopen;
    if (real_dlopen)
        sys_handle = real_dlopen("/usr/lib/libSystem.B.dylib", RTLD_LAZY);
    lcsys_real.open = (int (*)(const char *, int, ...))find_real("open");
    lcsys_real.openat = (int (*)(int, const char *, int, ...))find_real("openat");
    lcsys_real.stat = (int (*)(const char *, struct stat *))find_real("stat");
    lcsys_real.lstat = (int (*)(const char *, struct stat *))find_real("lstat");
    lcsys_real.fstatat = (int (*)(int, const char *, struct stat *, int))find_real("fstatat");
    lcsys_real.access = (int (*)(const char *, int))find_real("access");
    lcsys_real.faccessat = (int (*)(int, const char *, int, int))find_real("faccessat");
    lcsys_real.opendir = (DIR * (*)(const char *))find_real("opendir");
    lcsys_real.readlink = (ssize_t (*)(const char *, char *, size_t))find_real("readlink");
    lcsys_real.realpath = (char *(*)(const char *, char *))
        (sys_handle ? dlsym(sys_handle, "realpath$DARWIN_EXTSN") : NULL);
    if (!lcsys_real.realpath)
        lcsys_real.realpath = (char *(*)(const char *, char *))find_real("realpath");
    lcsys_real.mkdir = (int (*)(const char *, mode_t))find_real("mkdir");
    lcsys_real.rmdir = (int (*)(const char *))find_real("rmdir");
    lcsys_real.unlink = (int (*)(const char *))find_real("unlink");
    lcsys_real.rename = (int (*)(const char *, const char *))find_real("rename");
    lcsys_real.chmod = (int (*)(const char *, mode_t))find_real("chmod");
    lcsys_real.chdir = (int (*)(const char *))find_real("chdir");
    lcsys_real.exit = (void (*)(int))find_real("exit");
    lcsys_real._exit = (void (*)(int))find_real("_exit");
}

void lcsys_resolve_real(void)
{
    pthread_once(&real_once, resolve_real_once);
}

#define ENSURE() do { if (!lcsys_real.open) lcsys_resolve_real(); } while (0)

/* ---------------------------------------------------------------- init */

static void strip_trailing_slash(char *p)
{
    size_t n = strlen(p);
    while (n > 1 && p[n - 1] == '/')
        p[--n] = '\0';
}

int lcsys_init(const char *bundle_path, const char *home, const char *tmp, int log_fd)
{
    const char *e;
    memset(&lcsys_cfg, 0, sizeof lcsys_cfg);
    lcsys_cfg.log_fd = log_fd;
    snprintf(lcsys_cfg.bundle, sizeof lcsys_cfg.bundle, "%s", bundle_path ? bundle_path : "");
    strip_trailing_slash(lcsys_cfg.bundle);
    snprintf(lcsys_cfg.jb, sizeof lcsys_cfg.jb, "%s/jb", lcsys_cfg.bundle);
    snprintf(lcsys_cfg.frameworks, sizeof lcsys_cfg.frameworks, "%s/Frameworks", lcsys_cfg.bundle);
    snprintf(lcsys_cfg.home, sizeof lcsys_cfg.home, "%s", home ? home : "/");
    strip_trailing_slash(lcsys_cfg.home);
    snprintf(lcsys_cfg.tmp, sizeof lcsys_cfg.tmp, "%s", tmp ? tmp : "/tmp");
    strip_trailing_slash(lcsys_cfg.tmp);
    lcsys_cfg.fork_errno = EAGAIN;
    if ((e = getenv("LCSYS_FORK_ERRNO")) != NULL && atoi(e) > 0)
        lcsys_cfg.fork_errno = atoi(e);
    lcsys_cfg.trace = (e = getenv("LCSYS_TRACE")) != NULL && atoi(e) > 0;

    lcsys_resolve_real();
    signal(SIGPIPE, SIG_IGN); /* libwayland / pipes: never die on a closed reader */
    lcsys_ready = 1;
    lcsys_log("init bundle=%s home=%s tmp=%s log_fd=%d real_open=%p sys_handle=%p fork_errno=%d",
              lcsys_cfg.bundle, lcsys_cfg.home, lcsys_cfg.tmp, log_fd, (void *)lcsys_real.open, sys_handle,
              lcsys_cfg.fork_errno);
    return 0;
}

/* --------------------------------------------- path-taking overrides */

#define MAPPED(in, buf) (lcsys_ready ? lcsys_resolve_path((in), (buf), sizeof(buf)) : (in))

int open(const char *path, int oflag, ...)
{
    char buf[LCSYS_PATH_MAX];
    mode_t mode = 0;
    ENSURE();
    if (oflag & O_CREAT) {
        va_list ap;
        va_start(ap, oflag);
        mode = (mode_t)va_arg(ap, int);
        va_end(ap);
    }
    return lcsys_real.open(MAPPED(path, buf), oflag, mode);
}

int openat(int fd, const char *path, int oflag, ...)
{
    char buf[LCSYS_PATH_MAX];
    mode_t mode = 0;
    ENSURE();
    if (oflag & O_CREAT) {
        va_list ap;
        va_start(ap, oflag);
        mode = (mode_t)va_arg(ap, int);
        va_end(ap);
    }
    if (fd == AT_FDCWD || (path && path[0] == '/'))
        path = MAPPED(path, buf);
    return lcsys_real.openat(fd, path, oflag, mode);
}

int stat(const char *path, struct stat *st)
{
    char buf[LCSYS_PATH_MAX];
    ENSURE();
    return lcsys_real.stat(MAPPED(path, buf), st);
}

/* lstat / readlink: a ".symlink" marker is reported as a symlink to its target. */
static int marker_for(const char *path, char *marker, size_t cap, char *target, size_t tcap)
{
    char buf[LCSYS_PATH_MAX];
    struct stat st;
    int fd;
    ssize_t n;
    if (!lcsys_ready)
        return 0;
    lcsys_map_path(path, buf, sizeof buf);
    if (lcsys_real.lstat(buf, &st) == 0)
        return 0;
    if (snprintf(marker, cap, "%s.symlink", buf) >= (int)cap)
        return 0;
    fd = lcsys_real.open(marker, O_RDONLY | O_CLOEXEC, 0);
    if (fd < 0)
        return 0;
    n = read(fd, target, tcap - 1);
    close(fd);
    if (n <= 0)
        return 0;
    target[n] = '\0';
    while (n > 0 && (target[n - 1] == '\n' || target[n - 1] == '\r'))
        target[--n] = '\0';
    return n > 0;
}

int lstat(const char *path, struct stat *st)
{
    char buf[LCSYS_PATH_MAX], marker[LCSYS_PATH_MAX], target[LCSYS_PATH_MAX];
    ENSURE();
    if (marker_for(path, marker, sizeof marker, target, sizeof target)) {
        int r = lcsys_real.lstat(marker, st);
        if (r == 0) {
            st->st_mode = (st->st_mode & ~S_IFMT) | S_IFLNK;
            st->st_size = (off_t)strlen(target);
        }
        return r;
    }
    return lcsys_real.lstat(lcsys_ready ? lcsys_resolve_path(path, buf, sizeof buf) : path, st);
}

int fstatat(int fd, const char *path, struct stat *st, int flag)
{
    char buf[LCSYS_PATH_MAX];
    ENSURE();
    if (fd == AT_FDCWD || (path && path[0] == '/'))
        path = MAPPED(path, buf);
    return lcsys_real.fstatat(fd, path, st, flag);
}

int access(const char *path, int mode)
{
    char buf[LCSYS_PATH_MAX];
    ENSURE();
    return lcsys_real.access(MAPPED(path, buf), mode);
}

int faccessat(int fd, const char *path, int mode, int flag)
{
    char buf[LCSYS_PATH_MAX];
    ENSURE();
    if (fd == AT_FDCWD || (path && path[0] == '/'))
        path = MAPPED(path, buf);
    return lcsys_real.faccessat(fd, path, mode, flag);
}

DIR *opendir(const char *path)
{
    char buf[LCSYS_PATH_MAX];
    ENSURE();
    return lcsys_real.opendir(MAPPED(path, buf));
}

ssize_t readlink(const char *path, char *out, size_t bufsize)
{
    char buf[LCSYS_PATH_MAX], marker[LCSYS_PATH_MAX], target[LCSYS_PATH_MAX];
    ENSURE();
    if (marker_for(path, marker, sizeof marker, target, sizeof target)) {
        size_t n = strlen(target);
        if (n > bufsize)
            n = bufsize;
        memcpy(out, target, n);
        return (ssize_t)n;
    }
    return lcsys_real.readlink(MAPPED(path, buf), out, bufsize);
}

/* realpath exists under two names on Darwin: the plain one and the
 * $DARWIN_EXTSN variant (accepts NULL for resolved) that headers select by
 * default, so guests may import either. Define both. */
static char *lc_realpath_impl(const char *path, char *resolved)
{
    char buf[LCSYS_PATH_MAX];
    ENSURE();
    return lcsys_real.realpath(MAPPED(path, buf), resolved);
}
char *lc_realpath_plain(const char *__restrict, char *__restrict) __asm__("_realpath");
char *lc_realpath_plain(const char *__restrict path, char *__restrict resolved)
{
    return lc_realpath_impl(path, resolved);
}
char *lc_realpath_extsn(const char *__restrict, char *__restrict) __asm__("_realpath$DARWIN_EXTSN");
char *lc_realpath_extsn(const char *__restrict path, char *__restrict resolved)
{
    return lc_realpath_impl(path, resolved);
}

int mkdir(const char *path, mode_t mode)
{
    char buf[LCSYS_PATH_MAX];
    ENSURE();
    return lcsys_real.mkdir(MAPPED(path, buf), mode);
}

int rmdir(const char *path)
{
    char buf[LCSYS_PATH_MAX];
    ENSURE();
    return lcsys_real.rmdir(MAPPED(path, buf));
}

int unlink(const char *path)
{
    char buf[LCSYS_PATH_MAX];
    ENSURE();
    return lcsys_real.unlink(MAPPED(path, buf));
}

int rename(const char *from, const char *to)
{
    char a[LCSYS_PATH_MAX], b[LCSYS_PATH_MAX];
    ENSURE();
    return lcsys_real.rename(MAPPED(from, a), MAPPED(to, b));
}

int chmod(const char *path, mode_t mode)
{
    char buf[LCSYS_PATH_MAX];
    ENSURE();
    return lcsys_real.chmod(MAPPED(path, buf), mode);
}

int chdir(const char *path)
{
    char buf[LCSYS_PATH_MAX];
    ENSURE();
    if (lcsys_cfg.trace)
        lcsys_log("chdir(%s) (process-global in G1)", path ? path : "(null)");
    return lcsys_real.chdir(MAPPED(path, buf));
}

/* ------------------------------------------------ process overrides */

static void log_argv(const char *what, const char *path, char *const argv[])
{
    char line[1024];
    size_t o = 0;
    int i;
    line[0] = '\0';
    for (i = 0; argv && argv[i] && o < sizeof line - 4; i++) {
        int n = snprintf(line + o, sizeof line - o, "%s\"%s\"", i ? " " : "", argv[i]);
        if (n < 0)
            break;
        o += (size_t)n;
        if (o >= sizeof line)
            o = sizeof line - 1;
    }
    lcsys_log("%s(%s) argv=[%s] -> ENOSYS (G1: no exec)", what, path ? path : "(null)", line);
}

int execve(const char *path, char *const argv[], char *const envp[])
{
    (void)envp;
    log_argv("execve", path, argv);
    errno = ENOSYS;
    return -1;
}

int execv(const char *path, char *const argv[])
{
    log_argv("execv", path, argv);
    errno = ENOSYS;
    return -1;
}

int execvp(const char *file, char *const argv[])
{
    log_argv("execvp", file, argv);
    errno = ENOSYS;
    return -1;
}

int posix_spawn(pid_t *pid, const char *path, const posix_spawn_file_actions_t *file_actions,
                const posix_spawnattr_t *attrp, char *const argv[], char *const envp[])
{
    (void)pid; (void)file_actions; (void)attrp; (void)envp;
    log_argv("posix_spawn", path, argv);
    return ENOSYS; /* posix_spawn returns the error number, errno is not set */
}

int posix_spawnp(pid_t *pid, const char *file, const posix_spawn_file_actions_t *file_actions,
                 const posix_spawnattr_t *attrp, char *const argv[], char *const envp[])
{
    (void)pid; (void)file_actions; (void)attrp; (void)envp;
    log_argv("posix_spawnp", file, argv);
    return ENOSYS;
}

pid_t fork(void)
{
    lcsys_log("fork() -> -1 errno=%d (G1: no fork)", lcsys_cfg.fork_errno);
    errno = lcsys_cfg.fork_errno ? lcsys_cfg.fork_errno : EAGAIN;
    return -1;
}

/* unistd.h may mark vfork unavailable on iOS; define the symbol under another C name */
pid_t lc_vfork(void) __asm__("_vfork");
pid_t lc_vfork(void)
{
    lcsys_log("vfork() -> -1 errno=%d (G1: no fork)", lcsys_cfg.fork_errno);
    errno = lcsys_cfg.fork_errno ? lcsys_cfg.fork_errno : EAGAIN;
    return -1;
}

void exit(int status)
{
    ENSURE();
    lcsys_guest_exit(status); /* does not return on a guest thread */
    lcsys_real.exit(status);
    __builtin_unreachable();
}

void _exit(int status)
{
    ENSURE();
    lcsys_guest_exit(status);
    lcsys_real._exit(status);
    __builtin_unreachable();
}

void *dlopen(const char *path, int mode)
{
    char buf[LCSYS_PATH_MAX];
    const char *use = path;
    ENSURE();
    if (path && lcsys_ready && path[0] == '/') {
        /* guest absolute path: map it (the file may be a "<name>.lc" stub) and turn an
         * @LC: stub into the Frameworks dylib, e.g. /var/jb/usr/lib/gdk-pixbuf-2.0/2.10.0/
         * loaders/libpixbufloader-svg.so -> jb/.../libpixbufloader-svg.so.lc -> Frameworks/
         * libpixbufloader-svg.so; a path with no file behind it (shared-cache libs) is
         * passed through */
        if (lcsys_resolve_macho(path, buf, sizeof buf))
            use = buf;
    }
    if (lcsys_cfg.trace || (use != path))
        lcsys_log("dlopen(%s) -> %s", path ? path : "(null)", use ? use : "(null)");
    return lcsys_real.dlopen(use, mode);
}
