#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

/// 配布サーバーの source.json にある tweaks の 1 件。
@interface LCTSItem : NSObject
@property (nonatomic, copy) NSString *name;          // 表示名 (YouMod)
@property (nonatomic, copy) NSString *file;          // 置くときのファイル名 (YouMod.dylib)
@property (nonatomic, copy) NSString *folder;        // 置く先の調整フォルダ名 (youtube)
@property (nonatomic, copy) NSString *appName;       // どのアプリ向けか (YouTube)
@property (nonatomic, copy) NSString *detail;        // 説明
@property (nonatomic, copy) NSString *sha256;        // 配布側の中身
@property (nonatomic, copy) NSString *build;         // sha256 の頭 12 桁
@property (nonatomic, copy) NSURL *downloadURL;
@property (nonatomic) long long size;

/// 端末に置いてあるものと比べた状態
typedef NS_ENUM(NSInteger, LCTSState) {
    LCTSStateUnknown = 0,
    LCTSStateMissing,      // 未導入
    LCTSStateOutdated,     // 中身が違う
    LCTSStateCurrent,      // 同じ
};
@property (nonatomic) LCTSState state;
@property (nonatomic, copy) NSString *localBuild;    // 端末側の sha256 の頭 12 桁
@end

@interface LCTweakStoreViewController : UIViewController
+ (void)presentFrom:(UIWindow *)window;
@end

/// Tweaks の置き場所。LiveContainer 自身の Documents/Tweaks。
NSString *LCTSTweaksRoot(void);
