/*
 * pathmap.c - guest path -> host path.
 *
 *   /var/jb/...  /private/var/jb/...        -> <bundle>/jb/...
 *   /var/mobile  /var/root  (+/private/)    -> HOME (Documents-based)
 *   /tmp  /var/tmp  /private/tmp            -> TMPDIR
 *   anything else                           -> unchanged
 *
 * Then ".symlink" markers (written by stage.py where symlinks could not be
 * created): if a component of the mapped path does not exist but
 * "<component>.symlink" does, the marker's text is the link target
 * (absolute = jb-rooted guest path, relative = against the marker's dir);
 * the remaining suffix is re-appended and the walk restarts (max 8 hops).
 *
 * "<name>.lc" stub files (text "@LC:Frameworks/<flat>") stand where relinked
 * Mach-Os were; nothing is left at <name> itself (LiveContainer's installer
 * picks signing candidates by file name, so the stub must not be called
 * libfoo.dylib). The guest still sees /var/jb/<name>: when the mapped leaf is
 * missing but "<leaf>.lc" exists, the resolver returns the .lc path, so
 * stat/access/open of the guest path report the stub. lcsys_resolve_macho()
 * turns the stub text into <bundle>/Frameworks/<flat>. (readdir is not
 * faked: `ls /var/jb/usr/bin` lists ls.lc, not ls.)
 *
 * Only lcsys_real.* is used for filesystem access (the bare names would bind
 * to our own overrides in lcsys.c).
 */
#include "lcsys.h"

#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <string.h>
#include <unistd.h>

/* ---- small string helpers (no allocation) ---- */

static size_t lc_strlcpy(char *dst, const char *src, size_t cap)
{
    size_t n = strlen(src);
    if (cap) {
        size_t c = n < cap - 1 ? n : cap - 1;
        memcpy(dst, src, c);
        dst[c] = '\0';
    }
    return n;
}

static void lc_strlcat(char *dst, const char *src, size_t cap)
{
    size_t l = strlen(dst);
    if (l < cap)
        lc_strlcpy(dst + l, src, cap - l);
}

/* "/var/jb" matches "/var/jb" and "/var/jb/x", not "/var/jbx". *rest -> "" or "/x". */
static int prefix_match(const char *p, const char *prefix, const char **rest)
{
    size_t n = strlen(prefix);
    if (strncmp(p, prefix, n) != 0)
        return 0;
    if (p[n] != '\0' && p[n] != '/')
        return 0;
    *rest = p + n;
    return 1;
}

/* lexical normalisation in place: "//" -> "/", "/./" removed, "a/../" collapsed */
static void normalize(char *p)
{
    char out[LCSYS_PATH_MAX];
    size_t o = 0;
    int absolute = p[0] == '/';
    const char *s = p;
    out[0] = '\0';
    while (*s) {
        while (*s == '/')
            s++;
        if (!*s)
            break;
        const char *e = s;
        while (*e && *e != '/')
            e++;
        size_t len = (size_t)(e - s);
        if (len == 1 && s[0] == '.') {
            /* skip */
        } else if (len == 2 && s[0] == '.' && s[1] == '.') {
            if (o > 0) {
                while (o > 0 && out[o - 1] != '/')
                    o--;
                if (o > 0)
                    o--; /* drop the slash */
            }
        } else {
            if (o + 1 + len + 1 >= sizeof out)
                break;
            if (o > 0 || absolute)
                out[o++] = '/';
            memcpy(out + o, s, len);
            o += len;
        }
        s = e;
    }
    if (o == 0 && absolute)
        out[o++] = '/';
    out[o] = '\0';
    lc_strlcpy(p, out, LCSYS_PATH_MAX);
}

static void join2(char *out, size_t cap, const char *base, const char *rest)
{
    lc_strlcpy(out, base, cap);
    if (rest && *rest)
        lc_strlcat(out, rest, cap); /* rest starts with '/' */
}

char *lcsys_map_path(const char *in, char *out, size_t cap)
{
    const char *p, *rest;
    if (!in) {
        out[0] = '\0';
        return out;
    }
    if (!lcsys_ready || in[0] != '/') {
        lc_strlcpy(out, in, cap);
        return out;
    }
    p = in;
    if (strncmp(p, "/private/", 9) == 0)
        p += 8; /* "/private/var/jb" -> "/var/jb", "/private/tmp" -> "/tmp" */

    if (prefix_match(p, "/var/jb", &rest))
        join2(out, cap, lcsys_cfg.jb, rest);
    else if (prefix_match(p, "/var/mobile", &rest) || prefix_match(p, "/var/root", &rest))
        join2(out, cap, lcsys_cfg.home, rest);
    else if (prefix_match(p, "/tmp", &rest) || prefix_match(p, "/var/tmp", &rest))
        join2(out, cap, lcsys_cfg.tmp, rest);
    else
        lc_strlcpy(out, in, cap);

    if (lcsys_cfg.trace && strcmp(in, out) != 0)
        lcsys_log("map %s -> %s", in, out);
    return out;
}

static int under_jb(const char *host)
{
    size_t n = strlen(lcsys_cfg.jb);
    return strncmp(host, lcsys_cfg.jb, n) == 0 && (host[n] == '/' || host[n] == '\0');
}

/* Read a ".symlink" marker next to `prefix`. Returns 1 and fills target. */
static int read_marker(const char *prefix, char *target, size_t cap)
{
    char marker[LCSYS_PATH_MAX];
    int fd;
    ssize_t n;
    if (snprintf(marker, sizeof marker, "%s.symlink", prefix) >= (int)sizeof marker)
        return 0;
    fd = lcsys_real.open(marker, O_RDONLY | O_CLOEXEC, 0);
    if (fd < 0)
        return 0;
    n = read(fd, target, cap - 1);
    close(fd);
    if (n <= 0)
        return 0;
    target[n] = '\0';
    while (n > 0 && (target[n - 1] == '\n' || target[n - 1] == '\r' || target[n - 1] == ' '))
        target[--n] = '\0';
    return n > 0;
}

/* One marker hop on the mapped path `path` (in place). Returns 1 if a hop was made. */
static int marker_hop(char *path, size_t cap)
{
    struct stat st;
    size_t i, base = strlen(lcsys_cfg.jb);
    if (!under_jb(path))
        return 0;
    for (i = base + 1; ; i++) {
        char saved = path[i];
        if (saved != '/' && saved != '\0')
            continue;
        path[i] = '\0';
        if (lcsys_real.lstat(path, &st) != 0) {
            char target[LCSYS_PATH_MAX], nb[LCSYS_PATH_MAX], suffix[LCSYS_PATH_MAX];
            if (!read_marker(path, target, sizeof target)) {
                path[i] = saved;
                return 0; /* genuinely missing */
            }
            if (target[0] == '/') {
                lcsys_map_path(target, nb, sizeof nb);
            } else {
                char *slash;
                lc_strlcpy(nb, path, sizeof nb);
                slash = strrchr(nb, '/');
                if (slash)
                    slash[1] = '\0';
                else
                    nb[0] = '\0';
                lc_strlcat(nb, target, sizeof nb);
            }
            path[i] = saved;
            lc_strlcpy(suffix, path + i, sizeof suffix); /* "" or "/rest" */
            lc_strlcat(nb, suffix, sizeof nb);
            normalize(nb);
            if (lcsys_cfg.trace)
                lcsys_log("symlink marker %s -> %s", path, nb);
            lc_strlcpy(path, nb, cap);
            return 1;
        }
        path[i] = saved;
        if (saved == '\0')
            return 0;
    }
}

/* "<path>.lc" stands for the missing leaf `path` (a relinked Mach-O). Appends the
 * suffix in place when that file exists. Returns 1 if it did. */
static int stub_hop(char *path, size_t cap)
{
    struct stat st;
    size_t l = strlen(path), sl = strlen(LCSYS_STUB_SUFFIX);
    if (!under_jb(path) || l + sl + 1 > cap)
        return 0;
    if (l >= sl && strcmp(path + l - sl, LCSYS_STUB_SUFFIX) == 0)
        return 0; /* already the stub itself */
    memcpy(path + l, LCSYS_STUB_SUFFIX, sl + 1);
    if (lcsys_real.lstat(path, &st) == 0) {
        if (lcsys_cfg.trace)
            lcsys_log("stub %s", path);
        return 1;
    }
    path[l] = '\0';
    return 0;
}

char *lcsys_resolve_path(const char *in, char *out, size_t cap)
{
    int hops;
    struct stat st;
    lcsys_map_path(in, out, cap);
    if (!lcsys_ready)
        return out;
    for (hops = 0; hops < 8; hops++) {
        if (lcsys_real.lstat(out, &st) == 0)
            return out;
        if (marker_hop(out, cap))
            continue;
        stub_hop(out, cap); /* missing leaf, "<leaf>.lc" present: report the stub */
        return out;
    }
    return out;
}

char *lcsys_resolve_macho(const char *in, char *out, size_t cap)
{
    char head[LCSYS_PATH_MAX];
    int fd;
    ssize_t n;
    /* <mapped> (a real file or a .symlink chain), else <mapped>.lc: resolve_path
     * does both; the open below fails with ENOENT when neither exists */
    lcsys_resolve_path(in, out, cap);
    fd = lcsys_real.open(out, O_RDONLY | O_CLOEXEC, 0);
    if (fd < 0)
        return NULL;
    n = read(fd, head, sizeof head - 1);
    close(fd);
    if (n < 0)
        return NULL;
    head[n] = '\0';
    if (strncmp(head, LCSYS_STUB_PREFIX, strlen(LCSYS_STUB_PREFIX)) == 0) {
        char *flat = head + strlen(LCSYS_STUB_PREFIX), *e;
        for (e = flat; *e && *e != '\n' && *e != '\r'; e++)
            ;
        *e = '\0';
        if (!*flat || strchr(flat, '/')) {
            errno = ENOEXEC;
            return NULL;
        }
        snprintf(out, cap, "%s/%s", lcsys_cfg.frameworks, flat);
    }
    return out;
}
