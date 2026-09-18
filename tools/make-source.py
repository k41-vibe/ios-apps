#!/usr/bin/env python3
"""dist/ の中身から LiveContainer 用のソース JSON を作る。

LiveContainer は AltStore のソース形式をそのまま読める(LCAltStoreSourcesView.swift)。
一度ソースを登録しておけば、

  - 新しく足したアプリ   -> 一覧に出てくるので押せば入る(追加)
  - version を上げたアプリ -> 同じ bundle id なので置き換えるか聞かれる(更新)

となり、URL を都度渡す必要がなくなる。

tweaks の項目は AltStore 形式には無いので独自に足している。今の LiveContainer は
知らないキーを読み飛ばすだけなので害はなく、fork 側で読めるようにする前提で先に出しておく。

    python tools/make-source.py [--base URL]
"""
import argparse
import datetime
import hashlib
import io
import json
import pathlib
import plistlib
import zipfile

ROOT = pathlib.Path(__file__).resolve().parent.parent
DIST = ROOT / "dist"
DEFAULT_BASE = "https://node.tail1f41c8.ts.net:8789"

# tweak がどのアプリ向けで、LiveContainer のどのフォルダに入るか。
# フォルダ名は端末側で作ったものに合わせる必要がある。
TWEAKS = {
    "YouMod.dylib": {
        "folder": "youtube",   # 端末側の調整フォルダ名。LCTweakStore がここへ置く
        "name": "YouMod",
        "app": "YouTube",
        "bundleIdentifier": "com.google.ios.youtube",
        "description": "YouTube の広告除去・SponsorBlock・ダウンロード・日本語設定",
    },
    "YTMusicUltimate.dylib": {
        "folder": "youtubemusic",   # 端末側の調整フォルダ名。LCTweakStore がここへ置く
        "name": "YTMusicUltimate",
        "app": "YouTube Music",
        "bundleIdentifier": "com.google.ios.youtubemusic",
        "description": "YouTube Music の広告除去・音源とカバーの保存・日本語設定",
    },
    "SCInsta.dylib": {
        "folder": "instagram",   # 端末側の調整フォルダ名。LCTweakStore がここへ置く
        "name": "SCInsta",
        "app": "Instagram",
        "bundleIdentifier": "com.burbn.instagram",
        "description": "Instagram の広告除去・長押し保存・ベータ更新の抑制・日本語設定",
    },
}


def sha256(path):
    digest = hashlib.sha256()
    with open(path, "rb") as handle:
        for chunk in iter(lambda: handle.read(1 << 20), b""):
            digest.update(chunk)
    return digest.hexdigest()


def read_ipa_info(path):
    """ipa の中の Info.plist を読む。Payload/<何か>.app/Info.plist にある。"""
    with zipfile.ZipFile(path) as archive:
        candidates = [
            n for n in archive.namelist()
            if n.count("/") == 2 and n.startswith("Payload/") and n.endswith(".app/Info.plist")
        ]
        if not candidates:
            return None
        with archive.open(candidates[0]) as handle:
            return plistlib.load(io.BytesIO(handle.read()))


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--base", default=DEFAULT_BASE, help="配布サーバーの URL")
    args = parser.parse_args()
    base = args.base.rstrip("/")

    today = datetime.date.today().isoformat()
    apps = []

    for ipa in sorted(DIST.glob("*.ipa")):
        info = read_ipa_info(ipa)
        if not info:
            print("  info.plist が見つからない、飛ばす:", ipa.name)
            continue

        bundle_id = info.get("CFBundleIdentifier")
        if not bundle_id:
            print("  bundle id が無い、飛ばす:", ipa.name)
            continue

        name = info.get("CFBundleDisplayName") or info.get("CFBundleName") or ipa.stem
        # 表示用は CFBundleShortVersionString、同じ表示版のまま中身だけ変わることがあるので
        # ビルド番号も併記する。これが動かないと LiveContainer 側で「更新あり」にならない。
        version = str(info.get("CFBundleShortVersionString") or "1.0")
        build = str(info.get("CFBundleVersion") or "1")
        size = ipa.stat().st_size

        apps.append({
            "name": name,
            "bundleIdentifier": bundle_id,
            "developerName": "rutoi",
            "version": version,
            "versionDate": today,
            "versionDescription": f"build {build} / {ipa.name}",
            "downloadURL": f"{base}/{ipa.name}",
            "localizedDescription": info.get("CFBundleDisplayName") or name,
            "size": size,
            "versions": [{
                "version": version,
                "buildNumber": build,
                "date": today,
                "downloadURL": f"{base}/{ipa.name}",
                "size": size,
            }],
        })
        print(f"  app   {name:<16} {version} (build {build})  {size:>10,} B")

    tweaks = []
    for dylib in sorted((DIST / "tweaks").glob("*.dylib")):
        meta = TWEAKS.get(dylib.name)
        if not meta:
            print("  未登録の dylib、飛ばす:", dylib.name)
            continue
        digest = sha256(dylib)
        tweaks.append({
            "name": meta["name"],
            "file": dylib.name,
            "app": meta["app"],
            "folder": meta["folder"],
            "bundleIdentifier": meta["bundleIdentifier"],
            "localizedDescription": meta["description"],
            # 中身が変わったときだけ変わる。ビルド時の定義を持たせなくて済む。
            "build": digest[:12],
            "sha256": digest,
            "size": dylib.stat().st_size,
            "date": today,
            "downloadURL": f"{base}/tweaks/{dylib.name}",
        })
        print(f"  tweak {meta['name']:<16} {digest[:12]}  {dylib.stat().st_size:>10,} B")

    source = {
        "name": "rutoi の配布",
        "identifier": "ts.tail1f41c8.node.rutoi",
        "subtitle": "自分用のアプリと tweak",
        "description": "Tailscale 越しに母艦から配っている、自作アプリと改造 tweak の一覧。",
        "website": f"{base}/tweaks/index.html",
        "tintColor": "#4C8DFF",
        "apps": apps,
        "tweaks": tweaks,
    }

    out = DIST / "source.json"
    out.write_text(json.dumps(source, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    print(f"\n{out}  ({out.stat().st_size:,} B)  apps={len(apps)} tweaks={len(tweaks)}")
    print(f"登録する URL: {base}/source.json")


if __name__ == "__main__":
    main()
