#!/usr/bin/env python3
"""Localizable.strings(バイナリ plist 形式)の中身を並べる。

tweak の機能一覧は README に無いことが多いが、資材の .bundle に入っている
文言ファイルを読めば、設定画面に出る項目がそのまま取れる。

    python tools/dump-strings.py <Localizable.strings>
"""
import plistlib
import sys


def main():
    for path in sys.argv[1:]:
        with open(path, "rb") as f:
            data = plistlib.load(f)
        print(f"=== {path}  ({len(data)} 件)")
        for k in sorted(data):
            v = data[k]
            if isinstance(v, str) and v.strip():
                print(f"{k}\t{v}")


if __name__ == "__main__":
    main()
