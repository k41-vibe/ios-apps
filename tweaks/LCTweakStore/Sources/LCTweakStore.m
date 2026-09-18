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

#pragma mark - 一覧

@interface LCTweakStoreViewController () <UITableViewDataSource, UITableViewDelegate>
@property (nonatomic, strong) UITableView *table;
@property (nonatomic, strong) UILabel *status;
@property (nonatomic, strong) NSArray<LCTSItem *> *items;
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

    [fm removeItemAtPath:dest error:nil];
    if (![fm moveItemAtPath:staging toPath:dest error:&error]) {
        [self failed:item reason:error.localizedDescription]; return;
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

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return self.items.count;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"c"];
    if (!cell) cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:@"c"];
    LCTSItem *item = self.items[indexPath.row];

    NSString *mark;
    UIColor *color;
    switch (item.state) {
        case LCTSStateMissing:  mark = @"未導入";   color = UIColor.systemBlueColor;   break;
        case LCTSStateOutdated: mark = @"更新あり"; color = UIColor.systemOrangeColor; break;
        case LCTSStateCurrent:  mark = @"最新";     color = UIColor.secondaryLabelColor; break;
        default:                mark = @"";        color = UIColor.secondaryLabelColor; break;
    }
    cell.textLabel.text = [NSString stringWithFormat:@"%@  (%@)", item.name, mark];
    cell.textLabel.textColor = color;
    cell.detailTextLabel.numberOfLines = 0;
    cell.detailTextLabel.text = [NSString stringWithFormat:@"%@ 用 / %@ に置く\n配布 %@%@",
                                 item.appName, item.folder, item.build,
                                 item.localBuild ? [NSString stringWithFormat:@" / 端末 %@", item.localBuild] : @""];
    cell.accessoryType = (item.state == LCTSStateCurrent) ? UITableViewCellAccessoryNone
                                                          : UITableViewCellAccessoryDisclosureIndicator;
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
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
