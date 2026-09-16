#!/usr/bin/env python3
"""3 つの tweak の機能一覧ページ(dist/tweaks/features.html)を作る。

README には機能が書かれていないことが多いので、実物から取る。
  - YouMod / YTMusicUltimate : 資材 .bundle の Localizable.strings(バイナリ plist)。
    設定行は「KEY と KEY_DESC が対になっている」もの、と見なす
  - SCInsta : ソースの TweakSettings.m(switchCellWithTitle:subtitle: の並び)

    python tools/make-features-page.py <youmod.strings> <ytmu.strings> <TweakSettings.m> <出力>
"""
import html
import plistlib
import re
import sys


def pairs_from_strings(path, keys_path):
    """設定画面に実際に出る行だけを返す。

    どの文言が設定として使われるかは、tweak のソース(設定画面を組み立てている所)の
    `LOC(@"KEY")` が正。文言ファイルには状態表示やエラー文も混ざっているので、
    そちらから推測してはいけない。keys_path はソースから抜いた鍵の一覧(出現順)。
    """
    with open(path, "rb") as f:
        d = plistlib.load(f)
    keys = [k.strip() for k in open(keys_path, encoding="utf-8") if k.strip()]
    rows = []
    for key in keys:
        if key.endswith("_DESC"):
            continue
        value = d.get(key)
        if not isinstance(value, str) or not value.strip():
            continue
        rows.append((value, d.get(key + "_DESC", "") or ""))
    return rows


def rows_from_tweaksettings(path):
    """SCInsta のソースから (見出し/項目) を順番どおりに取り出す。"""
    text = open(path, encoding="utf-8").read()
    out = []
    nav = re.compile(r'navigationCellWithTitle:@"([^"]+)"')
    head = re.compile(r'@"header":\s*@"([^"]+)"')
    cell = re.compile(r'(?:switchCell|sliderCell|textFieldCell|selectionCell)WithTitle:@"([^"]*)"\s*subtitle:@"([^"]*)"')
    for line in text.split("\n"):
        m = nav.search(line)
        if m:
            out.append(("h1", m.group(1)))
            continue
        m = head.search(line)
        if m:
            out.append(("h2", m.group(1)))
            continue
        m = cell.search(line)
        if m:
            out.append(("row", (m.group(1), m.group(2))))
    return out


CSS = """
:root { color-scheme: light dark; }
body { font: 15px/1.55 -apple-system, sans-serif; margin: 0; padding: 20px 16px 60px; max-width: 760px; }
h1 { font-size: 21px; margin: 32px 0 2px; }
h1:first-of-type { margin-top: 8px; }
h2 { font-size: 15px; margin: 20px 0 6px; color: #888; font-weight: 600;
     border-bottom: 1px solid #8883; padding-bottom: 4px; }
.count { color: #888; font-size: 13px; margin-bottom: 10px; }
.row { display: flex; gap: 10px; padding: 6px 0; border-bottom: 1px solid #8882; align-items: baseline; }
.row .t { font-weight: 600; flex: 0 0 auto; max-width: 45%; }
.row .d { color: #888; font-size: 13px; }
.top { border: 1px solid #8884; border-radius: 10px; padding: 12px 14px; margin-bottom: 8px; font-size: 14px; }
a { color: #0a84ff; }
"""


def main():
    youmod, youmod_keys, ytmu, ytmu_keys, scinsta_src, out = sys.argv[1:7]
    parts = [f"<!doctype html><html lang='ja'><head><meta charset='utf-8'>",
             "<meta name='viewport' content='width=device-width, initial-scale=1'>",
             "<title>tweak 機能一覧</title>", f"<style>{CSS}</style></head><body>"]
    parts.append("<div class='top'>3 つの tweak の設定画面に出る項目。README ではなく、"
                 "実物(資材の文言ファイルとソース)から取り出したもの。"
                 "<br><a href='./'>← tweak 置き場に戻る</a></div>")

    for title, note, path, keys in [
        ("YouMod — YouTube",
         "設定の開き方: 右上のアカウント画像 → 設定 → 一覧に増えている「YouMod」。"
         "先頭に YouMod v2.0.0 と出る。SponsorBlock は別項目",
         youmod, youmod_keys),
        ("YTMusicUltimate — YouTube Music",
         "設定の開き方: 右上のアカウント画像をタップ → 出てくるメニューの下の方にある"
         "赤い炎アイコンの「YTMusicUltimate」",
         ytmu, ytmu_keys),
    ]:
        rows = pairs_from_strings(path, keys)
        parts.append(f"<h1>{html.escape(title)}</h1>")
        parts.append(f"<div class='count'>{len(rows)} 項目 / {html.escape(note)}</div>")
        for t, d in rows:
            parts.append(f"<div class='row'><div class='t'>{html.escape(t)}</div>"
                         f"<div class='d'>{html.escape(d)}</div></div>")

    items = rows_from_tweaksettings(scinsta_src)
    n = sum(1 for k, _ in items if k == "row")
    parts.append("<h1>SCInsta — Instagram</h1>")
    parts.append(f"<div class='count'>{n} 項目 / 設定の開き方: 2 本指で画面を約0.8秒長押し"
                 "(または下のホームタブを0.3秒長押し)</div>")
    for kind, v in items:
        if kind == "h1":
            parts.append(f"<h2>{html.escape(v)}</h2>")
        elif kind == "h2":
            parts.append(f"<h2>{html.escape(v)}</h2>")
        else:
            t, d = v
            parts.append(f"<div class='row'><div class='t'>{html.escape(t)}</div>"
                         f"<div class='d'>{html.escape(d)}</div></div>")

    parts.append("</body></html>")
    with open(out, "w", encoding="utf-8") as f:
        f.write("\n".join(parts))
    print(f"書き出し: {out}")


if __name__ == "__main__":
    main()
