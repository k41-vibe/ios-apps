// 開き方。LiveContainer の画面は SwiftUI なのでボタンを足すのが面倒だが、ジェスチャーなら
// ウィンドウに付けるだけで済む。
//
// 判定は %ctor では行わない。TweakLoader は LiveContainerSwiftUI を読む前に動くので、
// その時点の bundle id が期待どおりとは限らない(実機 2026-09-18)。画面が出来てから見る。

#import "LCTweakStore.h"
#import <objc/runtime.h>

static char kLCTSGestureKey;
static char kLCTSTabKey;

static BOOL LCTSIsHost(void) {
    return [NSBundle.mainBundle.bundleIdentifier isEqualToString:@"com.kdt.livecontainer"];
}

static void LCTSAttach(UIWindow *window) {
    if (!window || !LCTSIsHost() || objc_getAssociatedObject(window, &kLCTSGestureKey)) return;

    UILongPressGestureRecognizer *press =
        [[UILongPressGestureRecognizer alloc] initWithTarget:window action:@selector(lcts_handlePress:)];
    press.minimumPressDuration = 0.8;
    press.numberOfTouchesRequired = 2;
    press.cancelsTouchesInView = NO;   // SwiftUI 側の操作を邪魔しない
    [window addGestureRecognizer:press];
    objc_setAssociatedObject(window, &kLCTSGestureKey, press, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

%hook UIWindow

- (void)becomeKeyWindow { %orig; LCTSAttach(self); }
- (void)didMoveToWindow { %orig; LCTSAttach(self); }

%new
- (void)lcts_handlePress:(UILongPressGestureRecognizer *)sender {
    if (sender.state != UIGestureRecognizerStateBegan) return;
    [LCTweakStoreViewController presentFrom:(UIWindow *)self];
}

%end

// 「調整」タブの長押し。SwiftUI のタブも UIKit の UITabBar として作られる。
%hook UITabBar

- (void)didMoveToWindow {
    %orig;
    if (!LCTSIsHost() || objc_getAssociatedObject(self, &kLCTSTabKey)) return;

    UILongPressGestureRecognizer *press =
        [[UILongPressGestureRecognizer alloc] initWithTarget:self action:@selector(lcts_handleTabPress:)];
    press.minimumPressDuration = 0.5;
    press.cancelsTouchesInView = NO;
    [self addGestureRecognizer:press];
    objc_setAssociatedObject(self, &kLCTSTabKey, press, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

%new
- (void)lcts_handleTabPress:(UILongPressGestureRecognizer *)sender {
    if (sender.state != UIGestureRecognizerStateBegan) return;

    // UITabBar は項目ごとのビューを公開していないので、幅を項目数で割って何番目かを出す
    NSUInteger count = self.items.count;
    if (count == 0) return;
    CGPoint p = [sender locationInView:self];
    NSUInteger index = (NSUInteger)(p.x / (self.bounds.size.width / count));
    if (index >= count) index = count - 1;

    NSUInteger target = NSNotFound;
    for (NSUInteger i = 0; i < count; i++) {
        NSString *title = self.items[i].title ?: @"";
        if ([title isEqualToString:@"調整"] || [title localizedCaseInsensitiveContainsString:@"tweak"]) {
            target = i;
            break;
        }
    }
    if (target != NSNotFound && index != target) return;

    [LCTweakStoreViewController presentFrom:self.window];
}

%end

// hook が呼ばれなかった場合の保険。画面が出来上がるのを待って自分で探す。
static void LCTSPoll(int remaining) {
    if (remaining <= 0) return;
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

__attribute__((constructor))
static void LCTweakStoreInit(void) {
    // ここで bundle id を見ても当てにならない。ウィンドウが出来てから LCTSAttach が判定する
    LCTSPoll(20);
}
