#!/usr/bin/env python3
"""日本語の文言を tweak 本体(.dylib)に焼き込む C 配列を吐く。

tweak の文言は資材 .bundle の中にある。LiveContainer では .bundle を dylib の隣に
自分で置かないと見つからず、設定画面に内部名が並ぶ。置く手間をなくすため、
日本語だけは dylib に埋め込んでしまう。

    python tools/gen-embedded-ja.py <ja の Localizable.strings> <出力.x> <関数名の接頭辞>

出力は `<接頭辞>EmbeddedJapanese(NSString *key)` 1 関数。見つからなければ nil。
"""
import plistlib
import sys


def escape(s):
    out = []
    for ch in s:
        if ch == "\\":
            out.append("\\\\")
        elif ch == '"':
            out.append('\\"')
        elif ch == "\n":
            out.append("\\n")
        elif ch == "\t":
            out.append("\\t")
        elif ord(ch) < 0x20:
            out.append("\\x%02x" % ord(ch))
        else:
            out.append(ch)
    return "".join(out)


def main():
    src, out, prefix = sys.argv[1], sys.argv[2], sys.argv[3]
    with open(src, "rb") as f:
        data = plistlib.load(f)

    rows = sorted((k, v) for k, v in data.items() if isinstance(v, str) and v)

    lines = [
        "// 自動生成 (tools/gen-embedded-ja.py)。手で直さないこと。",
        "//",
        "// 資材 .bundle が見つからない環境(LiveContainer など)でも設定画面が日本語になるよう、",
        "// 日本語の文言だけを本体に持たせる。端末の言語が日本語のときだけ使う。",
        "#import <Foundation/Foundation.h>",
        "",
        "static NSString *const k%sJAKeys[] = {" % prefix,
    ]
    lines += ['    @"%s",' % escape(k) for k, _ in rows]
    lines.append("};")
    lines.append("")
    lines.append("static NSString *const k%sJAValues[] = {" % prefix)
    lines += ['    @"%s",' % escape(v) for _, v in rows]
    lines.append("};")
    lines.append("")
    # 端末の言語では判定しない。LiveContainer はゲストアプリの AppleLanguages を
    # 差し替えるので([NSLocale preferredLanguages] が当てにならない)、判定を挟むと
    # 「英語のまま」に倒れる。この fork は日本語で使うためのものなので常に日本語を返す。
    lines.append("NSString *%sEmbeddedJapanese(NSString *key) {" % prefix)
    lines.append("    if (!key) return nil;")
    lines.append("")
    lines.append("    static NSDictionary<NSString *, NSString *> *table = nil;")
    lines.append("    static dispatch_once_t onceToken;")
    lines.append("    dispatch_once(&onceToken, ^{")
    lines.append("        NSUInteger n = sizeof(k%sJAKeys) / sizeof(k%sJAKeys[0]);" % (prefix, prefix))
    lines.append("        table = [NSDictionary dictionaryWithObjects:k%sJAValues forKeys:k%sJAKeys count:n];"
                 % (prefix, prefix))
    lines.append("    });")
    lines.append("")
    lines.append("    return table[key];")
    lines.append("}")
    lines.append("")

    with open(out, "w", encoding="utf-8", newline="\n") as f:
        f.write("\n".join(lines))

    print(f"{out}: {len(rows)} 件")


if __name__ == "__main__":
    main()
