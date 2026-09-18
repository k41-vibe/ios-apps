// 開き方。LiveContainer の画面は SwiftUI なのでボタンを足すのが面倒だが、ジェスチャーなら
// UIWindow に付けるだけで済む。2 本指で 0.8 秒の長押しは SCInsta で使っていて誤爆しない。
//
// このファイルは LiveContainer 自身に読み込まれたときだけ動く。ゲストアプリに読み込まれても
// 何もしないよう、bundle id を見てから登録する。

#import "LCTweakStore.h"
#import <objc/runtime.h>

static char kLCTSGestureKey;

%hook UIWindow

- (void)becomeKeyWindow {
    %orig;

    if (![NSBundle.mainBundle.bundleIdentifier isEqualToString:@"com.kdt.livecontainer"]) return;
    if (objc_getAssociatedObject(self, &kLCTSGestureKey)) return;

    UILongPressGestureRecognizer *press =
        [[UILongPressGestureRecognizer alloc] initWithTarget:self action:@selector(lcts_handlePress:)];
    press.minimumPressDuration = 0.8;
    press.numberOfTouchesRequired = 2;
    // SwiftUI 側の操作を邪魔しないよう、こちらは素通しにする
    press.cancelsTouchesInView = NO;
    [self addGestureRecognizer:press];
    objc_setAssociatedObject(self, &kLCTSGestureKey, press, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    NSLog(@"[LCTweakStore] gesture installed on %@", self);
}

%new
- (void)lcts_handlePress:(UILongPressGestureRecognizer *)sender {
    if (sender.state != UIGestureRecognizerStateBegan) return;
    [LCTweakStoreViewController presentFrom:self];
}

%end

%ctor {
    %init;
    NSLog(@"[LCTweakStore] loaded in %@", NSBundle.mainBundle.bundleIdentifier);
}
