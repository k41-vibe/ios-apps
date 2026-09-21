#include "HVProbe.h"
#include <string.h>
#include <mach-o/dyld.h>
#include <mach-o/loader.h>
#include <arpa/inet.h>   /* ntohl: 署名の中身は全部ビッグエンディアン */

/* UTM の Services/UTMJailbreak.m と同じ呼び方。x16 に負の番号を入れた svc は
 * Mach トラップで、-5 が仮想化の窓口。番号が無いカーネルは失敗を返す */
__attribute__((naked)) static int64_t hv_trap_raw(unsigned int call, void *arg)
{
    __asm__ volatile("mov x16, #-0x5\n"
                     "svc 0x80\n"
                     "ret\n");
}

int64_t hv_probe(void)
{
    return hv_trap_raw(0 /* HV_CALL_VM_GET_CAPABILITIES */, NULL);
}

int hv_is_unsupported(int64_t r)
{
    return r == (int64_t)(int32_t)0xfae9400f;
}

/* ---- 署名の中の権限を取り出す ---------------------------------------- */

#define CSMAGIC_EMBEDDED_SIGNATURE 0xfade0cc0
#define CSMAGIC_EMBEDDED_ENTITLEMENTS 0xfade7171

struct cs_blob_index { uint32_t type; uint32_t offset; };
struct cs_superblob { uint32_t magic, length, count; struct cs_blob_index index[]; };
struct cs_entitlements { uint32_t magic, length; char xml[]; };

size_t ent_dump(char *out, size_t cap)
{
    if (!out || cap == 0) return 0;
    out[0] = '\0';

    /* 主実行ファイル(LiveContainer 経由なら LiveContainer 自身)を見る */
    const struct mach_header_64 *h = (const struct mach_header_64 *)_dyld_get_image_header(0);
    if (!h || h->magic != MH_MAGIC_64) return 0;

    const uint8_t *base = (const uint8_t *)h;
    const struct load_command *lc = (const struct load_command *)(base + sizeof(*h));
    const struct linkedit_data_command *sig = NULL;
    const struct segment_command_64 *linkedit = NULL;
    const struct segment_command_64 *text = NULL;

    for (uint32_t i = 0; i < h->ncmds; i++) {
        if (lc->cmd == LC_CODE_SIGNATURE) {
            sig = (const struct linkedit_data_command *)lc;
        } else if (lc->cmd == LC_SEGMENT_64) {
            const struct segment_command_64 *sc = (const struct segment_command_64 *)lc;
            if (strcmp(sc->segname, SEG_LINKEDIT) == 0) linkedit = sc;
            else if (strcmp(sc->segname, SEG_TEXT) == 0) text = sc;
        }
        lc = (const struct load_command *)((const uint8_t *)lc + lc->cmdsize);
    }
    if (!sig || !linkedit || !text) return 0;

    /* ファイル内の位置を、読み込み済みの番地へ直す */
    intptr_t slide = (intptr_t)base - (intptr_t)text->vmaddr;
    const uint8_t *cs = (const uint8_t *)(linkedit->vmaddr + slide
                                          + (intptr_t)sig->dataoff - (intptr_t)linkedit->fileoff);

    const struct cs_superblob *sb = (const struct cs_superblob *)cs;
    if (ntohl(sb->magic) != CSMAGIC_EMBEDDED_SIGNATURE) return 0;

    uint32_t count = ntohl(sb->count);
    if (count > 64) return 0;                      /* 壊れた署名で走り過ぎない */
    for (uint32_t i = 0; i < count; i++) {
        const struct cs_entitlements *e =
            (const struct cs_entitlements *)(cs + ntohl(sb->index[i].offset));
        if (ntohl(e->magic) != CSMAGIC_EMBEDDED_ENTITLEMENTS) continue;
        uint32_t len = ntohl(e->length);
        if (len <= sizeof(*e)) return 0;
        size_t n = len - sizeof(*e);
        if (n >= cap) n = cap - 1;
        memcpy(out, e->xml, n);
        out[n] = '\0';
        return n;
    }
    return 0;
}
