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
 * execv/execve/execvp: still stubs (they must not return, and a thread cannot
 * replace itself in place). posix_spawn/posix_spawnp go to procd for real.
 * fork/vfork: log, fail with EAGAIN
 * (LCSYS_FORK_ERRNO=<n> overrides; bash retries EAGAIN with 1,2,4,8,16 s
 * sleeps, ENOSYS makes it give up at once).
 * exit/_exit on a guest thread: record the status and end the thread only.
 */
#include "lcsys.h"

#include <crt_externs.h>   /* environ は iOS では _NSGetEnviron() 経由 */
#include <pwd.h>
#include <dlfcn.h>
#include <errno.h>
#include <fcntl.h>
#include <pthread.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <sys/resource.h>
#include <sys/wait.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <stddef.h>

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
    lcsys_real.statfs = (int (*)(const char *, struct statfs *))find_real("statfs");
    lcsys_real.statvfs = (int (*)(const char *, struct statvfs *))find_real("statvfs");
    lcsys_real.lstat = (int (*)(const char *, struct stat *))find_real("lstat");
    lcsys_real.fstatat = (int (*)(int, const char *, struct stat *, int))find_real("fstatat");
    lcsys_real.access = (int (*)(const char *, int))find_real("access");
    lcsys_real.faccessat = (int (*)(int, const char *, int, int))find_real("faccessat");
    lcsys_real.opendir = (DIR * (*)(const char *))find_real("opendir");
    lcsys_real.closedir = (int (*)(DIR *))find_real("closedir");
    lcsys_real.readdir = (struct dirent * (*)(DIR *))find_real("readdir");
    lcsys_real.readdir_r = (int (*)(DIR *, struct dirent *, struct dirent **))find_real("readdir_r");
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
    lcsys_real.fopen = (FILE *(*)(const char *, const char *))find_real("fopen");
    lcsys_real.freopen = (FILE *(*)(const char *, const char *, FILE *))find_real("freopen");
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
    /* Must be in place before any guest starts: iosc reaches the Metal fence broker
     * through NSXPCConnection at startup and aborts if the publish fails (xpcshim.m). */
    lcsys_install_xpc_shim();
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

/* A lookup relative to a real directory fd cannot go through lcsys_resolve_path:
 * we do not know which directory the fd is. readdir() now hands callers "ls" where
 * the file on disk is the "ls.lc" stub, and coreutils ls stats what readdir gave it
 * with fstatat(dirfd(dirp), name, ...) - so the *at() family retries the stub name,
 * but only for a bare name whose plain lookup already failed with ENOENT. Nothing
 * outside the jb tree is affected: there are no .lc files there, so the retry misses
 * and the original ENOENT stands. */
static int lc_stub_name(const char *path, char *buf, size_t cap)
{
    if (!lcsys_ready || !path || !*path || strchr(path, '/') != NULL)
        return 0;
    return snprintf(buf, cap, "%s%s", path, LCSYS_STUB_SUFFIX) < (int)cap;
}

int openat(int fd, const char *path, int oflag, ...)
{
    char buf[LCSYS_PATH_MAX], stub[LCSYS_PATH_MAX];
    mode_t mode = 0;
    int r;
    ENSURE();
    if (oflag & O_CREAT) {
        va_list ap;
        va_start(ap, oflag);
        mode = (mode_t)va_arg(ap, int);
        va_end(ap);
    }
    if (fd == AT_FDCWD || (path && path[0] == '/'))
        path = MAPPED(path, buf);
    r = lcsys_real.openat(fd, path, oflag, mode);
    if (r < 0 && errno == ENOENT && !(oflag & O_CREAT) && lc_stub_name(path, stub, sizeof stub))
        r = lcsys_real.openat(fd, stub, oflag, mode);
    return r;
}

/* fopen/freopen: see the note in lcsys.h. Without these, everything that reads a data file
 * through the stdio layer (xkbcommon's rules, fontconfig, gsettings schemas, ...) bypasses
 * the /var/jb mapping, because libSystem calls its OWN open() internally. */
static FILE *lc_fopen_impl(const char *path, const char *mode)
{
    char buf[LCSYS_PATH_MAX];
    ENSURE();
    return lcsys_real.fopen(MAPPED(path, buf), mode);
}

/* fopen も realpath と同じで Darwin では 2 つの名前を持つ。<stdio.h> が
 * __DARWIN_ALIAS_STARTING で切り替えるので、どちらで呼ばれるかはゲストの
 * 各パッケージのビルド設定次第になる。実測(ipa 内の 308 本を走査):
 * plain が iosc など、`$DARWIN_EXTSN` が libxkbcommon を含む 132 本。
 * 片方しか定義していなかったので、その 132 本は経路変換を素通りしていた。 */
FILE *lc_fopen_plain(const char *, const char *) __asm__("_fopen");
FILE *lc_fopen_plain(const char *path, const char *mode)
{
    return lc_fopen_impl(path, mode);
}

FILE *lc_fopen_extsn(const char *, const char *) __asm__("_fopen$DARWIN_EXTSN");
FILE *lc_fopen_extsn(const char *path, const char *mode)
{
    return lc_fopen_impl(path, mode);
}

FILE *freopen(const char *path, const char *mode, FILE *stream)
{
    char buf[LCSYS_PATH_MAX];
    ENSURE();
    return lcsys_real.freopen(path ? MAPPED(path, buf) : path, mode, stream);
}

/* ゲストが標準入出力を差し替えると、プロセス全体で 1 組しかないので
 * こちらのログの通り道まで巻き込まれる(fork の子は普通 /dev/null を被せる)。
 * ゲストのスレッドからの 0/1/2 への差し替えと閉じるのは空振りさせる。 */
int dup2(int oldfd, int newfd)
{
    static int (*real)(int, int);
    if (newfd >= 0 && newfd <= 2 && lcsys_is_guest_thread()) {
        lcsys_log("dup2(%d -> %d): ゲストなので見送る(ログの通り道を守る)", oldfd, newfd);
        return newfd;
    }
    if (!real)
        real = (int (*)(int, int))find_real("dup2");
    return real ? real(oldfd, newfd) : -1;
}

static int lc_close_impl(int fd)
{
    static int (*real)(int);
    if (fd >= 0 && fd <= 2 && lcsys_is_guest_thread()) {
        lcsys_log("close(%d): ゲストなので見送る", fd);
        return 0;
    }
    /* fork の子からの close は全部見送る。本物の fork なら親子で fd の表が
     * 分かれるが、ここでは 1 つしか無いので、子が閉じると親の分まで消える。
     * 子は exec して消えるだけなので、閉じ損ねても行儀の悪さで済む */
    if (fd >= 0 && lcsys_is_fork_child()) {
        lcsys_log("close(%d): fork の子なので見送る(fd の表は親と共有)", fd);
        return 0;
    }
    if (!real)
        real = (int (*)(int))find_real("close");
    return real ? real(fd) : -1;
}

/* close も名前が 2 つある。`$NOCANCEL` は「スレッドの取り消し点にしない」版で、
 * glib はこちらを呼ぶ。片方だけ定義すると素通りする(ビルド時の
 * tools/xios/audit_aliases.py が検出した)。 */
int lc_close_plain(int) __asm__("_close");
int lc_close_plain(int fd)
{
    return lc_close_impl(fd);
}

int lc_close_nocancel(int) __asm__("_close$NOCANCEL");
int lc_close_nocancel(int fd)
{
    return lc_close_impl(fd);
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

/* ------------------------------------------------------------ 利用者の台帳
 *
 * アプリのサンドボックスからは利用者の台帳が引けない。dbus はここで転ぶ
 * (実機 2026-09-12:
 *  `Could not get password database information for UID of current process:
 *   User "???" unknown` -> `Failed to start message bus`)。
 * 台帳そのものは iOS にも在るが、サンドボックスの中からは読めない。
 * 中身は「mobile / uid 501」で決まっているので、その 1 件だけを自前で返す。 */

static struct passwd *lcsys_passwd(void)
{
    static struct passwd pw;
    static char name[] = "mobile";
    static char pass[] = "*";
    static char gecos[] = "Mobile User";
    static char shell[] = "/var/jb/usr/bin/bash";
    static char home[LCSYS_PATH_MAX];
    static int ready;

    if (!ready) {
        ENSURE();
        snprintf(home, sizeof home, "%s", lcsys_cfg.home[0] ? lcsys_cfg.home : "/var/mobile");
        pw.pw_name = name;
        pw.pw_passwd = pass;
        pw.pw_uid = getuid();
        pw.pw_gid = getgid();
        pw.pw_gecos = gecos;
        pw.pw_dir = home;
        pw.pw_shell = shell;
        ready = 1;
    }
    return &pw;
}

static int copy_passwd(struct passwd *out, char *buf, size_t cap, struct passwd **res)
{
    struct passwd *src = lcsys_passwd();
    size_t need;
    char *p = buf;
    const char *fields[5];
    char **dst[5];
    int i;

    fields[0] = src->pw_name;   dst[0] = &out->pw_name;
    fields[1] = src->pw_passwd; dst[1] = &out->pw_passwd;
    fields[2] = src->pw_gecos;  dst[2] = &out->pw_gecos;
    fields[3] = src->pw_dir;    dst[3] = &out->pw_dir;
    fields[4] = src->pw_shell;  dst[4] = &out->pw_shell;

    need = 0;
    for (i = 0; i < 5; i++)
        need += strlen(fields[i]) + 1;
    if (need > cap) {
        if (res)
            *res = NULL;
        return ERANGE;
    }
    memset(out, 0, sizeof *out);
    out->pw_uid = src->pw_uid;
    out->pw_gid = src->pw_gid;
    for (i = 0; i < 5; i++) {
        size_t n = strlen(fields[i]) + 1;
        memcpy(p, fields[i], n);
        *dst[i] = p;
        p += n;
    }
    if (res)
        *res = out;
    return 0;
}

struct passwd *getpwuid(uid_t uid)
{
    (void)uid;
    return lcsys_passwd();
}

struct passwd *getpwnam(const char *name)
{
    (void)name;
    return lcsys_passwd();
}

int getpwuid_r(uid_t uid, struct passwd *pwd, char *buf, size_t cap, struct passwd **res)
{
    (void)uid;
    return copy_passwd(pwd, buf, cap, res);
}

int getpwnam_r(const char *name, struct passwd *pwd, char *buf, size_t cap, struct passwd **res)
{
    (void)name;
    return copy_passwd(pwd, buf, cap, res);
}

char *getlogin(void)
{
    return lcsys_passwd()->pw_name;
}

/* ---------------------------------------------------------------- libiosexec の台帳
 *
 * Procursus の libiosexec は LIBIOSEXEC_PREFIXED_ROOT=1 で組まれていて、getpwuid_r ではなく
 * 自前の ie_getpwuid_r(OpenBSD getpwent.c)を持つ。ipa 345 本中 295 本がそれを呼ぶので
 * 上の getpwuid 横取りは届かない(dbus は libdbus → ie_getpwuid_r。実機 2026-09-13 も
 * `User "???" unknown` のままだった)。ie_ 版は /var/jb/etc/pwd.db を dbopen で開く
 * ハッシュ DB 方式で、それを作る postinst(pwd_mkdb)は走っていないので DB が無い。
 * libiosexec の読み先は libLCsys なので dbopen を横取りし、pwd.db / spwd.db に対しては
 * mobile と root の 2 件だけを持つ偽 DB を返す。鍵と値の並びは getpwent.c
 * (_pwhashbyname / _pwhashbyuid / __hashpw)のとおり。group / shells はテキストなので
 * stage.py が jb/etc に置く。 */

typedef struct { void *data; size_t size; } lc_dbt;
typedef struct lc_db {
    int type;                                   /* DBTYPE(DB_HASH = 1) */
    int (*close)(struct lc_db *);
    int (*del)(const struct lc_db *, const lc_dbt *, unsigned);
    int (*get)(const struct lc_db *, const lc_dbt *, lc_dbt *, unsigned);
    int (*put)(const struct lc_db *, lc_dbt *, const lc_dbt *, unsigned);
    int (*seq)(const struct lc_db *, lc_dbt *, lc_dbt *, unsigned);
    int (*sync)(const struct lc_db *, unsigned);
    void *internal;
    int (*fd)(const struct lc_db *);
} lc_db;

struct lc_pwrec { const char *name, *gecos, *dir, *shell; unsigned uid, gid; };
struct lc_pwdb { char buf[512]; };

static const struct lc_pwrec *lc_pw_table(int *count)
{
    static struct lc_pwrec t[2];
    static int ready;
    if (!ready) {
        struct passwd *me = lcsys_passwd();
        t[0].name = me->pw_name; t[0].gecos = me->pw_gecos; t[0].dir = me->pw_dir; t[0].shell = me->pw_shell;
        t[0].uid = (unsigned)me->pw_uid; t[0].gid = (unsigned)me->pw_gid;
        t[1].name = "root"; t[1].gecos = "System Administrator"; t[1].dir = "/var/root";
        t[1].shell = "/var/jb/usr/bin/bash"; t[1].uid = 0; t[1].gid = 0;
        ready = 1;
    }
    *count = 2;
    return t;
}

/* name\0 passwd\0 uid(int) gid(int) change(time_t) class\0 gecos\0 dir\0 shell\0 expire(time_t) */
static size_t lc_pw_pack(const struct lc_pwrec *r, char *out, size_t cap)
{
    char *p = out;
    int i;
    long long t = 0;
#define LC_PUTS(s) do { size_t n_ = strlen(s) + 1; if ((size_t)(p - out) + n_ > cap) return 0; memcpy(p, (s), n_); p += n_; } while (0)
#define LC_PUTB(v, n) do { if ((size_t)(p - out) + (n) > cap) return 0; memcpy(p, (v), (n)); p += (n); } while (0)
    LC_PUTS(r->name);
    LC_PUTS("*");
    i = (int)r->uid; LC_PUTB(&i, sizeof i);
    i = (int)r->gid; LC_PUTB(&i, sizeof i);
    LC_PUTB(&t, sizeof t);
    LC_PUTS("");
    LC_PUTS(r->gecos);
    LC_PUTS(r->dir);
    LC_PUTS(r->shell);
    LC_PUTB(&t, sizeof t);
#undef LC_PUTS
#undef LC_PUTB
    return (size_t)(p - out);
}

static int lc_pwdb_get(const lc_db *db, const lc_dbt *key, lc_dbt *data, unsigned flags)
{
    struct lc_pwdb *st = db->internal;
    const unsigned char *k = key ? key->data : NULL;
    const struct lc_pwrec *t, *r = NULL;
    int n, i;
    size_t len;
    (void)flags;
    if (!k || key->size < 1)
        return 1;
    t = lc_pw_table(&n);
    if (k[0] == '1') {                                                  /* _PW_KEYBYNAME */
        for (i = 0; i < n; i++)
            if (strlen(t[i].name) == key->size - 1 && memcmp(t[i].name, k + 1, key->size - 1) == 0)
                r = &t[i];
    } else if (k[0] == '3' && key->size == 1 + sizeof(unsigned)) {     /* _PW_KEYBYUID */
        unsigned u;
        memcpy(&u, k + 1, sizeof u);
        for (i = 0; i < n; i++)
            if (t[i].uid == u)
                r = &t[i];
    } else if (k[0] == '2' && key->size == 1 + sizeof(int)) {          /* _PW_KEYBYNUM(1 始まり) */
        int num;
        memcpy(&num, k + 1, sizeof num);
        if (num >= 1 && num <= n)
            r = &t[num - 1];
    }
    if (!r)
        return 1;
    len = lc_pw_pack(r, st->buf, sizeof st->buf);
    if (!len)
        return -1;
    data->data = st->buf;
    data->size = len;
    return 0;
}
static int lc_pwdb_close(lc_db *db) { free(db->internal); free(db); return 0; }
static int lc_pwdb_del(const lc_db *db, const lc_dbt *k, unsigned f) { (void)db; (void)k; (void)f; errno = EPERM; return -1; }
static int lc_pwdb_put(const lc_db *db, lc_dbt *k, const lc_dbt *d, unsigned f) { (void)db; (void)k; (void)d; (void)f; errno = EPERM; return -1; }
static int lc_pwdb_seq(const lc_db *db, lc_dbt *k, lc_dbt *d, unsigned f) { (void)db; (void)k; (void)d; (void)f; return 1; }
static int lc_pwdb_sync(const lc_db *db, unsigned f) { (void)db; (void)f; return 0; }
static int lc_pwdb_fd(const lc_db *db) { (void)db; errno = ENOENT; return -1; }

static lc_db *lc_pwdb_open(void)
{
    lc_db *db = calloc(1, sizeof *db);
    struct lc_pwdb *st = calloc(1, sizeof *st);
    if (!db || !st) {
        free(db);
        free(st);
        errno = ENOMEM;
        return NULL;
    }
    db->type = 1;
    db->close = lc_pwdb_close;
    db->del = lc_pwdb_del;
    db->get = lc_pwdb_get;
    db->put = lc_pwdb_put;
    db->seq = lc_pwdb_seq;
    db->sync = lc_pwdb_sync;
    db->internal = st;
    db->fd = lc_pwdb_fd;
    return db;
}

static int lc_suffix(const char *s, const char *suf)
{
    size_t a = strlen(s), b = strlen(suf);
    return a >= b && strcmp(s + a - b, suf) == 0;
}

void *dbopen(const char *file, int flags, int mode, int type, const void *openinfo)
{
    static void *(*real)(const char *, int, int, int, const void *);
    static int logged;
    if (file && (lc_suffix(file, "/etc/pwd.db") || lc_suffix(file, "/etc/spwd.db"))) {
        if (!logged) {
            logged = 1;
            lcsys_log("dbopen(%s): 偽の passwd 台帳(mobile / root)を返す", file);
        }
        return lc_pwdb_open();
    }
    if (!real)
        real = (void *(*)(const char *, int, int, int, const void *))find_real("dbopen");
    if (!real) {
        errno = ENOENT;
        return NULL;
    }
    return real(file, flags, mode, type, openinfo);
}

/* dbus は passwd の後に getgrouplist で所属グループを引く。iOS の本物は membership
 * (OpenDirectory)経由で、サンドボックスの中から引けるかは分からない。主グループ 1 件で答える。 */
int getgrouplist(const char *name, int basegid, int *groups, int *ngroups)
{
    (void)name;
    if (!groups || !ngroups) {
        errno = EINVAL;
        return -1;
    }
    if (*ngroups < 1) {
        *ngroups = 1;
        return -1;
    }
    groups[0] = basegid;
    *ngroups = 1;
    return 0;
}

/* ---------------------------------------------------------------- AF_UNIX のパス
 *
 * bind / connect はこれまで横取りしていなかった(iosc の wayland ソケットはホストの実パスを
 * 渡していたので通っていた)。dbus-daemon は session.conf の unix:tmpdir=/var/jb/tmp や
 * シェルの /var/jb/tmp/iosc-shell-bus/session-bus をそのまま bind するので経路変換が要る。
 * さらに変換後は $TMPDIR(実機 88 文字)の下になり、sun_path の 104 バイトを超える
 * (…/tmp/iosc-shell-bus/session-bus で 116)。長いときは、そのスレッドだけの作業
 * ディレクトリ(pthread_fchdir_np、libsystem_pthread が公開している)を親ディレクトリに
 * 向けて相対名で bind / connect し、終わったら戻す。プロセス全体の cwd は触らない。 */

static int lc_thread_fchdir(int fd)
{
    static int (*fn)(int);
    static int ready;
    if (!ready) {
        fn = (int (*)(int))dlsym(RTLD_DEFAULT, "pthread_fchdir_np");
        ready = 1;
        if (!fn)
            lcsys_log("WARNING: pthread_fchdir_np が無い。sun_path に収まらない AF_UNIX パスは通せない");
    }
    return fn ? fn(fd) : -1;
}

typedef int (*lc_sockop)(int, const struct sockaddr *, socklen_t);

static int lc_unix_sockop(lc_sockop op, const char *what, int fd, const struct sockaddr *sa, socklen_t len)
{
    static int (*real_close)(int);
    const struct sockaddr_un *in = (const struct sockaddr_un *)sa;
    struct sockaddr_un out;
    char guest[LCSYS_PATH_MAX], host[LCSYS_PATH_MAX];
    size_t plen, maxlen = sizeof out.sun_path - 1;
    const char *use;
    int dirfd = -1, r, saved;

    /* sun_path は NUL 終端されていないことがある(長さは sun_len / len が持つ) */
    plen = len > offsetof(struct sockaddr_un, sun_path) ? len - offsetof(struct sockaddr_un, sun_path) : 0;
    if (plen > sizeof in->sun_path)
        plen = sizeof in->sun_path;
    plen = strnlen(in->sun_path, plen);
    if (plen == 0 || in->sun_path[0] != '/' || plen >= sizeof guest)
        return op(fd, sa, len);
    memcpy(guest, in->sun_path, plen);
    guest[plen] = '\0';
    lcsys_map_path(guest, host, sizeof host);
    use = host;
    if (strlen(host) > maxlen) {
        char *slash = strrchr(host, '/');
        if (!slash || slash == host) {
            errno = ENAMETOOLONG;
            return -1;
        }
        *slash = '\0';
        dirfd = open(host, O_RDONLY | O_DIRECTORY);
        if (dirfd < 0) {
            saved = errno;
            lcsys_log("%s(%s): 親 %s が開けない errno %d", what, guest, host, saved);
            errno = saved;
            return -1;
        }
        if (lc_thread_fchdir(dirfd) != 0) {
            saved = errno;
            if (!real_close)
                real_close = (int (*)(int))find_real("close");
            if (real_close)
                real_close(dirfd);
            errno = saved ? saved : ENAMETOOLONG;
            return -1;
        }
        use = slash + 1;
    }
    memset(&out, 0, sizeof out);
    out.sun_family = AF_UNIX;
    snprintf(out.sun_path, sizeof out.sun_path, "%s", use);
    out.sun_len = (unsigned char)(offsetof(struct sockaddr_un, sun_path) + strlen(use) + 1);
    r = op(fd, (const struct sockaddr *)&out, (socklen_t)out.sun_len);
    saved = errno;
    if (dirfd >= 0) {
        lc_thread_fchdir(-1);
        if (!real_close)
            real_close = (int (*)(int))find_real("close");
        if (real_close)
            real_close(dirfd);   /* fork の子でも本当に閉じる(自分で開いた fd) */
    }
    if (lcsys_cfg.trace || r != 0)
        lcsys_log("%s(%s) -> %s%s = %d errno %d", what, guest, dirfd >= 0 ? "<親>/" : "", use, r, saved);
    errno = saved;
    return r;
}

int bind(int fd, const struct sockaddr *sa, socklen_t len)
{
    static lc_sockop real;
    if (!real)
        real = (lc_sockop)find_real("bind");
    if (!real) {
        errno = ENOSYS;
        return -1;
    }
    if (!lcsys_ready || !sa || sa->sa_family != AF_UNIX)
        return real(fd, sa, len);
    return lc_unix_sockop(real, "bind", fd, sa, len);
}

static int lc_connect_impl(int fd, const struct sockaddr *sa, socklen_t len)
{
    static lc_sockop real;
    if (!real)
        real = (lc_sockop)find_real("connect");
    if (!real) {
        errno = ENOSYS;
        return -1;
    }
    if (!lcsys_ready || !sa || sa->sa_family != AF_UNIX)
        return real(fd, sa, len);
    return lc_unix_sockop(real, "connect", fd, sa, len);
}

/* connect も close と同じく `$NOCANCEL` の別名がある(audit_aliases.py が見張る) */
int lc_connect_plain(int, const struct sockaddr *, socklen_t) __asm__("_connect");
int lc_connect_plain(int fd, const struct sockaddr *sa, socklen_t len)
{
    return lc_connect_impl(fd, sa, len);
}

int lc_connect_nocancel(int, const struct sockaddr *, socklen_t) __asm__("_connect$NOCANCEL");
int lc_connect_nocancel(int fd, const struct sockaddr *sa, socklen_t len)
{
    return lc_connect_impl(fd, sa, len);
}

/* statfs/statvfs: ioscbg のデスクトップ部品(Storage)が空き容量をこれで読む。
 * 横取りしないと /var/jb を本物の根として見に行って失敗する。 */
int statfs(const char *path, struct statfs *b)
{
    char buf[LCSYS_PATH_MAX];
    ENSURE();
    return lcsys_real.statfs(MAPPED(path, buf), b);
}

int statvfs(const char *path, struct statvfs *b)
{
    char buf[LCSYS_PATH_MAX];
    ENSURE();
    return lcsys_real.statvfs(MAPPED(path, buf), b);
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
    char buf[LCSYS_PATH_MAX], stub[LCSYS_PATH_MAX];
    int r;
    ENSURE();
    if (fd == AT_FDCWD || (path && path[0] == '/'))
        path = MAPPED(path, buf);
    r = lcsys_real.fstatat(fd, path, st, flag);
    if (r != 0 && errno == ENOENT && lc_stub_name(path, stub, sizeof stub))
        r = lcsys_real.fstatat(fd, stub, st, flag);
    return r;
}

int access(const char *path, int mode)
{
    char buf[LCSYS_PATH_MAX];
    ENSURE();
    return lcsys_real.access(MAPPED(path, buf), mode);
}

int faccessat(int fd, const char *path, int mode, int flag)
{
    char buf[LCSYS_PATH_MAX], stub[LCSYS_PATH_MAX];
    int r;
    ENSURE();
    if (fd == AT_FDCWD || (path && path[0] == '/'))
        path = MAPPED(path, buf);
    r = lcsys_real.faccessat(fd, path, mode, flag);
    if (r != 0 && errno == ENOENT && lc_stub_name(path, stub, sizeof stub))
        r = lcsys_real.faccessat(fd, stub, mode, flag);
    return r;
}

/* opendir/closedir/readdir/readdir_r: stage.py leaves relinked Mach-Os as
 * "<name>.lc" stubs, so a raw listing of jb/usr/bin shows "ls.lc" and a
 * "*.so" module scan (gdk-pixbuf loaders, gio modules, gtk print backends)
 * matches nothing. The suffix is stripped back out here for directories that
 * live under <bundle>/jb; everything else is passed through untouched.
 * arm64 has no "readdir$INODE64" variants - the 64-bit-inode struct dirent is
 * the only one, so plain readdir/readdir_r are the right symbols. */
DIR *opendir(const char *path)
{
    char buf[LCSYS_PATH_MAX];
    const char *host;
    DIR *d;
    ENSURE();
    host = MAPPED(path, buf);
    d = lcsys_real.opendir(host);
    if (d)
        lcsys_dir_register(d, host); /* no-op unless host is under <bundle>/jb */
    return d;
}

int closedir(DIR *d)
{
    ENSURE();
    lcsys_dir_forget(d);
    return lcsys_real.closedir(d);
}

struct dirent *readdir(DIR *d)
{
    struct lc_dir *ld;
    struct dirent *e, *scratch;
    ENSURE();
    ld = lcsys_ready ? lcsys_dir_find(d) : NULL;
    scratch = lcsys_dir_scratch(ld);
    for (;;) {
        e = lcsys_real.readdir(d);
        if (!e || !scratch)
            return e;
        switch (lcsys_dir_filter(ld, e, scratch)) {
        case 1:
            return scratch; /* per-DIR buffer: same lifetime as libc's own */
        case -1:
            continue;       /* "<name>.lc" shadowed by a real "<name>" */
        default:
            return e;
        }
    }
}

int readdir_r(DIR *d, struct dirent *entry, struct dirent **result)
{
    struct lc_dir *ld;
    int rc;
    ENSURE();
    ld = lcsys_ready ? lcsys_dir_find(d) : NULL;
    for (;;) {
        rc = lcsys_real.readdir_r(d, entry, result);
        if (rc != 0 || !result || !*result || !ld)
            return rc;
        /* the entry lives in the caller's buffer: rewrite in place, no shared state */
        if (lcsys_dir_filter(ld, *result, *result) >= 0)
            return rc;
    }
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

/* exec は「同じプロセスのまま中身が別のプログラムになる」操作で、成功したら戻らない。
 * こちらでは「新しいプログラムをスレッドとして起こし、呼んだ側のスレッドを終える」で
 * 置き換える。呼んだ側が fork の子(= 化けるためだけに居る)なら、これがそのまま
 * 正しい意味になる。擬似 pid は新しい方へ引き継ぐので、親の waitpid も合う。
 *
 * 見つからなければ -1 を返して呼び出し元に次の候補を試させる
 * (libiosexec の ie_execl は PATH の候補を順に試す)。 */
static int exec_here(const char *what, const char *path, char *const argv[], char *const envp[])
{
    int pid;
    log_argv(what, path, argv);
    if (!lcsys_is_guest_thread()) {
        lcsys_log("%s: ゲストのスレッドではないので断る", what);
        errno = ENOSYS;
        return -1;
    }
    pid = lcsys_exec_handover(path, argv, envp ? envp : *_NSGetEnviron());
    if (pid < 0)
        return -1;   /* errno は lcsys_spawn のまま: ENOEXEC(スクリプト)か ENOENT */
    lcsys_guest_exit(0); /* 戻らない: このスレッドはここで終わる */
    errno = ENOSYS;      /* 念のため(guest_exit が戻るのはホストのスレッドだけ) */
    return -1;
}

int execve(const char *path, char *const argv[], char *const envp[])
{
    return exec_here("execve", path, argv, envp);
}

int execv(const char *path, char *const argv[])
{
    return exec_here("execv", path, argv, NULL);
}

int execvp(const char *file, char *const argv[])
{
    return exec_here("execvp", file, argv, NULL);
}

/* posix_spawn は fork と違って「1 回呼んで 1 回返る」ので、スレッドで代われる。
 * fork が絶対に真似できないのは 1 回の呼び出しから 2 回返るからで、posix_spawn には
 * その問題が無い。だからここは本物にできる。
 *
 * file_actions(子の fd を差し替える指示)と attrp は今は見ていない。procd は
 * 出力をプロセス共通のパイプに流すので、多くの用途ではそれで足りる。pty や
 * パイプを要求する相手が出てきたら、そのときに file_actions を解釈する。 */
static int spawn_via_procd(const char *what, pid_t *pid, const char *path,
                           char *const argv[], char *const envp[])
{
    int p;
    log_argv(what, path, argv);
    p = lcsys_spawn(path, argv, envp, -1, -1);
    if (p < 0) {
        int saved = errno;
        lcsys_log("%s: %s を起こせなかった (errno %d)", what, path ? path : "(null)", saved);
        return saved == ENOEXEC ? ENOEXEC : ENOENT;   /* ie_posix_spawn は ENOEXEC で #! を読む */
    }
    if (pid)
        *pid = (pid_t)p;
    lcsys_log("%s: %s -> pid %d(スレッドとして起動)", what, path, p);
    return 0;
}

int posix_spawn(pid_t *pid, const char *path, const posix_spawn_file_actions_t *file_actions,
                const posix_spawnattr_t *attrp, char *const argv[], char *const envp[])
{
    (void)file_actions; (void)attrp;
    return spawn_via_procd("posix_spawn", pid, path, argv, envp);
}

int posix_spawnp(pid_t *pid, const char *file, const posix_spawn_file_actions_t *file_actions,
                 const posix_spawnattr_t *attrp, char *const argv[], char *const envp[])
{
    (void)file_actions; (void)attrp;
    /* p つきは PATH から探す(libiosexec の ie_posix_spawnp と同じ: getenv("PATH") を順に) */
    if (file && !strchr(file, '/')) {
        const char *path_env = getenv("PATH");
        char dirs[LCSYS_PATH_MAX], full[LCSYS_PATH_MAX], *save = NULL, *d;
        snprintf(dirs, sizeof dirs, "%s", path_env && *path_env ? path_env
                 : "/var/jb/usr/local/bin:/var/jb/usr/bin:/var/jb/bin");
        for (d = strtok_r(dirs, ":", &save); d; d = strtok_r(NULL, ":", &save)) {
            if (snprintf(full, sizeof full, "%s/%s", d, file) >= (int)sizeof full)
                continue;
            if (access(full, F_OK) == 0)
                return spawn_via_procd("posix_spawnp", pid, full, argv, envp);
        }
    }
    return spawn_via_procd("posix_spawnp", pid, file, argv, envp);
}

/* fork / vfork は native/lcfork.c に移した(スタックを複製してスレッドで再現する)。
 * 従来どおり -1 を返させたいときは LCSYS_FORK=fail。 */

/* ------------------------------------------------------------ 子を待つ / 殺す
 *
 * 擬似 pid(1000 以上)は procd の台帳にしか無い。本物の waitpid に渡すと ECHILD、
 * 本物の kill に渡すと無関係のプロセスに届きかねない。台帳に在るものはこちらで
 * 受け、無いものだけ本物に流す。dbus-run-session は子を waitpid で待ち(実機 2026-09-12
 * の exit(1) の原因候補)、xios-setsid も同じ。終了コードは WIFEXITED の形に詰める。 */
#define LC_FAKE_PID_MIN 1000

static int known_fake_pid(int pid)
{
    int st;
    return pid >= LC_FAKE_PID_MIN && lcsys_alive(pid, &st) >= 0;
}

pid_t waitpid(pid_t pid, int *status, int options)
{
    static pid_t (*real)(pid_t, int *, int);
    if (pid >= LC_FAKE_PID_MIN && known_fake_pid((int)pid)) {
        int code = 0;
        int r = lcsys_waitpid((int)pid, &code, options & WNOHANG);
        if (r > 0 && status)
            *status = (code & 0xff) << 8;   /* WIFEXITED + WEXITSTATUS */
        return (pid_t)r;
    }
    if (pid == -1 && lcsys_is_guest_thread()) {
        /* 「どれでもいい」はゲストの子の対応関係を持っていないので答えられない。
         * WNOHANG なら「まだ」、そうでなければ子が居ないことにする */
        if (options & WNOHANG)
            return 0;
        errno = ECHILD;
        return -1;
    }
    if (!real)
        real = (pid_t (*)(pid_t, int *, int))find_real("waitpid");
    return real ? real(pid, status, options) : -1;
}

pid_t wait(int *status)
{
    return waitpid(-1, status, 0);
}

pid_t wait4(pid_t pid, int *status, int options, struct rusage *ru)
{
    static pid_t (*real)(pid_t, int *, int, struct rusage *);
    if ((pid >= LC_FAKE_PID_MIN && known_fake_pid((int)pid)) || (pid == -1 && lcsys_is_guest_thread())) {
        if (ru)
            memset(ru, 0, sizeof *ru);
        return waitpid(pid, status, options);
    }
    if (!real)
        real = (pid_t (*)(pid_t, int *, int, struct rusage *))find_real("wait4");
    return real ? real(pid, status, options, ru) : -1;
}

int kill(pid_t pid, int sig)
{
    static int (*real)(pid_t, int);
    if (pid >= LC_FAKE_PID_MIN && known_fake_pid((int)pid))
        return lcsys_kill((int)pid, sig);
    if (!real)
        real = (int (*)(pid_t, int))find_real("kill");
    return real ? real(pid, sig) : -1;
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

/* Upstream bug in the Procursus libpcre2-8.0.dylib we bundle: it lists
 * _SLJIT_UPDATE_WX_FLAGS as undefined (flat namespace) and nothing in the
 * closure exports it, so dlopen(RTLD_NOW) of libpcre2 - and therefore of
 * libglib/GTK, which depend on it - fails outright. It is sljit's W^X
 * cache-flush hook. On this device mmap(MAP_JIT) is EPERM (G0), so pcre2's
 * JIT compile fails and pcre2 falls back to its interpreter: the hook is never
 * reached with real code to flush, and a no-op is the correct body.
 * libLCsys is dlopen'd RTLD_GLOBAL by Runner.swift, so the flat-namespace
 * lookup finds this definition. (C adds the leading underscore.) */
__attribute__((visibility("default")))
void SLJIT_UPDATE_WX_FLAGS(void *from, void *to, int exec)
{
    (void)from;
    (void)to;
    (void)exec;
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
