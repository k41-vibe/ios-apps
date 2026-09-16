#!/usr/bin/env python3
"""tweak の資材にある小さな画像を、本体(.dylib)に焼き込む C 配列にする。

文言と同じ事情。資材 .bundle は脱獄環境の決まった場所を見に行くので、LiveContainer
では見つからない。タブのアイコンのように「無いと見た目が壊れる」ものだけ本体に入れる。

    python tools/gen-embedded-images.py <出力.m> <関数名の接頭辞> <倍率> <名前=ファイル> ...

例:
    python tools/gen-embedded-images.py out.m YTMU 3 "icons/downloads=downloads@3x.png"

出力は `<接頭辞>EmbeddedImage(NSString *name)` 1 関数。無ければ nil。
"""
import os
import sys


def main():
    out, prefix, scale = sys.argv[1], sys.argv[2], sys.argv[3]
    pairs = []
    for arg in sys.argv[4:]:
        name, _, path = arg.partition("=")
        with open(path, "rb") as f:
            pairs.append((name, f.read(), os.path.basename(path)))

    lines = [
        "// 自動生成 (tools/gen-embedded-images.py)。手で直さないこと。",
        "//",
        "// 資材 .bundle が見つからない環境でもタブのアイコンが出るよう、画像を本体に持たせる。",
        "#import <UIKit/UIKit.h>",
        "",
    ]

    for i, (name, data, src) in enumerate(pairs):
        lines.append(f"// {name}  ({src}, {len(data)} bytes)")
        lines.append(f"static const unsigned char k{prefix}Image{i}[] = {{")
        for off in range(0, len(data), 20):
            chunk = data[off:off + 20]
            lines.append("    " + "".join(f"0x{b:02x}," for b in chunk))
        lines.append("};")
        lines.append("")

    lines.append(f"NSString *const k{prefix}ImageNames[] = {{")
    lines += [f'    @"{name}",' for name, _, _ in pairs]
    lines.append("};")
    lines.append("")
    lines.append(f"UIImage *{prefix}EmbeddedImage(NSString *name) {{")
    lines.append("    if (!name) return nil;")
    lines.append("")
    lines.append("    static NSDictionary<NSString *, NSData *> *table = nil;")
    lines.append("    static dispatch_once_t onceToken;")
    lines.append("    dispatch_once(&onceToken, ^{")
    lines.append("        NSMutableDictionary *m = [NSMutableDictionary dictionary];")
    for i, (name, data, _) in enumerate(pairs):
        lines.append(f'        m[@"{name}"] = [NSData dataWithBytes:k{prefix}Image{i} '
                     f"length:sizeof(k{prefix}Image{i})];")
    lines.append("        table = m;")
    lines.append("    });")
    lines.append("")
    lines.append("    NSData *data = table[name];")
    lines.append("    if (!data) return nil;")
    lines.append(f"    return [UIImage imageWithData:data scale:{scale}.0];")
    lines.append("}")
    lines.append("")

    with open(out, "w", encoding="utf-8", newline="\n") as f:
        f.write("\n".join(lines))

    total = sum(len(d) for _, d, _ in pairs)
    print(f"{out}: {len(pairs)} 件, {total / 1024:.1f} KB")


if __name__ == "__main__":
    main()
