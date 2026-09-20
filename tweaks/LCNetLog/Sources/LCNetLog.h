#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

/// 捕まえた 1 件のやり取り。
@interface LCNLEntry : NSObject
@property (nonatomic) NSInteger index;
@property (nonatomic, copy) NSDate *at;
@property (nonatomic, copy) NSString *method;      // GET / POST / WS など
@property (nonatomic, copy) NSString *url;
@property (nonatomic, copy) NSDictionary *requestHeaders;
@property (nonatomic, copy) NSData *requestBody;
@property (nonatomic) NSInteger statusCode;        // 応答が来ていなければ 0
@property (nonatomic, copy) NSDictionary *responseHeaders;
@property (nonatomic, copy) NSData *responseBody;
@property (nonatomic) long long elapsedMs;

- (NSString *)oneLine;                              // 一覧の 1 行
- (NSString *)fullText;                             // 詳細と書き出し用
@end

/// 記録そのもの。どのアプリでも同じように動く。
@interface LCNetLog : NSObject
+ (instancetype)shared;

@property (nonatomic, readonly) BOOL recording;
@property (nonatomic, copy) NSString *filter;       // URL にこの文字を含むものだけ
@property (nonatomic, readonly) NSArray<LCNLEntry *> *entries;

- (void)start;
- (void)stop;
- (void)clear;
- (void)add:(LCNLEntry *)entry;

/// 全件を 1 つの文字にする。書き出しと送信で使う
- (NSString *)dump;
@end

@interface LCNetLogViewController : UIViewController
+ (void)presentFrom:(UIWindow *)window;
@end
