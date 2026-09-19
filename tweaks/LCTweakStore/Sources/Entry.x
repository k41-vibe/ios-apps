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

static void LCTSAddButton(UIWindow *window);

static void LCTSAttach(UIWindow *window) {
    if (!window || !LCTSIsHost() || objc_getAssociatedObject(window, &kLCTSGestureKey)) return;

    UILongPressGestureRecognizer *press =
        [[UILongPressGestureRecognizer alloc] initWithTarget:window action:@selector(lcts_handlePress:)];
    press.minimumPressDuration = 0.8;
    press.numberOfTouchesRequired = 2;
    press.cancelsTouchesInView = NO;   // SwiftUI 側の操作を邪魔しない
    press.delaysTouchesBegan = NO;
    press.delaysTouchesEnded = NO;
    // 他の認識と同時に成立させる。iOS 26 は長押しを先に取ることがある
    press.delegate = (id<UIGestureRecognizerDelegate>)window;
    [window addGestureRecognizer:press];
    objc_setAssociatedObject(window, &kLCTSGestureKey, press, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

%hook UIWindow

- (void)becomeKeyWindow { %orig; LCTSAttach(self); LCTSAddButton(self); }
- (void)didMoveToWindow { %orig; LCTSAttach(self); LCTSAddButton(self); }

%new
- (BOOL)gestureRecognizer:(UIGestureRecognizer *)a
shouldRecognizeSimultaneouslyWithGestureRecognizer:(UIGestureRecognizer *)b {
    return YES;
}

%new
- (void)lcts_handlePress:(UILongPressGestureRecognizer *)sender {
    if (sender.state != UIGestureRecognizerStateBegan) return;
    [LCTweakStoreViewController presentFrom:(UIWindow *)self];
}

%end

// 「調整」タブの長押し。SwiftUI のタブも UIKit の UITabBar として作られる。
//
// iOS 26 のタブバーは長押しを自分で処理するので、こちらの認識まで届かない(実機 2026-09-19)。
// 同時に成立することを許し、さらに他より先に判定させる。
%hook UITabBar

- (void)didMoveToWindow {
    %orig;
    if (!LCTSIsHost() || objc_getAssociatedObject(self, &kLCTSTabKey)) return;

    UILongPressGestureRecognizer *press =
        [[UILongPressGestureRecognizer alloc] initWithTarget:self action:@selector(lcts_handleTabPress:)];
    press.minimumPressDuration = 0.5;
    press.cancelsTouchesInView = NO;
    press.delaysTouchesBegan = NO;
    press.delaysTouchesEnded = NO;
    press.delegate = (id<UIGestureRecognizerDelegate>)self;
    [self addGestureRecognizer:press];

    // 標準の認識より先に判定させる。これをしないと、タブバー側が先に取って終わる
    for (UIGestureRecognizer *other in self.gestureRecognizers) {
        if (other != press) [other requireGestureRecognizerToFail:press];
    }
    objc_setAssociatedObject(self, &kLCTSTabKey, press, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

%new
- (BOOL)gestureRecognizer:(UIGestureRecognizer *)a
shouldRecognizeSimultaneouslyWithGestureRecognizer:(UIGestureRecognizer *)b {
    return YES;
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

// 画面に常に出しておくボタン。
//
// ジェスチャーは iOS 26 のタブバーと SwiftUI に取られて届かなかった(実機 2026-09-19)。
// ウィンドウの上に重ねるだけなら、SwiftUI の構造にも他の操作にも干渉しない。
static char kLCTSButtonKey;

static void LCTSAddButton(UIWindow *window) {
    if (!window || !LCTSIsHost() || objc_getAssociatedObject(window, &kLCTSButtonKey)) return;

    UIButton *button = [UIButton buttonWithType:UIButtonTypeSystem];
    [button setTitle:@"T" forState:UIControlStateNormal];
    button.titleLabel.font = [UIFont systemFontOfSize:17 weight:UIFontWeightBold];
    [button setTitleColor:UIColor.whiteColor forState:UIControlStateNormal];
    button.backgroundColor = [UIColor.systemBlueColor colorWithAlphaComponent:0.85];
    button.layer.cornerRadius = 22;
    button.frame = CGRectMake(window.bounds.size.width - 60,
                              window.bounds.size.height - 160, 44, 44);
    button.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin | UIViewAutoresizingFlexibleTopMargin;
    [button addTarget:window action:@selector(lcts_openFromButton:) forControlEvents:UIControlEventTouchUpInside];

    // 位置が邪魔なときのために動かせるようにする
    UIPanGestureRecognizer *pan =
        [[UIPanGestureRecognizer alloc] initWithTarget:window action:@selector(lcts_dragButton:)];
    [button addGestureRecognizer:pan];

    [window addSubview:button];
    objc_setAssociatedObject(window, &kLCTSButtonKey, button, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

%hook UIWindow
%new
- (void)lcts_openFromButton:(UIButton *)sender {
    [LCTweakStoreViewController presentFrom:(UIWindow *)self];
}
%new
- (void)lcts_dragButton:(UIPanGestureRecognizer *)sender {
    UIView *button = sender.view;
    CGPoint delta = [sender translationInView:self];
    button.center = CGPointMake(button.center.x + delta.x, button.center.y + delta.y);
    [sender setTranslation:CGPointZero inView:self];
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
                LCTSAddButton(w);
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
