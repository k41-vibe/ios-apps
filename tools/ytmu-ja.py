#!/usr/bin/env python3
"""YTMusicUltimate の日本語文言の抜けを埋める。

上流の ja.lproj は鍵は全部あるが、半分ほど英語のまま置かれている。呼び出し側は
「見つからなければ渡した既定値」を返す作りなので欠けはしないが、日本語の画面に
英語が混ざる。ここで足りない分を埋めた ja.lproj を書き出す。

    python tools/ytmu-ja.py <YTMusicUltimate.bundle のパス>

en.lproj と同じ鍵をすべて含む ja.lproj を作る(訳の無いものは英語のまま)。
"""
import os
import plistlib
import sys

JA = {
    "ALL_DOWNLOADS": "保存した音源すべて",
    "CLEAR_CACHE": "キャッシュを消す",
    "DEFAULT": "既定",
    "DELETE": "削除",
    "DELETE_MESSAGE": "%@ を削除しますか?",
    "DONE": "完了",
    "DONT_RUSH": "曲を再生して取得",
    "DONT_RUSH_DESC": "リンクを取り出すために曲の再生が必要です",
    "DONT_STICK_HEADERS": "見出しを固定しない",
    "DONT_STICK_HEADERS_DESC": "画面の上に貼りつく見出しを、普通にスクロールするようにします",
    "DOWNLOAD_AUDIO": "音源を保存",
    "DOWNLOAD_AUDIO_DESC": "プレイヤーの YTMUltimate ボタンから音源を保存できるようにします",
    "DOWNLOAD_COVER": "ジャケット画像を保存",
    "DOWNLOAD_COVER_DESC": "プレイヤーの YTMUltimate ボタンからジャケット画像を保存できるようにします",
    "DOWNLOAD_PREMIUM": "保存(Premium が必要)",
    "DOWNLOADING": "保存中",
    "DOWNLOADS": "保存済み",
    "EMPTY": "保存したものがここに並びます",
    "EXPLORE": "見つける",
    "FORCE_PREMIUM": "Premium を強制的に有効にする",
    "FORCE_PREMIUM_DESC": "Premium の機能を強制的に有効にします。",
    "FOUND_SEGMENT": "本編以外の区間を検出しました",
    "HIDE_DOWNLOADS": "「保存済み」タブを隠す",
    "HIDE_EXPLORE": "「見つける」タブを隠す",
    "HIDE_FILTER_BUTTON": "並べ替えボタンを消す",
    "HIDE_FILTER_BUTTON_DESC": "ライブラリと保存済みの絞り込みボタンを上部バーから消します",
    "HIDE_HOME": "「ホーム」タブを隠す",
    "HIDE_LIBRARY": "「ライブラリ」タブを隠す",
    "HIDE_SAMPLES": "「サンプル」タブを隠す",
    "HOME": "ホーム",
    "LIBRARY": "ライブラリ",
    "LINK_NOT_FOUND": "リンクが見つかりません",
    "LOGIN_INFO": "Google アカウントにサインインしたあと、アプリの再起動が必要です",
    "OOPS": "問題が起きました",
    "PREPARING": "準備中…",
    "REGIONAL_RESTRICTION": "お住まいの国では YouTube Music が制限されているようです。",
    "REMOVE_ALL": "音源をすべて削除",
    "RENAME": "名前を変更",
    "RETRY_LOGIN": "回避策を有効にしました。",
    "SAMPLES": "サンプル",
    "SAVED_TO_PHOTOS": "写真に保存しました",
    "SB_ASK": "確認する",
    "SB_BEHAVIOR": "動作",
    "SB_NOTIF_DURATION": "通知を出す秒数",
    "SB_SKIP": "スキップ",
    "SEEK_BUTTONS": "前後の曲のボタンを早送り・巻き戻しにする",
    "SEEK_TIME_FOOTER": "送る秒数を選びます",
    "SEGMENT_SKIPPED": "本編以外の区間をスキップしました",
    "SELECT_ACTION": "動作を選ぶ",
    "SHARE_ALL": "音源をすべて共有",
    "SKIP": "スキップ",
    "SKIP_CONTENT_WARNING": "コンテンツの警告を飛ばす",
    "SKIP_CONTENT_WARNING_DESC": "不適切な可能性がある内容の警告を飛ばします",
    "SKIP_NONMUSIC_PARTS": "SponsorBlock",
    "STARTUP_TAB": "起動時のタブ",
    "TAB_SETTINGS": "タブの設定",
    "TABBAR_SETTINGS": "タブバーの設定",
    "UNSKIP": "スキップを取り消す",
}


def load(path):
    with open(path, "rb") as f:
        return plistlib.load(f)


def main():
    bundle = sys.argv[1]
    en = load(os.path.join(bundle, "en.lproj", "Localizable.strings"))
    ja_path = os.path.join(bundle, "ja.lproj", "Localizable.strings")
    ja = load(ja_path) if os.path.exists(ja_path) else {}

    out = {}
    filled = kept = english = 0
    for key, value in en.items():
        if key in JA:
            out[key] = JA[key]
            filled += 1
        elif key in ja and ja[key] != value:
            out[key] = ja[key]          # 上流の訳をそのまま使う
            kept += 1
        else:
            out[key] = value            # 訳が無いものは英語のまま(鍵名は絶対に入れない)
            english += 1

    os.makedirs(os.path.dirname(ja_path), exist_ok=True)
    with open(ja_path, "wb") as f:
        plistlib.dump(out, f, fmt=plistlib.FMT_BINARY)

    print(f"書き出し: {ja_path}")
    print(f"  今回埋めた: {filled}")
    print(f"  上流の訳を採用: {kept}")
    print(f"  英語のまま: {english}")
    print(f"  合計: {len(out)} (en は {len(en)})")


if __name__ == "__main__":
    main()
