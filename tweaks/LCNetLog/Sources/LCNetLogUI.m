// 記録を見る画面。LCTweakStore と同じ作りにしてある。
//
// 一覧から 1 件選ぶと全文が出る。全件は配布サーバーへ送れる(serve-ipa.py の /upload/ が
// dist/reports/ に時刻つきで保存する)ので、PC 側で読める。

#import "LCNetLog.h"

static NSString *const kUploadLAN = @"http://192.168.10.113:8788/upload/";
static NSString *const kUploadTS  = @"https://node.tail1f41c8.ts.net:8789/upload/";

#pragma mark - 詳細

@interface LCNLDetailViewController : UIViewController
@property (nonatomic, strong) LCNLEntry *entry;
@end

@implementation LCNLDetailViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = self.entry.method;
    self.view.backgroundColor = UIColor.systemBackgroundColor;
    self.navigationItem.rightBarButtonItem =
        [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemAction
                                                      target:self action:@selector(copyAll)];

    UITextView *text = [[UITextView alloc] initWithFrame:self.view.bounds];
    text.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    text.editable = NO;
    text.font = [UIFont monospacedSystemFontOfSize:11 weight:UIFontWeightRegular];
    text.text = self.entry.fullText;
    [self.view addSubview:text];
}

- (void)copyAll {
    UIPasteboard.generalPasteboard.string = self.entry.fullText;
    self.title = @"コピー済み";
}
@end

#pragma mark - 一覧

@interface LCNetLogViewController () <UITableViewDataSource, UITableViewDelegate, UISearchBarDelegate>
@property (nonatomic, strong) UITableView *table;
@property (nonatomic, strong) UILabel *status;
@property (nonatomic, strong) NSArray<LCNLEntry *> *rows;
@property (nonatomic, strong) NSTimer *tick;
@end

@implementation LCNetLogViewController

+ (void)presentFrom:(UIWindow *)window {
    UIViewController *top = window.rootViewController;
    while (top.presentedViewController) top = top.presentedViewController;
    if ([top isKindOfClass:UINavigationController.class] &&
        [[(UINavigationController *)top viewControllers].firstObject isKindOfClass:self]) return;

    LCNetLogViewController *vc = [LCNetLogViewController new];
    UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:vc];
    [top presentViewController:nav animated:YES completion:nil];
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"通信";
    self.view.backgroundColor = UIColor.systemBackgroundColor;
    self.navigationItem.leftBarButtonItem =
        [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemClose
                                                      target:self action:@selector(close)];
    [self updateRightButtons];

    UISearchBar *search = [[UISearchBar alloc] init];
    search.placeholder = @"URL で絞る";
    search.delegate = self;
    search.text = LCNetLog.shared.filter;
    [search sizeToFit];

    self.table = [[UITableView alloc] initWithFrame:self.view.bounds style:UITableViewStylePlain];
    self.table.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    self.table.dataSource = self;
    self.table.delegate = self;
    self.table.tableHeaderView = search;
    [self.view addSubview:self.table];

    self.status = [[UILabel alloc] init];
    self.status.font = [UIFont preferredFontForTextStyle:UIFontTextStyleFootnote];
    self.status.textColor = UIColor.secondaryLabelColor;
    self.status.textAlignment = NSTextAlignmentCenter;
    self.status.frame = CGRectMake(0, 0, self.view.bounds.size.width, 44);
    self.table.tableFooterView = self.status;

    [self refresh];
    // 記録しながら見られるように、定期的に読み直す
    self.tick = [NSTimer scheduledTimerWithTimeInterval:1.0 target:self
                                               selector:@selector(refresh) userInfo:nil repeats:YES];
}

- (void)viewDidDisappear:(BOOL)animated {
    [super viewDidDisappear:animated];
    [self.tick invalidate];
    self.tick = nil;
}

- (void)close { [self dismissViewControllerAnimated:YES completion:nil]; }

- (void)updateRightButtons {
    LCNetLog *log = LCNetLog.shared;
    UIBarButtonItem *toggle =
        [[UIBarButtonItem alloc] initWithTitle:log.recording ? @"停止" : @"記録"
                                          style:UIBarButtonItemStylePlain
                                         target:self action:@selector(toggle)];
    toggle.tintColor = log.recording ? UIColor.systemRedColor : UIColor.systemBlueColor;
    UIBarButtonItem *more =
        [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemAction
                                                      target:self action:@selector(showMore)];
    self.navigationItem.rightBarButtonItems = @[more, toggle];
}

- (void)toggle {
    LCNetLog *log = LCNetLog.shared;
    log.recording ? [log stop] : [log start];
    [self updateRightButtons];
    [self refresh];
}

- (void)showMore {
    UIAlertController *sheet = [UIAlertController alertControllerWithTitle:nil message:nil
                                                            preferredStyle:UIAlertControllerStyleActionSheet];
    [sheet addAction:[UIAlertAction actionWithTitle:@"PC へ送る" style:UIAlertActionStyleDefault
                                            handler:^(UIAlertAction *a) { [self upload]; }]];
    [sheet addAction:[UIAlertAction actionWithTitle:@"全部コピー" style:UIAlertActionStyleDefault
                                            handler:^(UIAlertAction *a) {
        UIPasteboard.generalPasteboard.string = LCNetLog.shared.dump;
        self.status.text = @"コピー済み";
    }]];
    [sheet addAction:[UIAlertAction actionWithTitle:@"消去" style:UIAlertActionStyleDestructive
                                            handler:^(UIAlertAction *a) {
        [LCNetLog.shared clear];
        [self refresh];
    }]];
    [sheet addAction:[UIAlertAction actionWithTitle:@"キャンセル" style:UIAlertActionStyleCancel handler:nil]];
    sheet.popoverPresentationController.barButtonItem = self.navigationItem.rightBarButtonItems.firstObject;
    [self presentViewController:sheet animated:YES completion:nil];
}

/// 配布サーバーへ送る。LAN を先に試し、駄目なら Tailscale。
/// 自分の送信まで記録すると際限が無いので、その間だけ止める。
- (void)upload {
    LCNetLog *log = LCNetLog.shared;
    BOOL wasRecording = log.recording;
    [log stop];

    NSData *body = [log.dump dataUsingEncoding:NSUTF8StringEncoding];
    NSString *name = [NSString stringWithFormat:@"netlog-%@.txt",
                      NSBundle.mainBundle.bundleIdentifier ?: @"app"];
    [self uploadTo:@[kUploadLAN, kUploadTS] index:0 name:name body:body restore:wasRecording];
}

- (void)uploadTo:(NSArray<NSString *> *)bases index:(NSUInteger)index
            name:(NSString *)name body:(NSData *)body restore:(BOOL)restore {
    if (index >= bases.count) {
        self.status.text = @"PC に届きません";
        if (restore) [LCNetLog.shared start];
        return;
    }
    NSURL *url = [NSURL URLWithString:[bases[index] stringByAppendingString:name]];
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url];
    request.HTTPMethod = @"POST";
    request.timeoutInterval = 30;
    [request setValue:@"text/plain; charset=utf-8" forHTTPHeaderField:@"Content-Type"];

    self.status.text = [NSString stringWithFormat:@"送信中 %lu KB", (unsigned long)(body.length / 1024)];
    NSURLSession *session = [NSURLSession sessionWithConfiguration:
                             NSURLSessionConfiguration.ephemeralSessionConfiguration];
    [[session uploadTaskWithRequest:request fromData:body
                  completionHandler:^(NSData *data, NSURLResponse *resp, NSError *error) {
        dispatch_async(dispatch_get_main_queue(), ^{
            if (!error && [(NSHTTPURLResponse *)resp statusCode] == 200) {
                self.status.text = [NSString stringWithFormat:@"PC に届きました (%lu KB)",
                                    (unsigned long)(body.length / 1024)];
                if (restore) [LCNetLog.shared start];
            } else {
                [self uploadTo:bases index:index + 1 name:name body:body restore:restore];
            }
        });
    }] resume];
}

- (void)refresh {
    LCNetLog *log = LCNetLog.shared;
    self.rows = log.entries.reverseObjectEnumerator.allObjects;   // 新しいものを上に
    self.status.text = [NSString stringWithFormat:@"%lu 件 %@",
                        (unsigned long)self.rows.count, log.recording ? @"記録中" : @"停止"];
    [self.table reloadData];
}

#pragma mark 絞り込み

- (void)searchBar:(UISearchBar *)searchBar textDidChange:(NSString *)text {
    LCNetLog.shared.filter = text;
}

- (void)searchBarSearchButtonClicked:(UISearchBar *)searchBar { [searchBar resignFirstResponder]; }

#pragma mark 表

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return self.rows.count;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"c"];
    if (!cell) cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:@"c"];
    LCNLEntry *e = self.rows[indexPath.row];
    cell.textLabel.text = e.oneLine;
    cell.textLabel.font = [UIFont monospacedSystemFontOfSize:12 weight:UIFontWeightRegular];
    cell.detailTextLabel.text = [NSURL URLWithString:e.url ?: @""].host;
    cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    LCNLDetailViewController *vc = [LCNLDetailViewController new];
    vc.entry = self.rows[indexPath.row];
    [self.navigationController pushViewController:vc animated:YES];
}
@end
