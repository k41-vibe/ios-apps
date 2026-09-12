#!/usr/bin/env python3
"""Swift の文字列リテラルが行内で閉じているかだけを見る簡易チェック。

手元に Swift コンパイラが無いので、改行が文字列の途中に入ってしまう類の事故
(スクリプトで生成したときに起きやすい)だけでも先に捕まえる。
使い方: python tools/check_swift_strings.py <file...>
"""
import sys


def odd_quote_lines(path):
    bad = []
    for i, line in enumerate(open(path, encoding="utf-8"), 1):
        code = line.split("//")[0]      # 行コメントは無視(粗いが十分)
        code = code.replace('"""', "")  # 複数行文字列の区切りは数えない
        n, j = 0, 0
        while j < len(code):
            c = code[j]
            if c == "\\":
                j += 2                   # エスケープは次の 1 文字ごと飛ばす
                continue
            if c == '"':
                n += 1
            j += 1
        if n % 2:
            bad.append((i, line.rstrip()[:70]))
    return bad


def main(argv):
    rc = 0
    for path in argv:
        bad = odd_quote_lines(path)
        if bad:
            rc = 1
            print(f"{path}: 閉じていない文字列 {len(bad)} 行")
            for i, text in bad:
                print(f"  {i}: {text}")
        else:
            print(f"{path}: OK")
    return rc


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
