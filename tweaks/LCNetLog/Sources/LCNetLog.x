// どのアプリの通信も見られるようにする。LiveContainer のグローバルの調整フォルダに置くと
// 全ゲストに読み込まれる。
//
// 捕まえ方は NSURLSession のデリゲートを差し替える形にした。URLProtocol という差し込み口も
// あるが、あちらは WebSocket と、BSD ソケットを直に使う経路を拾えない。今のアプリは
// メッセージ系を WebSocket で流すことが多く、Instagram もその可能性がある。
//
// 記録の中には認証情報が入る。既定では止めてあり、画面から明示的に始めるまで何も残らない。

#import "LCNetLog.h"
#import <objc/runtime.h>

static const NSUInteger kBodyLimit = 256 * 1024;   // 1 件あたりの本文の上限
static const NSUInteger kEntryLimit = 2000;        // 保持する件数

#pragma mark - 1 件

@implementation LCNLEntry

/// 本文を読める形にする。JSON なら整形し、そうでなければ文字として出し、
/// それも無理なら 16 進で先頭だけ見せる。
static NSString *LCNLBody(NSData *data) {
    if (!data.length) return @"(なし)";
    id json = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
    if (json) {
        NSData *pretty = [NSJSONSerialization dataWithJSONObject:json
                                                         options:NSJSONWritingPrettyPrinted | NSJSONWritingSortedKeys
                                                           error:nil];
        if (pretty) return [[NSString alloc] initWithData:pretty encoding:NSUTF8StringEncoding];
    }
    NSString *text = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    if (text.length) return text;

    NSMutableString *hex = [NSMutableString string];
    const unsigned char *bytes = data.bytes;
    NSUInteger shown = MIN(data.length, (NSUInteger)512);
    for (NSUInteger i = 0; i < shown; i++) [hex appendFormat:@"%02x", bytes[i]];
    return [NSString stringWithFormat:@"(binary %lu B) %@%@",
            (unsigned long)data.length, hex, data.length > shown ? @"..." : @""];
}

- (NSString *)oneLine {
    NSURL *u = [NSURL URLWithString:self.url ?: @""];
    NSString *path = u.path.length ? u.path : self.url;
    return [NSString stringWithFormat:@"%@ %@ %@",
            self.statusCode ? @(self.statusCode).stringValue : @"...", self.method ?: @"?", path ?: @"?"];
}

- (NSString *)fullText {
    NSMutableString *s = [NSMutableString string];
    [s appendFormat:@"#%ld  %@  %lld ms\n", (long)self.index, self.at, self.elapsedMs];
    [s appendFormat:@"%@ %@\n", self.method ?: @"?", self.url ?: @"?"];
    [s appendString:@"\n--- 要求ヘッダ ---\n"];
    for (NSString *k in [self.requestHeaders.allKeys sortedArrayUsingSelector:@selector(compare:)]) {
        [s appendFormat:@"%@: %@\n", k, self.requestHeaders[k]];
    }
    [s appendFormat:@"\n--- 要求本文 ---\n%@\n", LCNLBody(self.requestBody)];
    [s appendFormat:@"\n--- 応答 %ld ---\n", (long)self.statusCode];
    for (NSString *k in [self.responseHeaders.allKeys sortedArrayUsingSelector:@selector(compare:)]) {
        [s appendFormat:@"%@: %@\n", k, self.responseHeaders[k]];
    }
    [s appendFormat:@"\n--- 応答本文 ---\n%@\n", LCNLBody(self.responseBody)];
    return s;
}
@end

#pragma mark - 記録

@interface LCNetLog ()
@property (nonatomic, readwrite) BOOL recording;
@property (nonatomic, strong) NSMutableArray<LCNLEntry *> *store;
@property (nonatomic, strong) NSLock *lock;
@property (nonatomic) NSInteger counter;
@end

@implementation LCNetLog

+ (instancetype)shared {
    static LCNetLog *one;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ one = [LCNetLog new]; });
    return one;
}

- (instancetype)init {
    if ((self = [super init])) {
        _store = [NSMutableArray array];
        _lock = [NSLock new];
        _filter = @"";
    }
    return self;
}

- (NSArray<LCNLEntry *> *)entries {
    [self.lock lock];
    NSArray *copy = [self.store copy];
    [self.lock unlock];
    return copy;
}

- (void)start { self.recording = YES; }
- (void)stop  { self.recording = NO; }

- (void)clear {
    [self.lock lock];
    [self.store removeAllObjects];
    self.counter = 0;
    [self.lock unlock];
}

- (void)add:(LCNLEntry *)entry {
    if (!self.recording) return;
    if (self.filter.length && [entry.url rangeOfString:self.filter
                                               options:NSCaseInsensitiveSearch].location == NSNotFound) return;
    [self.lock lock];
    entry.index = ++self.counter;
    [self.store addObject:entry];
    // 古いものから捨てる。長く付けたままでも記憶を使い切らない
    while (self.store.count > kEntryLimit) [self.store removeObjectAtIndex:0];
    [self.lock unlock];
}

- (NSString *)dump {
    NSMutableString *s = [NSMutableString string];
    [s appendFormat:@"app: %@\n", NSBundle.mainBundle.bundleIdentifier];
    [s appendFormat:@"filter: %@\n\n", self.filter.length ? self.filter : @"(なし)"];
    for (LCNLEntry *e in self.entries) {
        [s appendString:e.fullText];
        [s appendString:@"\n========================================\n\n"];
    }
    return s;
}
@end

#pragma mark - 捕まえる

// NSURLSession は完了処理を渡す形と、デリゲートに返す形の両方で使われる。ここでは前者を
// 差し替える。後者は下の NSURLSessionTask 側で拾う。
//
// 要求の本文は NSURLRequest から読めないことがある。HTTPBodyStream で渡されていると
// HTTPBody は nil になるので、そのときは読み直す。
static NSData *LCNLRequestBody(NSURLRequest *request) {
    if (request.HTTPBody.length) return request.HTTPBody;
    NSInputStream *stream = request.HTTPBodyStream;
    if (!stream) return nil;

    NSMutableData *body = [NSMutableData data];
    [stream open];
    uint8_t buffer[4096];
    while ([stream hasBytesAvailable] && body.length < kBodyLimit) {
        NSInteger read = [stream read:buffer maxLength:sizeof(buffer)];
        if (read <= 0) break;
        [body appendBytes:buffer length:read];
    }
    [stream close];
    return body.length ? body : nil;
}

static void LCNLRecord(NSURLRequest *request, NSURLResponse *response, NSData *data, NSTimeInterval started) {
    LCNetLog *log = LCNetLog.shared;
    if (!log.recording) return;

    LCNLEntry *entry = [LCNLEntry new];
    entry.at = [NSDate date];
    entry.method = request.HTTPMethod;
    entry.url = request.URL.absoluteString;
    entry.requestHeaders = request.allHTTPHeaderFields;
    NSData *body = LCNLRequestBody(request);
    entry.requestBody = body.length > kBodyLimit ? [body subdataWithRange:NSMakeRange(0, kBodyLimit)] : body;

    if ([response isKindOfClass:NSHTTPURLResponse.class]) {
        NSHTTPURLResponse *http = (NSHTTPURLResponse *)response;
        entry.statusCode = http.statusCode;
        entry.responseHeaders = http.allHeaderFields;
    }
    entry.responseBody = data.length > kBodyLimit ? [data subdataWithRange:NSMakeRange(0, kBodyLimit)] : data;
    entry.elapsedMs = (long long)((NSDate.timeIntervalSinceReferenceDate - started) * 1000);
    [log add:entry];
}

%group NetLog

%hook NSURLSession

// Logos は %orig(...) の中に波括弧つきのブロックを直接書くと括弧を数え間違える。
// ブロックは変数に入れてから渡す。
- (NSURLSessionDataTask *)dataTaskWithRequest:(NSURLRequest *)request
                            completionHandler:(void (^)(NSData *, NSURLResponse *, NSError *))handler {
    if (!handler || !LCNetLog.shared.recording) return %orig;
    NSTimeInterval started = NSDate.timeIntervalSinceReferenceDate;
    void (^wrapped)(NSData *, NSURLResponse *, NSError *) =
        ^(NSData *data, NSURLResponse *response, NSError *error) {
            LCNLRecord(request, response, data, started);
            handler(data, response, error);
        };
    return %orig(request, wrapped);
}

- (NSURLSessionDataTask *)dataTaskWithURL:(NSURL *)url
                        completionHandler:(void (^)(NSData *, NSURLResponse *, NSError *))handler {
    if (!handler || !LCNetLog.shared.recording) return %orig;
    NSURLRequest *request = [NSURLRequest requestWithURL:url];
    NSTimeInterval started = NSDate.timeIntervalSinceReferenceDate;
    void (^wrapped)(NSData *, NSURLResponse *, NSError *) =
        ^(NSData *data, NSURLResponse *response, NSError *error) {
            LCNLRecord(request, response, data, started);
            handler(data, response, error);
        };
    return %orig(url, wrapped);
}

- (NSURLSessionUploadTask *)uploadTaskWithRequest:(NSURLRequest *)request
                                         fromData:(NSData *)bodyData
                                completionHandler:(void (^)(NSData *, NSURLResponse *, NSError *))handler {
    if (!handler || !LCNetLog.shared.recording) return %orig;
    NSTimeInterval started = NSDate.timeIntervalSinceReferenceDate;
    NSMutableURLRequest *withBody = [request mutableCopy];
    if (!withBody.HTTPBody.length) withBody.HTTPBody = bodyData;
    void (^wrapped)(NSData *, NSURLResponse *, NSError *) =
        ^(NSData *data, NSURLResponse *response, NSError *error) {
            LCNLRecord(withBody, response, data, started);
            handler(data, response, error);
        };
    return %orig(request, bodyData, wrapped);
}

%end

// 完了処理を渡さず、デリゲートで受け取る形。要求だけでも残しておくと、どこへ何を送ったかは分かる。

%hook NSURLSessionTask

- (void)resume {
    %orig;
    LCNetLog *log = LCNetLog.shared;
    if (!log.recording) return;
    if (objc_getAssociatedObject(self, _cmd)) return;   // 再開のたびに増やさない
    objc_setAssociatedObject(self, _cmd, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);

    // 完了処理つきの経路は上で記録済み。そちらは NSURLSessionDataTask なので、
    // WebSocket とダウンロードだけをここで拾う
    if (![self isKindOfClass:NSClassFromString(@"__NSURLSessionWebSocketTask")] &&
        ![self isKindOfClass:NSURLSessionDownloadTask.class] &&
        ![self isKindOfClass:NSURLSessionStreamTask.class]) return;

    NSURLRequest *request = self.originalRequest;
    if (!request) return;
    LCNLEntry *entry = [LCNLEntry new];
    entry.at = [NSDate date];
    entry.method = [NSString stringWithFormat:@"%@(%@)",
                    request.HTTPMethod ?: @"?", NSStringFromClass([self class])];
    entry.url = request.URL.absoluteString;
    entry.requestHeaders = request.allHTTPHeaderFields;
    entry.requestBody = LCNLRequestBody(request);
    [log add:entry];
}

%end

%end  // group NetLog

void LCNetLogInstallHooks(void) {
    %init(NetLog);
}
