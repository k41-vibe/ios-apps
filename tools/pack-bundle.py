#!/usr/bin/env python3
r"""tweak の資材 .bundle を zip に詰める。

PowerShell の Compress-Archive(5.1)は入口名の区切りに円記号を使う。zip の仕様は
スラッシュなので、iOS のファイルAppで展開すると階層にならず
`YouMod.bundle\ja.lproj\Localizable.strings` という名前の1ファイルになってしまう。
Python の zipfile はスラッシュで書くので、こちらで詰め直す。

    python tools/pack-bundle.py <.bundle のパス> <出力する zip>
"""
import os
import sys
import zipfile


def main():
    bundle, out = sys.argv[1], sys.argv[2]
    bundle = bundle.rstrip("\\/")
    base = os.path.basename(bundle)
    parent = os.path.dirname(bundle)

    n = 0
    with zipfile.ZipFile(out, "w", zipfile.ZIP_DEFLATED) as z:
        for root, _dirs, files in os.walk(bundle):
            for name in files:
                full = os.path.join(root, name)
                rel = os.path.relpath(full, parent).replace(os.sep, "/")
                z.write(full, rel)
                n += 1

    size = os.path.getsize(out)
    print(f"{out}  {n} 件  {size / 1024:.0f} KB")
    with zipfile.ZipFile(out) as z:
        bad = [e for e in z.namelist() if "\\" in e]
        print(f"  区切りが / でない入口: {len(bad)}")
        for e in z.namelist():
            if "lproj" in e and e.endswith("Localizable.strings") and "/ja." in e:
                print(f"  日本語: {e}")


if __name__ == "__main__":
    main()
