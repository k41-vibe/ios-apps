// Updating a tweak by hand is the slowest part of every fix: save from Safari, open Files,
// find the tweak folder, replace the dylib. This does it from inside the app instead.
//
// It works because of two things LiveContainer does:
//
//   1. A tweak is loaded out of a folder the guest process can also write to -- the dylib
//      finds that folder by asking dladdr where it is itself.
//   2. LCUtils.signTweaks runs at every app launch, walks the tweak folder, and signs any
//      .dylib whose signature does not check out. A file put there by something other than
//      the importer is signed just the same.
//
// So: overwrite our own file, and the next launch picks up the new build. The running
// image is untouched -- the replacement goes in through rename(), which swaps the
// directory entry and leaves the inode this process has mapped alone.
//
// What the importer does that we now have to do ourselves is add the two rpaths that let
// @rpath/CydiaSubstrate.framework/CydiaSubstrate resolve. Those are linked in (see the
// Makefile) so a downloaded dylib needs no patching on the device.
//
// The split between what happens on its own and what does not is deliberate:
//
//   - the check runs by itself, a few seconds after launch, and fetches ONE short text
//     file holding a build id. No code is downloaded and nothing is written.
//   - the dylib is fetched and put in place only after the user taps through an alert
//     naming both builds and the host they came from.
//
// Replacing the binary the next launch will execute is not something to do quietly on
// someone's behalf, however convenient. Saying no once is remembered, so a build the user
// turned down does not ask again.

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <dlfcn.h>
#import <mach-o/loader.h>
#import <stdio.h>
#import <errno.h>

#ifndef LCAU_NAME
#define LCAU_NAME "Tweak"
#endif
#ifndef LCAU_BUILD_ID
#define LCAU_BUILD_ID "unknown"
#endif

// The user's own machine on their tailnet. Not reachable from the internet, and the
// certificate is a real one issued for that name, so no ATS exception is needed.
static NSString *const LCAUHost = @"node.tail1f41c8.ts.net";
static NSString *const LCAUBase = @"https://node.tail1f41c8.ts.net:8789/tweaks/auto/";

static NSString *const LCAUPendingKey  = @"LCAutoUpdatePendingBuild";
static NSString *const LCAUDeclinedKey = @"LCAutoUpdateDeclinedBuild";
static NSString *const LCAUDisabledKey = @"LCAutoUpdateDisabled";

NSString *LCAUCurrentBuild(void) {
    return @LCAU_BUILD_ID;
}

// Set once an update has been written, so the settings screen can say that a relaunch is
// all that is left.
NSString *LCAUPendingBuild(void) {
    return [[NSUserDefaults standardUserDefaults] stringForKey:LCAUPendingKey];
}

BOOL LCAUChecksDisabled(void) {
    return [[NSUserDefaults standardUserDefaults] boolForKey:LCAUDisabledKey];
}

void LCAUSetChecksDisabled(BOOL disabled) {
    [[NSUserDefaults standardUserDefaults] setBool:disabled forKey:LCAUDisabledKey];
}

// Where this dylib lives. The tweak folder is writable by us because the guest app runs
// inside LiveContainer's own sandbox.
static NSString *LCAUSelfPath(void) {
    Dl_info info;
    if (!dladdr((const void *)&LCAUSelfPath, &info) || !info.dli_fname) return nil;
    return [NSString stringWithUTF8String:info.dli_fname];
}

// A 404 body or a captive-portal page is still a pile of bytes. Only something that starts
// like a Mach-O is allowed to replace a working dylib.
static BOOL LCAULooksLikeDylib(NSData *data) {
    if (data.length < sizeof(struct mach_header_64)) return NO;
    uint32_t magic = 0;
    [data getBytes:&magic length:sizeof(magic)];
    return magic == MH_MAGIC_64 || magic == MH_CIGAM_64 || magic == FAT_MAGIC || magic == FAT_CIGAM;
}

static UIViewController *LCAUTopViewController(void) {
    UIWindow *keyWindow = nil;
    for (UIWindow *window in UIApplication.sharedApplication.windows) {
        if (window.isKeyWindow) { keyWindow = window; break; }
    }
    UIViewController *top = keyWindow.rootViewController;
    while (top.presentedViewController) top = top.presentedViewController;
    return top;
}

static void LCAUTell(NSString *title, NSString *message) {
    dispatch_async(dispatch_get_main_queue(), ^{
        UIViewController *top = LCAUTopViewController();
        if (!top) return;
        UIAlertController *alert = [UIAlertController alertControllerWithTitle:title
                                                                      message:message
                                                               preferredStyle:UIAlertControllerStyleAlert];
        [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
        [top presentViewController:alert animated:YES completion:nil];
    });
}

static void LCAUAsk(NSString *title, NSString *message, NSString *confirmTitle,
                    void (^confirm)(void), void (^decline)(void)) {
    dispatch_async(dispatch_get_main_queue(), ^{
        UIViewController *top = LCAUTopViewController();
        if (!top) return;
        UIAlertController *alert = [UIAlertController alertControllerWithTitle:title
                                                                      message:message
                                                               preferredStyle:UIAlertControllerStyleAlert];
        [alert addAction:[UIAlertAction actionWithTitle:confirmTitle style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
            if (confirm) confirm();
        }]];
        [alert addAction:[UIAlertAction actionWithTitle:@"あとで" style:UIAlertActionStyleCancel handler:^(UIAlertAction *a) {
            if (decline) decline();
        }]];
        [top presentViewController:alert animated:YES completion:nil];
    });
}

static void LCAUWrite(NSData *data, NSString *remoteBuild) {
    NSString *selfPath = LCAUSelfPath();
    if (!selfPath) {
        LCAUTell(@"更新できません", @"自分の .dylib の場所が分かりませんでした。");
        return;
    }

    // Written next to the dylib rather than in a temp directory, so the rename below stays
    // within one filesystem and is therefore atomic.
    NSString *staging = [selfPath stringByAppendingString:@".incoming"];
    NSError *error = nil;
    if (![data writeToFile:staging options:NSDataWritingAtomic error:&error]) {
        LCAUTell(@"更新できません", error.localizedDescription ?: @"書き込みに失敗しました。");
        return;
    }

    if (rename(staging.fileSystemRepresentation, selfPath.fileSystemRepresentation) != 0) {
        int failure = errno;
        [[NSFileManager defaultManager] removeItemAtPath:staging error:nil];
        LCAUTell(@"更新できません", [NSString stringWithFormat:@"置き換えに失敗しました (errno %d)。", failure]);
        return;
    }

    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    [defaults setObject:remoteBuild forKey:LCAUPendingKey];
    [defaults removeObjectForKey:LCAUDeclinedKey];
    NSLog(@"[LCAutoUpdate] %s %@ -> %@, applies on next launch", LCAU_NAME, LCAUCurrentBuild(), remoteBuild);

    LCAUTell(@"更新しました",
             [NSString stringWithFormat:@"%@ を置きました。\n\nアプリを一度終了して開き直すと切り替わります。"
                                        @"置き換えた直後の起動だけ少し待たされますが、それは LiveContainer が署名している時間です。",
              remoteBuild]);
}

static void LCAUFetchAndInstall(NSString *remote) {
    NSURLSessionConfiguration *config = [NSURLSessionConfiguration ephemeralSessionConfiguration];
    config.timeoutIntervalForRequest = 15;
    config.timeoutIntervalForResource = 300;
    NSURLSession *session = [NSURLSession sessionWithConfiguration:config];

    NSURL *payload = [NSURL URLWithString:[NSString stringWithFormat:@"%@%s.dylib", LCAUBase, LCAU_NAME]];
    [[session dataTaskWithURL:payload completionHandler:^(NSData *body, NSURLResponse *response, NSError *error) {
        if (error) {
            LCAUTell(@"取得できません", error.localizedDescription);
            return;
        }
        NSInteger status = ((NSHTTPURLResponse *)response).statusCode;
        if (status != 200) {
            LCAUTell(@"取得できません", [NSString stringWithFormat:@"サーバーが %ld を返しました。", (long)status]);
            return;
        }
        if (!LCAULooksLikeDylib(body)) {
            LCAUTell(@"取得できません", @"返ってきたものが .dylib ではありませんでした。");
            return;
        }
        LCAUWrite(body, remote);
    }] resume];
}

// Fetches only the build id. `announce` is NO for the check that runs by itself, so that a
// server that is simply not reachable stays quiet, and YES when the user asked.
static void LCAULookUp(BOOL announce) {
    NSURLSessionConfiguration *config = [NSURLSessionConfiguration ephemeralSessionConfiguration];
    config.timeoutIntervalForRequest = announce ? 10 : 6;
    NSURLSession *session = [NSURLSession sessionWithConfiguration:config];

    NSURL *manifest = [NSURL URLWithString:[NSString stringWithFormat:@"%@%s.txt", LCAUBase, LCAU_NAME]];
    [[session dataTaskWithURL:manifest completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];

        if (error) {
            if (announce) {
                LCAUTell(@"確認できません",
                         [NSString stringWithFormat:@"%@\n\n%@ に繋がりません。Tailscale が繋がっているか、"
                                                    @"PC 側で配布サーバーが動いているか確認してください。",
                          error.localizedDescription, LCAUHost]);
            }
            return;
        }
        NSInteger status = ((NSHTTPURLResponse *)response).statusCode;
        if (status != 200 || !data.length) {
            if (announce) LCAUTell(@"確認できません", [NSString stringWithFormat:@"サーバーが %ld を返しました。", (long)status]);
            return;
        }

        NSString *remote = [[[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding]
                            stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        if (remote.length == 0) {
            if (announce) LCAUTell(@"確認できません", @"版の情報が空でした。");
            return;
        }

        if ([remote isEqualToString:LCAUCurrentBuild()]) {
            [defaults removeObjectForKey:LCAUPendingKey];
            [defaults removeObjectForKey:LCAUDeclinedKey];
            if (announce) LCAUTell(@"最新です", [NSString stringWithFormat:@"%@ が最新の版です。", remote]);
            return;
        }

        // Already downloaded and waiting for a relaunch -- nothing to ask.
        if ([[defaults stringForKey:LCAUPendingKey] isEqualToString:remote]) {
            if (announce) {
                LCAUTell(@"すでに置いてあります",
                         [NSString stringWithFormat:@"%@ は取得済みです。アプリを開き直すと切り替わります。", remote]);
            }
            return;
        }

        // Turned down before. The settings row still asks; the launch check does not.
        if (!announce && [[defaults stringForKey:LCAUDeclinedKey] isEqualToString:remote]) return;

        LCAUAsk(@"新しい版があります",
                [NSString stringWithFormat:@"今: %@\n新しい版: %@\n\n取得元: %@\n\n"
                                           @"この .dylib を今の .dylib と置き換えます。次の起動から新しい版になります。",
                 LCAUCurrentBuild(), remote, LCAUHost],
                @"更新する",
                ^{ LCAUFetchAndInstall(remote); },
                ^{ [defaults setObject:remote forKey:LCAUDeclinedKey]; });
    }] resume];
}

// The settings row: always reports back, even when there is nothing to do.
void LCAUCheckForUpdate(void) {
    LCAULookUp(YES);
}

__attribute__((constructor)) static void LCAUInit(void) {
    if (LCAUChecksDisabled()) return;
    // Well off the launch path: the app is on screen long before this fires, and missing a
    // check costs nothing because the next launch runs it again.
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(8 * NSEC_PER_SEC)),
                   dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        LCAULookUp(NO);
    });
}
