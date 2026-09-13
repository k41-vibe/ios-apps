/*
 * procd.c - a Linux "process" is a thread: dlopen the relinked executable
 * (an MH_DYLIB that kept its LC_MAIN) and call its entry point on a pthread.
 *
 *   entry = (char *)mach_header + entry_point_command.entryoff
 *   int main(int argc, char **argv, char **envp, char **apple)
 *
 * (the same call dyld/libdyld makes for an LC_MAIN executable; LiveContainer
 * launches guest apps this way, ios_system runs its commands this way).
 *
 * pids are synthetic (>= 1000). The image is never dlclose'd, and dyld hands the
 * same image back for the same path, so a second spawn of one binary would re-enter
 * main() on top of the first run's statics - the G1 "ls twice" test. Two defences:
 * each spawn dlopens a private copy under <tmp>/procd (new path = new image), and
 * whatever getopt state the image exports is reset (reset_guest_getopt).
 *
 * G1 limits: fd 0/1/2, cwd and environ are shared by every guest thread
 * (fd_out/fd_err are accepted but ignored). exit()/_exit() from a guest
 * thread end only that thread (lcsys_guest_exit, called from lcsys.c).
 */
#include "lcsys.h"

#include <dirent.h>
#include <dlfcn.h>
#include <crt_externs.h>
#include <errno.h>
#include <fcntl.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/un.h>
#include <limits.h>
#include <mach-o/dyld.h>
#include <mach-o/loader.h>
#include <pthread.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#define GUEST_STACK (8u << 20)

typedef int (*guest_main_fn)(int, char **, char **, char **);

struct lc_proc {
    int pid;
    pthread_t thread;
    int argc;
    char **argv;
    char **envp;
    char *guest_path;   /* argv[0]-style path, e.g. /var/jb/usr/bin/ls */
    char *image_path;   /* <bundle>/Frameworks/ls.exe.dylib */
    guest_main_fn entry;
    int status;         /* exit code 0..255 */
    int done;
    int fork_child;     /* fork の子(exec で化けるためだけに居る短命なスレッド) */
    int single_instance; /* GLib/GTK を使う: 同じプロセスに 2 本目は起こせない(型登録が 1 つ) */
    int detached;       /* pthread_detach 済み: join できないので done を見て待つ */
    struct lc_proc *next;
};

static pthread_key_t guest_key;
static pthread_once_t key_once = PTHREAD_ONCE_INIT;
static pthread_once_t sweep_once = PTHREAD_ONCE_INIT;
static pthread_mutex_t procs_lock = PTHREAD_MUTEX_INITIALIZER;
static struct lc_proc *procs;
static int next_pid = 1000;

static void free_proc(struct lc_proc *p);

static void make_key(void)
{
    pthread_key_create(&guest_key, NULL);
}

/* ------------------------------------------------------ fork の受け皿 */

/* いま動いているのがゲストのスレッドか。fork の再現と、標準入出力を守る判断に使う */
int lcsys_is_guest_thread(void)
{
    pthread_once(&key_once, make_key);
    return pthread_getspecific(guest_key) != NULL;
}

/* fork の子(まだ exec していない短命なスレッド)か。
 * 本物の fork なら親子で fd の表が分かれるが、ここでは 1 つしか無い。
 * 子が「親の分はもう要らない」と閉じると、親の分まで消えてしまう
 * (実機 2026-09-12: dbus-run-session が
 *  `error reading address from bus daemon: Bad file descriptor` で転んだ)。
 * 子は exec して消えるだけなので、子からの close は見送る。 */
int lcsys_is_fork_child(void)
{
    struct lc_proc *p;
    pthread_once(&key_once, make_key);
    p = (struct lc_proc *)pthread_getspecific(guest_key);
    return p && p->fork_child;
}

struct fork_arg {
    void (*fn)(void *);
    void *arg;
    struct lc_proc *p;
};

static void *fork_thread(void *a)
{
    struct fork_arg *f = (struct fork_arg *)a;
    struct lc_proc *p = f->p;
    void (*fn)(void *) = f->fn;
    void *arg = f->arg;
    pthread_setspecific(guest_key, p);
    free(f);
    fn(arg);      /* 普通は戻ってこない(複製したスタックに飛び、最後は _exit) */
    p->status = 0;
    p->done = 1;
    return NULL;
}

/* fork() の子として、記録の付いたスレッドを 1 本立てる。返すのは擬似 pid。
 * 中身(スタックの複製と文脈の復元)は native/lcfork.c の仕事で、ここは
 * 「procd の台帳に載せて、ゲストの印を付けたスレッドを用意する」だけ。 */
int lcsys_fork_child(void (*fn)(void *), void *arg)
{
    struct lc_proc *p, *parent;
    struct fork_arg *f;
    pthread_attr_t attr;
    int rc;

    pthread_once(&key_once, make_key);
    parent = (struct lc_proc *)pthread_getspecific(guest_key);
    p = (struct lc_proc *)calloc(1, sizeof *p);
    f = (struct fork_arg *)calloc(1, sizeof *f);
    if (!p || !f) {
        free(p);
        free(f);
        return -1;
    }
    p->fork_child = 1;
    p->guest_path = strdup(parent && parent->guest_path ? parent->guest_path : "(fork)");
    p->image_path = strdup(p->guest_path ? p->guest_path : "(fork)");
    f->fn = fn;
    f->arg = arg;
    f->p = p;

    pthread_mutex_lock(&procs_lock);
    p->pid = next_pid++;
    p->next = procs;
    procs = p;
    pthread_mutex_unlock(&procs_lock);

    pthread_attr_init(&attr);
    pthread_attr_setstacksize(&attr, GUEST_STACK);
    rc = pthread_create(&p->thread, &attr, fork_thread, f);
    pthread_attr_destroy(&attr);
    if (rc != 0) {
        pthread_mutex_lock(&procs_lock);
        if (procs == p)
            procs = p->next;
        pthread_mutex_unlock(&procs_lock);
        free(f);
        free_proc(p);
        lcsys_log("fork: pthread_create failed (%d)", rc);
        return -1;
    }
    pthread_detach(p->thread);
    p->detached = 1;
    return p->pid;
}

/* exec の肩代わり: 新しいプログラムをスレッドとして起こし、**呼んだ側の擬似 pid を
 * そちらに引き継ぐ**。exec は「同じプロセスのまま中身が別のプログラムになる」操作なので、
 * 親が待っている pid が新しいプログラムを指していないと waitpid の意味が合わなくなる。
 * 成功したら呼んだ側は自分のスレッドを終えること(戻ってはいけない)。 */
int lcsys_exec_handover(const char *path, char *const argv[], char *const envp[])
{
    struct lc_proc *cur, *np;
    int newpid, tmp;

    pthread_once(&key_once, make_key);
    cur = (struct lc_proc *)pthread_getspecific(guest_key);
    newpid = lcsys_spawn(path, argv, envp, -1, -1);
    if (newpid < 0)
        return -1;
    if (!cur)
        return newpid;

    /* 番号を入れ替える。親が待っている番号が新しいプログラムに付く */
    pthread_mutex_lock(&procs_lock);
    for (np = procs; np; np = np->next)
        if (np->pid == newpid)
            break;
    if (np) {
        tmp = cur->pid;
        cur->pid = np->pid;
        np->pid = tmp;
    }
    pthread_mutex_unlock(&procs_lock);
    lcsys_log("exec: pid %d を引き継いだ(抜け殻は %d)", np ? np->pid : newpid, cur->pid);
    return np ? np->pid : newpid;
}

/* ------------------------------------------------------ exit hook */

int lcsys_guest_exit(int status)
{
    struct lc_proc *p;
    pthread_once(&key_once, make_key);
    p = (struct lc_proc *)pthread_getspecific(guest_key);
    if (!p)
        return 0; /* host thread: caller falls through to the real exit */
    fflush(NULL); /* stdout is shared and block-buffered on a pipe; atexit handlers are NOT run */
    p->status = status & 0xff;
    p->done = 1;
    lcsys_log("pid %d: exit(%d) -> thread ends", p->pid, status);
    pthread_exit(NULL);
}

/* ------------------------------------------------- image lookup */

static const struct mach_header_64 *find_image(const char *path)
{
    char want[PATH_MAX], have[PATH_MAX];
    uint32_t i, n = _dyld_image_count();
    const char *name;
    for (i = n; i-- > 0;) {
        name = _dyld_get_image_name(i);
        if (name && strcmp(name, path) == 0)
            return (const struct mach_header_64 *)_dyld_get_image_header(i);
    }
    if (!lcsys_real.realpath || !lcsys_real.realpath(path, want))
        return NULL;
    for (i = n; i-- > 0;) {
        name = _dyld_get_image_name(i);
        if (!name)
            continue;
        if (strcmp(name, want) == 0 || (lcsys_real.realpath(name, have) && strcmp(have, want) == 0))
            return (const struct mach_header_64 *)_dyld_get_image_header(i);
    }
    return NULL;
}

static guest_main_fn find_entry(const struct mach_header_64 *hdr, uint64_t *entryoff_out)
{
    const struct load_command *lc = (const struct load_command *)(hdr + 1);
    uint32_t i;
    for (i = 0; i < hdr->ncmds; i++) {
        if (lc->cmd == LC_MAIN) {
            const struct entry_point_command *ep = (const struct entry_point_command *)lc;
            *entryoff_out = ep->entryoff;
            return (guest_main_fn)((const char *)hdr + ep->entryoff);
        }
        lc = (const struct load_command *)((const char *)lc + lc->cmdsize);
    }
    return NULL;
}

/* 画像が libgobject / libgtk-4 を読み込むか(LC_LOAD_DYLIB を見る)。GLib の型登録
 * (GType)と GApplication はプロセスで 1 つなので、こういうプログラムの 2 本目を同じ
 * プロセスで起こすと初期化で落ちる(実機 2026-09-13: エディタを 2 回起動 →
 * editor_application_new で NULL 参照)。 */
static int image_uses_gobject(const struct mach_header_64 *hdr)
{
    const struct load_command *lc = (const struct load_command *)(hdr + 1);
    uint32_t i;
    for (i = 0; i < hdr->ncmds; i++) {
        if (lc->cmd == LC_LOAD_DYLIB || lc->cmd == LC_LOAD_WEAK_DYLIB) {
            const struct dylib_command *dc = (const struct dylib_command *)lc;
            const char *name = (const char *)lc + dc->dylib.name.offset;
            if (strstr(name, "libgobject-2.0") || strstr(name, "libgtk-4") || strstr(name, "libadwaita"))
                return 1;
        }
        lc = (const struct load_command *)((const char *)lc + lc->cmdsize);
    }
    return 0;
}

/* 2 回目のタップ = 既存の窓を前へ(docs/iosc-desktop-env.md §7)。iosc の wm ソケットに
 * `raise<TAB><app_id>` を書く。app_id は .desktop の基底名(GTK は application-id を
 * app_id として名乗り、両者は一致する)。IOSC_APPS_DIR の .desktop から Exec の先頭語が
 * このプログラムのものを探す。 */
static const char *base_name(const char *p);   /* 後ろの sh -c の節で定義 */

static void wm_raise_for(const char *guest)
{
    const char *dir = getenv("IOSC_APPS_DIR"), *sock = getenv("IOSC_WM_SOCK");
    const char *prog = base_name(guest);
    char app_id[256] = "";
    DIR *d;
    struct dirent *e;
    if (!dir || !sock)
        return;
    d = opendir(dir);
    if (!d)
        return;
    while (!app_id[0] && (e = readdir(d)) != NULL) {
        char path[LCSYS_PATH_MAX], line[512];
        size_t n = strlen(e->d_name);
        FILE *f;
        if (n < 9 || strcmp(e->d_name + n - 8, ".desktop") != 0)
            continue;
        snprintf(path, sizeof path, "%s/%s", dir, e->d_name);
        f = fopen(path, "r");
        if (!f)
            continue;
        while (fgets(line, sizeof line, f)) {
            if (strncmp(line, "Exec=", 5) == 0) {
                char *w = line + 5, *sp = strpbrk(w, " \t\r\n");
                if (sp) *sp = 0;
                if (strcmp(base_name(w), prog) == 0)
                    snprintf(app_id, sizeof app_id, "%.*s", (int)(n - 8), e->d_name);
                break;
            }
        }
        fclose(f);
    }
    closedir(d);
    if (!app_id[0]) {
        lcsys_log("raise: %s の app_id が %s の .desktop から引けない", prog, dir);
        return;
    }
    {
        struct sockaddr_un sa;
        char req[300], reply[32];
        int fd = socket(AF_UNIX, SOCK_STREAM, 0);
        ssize_t r;
        if (fd < 0)
            return;
        memset(&sa, 0, sizeof sa);
        sa.sun_family = AF_UNIX;
        snprintf(sa.sun_path, sizeof sa.sun_path, "%s", sock);
        if (connect(fd, (struct sockaddr *)&sa, sizeof sa) != 0) {
            lcsys_log("raise: wm ソケット %s に繋げない errno %d", sock, errno);
            close(fd);
            return;
        }
        snprintf(req, sizeof req, "raise\t%s\n", app_id);
        (void)write(fd, req, strlen(req));
        r = read(fd, reply, sizeof reply - 1);
        if (r > 0) reply[r] = 0; else reply[0] = 0;
        lcsys_log("raise: app_id=%s -> %s", app_id, reply[0] ? reply : "(応答なし)");
        close(fd);
    }
}

/* GLib/GTK を使うと分かったプログラムの台帳。GType の登録はプロセスで 1 回きりなので、
 * 2 回目以降は私用コピー(統計が真っさら → 型を二重登録して落ちる)ではなく、
 * 最初の実体(登録済みの型 id を持つ)で main を呼び直す。
 * 実機 2026-09-14 01:40: エディタを閉じて開き直したら 5 本目のコピーで
 * editor_application_new が NULL 参照。 */
static int gobject_program_known(const char *guest, int remember)
{
    struct seen { char *path; struct seen *next; };
    static struct seen *list;
    static pthread_mutex_t lock = PTHREAD_MUTEX_INITIALIZER;
    struct seen *s;
    int hit = 0;
    pthread_mutex_lock(&lock);
    for (s = list; s; s = s->next)
        if (strcmp(s->path, guest) == 0) { hit = 1; break; }
    if (!hit && remember && (s = (struct seen *)calloc(1, sizeof *s)) != NULL) {
        s->path = strdup(guest);
        if (s->path) { s->next = list; list = s; } else free(s);
    }
    pthread_mutex_unlock(&lock);
    return hit;
}

/* 同じプログラムが単一実体として動いているか */
static int single_instance_running(const char *guest)
{
    struct lc_proc *p;
    int hit = 0;
    pthread_mutex_lock(&procs_lock);
    for (p = procs; p; p = p->next)
        if (!p->done && p->single_instance && p->guest_path && strcmp(p->guest_path, guest) == 0) {
            hit = p->pid;
            break;
        }
    pthread_mutex_unlock(&procs_lock);
    return hit;
}

/* -------------------------------------------------------- helpers */

static char **copy_vector(char *const v[], int *count_out)
{
    int n = 0, i;
    char **out;
    while (v && v[n])
        n++;
    out = (char **)calloc((size_t)n + 1, sizeof(char *));
    if (!out)
        return NULL;
    for (i = 0; i < n; i++) {
        out[i] = strdup(v[i]);
        if (!out[i]) {
            while (i-- > 0)
                free(out[i]);
            free(out);
            return NULL;
        }
    }
    out[n] = NULL;
    if (count_out)
        *count_out = n;
    return out;
}

static void free_vector(char **v)
{
    int i;
    if (!v)
        return;
    for (i = 0; v[i]; i++)
        free(v[i]);
    free(v);
}

static void free_proc(struct lc_proc *p)
{
    free_vector(p->argv);
    free_vector(p->envp);
    free(p->guest_path);
    free(p->image_path);
    free(p);
}

/* Remove leftovers in <tmp>/procd/ from a previous run that was killed before it could
 * unlink its copies. Called once from lcsys_spawn; failures are not interesting. */
static void sweep_procd_dir(void)
{
    char dir[LCSYS_PATH_MAX], victim[LCSYS_PATH_MAX];
    struct dirent *e;
    DIR *d;
    int n = 0;

    snprintf(dir, sizeof dir, "%s/procd", lcsys_cfg.tmp);
    d = lcsys_real.opendir ? lcsys_real.opendir(dir) : NULL;
    if (!d)
        return;
    while ((e = lcsys_real.readdir(d)) != NULL) {
        if (e->d_name[0] == '.')
            continue;
        if (snprintf(victim, sizeof victim, "%s/%s", dir, e->d_name) < (int)sizeof victim &&
            lcsys_real.unlink(victim) == 0)
            n++;
    }
    lcsys_real.closedir(d);
    if (n)
        lcsys_log("procd: swept %d leftover image cop%s from %s", n, n == 1 ? "y" : "ies", dir);
}

/* Copy <image> to <tmp>/procd/<n>-<basename>; returns 0 and fills out.
 *
 * Only lcsys_real.* here: a bare open()/mkdir()/unlink() from inside this dylib binds
 * to OUR OWN overrides in lcsys.c, which push the argument through lcsys_resolve_path.
 * These are HOST paths (<tmp> is .../Containers/Data/Application/<uuid>/tmp, and
 * "/var/mobile" maps to HOME), so they came back mangled and every copy failed with
 * ENOENT on device. read/write/close are not overridden and are fine as-is.
 */
static int make_private_copy(const char *image, char *out, size_t cap)
{
    static int counter = 0;
    static pthread_mutex_t lock = PTHREAD_MUTEX_INITIALIZER;
    char dir[LCSYS_PATH_MAX];
    const char *base = strrchr(image, '/');
    const char *step = NULL, *where = NULL;
    int in = -1, outfd = -1, n, err;
    char buf[65536];
    ssize_t r = 0;

    lcsys_resolve_real();
    if (!lcsys_real.open || !lcsys_real.mkdir || !lcsys_real.unlink) {
        lcsys_log("private copy: real open/mkdir/unlink unavailable");
        errno = ENOSYS;
        return -1;
    }
    base = base ? base + 1 : image;
    snprintf(dir, sizeof dir, "%s/procd", lcsys_cfg.tmp);
    if (lcsys_real.mkdir(dir, 0700) != 0 && errno != EEXIST) {
        step = "mkdir";
        where = dir;
        goto fail;
    }
    pthread_mutex_lock(&lock);
    n = ++counter;
    pthread_mutex_unlock(&lock);
    snprintf(out, cap, "%s/%d-%s", dir, n, base);

    in = lcsys_real.open(image, O_RDONLY | O_CLOEXEC, 0);
    if (in < 0) {
        step = "open(src)";
        where = image;
        goto fail;
    }
    outfd = lcsys_real.open(out, O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC, 0700);
    if (outfd < 0) {
        step = "open(dst)";
        where = out;
        goto fail;
    }
    while ((r = read(in, buf, sizeof buf)) > 0) {
        if (write(outfd, buf, (size_t)r) != r) {
            step = "write";
            where = out;
            goto fail;
        }
    }
    if (r < 0) {
        step = "read";
        where = image;
        goto fail;
    }
    close(in);
    close(outfd);
    return 0;

fail:
    err = errno;
    if (in >= 0)
        close(in);
    if (outfd >= 0) {
        close(outfd);
        lcsys_real.unlink(out);
    }
    lcsys_log("private copy: %s %s failed (errno %d)", step, where, err);
    errno = err;
    return -1;
}

/* getopt state that lives in the GUEST image, not in libSystem: coreutils and friends
 * bundle gnulib's own getopt, so optind/first_nonopt/last_nonopt/__getopt_initialized
 * are that image's statics and resetting libc's optind (guest_thread) does nothing -
 * the "ls works, then ls fails with invalid option -- ''" alternation. dlsym on the
 * handle finds the image's own copy first, and falls back to libc's when the guest has
 * none; setting libc's optind to 0 is harmless because guest_thread runs afterwards and
 * puts it back to 1. GNU/gnulib convention: optind = 0 (NOT 1) forces a full
 * re-initialisation, including the argv-permutation cursors. */
static void reset_guest_getopt(void *handle, const char *guest, int announce)
{
    int *p_optind = (int *)dlsym(handle, "optind");
    int *p_opterr = (int *)dlsym(handle, "opterr");
    int *p_optreset = (int *)dlsym(handle, "optreset");
    char **p_optarg = (char **)dlsym(handle, "optarg");

    if (p_optind)
        *p_optind = 0;
    if (p_opterr)
        *p_opterr = 1;
    if (p_optreset)
        *p_optreset = 1;
    if (p_optarg)
        *p_optarg = NULL;
    if (announce)
        lcsys_log("%s: guest getopt state optind=%s opterr=%s optreset=%s optarg=%s", guest,
                  p_optind ? (p_optind == &optind ? "libc" : "own") : "-",
                  p_opterr ? (p_opterr == &opterr ? "libc" : "own") : "-",
                  p_optreset ? (p_optreset == &optreset ? "libc" : "own") : "-",
                  p_optarg ? (p_optarg == &optarg ? "libc" : "own") : "-");
}

/* First spawn of a given guest path? (only used to log the getopt lookup once) */
static int first_spawn_of(const char *guest)
{
    struct seen { char *path; struct seen *next; };
    static struct seen *list;
    static pthread_mutex_t lock = PTHREAD_MUTEX_INITIALIZER;
    struct seen *s;
    int first = 1;

    pthread_mutex_lock(&lock);
    for (s = list; s; s = s->next) {
        if (strcmp(s->path, guest) == 0) {
            first = 0;
            break;
        }
    }
    if (first && (s = (struct seen *)calloc(1, sizeof *s)) != NULL) {
        s->path = strdup(guest);
        if (s->path) {
            s->next = list;
            list = s;
        } else {
            free(s);
        }
    }
    pthread_mutex_unlock(&lock);
    return first;
}

/* "ls" -> "/var/jb/usr/bin/ls" (first hit that resolves to a readable file; the
 * file behind it is the jb/usr/bin/ls.lc stub, lcsys_resolve_macho handles that) */
/* 在るが Mach-O ではない(シェルスクリプトなど)? libiosexec の ie_execve は
 * ENOEXEC のときだけ #! を読んで `sh script` に書き換えて再挑戦する(execv.c:23-47)。
 * ENOENT を返すとそこで諦めるので、区別して返す。 */
static int is_non_macho_file(const char *guest)
{
    char host[LCSYS_PATH_MAX];
    struct stat st;
    lcsys_resolve_path(guest, host, sizeof host);
    return lcsys_real.stat(host, &st) == 0 && S_ISREG(st.st_mode);
}

static int locate_guest(const char *path, char *guest, size_t gcap, char *image, size_t icap)
{
    static const char *const dirs[] = { "/var/jb/usr/local/bin", "/var/jb/usr/bin", "/var/jb/bin", NULL };
    int i;
    if (strchr(path, '/')) {
        snprintf(guest, gcap, "%s", path);
        if (lcsys_resolve_macho(guest, image, icap))
            return 0;
        errno = is_non_macho_file(guest) ? ENOEXEC : ENOENT;
        return -1;
    }
    for (i = 0; dirs[i]; i++) {
        snprintf(guest, gcap, "%s/%s", dirs[i], path);
        if (lcsys_resolve_macho(guest, image, icap))
            return 0;
        if (is_non_macho_file(guest)) {
            errno = ENOEXEC;
            return -1;
        }
    }
    errno = ENOENT;
    return -1;
}

/* ------------------------------------------------------- the thread */

static void *guest_thread(void *arg)
{
    struct lc_proc *p = (struct lc_proc *)arg;
    char *apple[2];
    int rc;
    pthread_setspecific(guest_key, p);
    /* libc's getopt state (the guest image's own copy, if it has one, was reset in
     * lcsys_spawn before this thread started) */
    optind = 1;
    optreset = 1;
    opterr = 1;
    optarg = NULL;
    apple[0] = p->guest_path;
    apple[1] = NULL;
    rc = p->entry(p->argc, p->argv, p->envp, apple);
    fflush(NULL);
    p->status = rc & 0xff;
    p->done = 1;
    /* exit() 経由は lcsys_guest_exit が記録する。main から戻った場合もここで残す
     * (ioscoverview は return 0 で終わるので、実機 2026-09-13 のログに終了が無かった) */
    lcsys_log("pid %d: main returned %d -> thread ends", p->pid, rc);
    return NULL;
}


/* ------------------------------------------------- sh -c の肩代わり
 *
 * iosc-shell のドックは .desktop の Exec を `sh -lc "<Exec>"` で起こす(shell-draw.h sd_launch)。
 * -l は /etc/profile を読み、そこには `eval "$(dircolors -b)"` がある(profile.d/coreutils.sh)。
 * $(...) は fork で、子はそのまま dash の続き(exec しない)を走る。ここでは fork の子はスレッド
 * なので親子が同じ dash の大域(メモリスタック、ジョブ表)を同時に触り、親が落ちる
 * (2026-09-13 のクラッシュレポート: expandarg → evalbackcmd の直後で SIGSEGV)。
 *
 * `sh -c "<Exec>"` は「このコマンド行を走らせろ」という OS への注文なので、行が語と引用符だけの
 * 単純な形なら dash を通さず直接 spawn する。複雑な行は -l だけ落として dash に渡す
 * (profile の効きは環境変数で肩代わり: GSK_RENDERER=cairo は profile.d/10-gtk-renderer.sh)。 */

static const char *base_name(const char *p)
{
    const char *s = strrchr(p, '/');
    return s ? s + 1 : p;
}

int lcsys_is_shell_program(const char *path)
{
    const char *b = path ? base_name(path) : "";
    return !strcmp(b, "sh") || !strcmp(b, "dash") || !strcmp(b, "bash") || !strcmp(b, "ash");
}

const char *lcsys_guest_program(void)
{
    struct lc_proc *p;
    pthread_once(&key_once, make_key);
    p = (struct lc_proc *)pthread_getspecific(guest_key);
    return p ? p->guest_path : NULL;
}

/* 語と引用符だけのコマンド行を argv に割る。シェルの記号が裸で出てきたら NULL */
static char **split_simple_command(const char *cmd)
{
    char **argv = NULL, *word = NULL;
    size_t argc = 0, wlen = 0, wcap = 0;
    int in_word = 0, q = 0; /* q: 0 / '\'' / '"' */
    const char *p;

#define PUSH_CHAR(ch)                                                          \
    do {                                                                       \
        if (wlen + 1 >= wcap) {                                                \
            char *nw = realloc(word, wcap = wcap ? wcap * 2 : 64);             \
            if (!nw) goto fail;                                                \
            word = nw;                                                         \
        }                                                                      \
        word[wlen++] = (char)(ch);                                             \
        in_word = 1;                                                           \
    } while (0)
#define END_WORD()                                                             \
    do {                                                                       \
        if (in_word) {                                                         \
            char **na = realloc(argv, (argc + 2) * sizeof *argv);              \
            if (!na) goto fail;                                                \
            argv = na;                                                         \
            if (!word && !(word = calloc(1, wcap = 1))) goto fail;             \
            word[wlen] = 0;                                                    \
            argv[argc++] = word;                                               \
            argv[argc] = NULL;                                                 \
            word = NULL; wlen = wcap = 0; in_word = 0;                         \
        }                                                                      \
    } while (0)

    for (p = cmd; *p; p++) {
        char c = *p;
        if (q == '\'') {
            if (c == '\'') q = 0; else PUSH_CHAR(c);
            continue;
        }
        if (q == '"') {
            if (c == '"') { q = 0; continue; }
            if (c == '$' || c == '`') goto fail;
            if (c == '\\' && p[1] && strchr("\"\\$`", p[1])) { PUSH_CHAR(p[1]); p++; continue; }
            PUSH_CHAR(c);
            continue;
        }
        if (c == ' ' || c == '\t') { END_WORD(); continue; }
        if (c == '\'' || c == '"') { q = c; in_word = 1; continue; }
        if (c == '\\' && p[1]) { PUSH_CHAR(p[1]); p++; continue; }
        if (strchr("$`|;&<>(){}*?[~\n", c) || (c == '#' && !in_word)) goto fail;
        if (c == '=' && argc == 0) goto fail; /* 先頭語の代入 */
        PUSH_CHAR(c);
    }
    if (q) goto fail;
    END_WORD();
    if (!argv || argc == 0) goto fail;
    return argv;
fail:
    free(word);
    free_vector(argv);
    return NULL;
#undef PUSH_CHAR
#undef END_WORD
}

/* envp に KEY=VALUE を足す(同じ KEY は置き換える)。戻りは呼んだ側が free_vector する */
static char **env_with(char *const envp[], const char *kv)
{
    char **out;
    size_t n = 0, i, klen = strcspn(kv, "=") + 1;
    int replaced = 0;
    if (!envp)
        envp = *_NSGetEnviron();
    while (envp[n]) n++;
    out = calloc(n + 2, sizeof *out);
    if (!out)
        return NULL;
    for (i = 0; i < n; i++) {
        if (!replaced && strncmp(envp[i], kv, klen) == 0) { out[i] = strdup(kv); replaced = 1; }
        else out[i] = strdup(envp[i]);
        if (!out[i]) { free_vector(out); return NULL; }
    }
    if (!replaced && !(out[n++] = strdup(kv))) { free_vector(out); return NULL; }
    out[n] = NULL;
    return out;
}

/* `sh [-l] -c CMD` を見つけたら 1 を返し、*argv_out / *envp_out に差し替え後を置く。
 * 単純な行なら *argv_out[0] が新しい path。呼んだ側が両方を free_vector する */
static int unwrap_shell_c(const char *path, char *const argv[], char *const envp[],
                          char ***argv_out, char ***envp_out)
{
    const char *cmd = NULL;
    int login = 0, ci = 0, i;
    char **nargv;

    *argv_out = NULL;
    *envp_out = NULL;
    if (!lcsys_is_shell_program(path) || !argv || !argv[0] || !argv[1])
        return 0;
    if (argv[1][0] == '-' && argv[1][1] && strspn(argv[1] + 1, "lc") == strlen(argv[1] + 1)
        && strchr(argv[1], 'c')) {
        login = strchr(argv[1], 'l') != NULL;
        ci = 1;
    } else if (!strcmp(argv[1], "-l") && argv[2] && !strcmp(argv[2], "-c")) {
        login = 1;
        ci = 2;
    } else {
        return 0;
    }
    cmd = argv[ci + 1];
    if (!cmd)
        return 0;
    while (*cmd == ' ') cmd++;
    if (!strncmp(cmd, "exec ", 5))
        cmd += 5;

    if (login && !(*envp_out = env_with(envp, "GSK_RENDERER=cairo")))
        return 0;

    nargv = split_simple_command(cmd);
    if (nargv) {
        lcsys_log("sh -%sc \"%s\": 単純な行なので dash を通さず %s を直接起こす", login ? "l" : "", cmd, nargv[0]);
        *argv_out = nargv;
        return 1;
    }
    if (!login) {
        free_vector(*envp_out);
        *envp_out = NULL;
        return 0;
    }
    /* 複雑な行: -l だけ落とす(/etc/profile の $(...) が fork で落ちるため) */
    for (i = 0; argv[i]; i++) ;
    nargv = calloc(i + 2, sizeof *nargv);
    if (!nargv) { free_vector(*envp_out); *envp_out = NULL; return 0; }
    nargv[0] = strdup(argv[0]);
    nargv[1] = strdup("-c");
    for (i = ci + 1; argv[i]; i++)
        nargv[i - ci + 1] = strdup(argv[i]);
    lcsys_log("sh -lc \"%s\": 複雑な行なので -l を外して dash に渡す", cmd);
    *argv_out = nargv;
    return 1;
}

static int spawn_impl(const char *path, char *const argv[], char *const envp[], int fd_out, int fd_err);

int lcsys_spawn(const char *path, char *const argv[], char *const envp[], int fd_out, int fd_err)
{
    char **nargv = NULL, **nenvp = NULL;
    int rc, saved;
    if (unwrap_shell_c(path, argv, envp, &nargv, &nenvp)) {
        /* 単純な行なら nargv[0] が新しいプログラム。-l を外しただけなら path はそのまま */
        const char *npath = nargv[1] && !strcmp(nargv[1], "-c") ? path : nargv[0];
        rc = spawn_impl(npath, nargv, nenvp ? nenvp : envp, fd_out, fd_err);
    } else {
        rc = spawn_impl(path, argv, envp, fd_out, fd_err);
    }
    saved = errno;
    free_vector(nargv);
    free_vector(nenvp);
    errno = saved;
    return rc;
}

static int spawn_impl(const char *path, char *const argv[], char *const envp[], int fd_out, int fd_err)
{
    char guest[LCSYS_PATH_MAX], image[LCSYS_PATH_MAX], priv[LCSYS_PATH_MAX];
    const struct mach_header_64 *hdr;
    uint64_t entryoff = 0;
    guest_main_fn entry;
    void *handle;
    struct lc_proc *p;
    pthread_attr_t attr;
    int rc, first, copied = 0;

    (void)fd_out;
    (void)fd_err; /* G1: stdout/stderr are process-global (the Swift side dup2s one pipe onto 1 and 2) */
    if (!lcsys_ready) {
        errno = EINVAL;
        return -1;
    }
    pthread_once(&key_once, make_key);
    pthread_once(&sweep_once, sweep_procd_dir);
    lcsys_resolve_real();

    if (locate_guest(path, guest, sizeof guest, image, sizeof image) != 0) {
        int saved = errno;
        lcsys_log("spawn %s: %s (errno %d)", path,
                  saved == ENOEXEC ? "Mach-O ではない(スクリプト?)" : "not found", saved);
        errno = saved;
        return -1;
    }
    /* Fresh static state per "process": dyld hands back the SAME image for the same path, so a
     * second run of ls re-enters main() on top of gnulib getopt's static cursor (seen on device:
     * "invalid option -- '`'"). A private copy under <tmp>/procd/ is a different inode and loads
     * as a new image; the copy keeps its code signature, so it works in JIT-less mode.
     * Only from the second spawn onwards - the first one has nothing stale to escape, and every
     * copy costs one image that is never unloaded (see the growth note below). */
    {
        int running = single_instance_running(guest);
        if (running) {
            lcsys_log("spawn %s: pid %d としてもう動いている(GLib/GTK のアプリは 1 本まで)。2 本目は起こさない",
                      guest, running);
            wm_raise_for(guest);
            errno = EBUSY;
            return -1;
        }
    }
    first = first_spawn_of(guest);
    if (!first && gobject_program_known(guest, 0)) {
        lcsys_log("spawn %s: GLib/GTK のプログラムなので私用コピーは作らず最初の実体で main を呼び直す", guest);
    } else if (!first && !getenv("LCSYS_NO_COPY")) {
        if (make_private_copy(image, priv, sizeof priv) == 0) {
            snprintf(image, sizeof image, "%s", priv);
            copied = 1;
        } else {
            lcsys_log("spawn %s: private copy failed (errno %d), using shared image", path, errno);
        }
    }
    handle = lcsys_real.dlopen(image, RTLD_LOCAL | RTLD_NOW);
    if (!handle) {
        lcsys_log("spawn %s: dlopen(%s) failed: %s", path, image, dlerror());
        if (copied)
            lcsys_real.unlink(image);
        errno = ENOEXEC;
        return -1;
    }
    reset_guest_getopt(handle, guest, first);
    hdr = find_image(image);
    if (!hdr) {
        lcsys_log("spawn %s: loaded but image not found in _dyld list (%s)", path, image);
        if (copied)
            lcsys_real.unlink(image);
        errno = ENOEXEC;
        return -1;
    }
    /* Drop the name now, while the mapping holds the inode: nothing is left behind if the app
     * is killed later. The image itself stays mapped for the life of the process - we never
     * dlclose (a guest's atexit handlers live in libc and would dangle), so a long session that
     * re-runs commands many times keeps growing. Bounded enough for G1/G2; revisit at G3. */
    if (copied)
        lcsys_real.unlink(image); /* host path: the unlink override would remap it */
    entry = find_entry(hdr, &entryoff);
    if (!entry) {
        entry = (guest_main_fn)dlsym(handle, "main"); /* fallback: an exported _main */
        if (!entry) {
            lcsys_log("spawn %s: no LC_MAIN and no exported main in %s", path, image);
            errno = ENOEXEC;
            return -1;
        }
    }

    p = (struct lc_proc *)calloc(1, sizeof *p);
    if (!p) {
        errno = ENOMEM;
        return -1;
    }
    p->argv = copy_vector(argv, &p->argc);
    p->envp = copy_vector(envp, NULL);
    p->guest_path = strdup(guest);
    p->image_path = strdup(image);
    p->entry = entry;
    p->single_instance = image_uses_gobject(hdr);
    if (p->single_instance)
        gobject_program_known(guest, 1);
    if (!p->argv || !p->envp || !p->guest_path || !p->image_path || p->argc < 1) {
        free_proc(p);
        errno = EINVAL;
        return -1;
    }

    pthread_mutex_lock(&procs_lock);
    p->pid = next_pid++;
    p->next = procs;
    procs = p;
    pthread_mutex_unlock(&procs_lock);

    lcsys_log("pid %d: %s -> %s (header %p, entryoff %llu, entry %p, argc %d)", p->pid, guest, image,
              (const void *)hdr, (unsigned long long)entryoff, (void *)entry, p->argc);

    pthread_attr_init(&attr);
    pthread_attr_setstacksize(&attr, GUEST_STACK);
    rc = pthread_create(&p->thread, &attr, guest_thread, p);
    pthread_attr_destroy(&attr);
    if (rc != 0) {
        pthread_mutex_lock(&procs_lock);
        procs = p->next;
        pthread_mutex_unlock(&procs_lock);
        free_proc(p);
        lcsys_log("spawn %s: pthread_create failed (%d)", path, rc);
        errno = rc;
        return -1;
    }
    return p->pid;
}

/* Non-destructive status probe, for guests that are never waited for (iosc ends in
 * wl_display_run and only comes back when it dies). Unlike lcsys_wait this leaves the
 * proc on the list, so the same pid can be polled again and again.
 *
 *    1  running  (a struct lc_proc with that pid exists and done == 0)
 *    0  finished (main() returned or exit() was called; *status = the exit code)
 *   -1  unknown  (never spawned, or already reaped by lcsys_wait); errno = ECHILD
 *
 * `status` may be NULL, and is set to -1 unless the return value is 0. done/status are
 * written by the guest thread without taking procs_lock (same as lcsys_wait reads them);
 * they are a plain int flag written once at the end of the thread, so a stale read only
 * ever costs one more poll. */
int lcsys_alive(int pid, int *status)
{
    struct lc_proc *p;
    int alive = -1, st = -1;

    pthread_mutex_lock(&procs_lock);
    for (p = procs; p; p = p->next) {
        if (p->pid == pid) {
            alive = p->done ? 0 : 1;
            if (p->done)
                st = p->status;
            break;
        }
    }
    pthread_mutex_unlock(&procs_lock);
    if (status)
        *status = st;
    if (alive < 0)
        errno = ECHILD;
    return alive;
}

static struct lc_proc *unlink_proc(int pid)
{
    struct lc_proc *p, **pp;
    pthread_mutex_lock(&procs_lock);
    for (pp = &procs; (p = *pp) != NULL; pp = &p->next) {
        if (p->pid == pid) {
            *pp = p->next;
            break;
        }
    }
    pthread_mutex_unlock(&procs_lock);
    return p;
}

/* 終わるまで待って回収する。detached(fork の子)は join できないので done を見る。
 * done=1 はスレッドの最後の書き込みで、その後は p を触らないので、見えたら free してよい。 */
static void join_proc(struct lc_proc *p)
{
    if (p->detached) {
        while (!p->done)
            usleep(5000);
    } else {
        pthread_join(p->thread, NULL);
    }
}

/* pid の持ち主が終わるまで待って回収する。exec の肩代わり(lcsys_exec_handover)は
 * 「子が exec した瞬間に pid を新しいプログラムへ付け替える」ので、待っている最中に
 * 持ち主が変わりうる。抜け殻(元の子スレッド)が終わっただけなら、同じ pid を
 * 引き継いだプログラムを待ち直す。実機 2026-09-13: iosc-shell が dbus-daemon を fork+exec
 * して waitpid した直後に socket を見に行き、まだ無いので dbus-run-session に落ちていた。 */
static struct lc_proc *collect_pid(int pid)
{
    struct lc_proc *p;
    int st;
    for (;;) {
        p = unlink_proc(pid);
        if (!p)
            return NULL;
        join_proc(p);
        if (lcsys_alive(pid, &st) < 0)
            return p;               /* 同じ pid の持ち主はもう居ない: これが本体 */
        lcsys_log("pid %d: 抜け殻(%d)が終わったので、引き継いだ本体を待ち直す", pid, p->pid);
        free_proc(p);
    }
}

int lcsys_wait(int pid, int *status)
{
    struct lc_proc *p = collect_pid(pid);
    if (!p) {
        errno = ECHILD;
        return -1;
    }
    if (status)
        *status = p->done ? p->status : -1;
    free_proc(p);
    return 0;
}

/* waitpid 相当(lcsys.c の waitpid 横取りが呼ぶ)。
 * nohang: 動いていれば 0 を返し、回収しない。 */
int lcsys_waitpid(int pid, int *status, int nohang)
{
    struct lc_proc *p;
    int st = -1;

    if (nohang) {
        int alive = lcsys_alive(pid, &st);
        if (alive < 0)
            return -1;      /* errno ECHILD */
        if (alive == 1)
            return 0;
    }
    p = collect_pid(pid);
    if (!p) {
        errno = ECHILD;
        return -1;
    }
    if (status)
        *status = p->done ? p->status : 0;
    free_proc(p);
    return pid;
}

/* kill 相当。スレッドは安全に止められないので、知っている pid なら記録だけして 0。
 * sig 0(生存確認)は本来の意味どおり。 */
int lcsys_kill(int pid, int sig)
{
    int st = -1;
    int alive = lcsys_alive(pid, &st);
    if (alive < 0) {
        errno = ESRCH;
        return -1;
    }
    if (sig != 0)
        lcsys_log("kill(%d, %d): 擬似 pid はスレッドなので止められない(%s)", pid, sig,
                  alive ? "動いたまま" : "もう終わっている");
    return 0;
}
