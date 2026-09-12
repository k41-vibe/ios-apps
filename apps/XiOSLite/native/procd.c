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

#include <dlfcn.h>
#include <errno.h>
#include <fcntl.h>
#include <sys/stat.h>
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
    struct lc_proc *next;
};

static pthread_key_t guest_key;
static pthread_once_t key_once = PTHREAD_ONCE_INIT;
static pthread_once_t sweep_once = PTHREAD_ONCE_INIT;
static pthread_mutex_t procs_lock = PTHREAD_MUTEX_INITIALIZER;
static struct lc_proc *procs;
static int next_pid = 1000;

static void make_key(void)
{
    pthread_key_create(&guest_key, NULL);
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
static int locate_guest(const char *path, char *guest, size_t gcap, char *image, size_t icap)
{
    static const char *const dirs[] = { "/var/jb/usr/bin", "/var/jb/usr/local/bin", "/var/jb/bin", NULL };
    int i;
    if (strchr(path, '/')) {
        snprintf(guest, gcap, "%s", path);
        return lcsys_resolve_macho(guest, image, icap) ? 0 : -1;
    }
    for (i = 0; dirs[i]; i++) {
        snprintf(guest, gcap, "%s/%s", dirs[i], path);
        if (lcsys_resolve_macho(guest, image, icap))
            return 0;
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
    return NULL;
}

int lcsys_spawn(const char *path, char *const argv[], char *const envp[], int fd_out, int fd_err)
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
        lcsys_log("spawn %s: not found (errno %d)", path, errno);
        errno = ENOENT;
        return -1;
    }
    /* Fresh static state per "process": dyld hands back the SAME image for the same path, so a
     * second run of ls re-enters main() on top of gnulib getopt's static cursor (seen on device:
     * "invalid option -- '`'"). A private copy under <tmp>/procd/ is a different inode and loads
     * as a new image; the copy keeps its code signature, so it works in JIT-less mode.
     * Only from the second spawn onwards - the first one has nothing stale to escape, and every
     * copy costs one image that is never unloaded (see the growth note below). */
    first = first_spawn_of(guest);
    if (!first && !getenv("LCSYS_NO_COPY")) {
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

int lcsys_wait(int pid, int *status)
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
    if (!p) {
        errno = ECHILD;
        return -1;
    }
    pthread_join(p->thread, NULL);
    if (status)
        *status = p->done ? p->status : -1;
    free_proc(p);
    return 0;
}
