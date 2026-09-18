// 開き方。LiveContainer の画面は SwiftUI なのでボタンを足すのが面倒だが、ジェスチャーなら
// ウィンドウに付けるだけで済む。2 本指で 0.8 秒の長押しは SCInsta で使っていて誤爆しない。
//
// %hook UIWindow の becomeKeyWindow だけに頼ると付かないことがあった(実機 2026-09-18)。
// SwiftUI のウィンドウは UIWindowScene 経由で作られ、こちらの hook が呼ばれる保証がない。
// そこで読み込み直後から一定間隔でウィンドウを探し、見つけたら付けて止める。
//
// ゲストアプリに読み込まれても何もしないよう、bundle id を見てから登録する。

#import "LCTweakStore.h"
#import <objc/runtime.h>

static char kLCTSGestureKey;
static char kLCTSTabKey;

static BOOL LCTSIsHost(void) {
    return [NSBundle.mainBundle.bundleIdentifier isEqualToString:@"com.kdt.livecontainer"];
}

static void LCTSAttach(UIWindow *window) {
    if (!window || objc_getAssociatedObject(window, &kLCTSGestureKey)) return;

    UILongPressGestureRecognizer *press =
        [[UILongPressGestureRecognizer alloc] initWithTarget:window action:@selector(lcts_handlePress:)];
    press.minimumPressDuration = 0.8;
    press.numberOfTouchesRequired = 2;
    // SwiftUI 側の操作を邪魔しないよう、こちらは素通しにする
    press.cancelsTouchesInView = NO;
    [window addGestureRecognizer:press];
    objc_setAssociatedObject(window, &kLCTSGestureKey, press, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    NSLog(@"[LCTweakStore] gesture installed on %@", window);
}

%hook UIWindow

- (void)becomeKeyWindow {
    %orig;
    if (LCTSIsHost()) LCTSAttach(self);
}

- (void)didMoveToWindow {
    %orig;
    if (LCTSIsHost()) LCTSAttach(self);
}

%new
- (void)lcts_handlePress:(UILongPressGestureRecognizer *)sender {
    if (sender.state != UIGestureRecognizerStateBegan) return;
    [LCTweakStoreViewController presentFrom:(UIWindow *)self];
}

%end

// 「調整」タブのアイコンを長押しで開く。
//
// LiveContainer の画面は SwiftUI だが、タブは UIKit の UITabBar として作られるので、
// そこへ長押しを付けて、押された位置がどのタブかを見る。SwiftUI 側の項目に直接触れずに済む。
%hook UITabBar

- (void)didMoveToWindow {
    %orig;
    if (!LCTSIsHost()) return;
    if (objc_getAssociatedObject(self, &kLCTSTabKey)) return;

    UILongPressGestureRecognizer *press =
        [[UILongPressGestureRecognizer alloc] initWithTarget:self action:@selector(lcts_handleTabPress:)];
    press.minimumPressDuration = 0.5;
    press.cancelsTouchesInView = NO;
    [self addGestureRecognizer:press];
    objc_setAssociatedObject(self, &kLCTSTabKey, press, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    NSLog(@"[LCTweakStore] tab gesture installed, items=%lu", (unsigned long)self.items.count);
}

%new
- (void)lcts_handleTabPress:(UILongPressGestureRecognizer *)sender {
    if (sender.state != UIGestureRecognizerStateBegan) return;

    // 押された位置にあるのがどの項目か。UITabBar は項目ごとのビューを公開していないので、
    // 幅を項目数で割って何番目かを出す。タブは等間隔に並ぶ
    NSUInteger count = self.items.count;
    if (count == 0) return;
    CGPoint p = [sender locationInView:self];
    NSUInteger index = (NSUInteger)(p.x / (self.bounds.size.width / count));
    if (index >= count) index = count - 1;

    // 「調整」は Tweaks のタブ。並びが変わっても効くよう、まず名前で探す
    NSUInteger target = NSNotFound;
    for (NSUInteger i = 0; i < count; i++) {
        NSString *title = self.items[i].title ?: @"";
        if ([title isEqualToString:@"調整"] || [title localizedCaseInsensitiveContainsString:@"tweak"]) {
            target = i;
            break;
        }
    }
    if (target != NSNotFound && index != target) return;

    NSLog(@"[LCTweakStore] tab %lu long pressed", (unsigned long)index);
    [LCTweakStoreViewController presentFrom:self.window];
}

%end

// hook が呼ばれなかった場合の保険。画面が出来上がるのを待って自分で探す。
static void LCTSPoll(int remaining) {
    if (remaining <= 0) {
        NSLog(@"[LCTweakStore] ウィンドウが見つからないまま打ち切り");
        return;
    }
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        BOOL found = NO;
        for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
            if (![scene isKindOfClass:UIWindowScene.class]) continue;
            for (UIWindow *w in ((UIWindowScene *)scene).windows) {
                LCTSAttach(w);
                found = YES;
            }
        }
        if (!found) LCTSPoll(remaining - 1);
    });
}

// 読み込まれたことを画面で示す。ジェスチャーが反応しない原因が「読み込まれていない」のか
// 「付いていない」のか、外から見分けがつかなかったので入れた。
// 一度確認したら LCTweakStoreShowBanner を切れば出なくなる。
static void LCTSAnnounce(int remaining) {
    if (remaining <= 0) return;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        UIWindow *key = nil;
        for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
            if (![scene isKindOfClass:UIWindowScene.class]) continue;
            for (UIWindow *w in ((UIWindowScene *)scene).windows) {
                if (w.isKeyWindow) { key = w; break; }
            }
        }
        if (!key) { LCTSAnnounce(remaining - 1); return; }

        UILabel *label = [[UILabel alloc] init];
        label.text = @"LCTweakStore 読み込み済み。ここを押すと開きます";
        label.font = [UIFont systemFontOfSize:13 weight:UIFontWeightSemibold];
        label.textColor = UIColor.whiteColor;
        label.backgroundColor = [UIColor.systemBlueColor colorWithAlphaComponent:0.92];
        label.textAlignment = NSTextAlignmentCenter;
        label.numberOfLines = 0;
        label.userInteractionEnabled = YES;
        label.layer.cornerRadius = 10;
        label.layer.masksToBounds = YES;
        CGFloat w = key.bounds.size.width - 24;
        label.frame = CGRectMake(12, key.safeAreaInsets.top + 8, w, 44);
        [label addGestureRecognizer:
            [[UITapGestureRecognizer alloc] initWithTarget:key action:@selector(lcts_openFromBanner:)]];
        [key addSubview:label];
        NSLog(@"[LCTweakStore] banner shown");
    });
}

%hook UIWindow
%new
- (void)lcts_openFromBanner:(UITapGestureRecognizer *)sender {
    [sender.view removeFromSuperview];
    [LCTweakStoreViewController presentFrom:(UIWindow *)self];
}
%end

%ctor {
    %init;
    NSLog(@"[LCTweakStore] loaded in %@", NSBundle.mainBundle.bundleIdentifier);
    if (!LCTSIsHost()) return;
    LCTSPoll(20);
    if (![NSUserDefaults.standardUserDefaults boolForKey:@"LCTweakStoreHideBanner"]) {
        LCTSAnnounce(20);
    }
}
