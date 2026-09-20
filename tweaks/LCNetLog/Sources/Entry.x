// 開き方。LCTweakStore と違い、こちらは全ゲストアプリで開けるようにする。どのアプリの通信を
// 見たいかは、そのときどきで変わるため。
//
// 画面の右下にボタンを重ねる。ジェスチャーは iOS 26 のタブバーと SwiftUI に取られて届かない
// ことがあった(実機 2026-09-19)。重ねるだけなら相手の作りに関係なく押せる。
//
// 既定では出さない。通信の記録はどのアプリでも使えてしまうので、置いただけで全部の画面に
// ボタンが出るのは行き過ぎる。設定で出すアプリを選ぶ。

#import "LCNetLog.h"
#import <objc/runtime.h>

static char kLCNLButtonKey;

extern void LCNetLogInstallHooks(void);

/// このアプリでボタンを出すか。
///
/// LCNetLogApps に bundle id を並べる。"*" なら全部。空なら出さない。
/// LiveContainer 自身は対象外。ここで通信を見たい場面が無く、起動のたびに邪魔になる。
static BOOL LCNLEnabledHere(void) {
    NSString *bid = NSBundle.mainBundle.bundleIdentifier ?: @"";
    if ([NSBundle.mainBundle.bundlePath rangeOfString:@"/Documents/Applications/"].location == NSNotFound) {
        return NO;   // LiveContainer 自身
    }
    NSString *list = [NSUserDefaults.standardUserDefaults stringForKey:@"LCNetLogApps"] ?: @"*";
    if ([list isEqualToString:@"*"]) return YES;
    for (NSString *one in [list componentsSeparatedByString:@","]) {
        if ([[one stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet] isEqualToString:bid]) {
            return YES;
        }
    }
    return NO;
}

static void LCNLAddButton(UIWindow *window) {
    if (!window || !LCNLEnabledHere() || objc_getAssociatedObject(window, &kLCNLButtonKey)) return;

    UIButton *button = [UIButton buttonWithType:UIButtonTypeSystem];
    [button setTitle:@"N" forState:UIControlStateNormal];
    button.titleLabel.font = [UIFont systemFontOfSize:15 weight:UIFontWeightBold];
    [button setTitleColor:UIColor.whiteColor forState:UIControlStateNormal];
    button.backgroundColor = [UIColor.systemGreenColor colorWithAlphaComponent:0.75];
    button.layer.cornerRadius = 18;
    button.frame = CGRectMake(window.bounds.size.width - 48, window.bounds.size.height - 220, 36, 36);
    button.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin | UIViewAutoresizingFlexibleTopMargin;
    [button addTarget:window action:@selector(lcnl_open:) forControlEvents:UIControlEventTouchUpInside];

    // 邪魔なときのために動かせるようにする
    [button addGestureRecognizer:
        [[UIPanGestureRecognizer alloc] initWithTarget:window action:@selector(lcnl_drag:)]];

    [window addSubview:button];
    objc_setAssociatedObject(window, &kLCNLButtonKey, button, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

%hook UIWindow

- (void)becomeKeyWindow { %orig; LCNLAddButton(self); }
- (void)didMoveToWindow { %orig; LCNLAddButton(self); }

%new
- (void)lcnl_open:(UIButton *)sender {
    [LCNetLogViewController presentFrom:(UIWindow *)self];
}

%new
- (void)lcnl_drag:(UIPanGestureRecognizer *)sender {
    UIView *button = sender.view;
    CGPoint delta = [sender translationInView:self];
    button.center = CGPointMake(button.center.x + delta.x, button.center.y + delta.y);
    [sender setTranslation:CGPointZero inView:self];
}

%end

// hook が呼ばれなかった場合の保険。画面が出来上がるのを待って自分で探す。
static void LCNLPoll(int remaining) {
    if (remaining <= 0) return;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        BOOL found = NO;
        for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
            if (![scene isKindOfClass:UIWindowScene.class]) continue;
            for (UIWindow *w in ((UIWindowScene *)scene).windows) {
                LCNLAddButton(w);
                found = YES;
            }
        }
        if (!found) LCNLPoll(remaining - 1);
    });
}

%ctor {
    %init;
    LCNetLogInstallHooks();
    LCNLPoll(20);
}
