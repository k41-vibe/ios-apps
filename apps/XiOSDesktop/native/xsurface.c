/*
 * xsurface.c - the ddx (display) client: our side of iosc's -ddx-sock.
 *
 * Port of x11/apps/Xios/Sources/XSurface.c, written from the protocol notes in
 * tools/xios/iosc-host-protocol.md (sections 1-5). iosc paints into IOSurfaces and
 * only ever tells us "surface N holds frame `seq`, wait for fence value F before you
 * read it"; the pixels never travel through the socket. Everything here runs in the
 * SAME process as iosc (procd.c runs it on a thread), which changes nothing about the
 * protocol - task_for_pid(mach_task_self(), getpid()) and mach_port_extract_right on
 * one's own task are unprivileged, and IOSurfaceCreateMachPort/LookupFromMachPort
 * round-trip inside a task just as well as across one (protocol notes, section 3).
 *
 * Handshake order (section 2; the mach message comes BEFORE the socket reply):
 *
 *   connect -> allocate a reply port -> send HELLO -> receive 1 mach message (the
 *   primary IOSurface) -> read the server HELLO (+ its "iosc" identifier) ->
 *   if STREAM_V2: read STREAM_INFO (+ the 32-byte release-timeline token), then for
 *   each further buffer a mach message followed by its SURFACE record -> O_NONBLOCK.
 *
 * The two 32-byte tokens are handed out raw (xs_release_token / xs_last_fence_token).
 * Swift turns them into id<MTLSharedEvent> through lcsys_shared_event_for_token()
 * (xpcshim.m), the in-process stand-in for the root metal-event-broker XPC service.
 *
 * One DIRTY = one RELEASED, never coalesced (section 5): if we stop acking, all three
 * classic-mode buffers go pending, xios_output_acquire() returns 0 and iosc spins in
 * repaint_retry_soon() - no crash, just a frozen screen.
 *
 * Thread safety: xs_poll runs on the draw thread while xs_release/xs_presented are
 * called from Metal completion handlers, so every entry point takes one mutex. No
 * callback is ever invoked while holding it.
 *
 * Paths here are HOST paths (the ddx socket lives in $TMPDIR), and connect()/recv()
 * are not among the overridden libc entry points, so nothing in this file goes
 * through pathmap.c.
 */
#include "lcsys.h"

#include <dlfcn.h>   /* task_for_pid の本体を引くため */
#include <errno.h>
#include <fcntl.h>
#include <poll.h>
#include <pthread.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/time.h>
#include <sys/un.h>
#include <unistd.h>

#include <mach/mach.h>
#include <mach/message.h>

#include <CoreFoundation/CoreFoundation.h>
#include <IOSurface/IOSurfaceRef.h>

/* ------------------------------------------------------------ the wire format */

#define XIOS_MAGIC 0x584D5331u /* 'XMS1' */

enum {
    XIOS_MSG_HELLO        = 0x01,
    XIOS_MSG_DIRTY        = 0x02,
    XIOS_MSG_CURSOR       = 0x03,
    XIOS_MSG_PRESENTED    = 0x05,
    XIOS_MSG_PACING       = 0x06,
    XIOS_MSG_SURFACE      = 0x07,
    XIOS_MSG_SURFACE_DROP = 0x08,
    XIOS_MSG_RELEASED     = 0x09,
    XIOS_MSG_STREAM_INFO  = 0x0a,
    XIOS_MSG_CURSOR_IMAGE = 0x0b
};

/* XiosProtocol.h:18-33 - 32 bytes, native little endian. The unions upstream gives
 * these fields (window_id/state, a/x, b/y, c/code, d/mods) are only spellings. */
typedef struct {
    uint32_t magic;
    uint32_t type;
    uint32_t window_id;
    uint32_t length; /* payload bytes following this record */
    int32_t a;
    int32_t b;
    int32_t c;
    int32_t d;
} xios_msg;

typedef char xs_assert_msg_is_32[(sizeof(xios_msg) == 32) ? 1 : -1];

#define XS_FOURCC_BGRA 0x42475241 /* 'BGRA', the server HELLO's d */
#define XS_SURFACE_FLIP_Y 1

#define XS_MAX_SURFACES 8
#define XS_MAX_PAYLOAD (4u << 20) /* a CURSOR_IMAGE is w*h*4; anything larger is a desync */
#define XS_HANDSHAKE_MS 3000      /* total budget per blocking read (SO_RCVTIMEO is 200 ms) */
#define XS_MACH_MS 1500           /* XSurface.c:253 */

struct xs_slot {
    uint32_t id;
    void *surface; /* IOSurfaceRef, +1 from IOSurfaceLookupFromMachPort */
    int w, h, stride, flags;
};

struct xs_conn {
    int fd;
    mach_port_t port; /* our reply port: receive right + one send right, same name */
    pthread_mutex_t lock;
    uint32_t caps;
    int w, h, stride; /* the primary surface */

    struct xs_slot surf[XS_MAX_SURFACES];
    int nsurf;
    int nbuffers; /* STREAM_INFO's a */

    unsigned char release_token[XS_TOKEN_BYTES];
    int has_release_token;
    unsigned char fence_token[XS_TOKEN_BYTES];
    int has_fence_token;

    /* resumable reader for xs_poll: a record can arrive in pieces */
    unsigned char hdr[32];
    size_t hdr_have;
    xios_msg cur;
    unsigned char *pay;
    size_t pay_cap, pay_have;
    int in_pay;

    int broken;
    unsigned long dirty_count, release_count;
};

/* ------------------------------------------------------------------- plumbing */

static long xs_now_ms(void)
{
    struct timeval tv;

    gettimeofday(&tv, NULL);
    return (long)tv.tv_sec * 1000L + (long)(tv.tv_usec / 1000);
}

/* Blocking read of exactly n bytes. SO_RCVTIMEO is deliberately short so a wedged
 * compositor cannot hang the caller forever; we retry until deadline_ms elapses. */
static int xs_read_full(int fd, void *buf, size_t n, int deadline_ms)
{
    unsigned char *p = (unsigned char *)buf;
    long end = xs_now_ms() + deadline_ms;
    size_t got = 0;

    while (got < n) {
        ssize_t r = recv(fd, p + got, n - got, 0);
        if (r > 0) {
            got += (size_t)r;
            continue;
        }
        if (r == 0) {
            errno = ECONNRESET;
            return -1;
        }
        if (errno == EINTR)
            continue;
        if (errno == EAGAIN || errno == EWOULDBLOCK) {
            if (xs_now_ms() >= end) {
                errno = ETIMEDOUT;
                return -1;
            }
            continue;
        }
        return -1;
    }
    return 0;
}

static int xs_skip(int fd, size_t n, int deadline_ms)
{
    unsigned char buf[256];

    while (n) {
        size_t chunk = n > sizeof buf ? sizeof buf : n;
        if (xs_read_full(fd, buf, chunk, deadline_ms) != 0)
            return -1;
        n -= chunk;
    }
    return 0;
}

/* 32 bytes never fill a socket buffer, but the fd is non-blocking after the
 * handshake, so wait for writability rather than dropping an ack on the floor. */
static int xs_write_full(int fd, const void *buf, size_t n)
{
    const unsigned char *p = (const unsigned char *)buf;
    size_t sent = 0;

    while (sent < n) {
        ssize_t r = send(fd, p + sent, n - sent, 0);
        if (r > 0) {
            sent += (size_t)r;
            continue;
        }
        if (r < 0 && errno == EINTR)
            continue;
        if (r < 0 && (errno == EAGAIN || errno == EWOULDBLOCK)) {
            struct pollfd pf;
            pf.fd = fd;
            pf.events = POLLOUT;
            pf.revents = 0;
            if (poll(&pf, 1, 200) <= 0) {
                errno = ETIMEDOUT;
                return -1;
            }
            continue;
        }
        return -1;
    }
    return 0;
}

static void xs_msg_init(xios_msg *m, uint32_t type, uint32_t window_id)
{
    memset(m, 0, sizeof *m);
    m->magic = XIOS_MAGIC;
    m->type = type;
    m->window_id = window_id;
}

/* Receive one mach message carrying exactly one port descriptor (protocol notes,
 * section 3; the sender is xios_surface.c:36-40). mach_msg_max_trailer_t is used for
 * the receive buffer so the kernel always has room for whatever trailer it appends. */
static int xs_recv_port(mach_port_t port, mach_port_t *out, int timeout_ms, const char *what)
{
    struct {
        mach_msg_header_t header;
        mach_msg_body_t body;
        mach_msg_port_descriptor_t port;
        mach_msg_max_trailer_t trailer;
    } r;
    mach_msg_return_t kr;

    memset(&r, 0, sizeof r);
    kr = mach_msg(&r.header, MACH_RCV_MSG | MACH_RCV_TIMEOUT, 0, (mach_msg_size_t)sizeof r, port,
                  (mach_msg_timeout_t)timeout_ms, MACH_PORT_NULL);
    if (kr != MACH_MSG_SUCCESS) {
        lcsys_log("xsurface: mach_msg(%s) failed 0x%x", what, (unsigned)kr);
        errno = ETIMEDOUT;
        return -1;
    }
    if (!(r.header.msgh_bits & MACH_MSGH_BITS_COMPLEX) || r.body.msgh_descriptor_count != 1) {
        lcsys_log("xsurface: mach_msg(%s) is not a 1-port complex message (bits=0x%x count=%u)", what,
                  (unsigned)r.header.msgh_bits, (unsigned)r.body.msgh_descriptor_count);
        mach_msg_destroy(&r.header);
        errno = EPROTO;
        return -1;
    }
    *out = r.port.name;
    return 0;
}

/* mach port -> IOSurfaceRef. IOSurfaceLookupFromMachPort returns a +1 reference (kept
 * for the life of the connection, released in xs_close); the send right we just
 * received is ours to drop as soon as the surface exists. */
static void *xs_surface_from_port(mach_port_t p, const char *what)
{
    IOSurfaceRef s = IOSurfaceLookupFromMachPort(p);

    if (!s)
        lcsys_log("xsurface: IOSurfaceLookupFromMachPort(%s) returned NULL", what);
    mach_port_deallocate(mach_task_self(), p);
    return (void *)s;
}

static int xs_add_slot(struct xs_conn *c, uint32_t id, void *surface, int w, int h, int stride, int flags)
{
    int i;

    for (i = 0; i < c->nsurf; i++) {
        if (c->surf[i].id == id) { /* a SURFACE for an id we already know: replace it */
            if (c->surf[i].surface)
                CFRelease((CFTypeRef)c->surf[i].surface);
            c->surf[i].surface = surface;
            c->surf[i].w = w;
            c->surf[i].h = h;
            c->surf[i].stride = stride;
            c->surf[i].flags = flags;
            lcsys_log("xsurface: surface id=%u replaced (%dx%d stride=%d)", id, w, h, stride);
            return 0;
        }
    }
    if (c->nsurf >= XS_MAX_SURFACES) {
        lcsys_log("xsurface: more than %d surfaces; dropping id=%u", XS_MAX_SURFACES, id);
        if (surface)
            CFRelease((CFTypeRef)surface);
        errno = ENOSPC;
        return -1;
    }
    c->surf[c->nsurf].id = id;
    c->surf[c->nsurf].surface = surface;
    c->surf[c->nsurf].w = w;
    c->surf[c->nsurf].h = h;
    c->surf[c->nsurf].stride = stride;
    c->surf[c->nsurf].flags = flags;
    c->nsurf++;
    lcsys_log("xsurface: surface id=%u %dx%d stride=%d flags=0x%x iosurface=%p (%d known)", id, w, h, stride,
              (unsigned)flags, surface, c->nsurf);
    return 0;
}

static void xs_free(struct xs_conn *c)
{
    int i, saved = errno;

    if (!c)
        return;
    for (i = 0; i < c->nsurf; i++)
        if (c->surf[i].surface)
            CFRelease((CFTypeRef)c->surf[i].surface);
    if (c->fd >= 0)
        close(c->fd);
    if (c->port != MACH_PORT_NULL) {
        /* one name, two rights: drop the send right first, because destroying the
         * receive right would otherwise turn it into a dead name */
        mach_port_mod_refs(mach_task_self(), c->port, MACH_PORT_RIGHT_SEND, -1);
        mach_port_mod_refs(mach_task_self(), c->port, MACH_PORT_RIGHT_RECEIVE, -1);
    }
    free(c->pay);
    pthread_mutex_destroy(&c->lock);
    free(c);
    errno = saved;
}

/* ------------------------------------------------------------------ handshake */

static struct xs_conn *xs_try_connect(const char *path, uint32_t caps)
{
    struct xs_conn *c;
    struct sockaddr_un sa;
    struct timeval tv;
    xios_msg m;
    mach_port_t sp = MACH_PORT_NULL;
    kern_return_t kr;
    unsigned char token[XS_TOKEN_BYTES];
    char ident[64];
    size_t plen = path ? strlen(path) : 0;
    int on = 1, i, flags;

    if (plen == 0 || plen >= sizeof sa.sun_path) {
        lcsys_log("xsurface: ddx path %s (%zu B, sun_path holds %zu)", plen ? "too long" : "missing", plen,
                  sizeof sa.sun_path);
        errno = plen ? ENAMETOOLONG : EINVAL;
        return NULL;
    }
    c = (struct xs_conn *)calloc(1, sizeof *c);
    if (!c)
        return NULL;
    c->fd = -1;
    c->caps = caps;
    pthread_mutex_init(&c->lock, NULL);

    c->fd = socket(AF_UNIX, SOCK_STREAM, 0);
    if (c->fd < 0) {
        lcsys_log("xsurface: socket() errno %d", errno);
        xs_free(c);
        return NULL;
    }
    memset(&sa, 0, sizeof sa);
    sa.sun_family = AF_UNIX;
    memcpy(sa.sun_path, path, plen);
    if (connect(c->fd, (struct sockaddr *)&sa, (socklen_t)sizeof sa) != 0) {
        lcsys_log("xsurface: connect(%s) errno %d", path, errno);
        xs_free(c);
        return NULL;
    }
    /* short timeout + xs_read_full's own deadline. SIGPIPE is already ignored by
     * lcsys_init; SO_NOSIGPIPE also covers a caller that reset the disposition. */
    tv.tv_sec = 0;
    tv.tv_usec = 200 * 1000;
    setsockopt(c->fd, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof tv);
    tv.tv_sec = 1;
    tv.tv_usec = 0;
    setsockopt(c->fd, SOL_SOCKET, SO_SNDTIMEO, &tv, sizeof tv);
    setsockopt(c->fd, SOL_SOCKET, SO_NOSIGPIPE, &on, sizeof on);

    /* 2. a reply port with a send right, so the server's mach_port_extract_right
     *    (MACH_MSG_TYPE_COPY_SEND, xios_surface.c:447) finds something to copy */
    kr = mach_port_allocate(mach_task_self(), MACH_PORT_RIGHT_RECEIVE, &c->port);
    if (kr != KERN_SUCCESS) {
        lcsys_log("xsurface: mach_port_allocate failed 0x%x", (unsigned)kr);
        c->port = MACH_PORT_NULL;
        errno = EPERM;
        xs_free(c);
        return NULL;
    }
    kr = mach_port_insert_right(mach_task_self(), c->port, c->port, MACH_MSG_TYPE_MAKE_SEND);
    if (kr != KERN_SUCCESS) {
        lcsys_log("xsurface: mach_port_insert_right failed 0x%x", (unsigned)kr);
        errno = EPERM;
        xs_free(c);
        return NULL;
    }

    /* 3. HELLO. xios_surface.c:812-822 rejects anything but a>0, b!=0, (c & ~1)==0,
     *    d==0, length==0. The pid is re-derived from LOCAL_PEERPID anyway. */
    xs_msg_init(&m, XIOS_MSG_HELLO, 1);
    m.a = (int32_t)getpid();
    m.b = (int32_t)c->port;
    m.c = (int32_t)caps;
    lcsys_log("xsurface: HELLO pid=%d port=%u caps=0x%x -> %s", (int)getpid(), (unsigned)c->port,
              (unsigned)caps, path);
    if (xs_write_full(c->fd, &m, sizeof m) != 0) {
        lcsys_log("xsurface: sending HELLO failed errno %d", errno);
        xs_free(c);
        return NULL;
    }

    /* 4. the primary IOSurface arrives by mach message BEFORE the socket reply */
    if (xs_recv_port(c->port, &sp, XS_MACH_MS, "primary surface") != 0) {
        xs_free(c);
        return NULL;
    }

    /* 5. server HELLO + its identifier ("iosc") */
    if (xs_read_full(c->fd, &m, sizeof m, XS_HANDSHAKE_MS) != 0) {
        lcsys_log("xsurface: no server HELLO (errno %d)", errno);
        mach_port_deallocate(mach_task_self(), sp);
        xs_free(c);
        return NULL;
    }
    if (m.magic != XIOS_MAGIC || m.type != XIOS_MSG_HELLO || m.window_id != 1) {
        lcsys_log("xsurface: bad server HELLO magic=0x%x type=0x%x version=%u", m.magic, m.type, m.window_id);
        mach_port_deallocate(mach_task_self(), sp);
        errno = EPROTO;
        xs_free(c);
        return NULL;
    }
    c->w = m.a;
    c->h = m.b;
    c->stride = m.c;
    ident[0] = 0;
    if (m.length) {
        size_t take = m.length < sizeof ident - 1 ? m.length : sizeof ident - 1;
        if (xs_read_full(c->fd, ident, take, XS_HANDSHAKE_MS) != 0 ||
            xs_skip(c->fd, m.length - take, XS_HANDSHAKE_MS) != 0) {
            lcsys_log("xsurface: truncated HELLO identifier");
            mach_port_deallocate(mach_task_self(), sp);
            xs_free(c);
            return NULL;
        }
        ident[take] = 0;
    }
    lcsys_log("xsurface: server HELLO %dx%d stride=%d format=%c%c%c%c ident=\"%s\"", c->w, c->h, c->stride,
              (char)(m.d >> 24), (char)(m.d >> 16), (char)(m.d >> 8), (char)m.d, ident);
    if (m.d != XS_FOURCC_BGRA)
        lcsys_log("xsurface: WARNING the format is not 'BGRA'; the texture is wrapped as bgra8Unorm anyway");

    {
        void *s = xs_surface_from_port(sp, "primary");
        int sw, sh, ss;

        if (!s) {
            errno = EPROTO;
            xs_free(c);
            return NULL;
        }
        /* XSurface.c:278-283 cross-checks the record against the surface itself. A
         * mismatch means a desync, but the record is only advisory: log it loudly and
         * believe the IOSurface, which is what we actually sample. */
        sw = (int)IOSurfaceGetWidth((IOSurfaceRef)s);
        sh = (int)IOSurfaceGetHeight((IOSurfaceRef)s);
        ss = (int)IOSurfaceGetBytesPerRow((IOSurfaceRef)s);
        if (sw != c->w || sh != c->h || ss != c->stride)
            lcsys_log("xsurface: WARNING HELLO says %dx%d/%d but the IOSurface is %dx%d/%d", c->w, c->h,
                      c->stride, sw, sh, ss);
        c->w = sw;
        c->h = sh;
        c->stride = ss;
        if (xs_add_slot(c, 1, s, c->w, c->h, c->stride, 0) != 0) {
            xs_free(c);
            return NULL;
        }
    }

    /* 6. STREAM_V2: STREAM_INFO + the release-timeline token, then one mach port and
     *    one SURFACE record per further buffer (xios_surface.c:889-918) */
    c->nbuffers = 1;
    if (caps & XS_HELLO_CAP_STREAM_V2) {
        if (xs_read_full(c->fd, &m, sizeof m, XS_HANDSHAKE_MS) != 0) {
            lcsys_log("xsurface: no STREAM_INFO (errno %d)", errno);
            xs_free(c);
            return NULL;
        }
        if (m.magic != XIOS_MAGIC || m.type != XIOS_MSG_STREAM_INFO || m.length != XS_TOKEN_BYTES) {
            lcsys_log("xsurface: bad STREAM_INFO magic=0x%x type=0x%x length=%u", m.magic, m.type, m.length);
            errno = EPROTO;
            xs_free(c);
            return NULL;
        }
        if (xs_read_full(c->fd, token, sizeof token, XS_HANDSHAKE_MS) != 0) {
            lcsys_log("xsurface: truncated release token");
            xs_free(c);
            return NULL;
        }
        memcpy(c->release_token, token, sizeof token);
        c->has_release_token = 1;
        c->nbuffers = m.a;
        lcsys_log("xsurface: STREAM_INFO buffers=%d release token=%02x%02x%02x%02x", c->nbuffers, token[0],
                  token[1], token[2], token[3]);
        for (i = 1; i < c->nbuffers; i++) {
            void *s;

            if (xs_recv_port(c->port, &sp, XS_MACH_MS, "extra surface") != 0) {
                xs_free(c);
                return NULL;
            }
            if (xs_read_full(c->fd, &m, sizeof m, XS_HANDSHAKE_MS) != 0 || m.magic != XIOS_MAGIC ||
                m.type != XIOS_MSG_SURFACE) {
                lcsys_log("xsurface: bad SURFACE record #%d magic=0x%x type=0x%x errno=%d", i, m.magic,
                          m.type, errno);
                mach_port_deallocate(mach_task_self(), sp);
                errno = EPROTO;
                xs_free(c);
                return NULL;
            }
            if (m.length && xs_skip(c->fd, m.length, XS_HANDSHAKE_MS) != 0) {
                mach_port_deallocate(mach_task_self(), sp);
                xs_free(c);
                return NULL;
            }
            s = xs_surface_from_port(sp, "extra");
            if (!s) {
                errno = EPROTO;
                xs_free(c);
                return NULL;
            }
            if (xs_add_slot(c, m.window_id, s, m.a, m.b, m.c, m.d) != 0) {
                xs_free(c);
                return NULL;
            }
        }
    }

    /* 7. from here on the reader must never block the draw thread */
    flags = fcntl(c->fd, F_GETFL, 0);
    if (flags < 0 || fcntl(c->fd, F_SETFL, flags | O_NONBLOCK) != 0) {
        lcsys_log("xsurface: O_NONBLOCK failed errno %d", errno);
        xs_free(c);
        return NULL;
    }
    lcsys_log("xsurface: ready, %d surface(s), output %dx%d stride %d, caps=0x%x", c->nsurf, c->w, c->h,
              c->stride, (unsigned)caps);
    return c;
}

/* iOS では task_for_pid() が **自分自身の pid に対しても** 通らない(実機 2026-09-12:
 * "xios: task_for_pid(1199) failed: 0x5 ((os/kern) failure)")。macOS とは違う点で、
 * ここが画面が出ない直接の原因だった。iosc は相手(= 我々)の task port を取ってから
 * IOSurface のポートを送るので、これが失敗すると絵が一枚も渡ってこない。
 *
 * iosc の libSystem 依存は relink で @rpath/libLCsys.dylib に差し替えてあるので、
 * この定義が iosc の task_for_pid 呼び出しに割り当たる。自分の pid なら
 * mach_task_self() を返すだけでよい(自分の task port はいつでも持っている)。
 * 他人の pid は本物に渡す(そちらは従来どおり失敗する)。 */
kern_return_t task_for_pid(mach_port_name_t target, int pid, mach_port_name_t *t)
{
    static kern_return_t (*real)(mach_port_name_t, int, mach_port_name_t *);
    static int resolved;

    if (pid == getpid()) {
        if (t)
            *t = mach_task_self();
        lcsys_log("xsurface: task_for_pid(self=%d) -> mach_task_self() (iOS では本物は失敗する)", pid);
        return KERN_SUCCESS;
    }
    if (!resolved) {
        resolved = 1;
        real = (kern_return_t (*)(mach_port_name_t, int, mach_port_name_t *))dlsym(RTLD_NEXT, "task_for_pid");
    }
    if (real)
        return real(target, pid, t);
    return KERN_FAILURE;
}

xs_conn *xs_connect(const char *ddx_sock_path)
{
    struct xs_conn *c = NULL;
    int saved, attempt;

    /* iosc はソケットを bind してから listen するまでに GPU の初期化を挟むので、
     * ファイルが見えていても少しの間 ECONNREFUSED が返る(実機 2026-09-12)。
     * 繋がるまで 200ms 間隔で最大 10 秒待つ。 */
    for (attempt = 0; attempt < 50; attempt++) {
        c = xs_try_connect(ddx_sock_path, XS_HELLO_CAP_STREAM_V2);
        if (c || errno != ECONNREFUSED)
            break;
        if (attempt == 0)
            lcsys_log("xsurface: まだ listen していない(ECONNREFUSED)。繋がるまで待つ");
        usleep(200 * 1000);
    }
    if (c)
        return c;
    saved = errno;
    lcsys_log("xsurface: the STREAM_V2 handshake failed (errno %d); retrying with caps=0", saved);
    c = xs_try_connect(ddx_sock_path, 0);
    if (!c)
        lcsys_log("xsurface: the caps=0 handshake failed too (errno %d)", errno);
    return c;
}

/* ----------------------------------------------------------------- the drain */

static ssize_t xs_read_some(struct xs_conn *c, void *buf, size_t n)
{
    ssize_t r;

    for (;;) {
        r = recv(c->fd, buf, n, 0);
        if (r > 0)
            return r;
        if (r == 0) {
            lcsys_log("xsurface: the ddx socket was closed by iosc");
            c->broken = 1;
            errno = ECONNRESET;
            return -1;
        }
        if (errno == EINTR)
            continue;
        if (errno == EAGAIN || errno == EWOULDBLOCK)
            return 0;
        lcsys_log("xsurface: recv errno %d", errno);
        c->broken = 1;
        return -1;
    }
}

static int xs_pay_reserve(struct xs_conn *c, size_t n)
{
    unsigned char *p;

    if (n <= c->pay_cap)
        return 0;
    p = (unsigned char *)realloc(c->pay, n);
    if (!p) {
        lcsys_log("xsurface: out of memory for a %zu B payload", n);
        return -1;
    }
    c->pay = p;
    c->pay_cap = n;
    return 0;
}

/* Act on c->cur (+ c->pay). 0 = keep draining, 1 = a DIRTY was delivered, -1 = fatal. */
static int xs_handle(struct xs_conn *c, uint32_t *surface_id, uint64_t *seq, uint64_t *fence_value)
{
    const xios_msg *m = &c->cur;

    switch (m->type) {
    case XIOS_MSG_DIRTY:
        c->dirty_count++;
        if (surface_id)
            *surface_id = m->window_id;
        if (seq)
            *seq = ((uint64_t)(uint32_t)m->b << 32) | (uint32_t)m->a;
        if (fence_value)
            *fence_value = ((uint64_t)(uint32_t)m->d << 32) | (uint32_t)m->c;
        if (c->pay_have >= XS_TOKEN_BYTES) {
            memcpy(c->fence_token, c->pay, XS_TOKEN_BYTES);
            c->has_fence_token = 1;
        } else if (!c->has_fence_token) {
            lcsys_log("xsurface: DIRTY without a fence token (length=%u)", m->length);
        }
        return 1;

    case XIOS_MSG_SURFACE: {
        /* a dynamically added surface: its mach port was sent just before the record */
        mach_port_t sp = MACH_PORT_NULL;
        void *s;

        if (xs_recv_port(c->port, &sp, 200, "dynamic surface") != 0)
            return 0; /* nothing to register, but the byte stream is still in step */
        s = xs_surface_from_port(sp, "dynamic");
        if (s)
            xs_add_slot(c, m->window_id, s, m->a, m->b, m->c, m->d);
        return 0;
    }

    case XIOS_MSG_SURFACE_DROP: {
        int i;

        for (i = 0; i < c->nsurf; i++) {
            if (c->surf[i].id != m->window_id)
                continue;
            lcsys_log("xsurface: SURFACE_DROP id=%u", m->window_id);
            if (c->surf[i].surface)
                CFRelease((CFTypeRef)c->surf[i].surface);
            c->surf[i] = c->surf[c->nsurf - 1];
            c->nsurf--;
            break;
        }
        return 0;
    }

    case XIOS_MSG_STREAM_INFO:
        if (c->pay_have >= XS_TOKEN_BYTES) {
            memcpy(c->release_token, c->pay, XS_TOKEN_BYTES);
            c->has_release_token = 1;
            c->nbuffers = m->a;
            lcsys_log("xsurface: STREAM_INFO again, buffers=%d", c->nbuffers);
        }
        return 0;

    case XIOS_MSG_CURSOR:
    case XIOS_MSG_CURSOR_IMAGE:
        return 0; /* no cursor yet: G2 draws the framebuffer only */

    case XIOS_MSG_HELLO:
        lcsys_log("xsurface: a second HELLO is fatal (XSurface.c:562-564)");
        c->broken = 1;
        errno = EPROTO;
        return -1;

    default:
        lcsys_log("xsurface: unknown message type 0x%x length=%u -> reconnect", m->type, m->length);
        c->broken = 1;
        errno = EPROTO;
        return -1;
    }
}

static int xs_poll_locked(struct xs_conn *c, uint32_t *surface_id, uint64_t *seq, uint64_t *fence_value)
{
    for (;;) {
        ssize_t r;
        int rc;

        if (c->broken) {
            errno = ECONNRESET;
            return -1;
        }
        if (!c->in_pay) {
            r = xs_read_some(c, c->hdr + c->hdr_have, sizeof c->hdr - c->hdr_have);
            if (r < 0)
                return -1;
            if (r == 0)
                return 0;
            c->hdr_have += (size_t)r;
            if (c->hdr_have < sizeof c->hdr)
                continue;
            memcpy(&c->cur, c->hdr, sizeof c->cur);
            c->hdr_have = 0;
            c->pay_have = 0;
            if (c->cur.magic != XIOS_MAGIC) {
                lcsys_log("xsurface: stream desync, magic=0x%x", c->cur.magic);
                c->broken = 1;
                errno = EPROTO;
                return -1;
            }
            if (c->cur.length > XS_MAX_PAYLOAD) {
                lcsys_log("xsurface: a payload of %u B is absurd; treating it as a desync", c->cur.length);
                c->broken = 1;
                errno = EPROTO;
                return -1;
            }
            if (c->cur.length > 0) {
                if (xs_pay_reserve(c, c->cur.length) != 0) {
                    c->broken = 1;
                    errno = ENOMEM;
                    return -1;
                }
                c->in_pay = 1;
                continue;
            }
        } else {
            r = xs_read_some(c, c->pay + c->pay_have, c->cur.length - c->pay_have);
            if (r < 0)
                return -1;
            if (r == 0)
                return 0;
            c->pay_have += (size_t)r;
            if (c->pay_have < c->cur.length)
                continue;
            c->in_pay = 0;
        }
        rc = xs_handle(c, surface_id, seq, fence_value);
        if (rc != 0)
            return rc;
    }
}

int xs_poll(xs_conn *c, uint32_t *surface_id, uint64_t *seq, uint64_t *fence_value)
{
    int rc;

    if (!c) {
        errno = EINVAL;
        return -1;
    }
    pthread_mutex_lock(&c->lock);
    rc = xs_poll_locked(c, surface_id, seq, fence_value);
    pthread_mutex_unlock(&c->lock);
    return rc;
}

/* ------------------------------------------------------------------ the rest */

void *xs_surface(xs_conn *c, uint32_t surface_id)
{
    void *s = NULL;
    int i;

    if (!c)
        return NULL;
    pthread_mutex_lock(&c->lock);
    for (i = 0; i < c->nsurf; i++) {
        if (c->surf[i].id == surface_id) {
            s = c->surf[i].surface;
            break;
        }
    }
    pthread_mutex_unlock(&c->lock);
    return s;
}

int xs_count(xs_conn *c)
{
    int n;

    if (!c)
        return 0;
    pthread_mutex_lock(&c->lock);
    n = c->nsurf;
    pthread_mutex_unlock(&c->lock);
    return n;
}

void xs_info(xs_conn *c, int *w, int *h, int *stride)
{
    if (!c) {
        if (w)
            *w = 0;
        if (h)
            *h = 0;
        if (stride)
            *stride = 0;
        return;
    }
    pthread_mutex_lock(&c->lock);
    if (w)
        *w = c->w;
    if (h)
        *h = c->h;
    if (stride)
        *stride = c->stride;
    pthread_mutex_unlock(&c->lock);
}

/* Section 5: the caller must already have COMMITTED a command buffer that signals the
 * release timeline with this seq. The server only accepts an ack whose seq matches the
 * slot's last_seq (xios_output_queue.h:121-134), so acks cannot be coalesced. */
int xs_release(xs_conn *c, uint32_t surface_id, uint64_t seq)
{
    xios_msg m;
    int rc;

    if (!c) {
        errno = EINVAL;
        return -1;
    }
    xs_msg_init(&m, XIOS_MSG_RELEASED, surface_id);
    m.a = (int32_t)(uint32_t)(seq & 0xffffffffu);
    m.b = (int32_t)(uint32_t)(seq >> 32);
    pthread_mutex_lock(&c->lock);
    rc = c->broken ? -1 : xs_write_full(c->fd, &m, sizeof m);
    if (rc == 0)
        c->release_count++;
    pthread_mutex_unlock(&c->lock);
    if (rc != 0)
        lcsys_log("xsurface: RELEASED id=%u seq=%llu failed errno %d", surface_id, (unsigned long long)seq,
                  errno);
    return rc;
}

int xs_presented(xs_conn *c, uint64_t seq, uint32_t us_since_present, int measured)
{
    xios_msg m;
    int rc;

    if (!c) {
        errno = EINVAL;
        return -1;
    }
    /* window_id is not part of PRESENTED (protocol notes, section 2): zero it. */
    xs_msg_init(&m, XIOS_MSG_PRESENTED, 0);
    m.a = (int32_t)(uint32_t)(seq & 0xffffffffu);
    m.b = (int32_t)(uint32_t)(seq >> 32);
    m.c = (int32_t)us_since_present;
    m.d = measured ? 1 : 0;
    pthread_mutex_lock(&c->lock);
    rc = c->broken ? -1 : xs_write_full(c->fd, &m, sizeof m);
    pthread_mutex_unlock(&c->lock);
    return rc;
}

/* 表示の時計をコンポジタに渡す(XSurface.c:659 xsurface_pacing と同じ並び)。
 * a = 次の表示期限までの µs、b = 周期 µs、c/d = 最小/最大 fps×1000。
 * iosc はこれで pacing=event-loop から vblank に切り替わる。 */
int xs_pacing(xs_conn *c, int32_t until_deadline_us, uint32_t interval_us, int32_t min_mfps, int32_t max_mfps)
{
    xios_msg m;
    int rc;

    if (!c || interval_us == 0) {
        errno = EINVAL;
        return -1;
    }
    xs_msg_init(&m, XIOS_MSG_PACING, 0);
    m.a = until_deadline_us;
    m.b = interval_us > (uint32_t)INT32_MAX ? INT32_MAX : (int32_t)interval_us;
    m.c = min_mfps;
    m.d = max_mfps;
    pthread_mutex_lock(&c->lock);
    rc = c->broken ? -1 : xs_write_full(c->fd, &m, sizeof m);
    pthread_mutex_unlock(&c->lock);
    return rc;
}

const unsigned char *xs_release_token(xs_conn *c)
{
    return (c && c->has_release_token) ? c->release_token : NULL;
}

const unsigned char *xs_last_fence_token(xs_conn *c)
{
    return (c && c->has_fence_token) ? c->fence_token : NULL;
}

void xs_close(xs_conn *c)
{
    if (!c)
        return;
    lcsys_log("xsurface: close (dirty=%lu released=%lu)", c->dirty_count, c->release_count);
    xs_free(c);
}
