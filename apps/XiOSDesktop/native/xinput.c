/* iosc の入力ソケット(-input-sock)に触った場所とキーを流す側。
 *
 * 仕様は tools/xios/iosc-host-protocol.md の 6 節。画面(ddx)と同じ 32 バイトの
 * レコードだが、フィールドの読み方が違う: a=x, b=y, c=code, window_id=state,
 * d=mods, length=ペイロード長。
 *
 * 注意が 2 つある。
 *   1. HELLO は双方向。サーバーは accept 直後に送ってくるし、こちらも最初に送る。
 *      window_id==1 かつ length,a,b,c,d が全部 0 でないと切断される。
 *   2. サーバーから来るのは TRAITS と HAPTIC だけ。こちらがそれ以外を送ると切られる。
 *      来たものを読まずに放置すると受信バッファが詰まるので、捨てるためだけの
 *      スレッドを 1 本回す。
 *
 * 座標は出力(IOSurface)のピクセル。変換は呼ぶ側(ScreenView)の仕事。
 */

#include "lcsys.h"

#include <errno.h>
#include <fcntl.h>
#include <pthread.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/time.h>
#include <sys/un.h>
#include <unistd.h>

#define XIOS_MAGIC 0x584D5331u /* 'XMS1' */

enum {
    XI_MSG_HELLO  = 0x01,
    XI_MSG_MOTION = 0x100,
    XI_MSG_BUTTON = 0x101,
    XI_MSG_KEY    = 0x102,
    XI_MSG_TEXT   = 0x103,
    XI_MSG_TRAITS = 0x104,
    XI_MSG_TOUCH  = 0x105,
    XI_MSG_AXIS   = 0x108,
    XI_MSG_OUTPUT = 0x109,
    XI_MSG_HAPTIC = 0x10a
};

typedef struct {
    uint32_t magic;
    uint32_t type;
    uint32_t window_id; /* = state */
    uint32_t length;
    int32_t a;          /* = x */
    int32_t b;          /* = y */
    int32_t c;          /* = code */
    int32_t d;          /* = mods */
} xi_msg;

typedef char xi_assert_msg_is_32[(sizeof(xi_msg) == 32) ? 1 : -1];

void xi_close(void *h);

#define XI_MAX_TEXT 4096 /* IoscInput.c:105 の上限 */

struct xi_conn {
    int fd;
    pthread_mutex_t lock;
    pthread_t reaper;
    volatile int closing;
    unsigned long sent;
    /* サーバーから来る TRAITS(code=content_hint, state=content_purpose, mods=enabled)。
     * 「文字を受け取る欄が選ばれた/外れた」の合図で、表示側がこれでキーボードを出し入れする
     * (osk-plan.md)。同じ値の再送も 1 件と数える: 同じ欄の中で入力が続いている合図で、
     * 保留中の「下げる」を取り消すのに使う */
    unsigned long traits_seq;
    uint32_t tr_hint, tr_purpose, tr_enabled;
};

/* ------------------------------------------------------------ 送受信の下回り */

static int write_all(int fd, const void *buf, size_t n)
{
    const char *p = buf;
    while (n) {
        ssize_t w = send(fd, p, n, 0);
        if (w > 0) {
            p += w;
            n -= (size_t)w;
            continue;
        }
        if (w < 0 && (errno == EINTR || errno == EAGAIN))
            continue;
        return -1;
    }
    return 0;
}

static int read_all(int fd, void *buf, size_t n)
{
    char *p = buf;
    while (n) {
        ssize_t r = recv(fd, p, n, 0);
        if (r > 0) {
            p += r;
            n -= (size_t)r;
            continue;
        }
        if (r < 0 && errno == EINTR)
            continue;
        return -1;
    }
    return 0;
}

/* サーバーからの TRAITS / HAPTIC を読む。読まないと詰まる。TRAITS は控えておく。 */
static void *reaper_main(void *arg)
{
    struct xi_conn *c = arg;
    xi_msg m;
    while (!c->closing) {
        if (read_all(c->fd, &m, sizeof m) != 0)
            break;
        if (m.magic != XIOS_MAGIC) {
            lcsys_log("xinput: 受信が化けている magic=0x%x -> 読むのをやめる", m.magic);
            break;
        }
        if (m.type == XI_MSG_TRAITS) {
            pthread_mutex_lock(&c->lock);
            c->tr_hint = (uint32_t)m.c;
            c->tr_purpose = m.window_id;
            c->tr_enabled = (uint32_t)m.d;
            c->traits_seq++;
            pthread_mutex_unlock(&c->lock);
        }
        if (m.length > XI_MAX_TEXT) {
            lcsys_log("xinput: %u B のペイロードはあり得ない -> 読むのをやめる", m.length);
            break;
        }
        if (m.length) {
            char scratch[XI_MAX_TEXT];
            if (read_all(c->fd, scratch, m.length) != 0)
                break;
        }
    }
    return NULL;
}

static int send_msg(struct xi_conn *c, uint32_t type, int32_t x, int32_t y, int32_t code,
                    uint32_t state, int32_t mods, const void *payload, uint32_t paylen)
{
    xi_msg m;
    int rc;
    if (!c || c->fd < 0)
        return -1;
    memset(&m, 0, sizeof m);
    m.magic = XIOS_MAGIC;
    m.type = type;
    m.window_id = state;
    m.length = paylen;
    m.a = x;
    m.b = y;
    m.c = code;
    m.d = mods;
    pthread_mutex_lock(&c->lock);
    rc = write_all(c->fd, &m, sizeof m);
    if (rc == 0 && paylen)
        rc = write_all(c->fd, payload, paylen);
    if (rc == 0)
        c->sent++;
    pthread_mutex_unlock(&c->lock);
    if (rc != 0)
        lcsys_log("xinput: 送信失敗 type=0x%x errno %d", type, errno);
    return rc;
}

/* ------------------------------------------------------------ 接続 */

void *xi_connect(const char *path)
{
    struct sockaddr_un sa;
    struct timeval tv;
    struct xi_conn *c;
    size_t plen;
    xi_msg hello;
    int fd;

    plen = path ? strlen(path) : 0;
    if (!plen || plen >= sizeof sa.sun_path) {
        lcsys_log("xinput: 入力ソケットのパスが %s (%zu B)", plen ? "長すぎる" : "無い", plen);
        return NULL;
    }
    fd = socket(AF_UNIX, SOCK_STREAM, 0);
    if (fd < 0) {
        lcsys_log("xinput: socket() errno %d", errno);
        return NULL;
    }
    memset(&sa, 0, sizeof sa);
    sa.sun_family = AF_UNIX;
    memcpy(sa.sun_path, path, plen + 1);
    if (connect(fd, (struct sockaddr *)&sa, sizeof sa) != 0) {
        lcsys_log("xinput: connect(%s) errno %d", path, errno);
        close(fd);
        return NULL;
    }
    tv.tv_sec = 3;
    tv.tv_usec = 0;
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof tv);
    /* 相手が閉じた口に書いてもアプリごと落ちないように(IoscInput.c:35-38 と同じ) */
    {
        int on = 1;
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, sizeof on);
    }

    c = calloc(1, sizeof *c);
    if (!c) {
        close(fd);
        return NULL;
    }
    c->fd = fd;
    pthread_mutex_init(&c->lock, NULL);

    /* こちらの HELLO。a/b/c/d と length は 0 でなければ切られる(XiosProtocol.h:181-190) */
    if (send_msg(c, XI_MSG_HELLO, 0, 0, 0, 1, 0, NULL, 0) != 0) {
        xi_close(c);
        return NULL;
    }
    /* サーバーの HELLO(accept 直後に送られている) */
    if (read_all(fd, &hello, sizeof hello) != 0 || hello.magic != XIOS_MAGIC
        || hello.type != XI_MSG_HELLO) {
        lcsys_log("xinput: サーバーの HELLO が来ない/化けている (errno %d magic=0x%x type=0x%x)",
                  errno, hello.magic, hello.type);
        xi_close(c);
        return NULL;
    }
    tv.tv_sec = 0;
    tv.tv_usec = 0;
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof tv);
    if (pthread_create(&c->reaper, NULL, reaper_main, c) != 0) {
        lcsys_log("xinput: 受信スレッドが作れない errno %d", errno);
        c->reaper = NULL;
    }
    lcsys_log("xinput: ready -> %s", path);
    return c;
}

void xi_close(void *h)
{
    struct xi_conn *c = h;
    if (!c)
        return;
    c->closing = 1;
    if (c->fd >= 0) {
        shutdown(c->fd, SHUT_RDWR);
        close(c->fd);
        c->fd = -1;
    }
    if (c->reaper)
        pthread_join(c->reaper, NULL);
    pthread_mutex_destroy(&c->lock);
    free(c);
}

/* ------------------------------------------------------------ 出す側 */

int xi_motion(void *c, int x, int y)
{
    return send_msg(c, XI_MSG_MOTION, x, y, 0, 0, 0, NULL, 0);
}

/* code は 1=左 2=中 3=右、state は押下で 1 */
int xi_button(void *c, int x, int y, int code, int state)
{
    return send_msg(c, XI_MSG_BUTTON, x, y, code, (uint32_t)state, 0, NULL, 0);
}

/* slot は 0..9、phase は 0=離 1=触 2=移動 3=取消 */
int xi_touch(void *c, int x, int y, int slot, int phase)
{
    return send_msg(c, XI_MSG_TOUCH, x, y, slot, (uint32_t)phase, 0, NULL, 0);
}

/* code は X の keysym。mods は bit0 shift / bit1 ctrl / bit2 alt */
int xi_key(void *c, int keysym, int state, int mods)
{
    return send_msg(c, XI_MSG_KEY, 0, 0, keysym, (uint32_t)state, mods, NULL, 0);
}

/* TEXT は code と length の両方にバイト数を入れる。違うと拒否される(IoscInput.c:105) */
int xi_text(void *c, const char *utf8)
{
    size_t n = utf8 ? strlen(utf8) : 0;
    if (!n || n > XI_MAX_TEXT)
        return -1;
    return send_msg(c, XI_MSG_TEXT, 0, 0, (int32_t)n, 0, 0, utf8, (uint32_t)n);
}

int xi_axis(void *c, int dx256, int dy256, int source, int stop, int mods)
{
    return send_msg(c, XI_MSG_AXIS, dx256, dy256, source, (uint32_t)stop, mods, NULL, 0);
}

/* 画面の向きと論理サイズをサーバーに伝える(アプリ -> サーバー) */
int xi_output(void *c, int logical_w, int logical_h, int rotation)
{
    return send_msg(c, XI_MSG_OUTPUT, logical_w, logical_h, rotation & 3, 0, 0, NULL, 0);
}

/* 最後に受けた TRAITS。戻り値は受信の通し番号(変わっていなければ新しい TRAITS は無い)。 */
unsigned long xi_traits(void *h, uint32_t *hint, uint32_t *purpose, uint32_t *enabled)
{
    struct xi_conn *c = h;
    unsigned long seq;
    if (!c)
        return 0;
    pthread_mutex_lock(&c->lock);
    if (hint) *hint = c->tr_hint;
    if (purpose) *purpose = c->tr_purpose;
    if (enabled) *enabled = c->tr_enabled;
    seq = c->traits_seq;
    pthread_mutex_unlock(&c->lock);
    return seq;
}

unsigned long xi_sent(void *h)
{
    struct xi_conn *c = h;
    return c ? c->sent : 0;
}
