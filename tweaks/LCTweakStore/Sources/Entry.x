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

%ctor {
    %init;
    NSLog(@"[LCTweakStore] loaded in %@", NSBundle.mainBundle.bundleIdentifier);
    if (LCTSIsHost()) LCTSPoll(20);
}
