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
 * pids are synthetic (>= 1000). The image is never dlclose'd: a second spawn
 * of the same binary re-enters main() with whatever static state the first
 * run left behind - that is exactly what the G1 "ls twice" test looks for.
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

/* Copy <image> to <tmp>/procd/<n>-<basename>; returns 0 and fills out. */
static int make_private_copy(const char *image, char *out, size_t cap)
{
    static int counter = 0;
    static pthread_mutex_t lock = PTHREAD_MUTEX_INITIALIZER;
    char dir[LCSYS_PATH_MAX];
    const char *base = strrchr(image, '/');
    int in, outfd, n;
    char buf[65536];
    ssize_t r;

    base = base ? base + 1 : image;
    snprintf(dir, sizeof dir, "%s/procd", lcsys_cfg.tmp);
    mkdir(dir, 0700);
    pthread_mutex_lock(&lock);
    n = ++counter;
    pthread_mutex_unlock(&lock);
    snprintf(out, cap, "%s/%d-%s", dir, n, base);

    in = open(image, O_RDONLY);
    if (in < 0)
        return -1;
    outfd = open(out, O_WRONLY | O_CREAT | O_TRUNC, 0700);
    if (outfd < 0) {
        close(in);
        return -1;
    }
    while ((r = read(in, buf, sizeof buf)) > 0) {
        if (write(outfd, buf, (size_t)r) != r) {
            close(in);
            close(outfd);
            unlink(out);
            return -1;
        }
    }
    close(in);
    close(outfd);
    if (r < 0) {
        unlink(out);
        return -1;
    }
    return 0;
}

/* "ls" -> "/var/jb/usr/bin/ls" (first hit that resolves to a readable file) */
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
    /* getopt state is process-global; every "process" starts fresh */
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
    char guest[LCSYS_PATH_MAX], image[LCSYS_PATH_MAX];
    const struct mach_header_64 *hdr;
    uint64_t entryoff = 0;
    guest_main_fn entry;
    void *handle;
    struct lc_proc *p;
    pthread_attr_t attr;
    int rc;

    (void)fd_out;
    (void)fd_err; /* G1: stdout/stderr are process-global (the Swift side dup2s one pipe onto 1 and 2) */
    if (!lcsys_ready) {
        errno = EINVAL;
        return -1;
    }
    pthread_once(&key_once, make_key);
    lcsys_resolve_real();

    if (locate_guest(path, guest, sizeof guest, image, sizeof image) != 0) {
        lcsys_log("spawn %s: not found (errno %d)", path, errno);
        errno = ENOENT;
        return -1;
    }
    /* Fresh static state per "process": dyld returns the same image for the same path, so a
     * second run of ls would reuse gnulib getopt's static cursor (seen on device: "invalid
     * option -- '`'"). A private copy under tmp/procd/ has a different inode/path and is
     * loaded as a new image. The copy keeps its code signature, so it loads in JIT-less mode. */
    if (!getenv("LCSYS_NO_COPY")) {
        char priv[LCSYS_PATH_MAX];
        if (make_private_copy(image, priv, sizeof priv) == 0)
            snprintf(image, sizeof image, "%s", priv);
        else
            lcsys_log("spawn %s: private copy failed (errno %d), using shared image", path, errno);
    }
    handle = lcsys_real.dlopen(image, RTLD_LOCAL | RTLD_NOW);
    if (!handle) {
        lcsys_log("spawn %s: dlopen(%s) failed: %s", path, image, dlerror());
        errno = ENOEXEC;
        return -1;
    }
    hdr = find_image(image);
    if (!hdr) {
        lcsys_log("spawn %s: loaded but image not found in _dyld list (%s)", path, image);
        errno = ENOEXEC;
        return -1;
    }
    if (strstr(image, "/procd/"))
        unlink(image); /* mapped already; keeps tmp clean even if we never dlclose */
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
