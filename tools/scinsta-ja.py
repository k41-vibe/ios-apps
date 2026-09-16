#!/usr/bin/env python3
"""SCInsta の設定画面を日本語にする。

SCInsta には多言語の仕組みが無く、文言は TweakSettings.m に英語で直接書いてある。
なので対訳表で置き換える。上流が更新されたら、このスクリプトを新しい
TweakSettings.m に当て直せばよい(訳の無い文言はそのまま残り、最後に一覧で出る)。

    python tools/scinsta-ja.py <TweakSettings.m>
"""
import re
import sys

JA = {
    # 見出し
    "General": "全般",
    "Notes": "ノート",
    "Focus/distractions": "集中(気の散るもの)",
    "Feed": "フィード",
    "Reels": "リール",
    "Hiding": "非表示",
    "Limits": "制限",
    "Saving": "保存",
    "Customize gestures": "長押しの設定",
    "Stories and messages": "ストーリーとメッセージ",
    "Messages": "メッセージ",
    "Visual messages & stories": "消える写真・動画とストーリー",
    "Navigation": "ナビゲーション",
    "Hiding tabs": "タブを隠す",
    "Confirm actions": "操作の確認",
    "Experimental": "実験中",
    "Warning": "注意",
    "Debug": "開発者向け",
    "FLEX": "FLEX",
    "SCInsta": "SCInsta",
    "Instagram": "Instagram",
    "Credits": "クレジット",
    "Developer": "開発者",
    "Tap Controls": "タップ操作",
    "Icon order": "アイコンの並び",

    # 全般
    "Hide ads": "広告を隠す",
    "Removes all ads from the Instagram app": "アプリ内の広告をすべて取り除きます",
    "Hide Meta AI": "Meta AI を隠す",
    "Hides the meta ai buttons/functionality within the app": "アプリ内の Meta AI のボタンと機能を隠します",
    "Copy description": "説明文をコピー",
    "Copy description text fields by long-pressing on them": "説明文を長押しするとコピーできます",
    "Do not save recent searches": "検索履歴を残さない",
    "Search bars will no longer save your recent searches": "検索欄が最近の検索を保存しなくなります",
    "Use detailed color picker": "詳細なカラーピッカー",
    "Long press on the eyedropper tool in stories to customize the text color more precisely":
        "ストーリーのスポイトを長押しすると、文字色をより細かく選べます",
    "Enable liquid glass buttons": "リキッドグラスのボタン",
    "Enables experimental liquid glass buttons within the app": "アプリ内のボタンを実験的なリキッドグラス表示にします",
    "Enable liquid glass surfaces": "リキッドグラスの面",
    "Enables liquid glass for other elements, such as menus": "メニューなど、他の要素もリキッドグラス表示にします",
    "Enable teen app icons": "ティーン向けアイコンを使う",
    "When enabled, hold down on the Instagram logo to change the app icon":
        "有効にすると、Instagram のロゴを長押ししてアプリのアイコンを変えられます",

    # ノート
    "Hide notes tray": "ノート欄を隠す",
    "Hides the notes tray in the dm inbox": "DM 一覧の上にあるノート欄を隠します",
    "Hide friends map": "友達マップを隠す",
    "Hides the friends map icon in the notes tray": "ノート欄にある友達マップのアイコンを隠します",
    "Enable note theming": "ノートのテーマを使う",
    "Enables the ability to use the notes theme picker": "ノートのテーマ選択を使えるようにします",
    "Custom note themes": "ノートのテーマを自作",
    "Provides an option to set custom emojis and background/text colors": "絵文字と背景色・文字色を自分で決められます",

    # 集中
    "No suggested users": "おすすめユーザーを消す",
    "Hides all suggested users for you to follow, outside your feed": "フィードの外にある「おすすめのユーザー」をすべて隠します",
    "No suggested chats": "おすすめチャットを消す",
    "Hides the suggested broadcast channels in direct messages": "DM のおすすめチャンネルを隠します",
    "Hide explore posts grid": "発見タブの投稿一覧を隠す",
    "Hides the grid of suggested posts on the explore/search tab": "発見(検索)タブに並ぶおすすめ投稿の格子を隠します",
    "Hide trending searches": "話題の検索を隠す",
    "Hides the trending searches under the explore search bar": "検索欄の下に出る「話題の検索」を隠します",

    # フィード
    "Hide stories tray": "ストーリー欄を隠す",
    "Hides the story tray at the top and within your feed": "上部とフィード内のストーリー欄を隠します",
    "Hide entire feed": "フィードを丸ごと隠す",
    "Removes all content from your home feed, including posts": "ホームのフィードから投稿を含むすべての内容を消します",
    "No suggested posts": "おすすめ投稿を消す",
    "Removes suggested posts from your feed": "フィードからおすすめ投稿を取り除きます",
    "No suggested for you": "「あなたへのおすすめ」を消す",
    "Hides suggested accounts for you to follow": "フォローのおすすめアカウントを隠します",
    "No suggested reels": "おすすめリールを消す",
    "Hides suggested reels to watch": "おすすめのリールを隠します",
    "No suggested threads posts": "Threads の投稿を消す",
    "Hides suggested threads posts": "おすすめされる Threads の投稿を隠します",
    "Disable video autoplay": "動画の自動再生を止める",
    "Prevents videos on your feed from playing automatically": "フィードの動画が勝手に再生されなくなります",

    # リール
    "Always show progress scrubber": "シークバーを常に出す",
    "Forces the progress bar to appear on every reel": "すべてのリールで進行バーを表示します",
    "Disable auto-unmuting reels": "自動でミュート解除しない",
    "Prevents reels from unmuting when the volume/silent button is pressed": "音量ボタンや消音スイッチでミュートが解除されなくなります",
    "Confirm reel refresh": "リール更新の確認",
    "Shows an alert when you trigger a reels refresh": "リールを更新しようとしたとき確認を出します",
    "Hide reels header": "リールの上部バーを隠す",
    "Hides the top navigation bar when watching reels": "リール視聴中の上部バーを隠します",
    "Hide reels blend button": "ブレンドのボタンを隠す",
    "Hides the button in DMs to open a reels blend": "DM にあるリールのブレンドを開くボタンを隠します",
    "Disable scrolling reels": "リールのスクロールを止める",
    "Prevents reels from being scrolled to the next video": "次の動画へスクロールできなくします",
    "Prevent doom scrolling": "延々と見続けるのを防ぐ",
    "Limits the amount of reels available to scroll at any given time, and prevents refreshing":
        "一度にスクロールできるリールの数を制限し、更新もできなくします",
    "Doom scrolling limit": "スクロールできる本数",
    "Change what happens when you tap on a reel": "リールをタップしたときの動作を変えます",
    "Mute/Unmute": "ミュート切り替え",
    "Pause/Play": "一時停止と再生",
    "Disabled": "無効",
    "Enabled": "有効",
    "Default": "既定",
    "Standard": "標準",
    "Alternate": "別の形",
    "Classic": "従来",

    # 保存
    "Download feed posts": "フィードの投稿を保存",
    "Long-press with finger(s) to download posts in the home tab": "ホームで投稿を指で長押しすると保存します",
    "Download reels": "リールを保存",
    "Long-press with finger(s) on a reel to download": "リールを指で長押しすると保存します",
    "Download stories": "ストーリーを保存",
    "Long-press with finger(s) while viewing someone's story to download": "ストーリーを見ている間に指で長押しすると保存します",
    "Save profile picture": "プロフィール写真を保存",
    "On someone's profile, click their profile picture to enlarge it, then hold to download":
        "プロフィール写真をタップして拡大し、そのまま長押しすると保存します",
    "Finger count for long-press": "長押しする指の本数",
    "Long-press hold time": "長押しの秒数",
    "Press finger(s) for %@ %@": "%@ %@ 長押し",
    "I have %@%@": "%@%@",
    "Downloads with %@ %@": "%@ %@ で保存",
    "Only loads %@ %@": "%@ %@ だけ読み込む",

    # メッセージ
    "Keep deleted messages": "削除されたメッセージを残す",
    "Saves deleted messages in chat conversations": "会話の中で削除されたメッセージを残します",
    "Manually mark messages as seen": "既読を手動でつける",
    "Adds a button to DM threads, which will mark messages as seen": "DM に、既読をつけるボタンを足します",
    "Disable typing status": "入力中を知らせない",
    "Prevents the typing indicator from being shown to others when you're typing in DMs":
        "DM の入力中に、相手へ「入力中」が出なくなります",
    "Unlimited replay of visual messages": "消える写真・動画を何度でも見る",
    "Replays direct visual messages normal/once stories unlimited times (toggle with image check icon)":
        "一度きりの写真・動画を何度でも再生できます(画像のチェックアイコンで切り替え)",
    "Disable view-once limitations": "一度きりの制限を外す",
    "Makes view-once messages behave like normal visual messages (loopable/pauseable)":
        "一度きりのメッセージを普通の写真・動画と同じように扱います(繰り返し・一時停止可)",
    "Disable screenshot detection": "スクショの検知を止める",
    "Removes the screenshot-prevention features for visual messages in DMs": "DM の写真・動画のスクショ防止機能を無効にします",
    "Disable story seen receipt": "ストーリーの足跡を残さない",
    "Hides the notification for others when you view their story": "相手のストーリーを見ても通知されなくなります",
    "Disable instants creation": "インスタントの作成を隠す",
    "Hides the functionality to create/send instants": "インスタントを作る・送る機能を隠します",

    # ナビゲーション
    "Hide feed tab": "ホームタブを隠す",
    "Hides the feed/home tab on the bottom navigation bar": "下のバーからホームタブを隠します",
    "Hide explore tab": "検索タブを隠す",
    "Hides the explore/search tab on the bottom navigation bar": "下のバーから検索タブを隠します",
    "Hide reels tab": "リールタブを隠す",
    "Hides the reels tab on the bottom navigation bar": "下のバーからリールタブを隠します",
    "Hide create tab": "作成タブを隠す",
    "Hides the create tab on the bottom navigation bar": "下のバーから作成タブを隠します",
    "Swipe between tabs": "スワイプでタブを移動",
    "Lets you swipe to switch between navigation bar tabs": "横スワイプで下のバーのタブを切り替えられます",
    "The order of the icons on the bottom navigation bar": "下のバーに並ぶアイコンの順番",

    # 確認
    "Confirm like: Posts/Stories": "いいねの確認(投稿・ストーリー)",
    "Shows an alert when you click the like button on posts or stories to confirm the like":
        "投稿やストーリーでいいねを押したとき確認を出します",
    "Confirm like: Reels": "いいねの確認(リール)",
    "Shows an alert when you click the like button on reels to confirm the like": "リールでいいねを押したとき確認を出します",
    "Confirm follow": "フォローの確認",
    "Shows an alert when you click the follow button to confirm the follow": "フォローを押したとき確認を出します",
    "Confirm repost": "リポストの確認",
    "Shows an alert when you click the repost button to confirm before resposting": "リポストを押したとき確認を出します",
    "Confirm call": "通話の確認",
    "Shows an alert when you click the audio/video call button to confirm before calling": "通話ボタンを押したとき確認を出します",
    "Confirm voice messages": "音声メッセージの確認",
    "Shows an alert to confirm before sending a voice message": "音声メッセージを送る前に確認を出します",
    "Confirm follow requests": "フォロー申請の確認",
    "Shows an alert when you accept/decline a follow request": "フォロー申請を承認・拒否するとき確認を出します",
    "Confirm shh mode": "消えるメッセージの確認",
    "Shows an alert to confirm before toggling disappearing messages": "消えるメッセージを切り替える前に確認を出します",
    "Confirm posting comment": "コメント投稿の確認",
    "Shows an alert when you click the post comment button to confirm": "コメントを投稿するとき確認を出します",
    "Confirm changing theme": "テーマ変更の確認",
    "Shows an alert when you change a chat theme to confirm": "チャットのテーマを変えるとき確認を出します",
    "Confirm sticker interaction": "スタンプ操作の確認",
    "Shows an alert when you click a sticker on someone's story to confirm the action":
        "ストーリーのスタンプを押したとき確認を出します",

    # 実験・開発者向け
    "These features are unstable and cause the Instagram app to crash unexpectedly.\\n\\nUse at your own risk!":
        "ここの機能は不安定で、Instagram が突然落ちることがあります。\\n\\n自己責任で使ってください。",
    "Enable FLEX gesture": "FLEX のジェスチャーを使う",
    "Allows you to hold 5 fingers on the screen to open the FLEX explorer": "画面を 5 本指で長押しすると FLEX が開きます",
    "Open FLEX on app launch": "起動時に FLEX を開く",
    "Automatically opens the FLEX explorer when the app launches": "アプリを起動したとき自動で FLEX を開きます",
    "Open FLEX on app focus": "前面に戻ったとき FLEX を開く",
    "Automatically opens the FLEX explorer when the app is focused": "アプリが前面に戻ったとき自動で FLEX を開きます",
    "Enable tweak settings quick-access": "設定のショートカット",
    "Allows you to hold on the home tab to open the SCInsta settings": "ホームタブを長押しすると SCInsta の設定が開きます",
    "Show tweak settings on app launch": "起動時に設定を開く",
    "Automatically opens the SCInsta settings when the app launches": "アプリを起動したとき自動で SCInsta の設定を開きます",
    "Disable safe mode": "セーフモードを無効にする",
    "Makes Instagram not reset settings after subsequent crashes (at your own risk)":
        "続けて落ちたときに Instagram が設定を初期化しないようにします(自己責任)",
    "Reset onboarding completion state": "初回案内の状態を戻す",
    "Requires restart": "再起動が必要",

    # その他
    "Donate": "開発者を支援する",
    "Consider donating to support this tweak's development!": "この tweak の開発を支えたい方はこちらから",
    "View Repo": "リポジトリを見る",
    "View the tweak's source code on GitHub": "GitHub でソースコードを見る",
}


def main():
    path = sys.argv[1]
    text = open(path, encoding="utf-8").read()
    original = text
    used = set()

    # @"..." の中身だけを見て、対訳表にあるものを差し替える
    def repl(m):
        s = m.group(1)
        if s in JA:
            used.add(s)
            return '@"' + JA[s] + '"'
        return m.group(0)

    text = re.sub(r'@"((?:[^"\\]|\\.)*)"', repl, text)

    with open(path, "w", encoding="utf-8", newline="\n") as f:
        f.write(text)

    print(f"置換: {len(used)} / 対訳表 {len(JA)} 件")
    missing = sorted(set(JA) - used)
    if missing:
        print("\n対訳表にあるが原文に見つからなかったもの(上流で文言が変わった可能性):")
        for s in missing:
            print(f"  {s}")
    print(f"\n変更: {'あり' if text != original else 'なし'}")


if __name__ == "__main__":
    main()
