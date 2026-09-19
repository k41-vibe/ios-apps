// LiveContainer 自身に読み込ませて、tweak の dylib を配布サーバーから直接入れられるようにする。
//
// これまでは dylib を Safari で保存し、ファイル App で調整フォルダを開いて置き換えていた。
// LiveContainer には既にアプリ用のソース機能(LCAltStoreSourcesView)があるが、AltStore の
// ソース形式に tweak という概念が無いので、tweak だけがその仕組みに乗れていない。
//
// ここでやるのは 3 つ。
//   1. source.json の tweaks を読む(こちらで足した独自の項目)
//   2. 端末に置いてある dylib の sha256 と比べて、未導入・古い・最新を判定する
//   3. 押されたら取得して調整フォルダに置き、LiveContainer 本体の LCPatchAddRPath を通す
//
// 3 の rpath 補正が要るのは、LiveContainer が取り込み時に足している 2 本を自分でも足さないと
// @rpath/CydiaSubstrate.framework/CydiaSubstrate が解決できないため。関数は LiveContainerShared が
// 外部シンボルとして持っているので dlsym で取る(実機 3.8.0 で _LCPatchAddRPath を確認)。
// 署名は起動時に LCUtils.signTweaks が拾うので、こちらでは何もしない。

#import "LCTweakStore.h"
#import <CommonCrypto/CommonDigest.h>
#import <dlfcn.h>
#import <mach-o/loader.h>

// LAN を先に試す。Tailscale は LocalDevVPN と同時に使えず(iOS は VPN 構成を 1 つしか
// 有効にできない)、自宅では切れていることが多い。名前解決の失敗を待つと数秒無駄になる。
static NSString *const kSourceURLLAN = @"http://192.168.10.113:8788/source.json";
static NSString *const kSourceURL = @"https://node.tail1f41c8.ts.net:8789/source.json";

@implementation LCTSItem
@end

NSString *LCTSTweaksRoot(void) {
    NSArray *docs = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
    return [docs.firstObject stringByAppendingPathComponent:@"Tweaks"];
}

static NSString *LCTSDigest(NSData *data) {
    if (!data) return nil;
    unsigned char out[CC_SHA256_DIGEST_LENGTH];
    CC_SHA256(data.bytes, (CC_LONG)data.length, out);
    NSMutableString *s = [NSMutableString stringWithCapacity:CC_SHA256_DIGEST_LENGTH * 2];
    for (int i = 0; i < CC_SHA256_DIGEST_LENGTH; i++) [s appendFormat:@"%02x", out[i]];
    return s;
}

// LiveContainer が取り込み時にやっているのと同じ補正。
// LCParseMachO(path, false, ^(path, header, ...){ LCPatchAddRPath(path, header); })
static BOOL LCTSPatchRPath(NSString *path, NSString **error) {
    typedef void (*ParseFn)(const char *path, bool readOnly, void (^cb)(const char *, struct mach_header_64 *, void *, void *));
    typedef void (*PatchFn)(const char *path, struct mach_header_64 *header);

    ParseFn parse = (ParseFn)dlsym(RTLD_DEFAULT, "LCParseMachO");
    PatchFn patch = (PatchFn)dlsym(RTLD_DEFAULT, "LCPatchAddRPath");
    if (!parse || !patch) {
        *error = @"LiveContainer の LCParseMachO / LCPatchAddRPath が見つかりません。"
                 @"「Load Tweaks to LiveContainer Itself」が有効か確認してください";
        return NO;
    }
    __block BOOL touched = NO;
    parse(path.UTF8String, false, ^(const char *p, struct mach_header_64 *header, void *a, void *b) {
        patch(p, header);
        touched = YES;
    });
    if (!touched) *error = @"Mach-O として読めませんでした";
    return touched;
}

// 置いた dylib に署名する。
//
// ゲストアプリ向けの tweak なら、対象アプリを起動するときに LiveContainer が署名するので
// 何もしなくてよい。LCTweakStore 自身は LiveContainer の起動時に読まれるため、署名より先に
// 読み込みが来る。そのままだと次の起動で code signature invalid になり、何も読まれない。
//
// LiveContainer と同じ ZSigner を使う。ZSign.dylib は LiveContainer 起動時には読まれて
// いないので自分で dlopen する(LCUtils.loadStoreFrameworksWithError2 と同じ経路)。
// ZSigner の型。LiveContainer の中にあるクラスなので、こちらで宣言して直接呼ぶ
@interface ZSigner : NSObject
+ (NSProgress *)signMachOPathArr:(NSArray *)paths
                        bundleId:(NSString *)bundleId
                            cert:(NSData *)cert
                            pass:(NSString *)pass
               completionHandler:(void (^)(BOOL success, NSError *error))handler;
@end

@interface LCSharedUtils : NSObject
+ (NSString *)appGroupID;
+ (NSString *)certificatePassword;
@end

static BOOL LCTSSign(NSString *path, NSString **error) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        dlopen("@executable_path/Frameworks/ZSign.dylib", RTLD_GLOBAL);
    });

    Class signer = NSClassFromString(@"ZSigner");
    Class shared = NSClassFromString(@"LCSharedUtils");
    if (!signer || !shared) { *error = @"ZSigner が読めない"; return NO; }

    NSUserDefaults *group = [[NSUserDefaults alloc] initWithSuiteName:[shared appGroupID]];
    NSData *cert = [group objectForKey:@"LCCertificateData"]
                 ?: [NSUserDefaults.standardUserDefaults objectForKey:@"LCCertificateData"];
    NSString *pass = [shared certificatePassword];
    if (!cert || !pass) { *error = @"証明書が無い"; return NO; }

    // 署名は非同期で返るので終わるまで待つ。押したあとすぐ使える状態にしたい
    __block BOOL ok = NO;
    __block NSString *failure = nil;
    dispatch_semaphore_t done = dispatch_semaphore_create(0);
    [signer signMachOPathArr:@[path]
                    bundleId:NSBundle.mainBundle.bundleIdentifier
                        cert:cert
                        pass:pass
           completionHandler:^(BOOL success, NSError *err) {
        ok = success;
        failure = err.localizedDescription;
        dispatch_semaphore_signal(done);
    }];

    if (dispatch_semaphore_wait(done, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(120 * NSEC_PER_SEC))) != 0) {
        *error = @"署名が終わらない";
        return NO;
    }
    if (!ok) *error = failure ?: @"署名に失敗";
    return ok;
}


#pragma mark - 一覧

@interface LCTweakStoreViewController () <UITableViewDataSource, UITableViewDelegate>
@property (nonatomic, strong) UITableView *table;
@property (nonatomic, strong) UILabel *status;
@property (nonatomic, strong) NSArray<LCTSItem *> *items;
@property (nonatomic, strong) NSArray<NSString *> *strays;
@property (nonatomic, strong) NSURLSession *session;
@end

@implementation LCTweakStoreViewController

+ (void)presentFrom:(UIWindow *)window {
    UIViewController *top = window.rootViewController;
    while (top.presentedViewController) top = top.presentedViewController;
    if ([top isKindOfClass:[UINavigationController class]] &&
        [[(UINavigationController *)top viewControllers].firstObject isKindOfClass:[LCTweakStoreViewController class]]) {
        return; // すでに開いている
    }
    LCTweakStoreViewController *vc = [LCTweakStoreViewController new];
    UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:vc];
    [top presentViewController:nav animated:YES completion:nil];
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"tweak の取り込み";
    self.view.backgroundColor = UIColor.systemBackgroundColor;
    self.navigationItem.leftBarButtonItem =
        [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemClose
                                                      target:self action:@selector(close)];
    self.navigationItem.rightBarButtonItem =
        [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemRefresh
                                                      target:self action:@selector(reload)];

    self.table = [[UITableView alloc] initWithFrame:self.view.bounds style:UITableViewStyleInsetGrouped];
    self.table.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    self.table.dataSource = self;
    self.table.delegate = self;
    [self.view addSubview:self.table];

    self.status = [[UILabel alloc] init];
    self.status.numberOfLines = 0;
    self.status.textAlignment = NSTextAlignmentCenter;
    self.status.font = [UIFont preferredFontForTextStyle:UIFontTextStyleFootnote];
    self.status.textColor = UIColor.secondaryLabelColor;
    self.table.tableFooterView = self.status;

    NSURLSessionConfiguration *config = [NSURLSessionConfiguration ephemeralSessionConfiguration];
    config.timeoutIntervalForRequest = 10;
    config.timeoutIntervalForResource = 600;
    self.session = [NSURLSession sessionWithConfiguration:config];

    [self reload];
}

- (void)close { [self dismissViewControllerAnimated:YES completion:nil]; }

- (void)setStatusText:(NSString *)text {
    dispatch_async(dispatch_get_main_queue(), ^{
        self.status.text = text;
        [self.status sizeToFit];
        CGRect f = self.status.frame;
        f.size.width = self.table.bounds.size.width;
        f.size.height = MAX(f.size.height + 24, 44);
        self.status.frame = f;
        self.table.tableFooterView = self.status;
    });
}

#pragma mark - 取得

- (void)reload {
    [self setStatusText:@"配布サーバーを見ています"];
    // Tailscale と LAN の両方を順に試す。片方しか届かない状況があるため
    [self fetchSourceFrom:@[kSourceURLLAN, kSourceURL] index:0];
}

- (void)fetchSourceFrom:(NSArray<NSString *> *)urls index:(NSUInteger)index {
    if (index >= urls.count) {
        [self setStatusText:@"配布サーバーに届きません。\nTailscale か同じ Wi-Fi に繋がっているか、"
                            @"PC で tools/serve-ipa.py が動いているか確認してください"];
        return;
    }
    NSURL *url = [NSURL URLWithString:urls[index]];
    [[self.session dataTaskWithURL:url completionHandler:^(NSData *data, NSURLResponse *resp, NSError *error) {
        NSInteger code = [(NSHTTPURLResponse *)resp statusCode];
        if (error || code != 200 || data.length == 0) {
            [self setStatusText:[NSString stringWithFormat:@"%@ に届きません(%@)。次を試します",
                                 url.host, error.localizedDescription ?: [NSString stringWithFormat:@"HTTP %ld", (long)code]]];
            [self fetchSourceFrom:urls index:index + 1];
            return;
        }
        NSDictionary *root = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
        NSArray *raw = root[@"tweaks"];
        if (![raw isKindOfClass:[NSArray class]]) {
            [self setStatusText:@"source.json に tweaks がありません"];
            return;
        }
        NSMutableArray<LCTSItem *> *items = [NSMutableArray array];
        for (NSDictionary *d in raw) {
            if (![d isKindOfClass:[NSDictionary class]]) continue;
            LCTSItem *item = [LCTSItem new];
            item.name = d[@"name"] ?: @"(名前なし)";
            item.file = d[@"file"];
            item.folder = d[@"folder"];
            item.appName = d[@"app"] ?: @"";
            item.detail = d[@"localizedDescription"] ?: @"";
            item.sha256 = d[@"sha256"];
            item.build = d[@"build"] ?: @"";
            item.size = [d[@"size"] longLongValue];
            NSString *dl = d[@"downloadURL"];
            item.downloadURL = dl ? [NSURL URLWithString:dl] : nil;
            if (!item.file || !item.folder || !item.downloadURL) continue;  // 不完全な行は出さない
            [self refreshState:item];
            [items addObject:item];
        }
        self.items = items;
        self.strays = [self findStrays:items];
        dispatch_async(dispatch_get_main_queue(), ^{ [self.table reloadData]; });
        [self setStatusText:[NSString stringWithFormat:@"%@ から %lu 件\n置き先: %@",
                             url.host, (unsigned long)items.count, LCTSTweaksRoot()]];
    }] resume];
}

/// 端末に置いてあるものと比べる
- (void)refreshState:(LCTSItem *)item {
    NSString *path = [[LCTSTweaksRoot() stringByAppendingPathComponent:item.folder]
                      stringByAppendingPathComponent:item.file];
    NSData *local = [NSData dataWithContentsOfFile:path];
    if (!local) { item.state = LCTSStateMissing; item.localBuild = nil; return; }
    NSString *digest = LCTSDigest(local);
    item.localBuild = [digest substringToIndex:MIN(12u, digest.length)];
    // rpath を足したあとなので、配布物とは中身が変わっている。だから sha256 の一致では判定できない。
    // 入れたときの配布側 sha256 を覚えておき、それと比べる。
    NSString *marked = [self recordedSourceDigestFor:item];
    item.state = (marked && [marked isEqualToString:item.sha256]) ? LCTSStateCurrent : LCTSStateOutdated;
}

- (NSString *)recordKey:(LCTSItem *)item {
    return [NSString stringWithFormat:@"LCTS.%@.%@", item.folder, item.file];
}
- (NSString *)recordedSourceDigestFor:(LCTSItem *)item {
    return [[NSUserDefaults standardUserDefaults] stringForKey:[self recordKey:item]];
}
- (void)recordSourceDigestFor:(LCTSItem *)item {
    [[NSUserDefaults standardUserDefaults] setObject:item.sha256 forKey:[self recordKey:item]];
}

/// 配布に載っていない dylib を Tweaks の下から拾う。
///
/// 過去に SCInsta-v8.dylib のような版番号つきの名前で置いたものが残っていると、LiveContainer は
/// フォルダ内の dylib を全部読み込むので古い方も動く。名前が違うので置き換えでは消えない。
- (NSArray<NSString *> *)findStrays:(NSArray<LCTSItem *> *)items {
    NSMutableSet *known = [NSMutableSet set];
    for (LCTSItem *item in items) {
        [known addObject:[item.folder.length ? [item.folder stringByAppendingPathComponent:item.file] : item.file
                          lowercaseString]];
    }
    NSString *root = LCTSTweaksRoot();
    NSMutableArray *out = [NSMutableArray array];
    NSDirectoryEnumerator *walk = [NSFileManager.defaultManager enumeratorAtPath:root];
    for (NSString *rel in walk) {
        NSString *name = rel.lastPathComponent;
        if (![name.pathExtension isEqualToString:@"dylib"]) continue;
        if ([name isEqualToString:@"TweakLoader.dylib"]) continue;   // LiveContainer のもの
        if ([known containsObject:rel.lowercaseString]) continue;
        [out addObject:rel];
    }
    return [out sortedArrayUsingSelector:@selector(compare:)];
}

#pragma mark - 取り込み

- (void)install:(LCTSItem *)item {
    [self setStatusText:[NSString stringWithFormat:@"%@ を取得中 (%lld KB)", item.name, item.size / 1024]];
    [[self.session dataTaskWithURL:item.downloadURL completionHandler:^(NSData *data, NSURLResponse *resp, NSError *error) {
        NSInteger code = [(NSHTTPURLResponse *)resp statusCode];
        if (error) { [self failed:item reason:error.localizedDescription]; return; }
        if (code != 200) { [self failed:item reason:[NSString stringWithFormat:@"HTTP %ld", (long)code]]; return; }

        // 配布側が言っている中身と一致するか。途中で切れたものを置かないための確認
        NSString *digest = LCTSDigest(data);
        if (item.sha256.length && ![digest isEqualToString:item.sha256]) {
            [self failed:item reason:@"取得した中身が配布側と一致しません"];
            return;
        }
        [self writeAndPatch:item data:data];
    }] resume];
}

- (void)writeAndPatch:(LCTSItem *)item data:(NSData *)data {
    NSFileManager *fm = NSFileManager.defaultManager;
    NSString *dir = [LCTSTweaksRoot() stringByAppendingPathComponent:item.folder];
    NSError *error = nil;
    if (![fm fileExistsAtPath:dir]) {
        if (![fm createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:&error]) {
            [self failed:item reason:error.localizedDescription]; return;
        }
    }
    NSString *dest = [dir stringByAppendingPathComponent:item.file];
    // 同じフォルダに一度書いてから置き換える。途中で失敗しても動いている dylib を壊さない
    NSString *staging = [dest stringByAppendingString:@".incoming"];
    if (![data writeToFile:staging options:NSDataWritingAtomic error:&error]) {
        [self failed:item reason:error.localizedDescription]; return;
    }

    NSString *patchError = nil;
    if (!LCTSPatchRPath(staging, &patchError)) {
        [fm removeItemAtPath:staging error:nil];
        [self failed:item reason:patchError]; return;
    }

    // 消してから移す形だと、読み込み中で消せなかったときに移動が「同じ名前がある」で失敗する。
    // replaceItemAtURL は置き換えを 1 回で行うので、その隙間が無い(実機 2026-09-19)。
    if (![fm fileExistsAtPath:dest]) {
        if (![fm moveItemAtPath:staging toPath:dest error:&error]) {
            [self failed:item reason:error.localizedDescription]; return;
        }
    } else if (![fm replaceItemAtURL:[NSURL fileURLWithPath:dest]
                       withItemAtURL:[NSURL fileURLWithPath:staging]
                      backupItemName:nil
                             options:0
                    resultingItemURL:nil
                               error:&error]) {
        [fm removeItemAtPath:staging error:nil];
        [self failed:item reason:error.localizedDescription]; return;
    }

    NSString *signError = nil;
    if (!LCTSSign(dest, &signError)) {
        [self setStatusText:[NSString stringWithFormat:@"%@ 配置済み。署名は手動で (%@)", item.name, signError]];
    }

    [self recordSourceDigestFor:item];
    [self refreshState:item];
    dispatch_async(dispatch_get_main_queue(), ^{ [self.table reloadData]; });
    [self setStatusText:[NSString stringWithFormat:
        @"%@ を %@/ に置きました (%@)\n対象のアプリを開き直すと反映されます。"
        @"初回の起動は署名のぶん時間がかかります", item.name, item.folder, item.build]];
}

- (void)failed:(LCTSItem *)item reason:(NSString *)reason {
    [self setStatusText:[NSString stringWithFormat:@"%@ の取り込みに失敗: %@", item.name, reason ?: @"(理由不明)"]];
}

#pragma mark - 表

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
    return self.strays.count ? 2 : 1;
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    return section == 0 ? nil : @"配布にないファイル";
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return section == 0 ? self.items.count : self.strays.count;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"c"];
    if (!cell) cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:@"c"];

    // 端末に残っている、配布に載っていないファイル。過去に版番号つきの名前で置いたものが該当する
    if (indexPath.section == 1) {
        NSString *rel = self.strays[indexPath.row];
        cell.textLabel.text = rel.lastPathComponent;
        cell.detailTextLabel.text = rel.stringByDeletingLastPathComponent;
        UILabel *badge = [[UILabel alloc] init];
        badge.text = @"削除";
        badge.textColor = UIColor.systemRedColor;
        badge.font = [UIFont preferredFontForTextStyle:UIFontTextStyleFootnote];
        [badge sizeToFit];
        cell.accessoryView = badge;
        return cell;
    }

    LCTSItem *item = self.items[indexPath.row];

    NSString *mark;
    UIColor *color;
    switch (item.state) {
        case LCTSStateMissing:  mark = @"入れる"; color = UIColor.systemBlueColor;     break;
        case LCTSStateOutdated: mark = @"更新";   color = UIColor.systemOrangeColor;   break;
        default:                mark = @"";       color = UIColor.secondaryLabelColor; break;
    }
    cell.textLabel.text = item.name;
    cell.detailTextLabel.text = item.appName.length ? item.appName : item.folder;

    // 状態は右端に出す。行の文字数を増やさない
    if (mark.length) {
        UILabel *badge = [[UILabel alloc] init];
        badge.text = mark;
        badge.textColor = color;
        badge.font = [UIFont preferredFontForTextStyle:UIFontTextStyleFootnote];
        [badge sizeToFit];
        cell.accessoryView = badge;
    } else {
        cell.accessoryView = nil;
    }

    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];

    if (indexPath.section == 1) {
        NSString *rel = self.strays[indexPath.row];
        UIAlertController *alert = [UIAlertController
            alertControllerWithTitle:rel.lastPathComponent
                             message:@"削除する"
                      preferredStyle:UIAlertControllerStyleAlert];
        [alert addAction:[UIAlertAction actionWithTitle:@"削除" style:UIAlertActionStyleDestructive
                                                handler:^(UIAlertAction *a) {
            NSString *full = [LCTSTweaksRoot() stringByAppendingPathComponent:rel];
            NSError *err = nil;
            if ([NSFileManager.defaultManager removeItemAtPath:full error:&err]) {
                [self setStatusText:[NSString stringWithFormat:@"%@ 削除", rel.lastPathComponent]];
                [self reload];
            } else {
                [self setStatusText:err.localizedDescription];
            }
        }]];
        [alert addAction:[UIAlertAction actionWithTitle:@"キャンセル" style:UIAlertActionStyleCancel handler:nil]];
        [self presentViewController:alert animated:YES completion:nil];
        return;
    }

    LCTSItem *item = self.items[indexPath.row];
    NSString *title = (item.state == LCTSStateCurrent) ? @"入れ直しますか" : @"入れますか";
    UIAlertController *alert = [UIAlertController
        alertControllerWithTitle:title
                         message:[NSString stringWithFormat:@"%@\n\n%@\n%@/ に %@ として置きます",
                                  item.name, item.detail, item.folder, item.file]
                  preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"入れる" style:UIAlertActionStyleDefault
                                            handler:^(UIAlertAction *a) { [self install:item]; }]];
    [alert addAction:[UIAlertAction actionWithTitle:@"やめる" style:UIAlertActionStyleCancel handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}

@end
