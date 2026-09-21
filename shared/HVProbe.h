/*
 * HVProbe.h - UTM の高速化に効く 2 つの前提を、実機で確かめるための最小の道具。
 *
 * 1. hv_probe(): CPU の仮想化機能がカーネル側に在るか。
 *    UTM は Services/UTMJailbreak.m の jb_has_hypervisor() で
 *      (a) このトラップの返り値が HV_UNSUPPORTED でない
 *      (b) 署名に com.apple.private.hypervisor がある
 *    の両方を要求する。(b) は Apple の非公開権限なので入れられない。
 *    (a) だけでも見ておくと、「権限だけが壁」なのか「カーネルにも無い」のかが分かれる。
 *
 * 2. ent_dump(): 自分の署名に入っている権限の一覧。
 *    LiveContainer のゲストは LiveContainer の権限で動くので、
 *    UTM 単体とは中身が違う。UTM が split-wx を選ぶ判定は
 *    dynamic-codesigning の有無だけを見ているので、それが無いことを確かめる。
 *    GPU 経路が要求する extended-virtual-addressing の有無もここで分かる。
 */
#ifndef HVPROBE_H
#define HVPROBE_H
#include <stdint.h>
#include <stddef.h>

/* Mach トラップ -5 を呼ぶ。無効な番号でもカーネルは失敗を返すだけで落ちない */
int64_t hv_probe(void);

/* 返り値が HV_UNSUPPORTED(0xfae9400f)かどうか。マクロだと Swift から見えないので関数にする */
int hv_is_unsupported(int64_t r);

/* 主実行ファイルの署名から権限の XML を取り出す。見つからなければ 0 を返す。
 * 返り値は書き込んだバイト数(終端の 0 を含まない) */
size_t ent_dump(char *out, size_t cap);

#endif
