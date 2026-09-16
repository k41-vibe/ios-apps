#!/usr/bin/env python3
"""tweak の原因パターンを数える。

これまで実機で落ちた原因は、毎回ちがう関数に見えて、種類としては数えるほどしか無い。
その種類を機械で数えるための道具。

    python tools/tweak-lint.py <ソースの入ったフォルダ> [...]
    python tools/tweak-lint.py --json <フォルダ>     # 機械で読む形

見つけるもの(誤検出の少ない順):

ここで %ctor と %init は見ない。2026-09-15 に「%ctor に %init が無いと hook が登録されない」
と判断して直したが、logos.pl を読むとそうなっていない。%init がファイルに一度も出てこなければ
Logos が既定の constructor を作る(logos.pl:875)し、初期化されていない hook グループが残れば
コンパイルを失敗させる(logos.pl:885)。つまりこの失敗の形は存在せず、Logos 自身が捕まえる。

  format-not-literal 書式に変数を渡している。その変数が nil だと -stringWithFormat: は
                     例外を投げる。ローカライズの引き当て失敗が、書式の nil として出る。

  raw-kvc            valueForKey: / setValue:forKey: を素で呼んでいる。相手はホストアプリの
                     クラスで、鍵が消えていれば nil ではなく例外になる。各 fork の安全版
                     (YouModSafeValueForKey / ytmu_safeValueForKey / SCIUtils)を通す。

  url-from-var       [NSURL URLWithString:] に変数を渡している。nil を渡すと例外。

  index-from-var     配列に変数の添字で触っている。長さはホストアプリ次第なので、
                     count を見ずに触ると範囲外で落ちる。

数えるだけで、直しはしない。0 件が目的ではなく、「増えていないか」を見るための数字。
"""
import argparse
import json
import os
import re
import sys

SOURCE_SUFFIXES = (".x", ".xm", ".m", ".mm")

# 安全版を提供している側のファイル。ここの素の KVC は実装そのものなので数えない。
SAFE_IMPL_HINTS = ("SafeKVC", "GlobalFunctions", "Utils.m", "NSBundle+")

# 書式が文字列そのものなら安全。@"..." で始まるかどうかだけ見る。
LITERAL_FORMAT = re.compile(r'stringWithFormat:\s*@"')
ANY_FORMAT = re.compile(r"stringWithFormat:\s*([^\s\]]+)")

RAW_KVC = re.compile(r"\[\s*[A-Za-z_][\w.]*\s+(?:valueForKey|setValue)\s*:")
URL_WITH_STRING = re.compile(r"URLWithString:\s*([^\s\]]+)")
# obj[i] と [obj objectAtIndex:i] の、添字が数字でないもの
INDEX_SUBSCRIPT = re.compile(r"\w\[\s*([A-Za-z_]\w*)\s*\]")
INDEX_MESSAGE = re.compile(r"objectAtIndex:\s*([A-Za-z_]\w*)")

# 同じ行か少し上で nil を見ているか。見ていれば数えない。
GUARDED = re.compile(r"\bif\s*\(|\?:|\?\s|respondsToSelector|\bcount\b|\blength\b|!\s*\w+\s*\)")


def read(path):
    with open(path, "r", encoding="utf-8", errors="replace") as handle:
        return handle.read()


def strip_comments(text):
    """行番号を保ったままコメントと文字列を潰す。中身の // や @" で誤検出しないため。"""
    out = []
    i, n = 0, len(text)
    while i < n:
        two = text[i:i + 2]
        if two == "//":
            j = text.find("\n", i)
            j = n if j < 0 else j
            out.append(" " * (j - i))
            i = j
        elif two == "/*":
            j = text.find("*/", i + 2)
            j = n if j < 0 else j + 2
            out.append("".join(c if c == "\n" else " " for c in text[i:j]))
            i = j
        else:
            out.append(text[i])
            i += 1
    return "".join(out)


def context(lines, index, before=2):
    lo = max(0, index - before)
    return " ".join(lines[lo:index + 1])


def scan_file(path):
    raw = read(path)
    text = strip_comments(raw)
    lines = text.splitlines()
    base = os.path.basename(path)
    safe_impl = any(hint in base for hint in SAFE_IMPL_HINTS)
    found = []

    def add(kind, line, detail):
        found.append({"kind": kind, "file": path, "line": line, "detail": detail})

    for i, line in enumerate(lines):
        line_no = i + 1

        for match in ANY_FORMAT.finditer(line):
            if LITERAL_FORMAT.search(line[match.start():]):
                continue
            add("format-not-literal", line_no, "書式が変数: %s" % match.group(1)[:60])

        if not safe_impl and RAW_KVC.search(line):
            add("raw-kvc", line_no, line.strip()[:90])

        for match in URL_WITH_STRING.finditer(line):
            arg = match.group(1)
            if arg.startswith('@"'):
                continue
            if GUARDED.search(context(lines, i)):
                continue
            add("url-from-var", line_no, "URLWithString: %s (nil の確認が見えない)" % arg[:50])

        for pattern in (INDEX_SUBSCRIPT, INDEX_MESSAGE):
            for match in pattern.finditer(line):
                name = match.group(1)
                if name in ("i", "j", "k", "idx", "index") and "for" in line:
                    continue
                if GUARDED.search(context(lines, i)):
                    continue
                add("index-from-var", line_no, "添字が変数: %s (count の確認が見えない)" % name)

    return found


def walk(roots):
    for root in roots:
        if os.path.isfile(root):
            yield root
            continue
        for dirpath, dirnames, filenames in os.walk(root):
            dirnames[:] = [d for d in dirnames if d not in (".git", "modules", ".theos", "packages")]
            for name in sorted(filenames):
                if name.endswith(SOURCE_SUFFIXES):
                    yield os.path.join(dirpath, name)


def main():
    parser = argparse.ArgumentParser(add_help=True)
    parser.add_argument("roots", nargs="+")
    parser.add_argument("--json", action="store_true")
    parser.add_argument("--kind", action="append", help="この種類だけ出す")
    args = parser.parse_args()

    findings = []
    for path in walk(args.roots):
        findings.extend(scan_file(path))
    if args.kind:
        findings = [f for f in findings if f["kind"] in args.kind]

    if args.json:
        json.dump(findings, sys.stdout, ensure_ascii=False, indent=1)
        return 0

    counts = {}
    for f in findings:
        counts[f["kind"]] = counts.get(f["kind"], 0) + 1

    for kind in sorted(counts, key=lambda k: -counts[k]):
        print("%-20s %4d" % (kind, counts[kind]))
        for f in findings:
            if f["kind"] != kind:
                continue
            rel = os.path.relpath(f["file"])
            print("   %s:%d  %s" % (rel, f["line"], f["detail"]))
    print()
    print("合計 %d" % len(findings))
    # どれも「見る価値がある」であって「必ず不具合」ではないので、件数で落とさない。
    return 0


if __name__ == "__main__":
    sys.exit(main())
