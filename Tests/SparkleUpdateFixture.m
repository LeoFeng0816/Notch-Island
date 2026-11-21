#import <AppKit/AppKit.h>
#import <Sparkle/Sparkle.h>

@interface Fixture : NSObject <NSApplicationDelegate, SPUUserDriver>
@property (nonatomic, strong) SPUUpdater *updater;
@end
@implementation Fixture
- (void)applicationDidFinishLaunching:(NSNotification *)notification {
    NSBundle *bundle = NSBundle.mainBundle;
    NSString *version = [bundle objectForInfoDictionaryKey:@"CFBundleVersion"];
    NSURL *receipt = [NSURL fileURLWithPath:[bundle objectForInfoDictionaryKey:@"SmokeReceipt"]];
    [[NSString stringWithFormat:@"%@ %@\n", version, bundle.bundlePath] writeToURL:receipt atomically:YES encoding:NSUTF8StringEncoding error:NULL];
    if ([version isEqualToString:@"2"]) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC), dispatch_get_main_queue(), ^{ [NSApp terminate:nil]; });
        return;
    }
    self.updater = [[SPUUpdater alloc] initWithHostBundle:bundle applicationBundle:bundle userDriver:self delegate:nil];
    NSError *error;
    if (![self.updater startUpdater:&error]) { fprintf(stderr, "start error: %s\n", [[error description] UTF8String]); exit(2); }
    [self.updater checkForUpdates];
}
- (void)showUpdatePermissionRequest:(SPUUpdatePermissionRequest *)request reply:(void (^)(SUUpdatePermissionResponse *))reply {
    reply([[SUUpdatePermissionResponse alloc] initWithAutomaticUpdateChecks:NO sendSystemProfile:NO]);
}
- (void)showUserInitiatedUpdateCheckWithCancellation:(void (^)(void))cancellation {}
- (void)showUpdateFoundWithAppcastItem:(SUAppcastItem *)item state:(SPUUserUpdateState *)state reply:(void (^)(SPUUserUpdateChoice))reply {
    fprintf(stderr, "offered %s\n", item.versionString.UTF8String);
    if ([NSProcessInfo.processInfo.arguments containsObject:@"--cancel"]) {
        reply(SPUUserUpdateChoiceDismiss);
        exit(0);
    }
    reply(SPUUserUpdateChoiceInstall);
}
- (void)showUpdateReleaseNotesWithDownloadData:(SPUDownloadData *)downloadData {}
- (void)showUpdateReleaseNotesFailedToDownloadWithError:(NSError *)error {}
- (void)showUpdateNotFoundWithError:(NSError *)error acknowledgement:(void (^)(void))acknowledgement {
    fprintf(stderr, "none: %s\n", [[error description] UTF8String]); acknowledgement(); exit(3);
}
- (void)showUpdaterError:(NSError *)error acknowledgement:(void (^)(void))acknowledgement {
    for (NSError *cause = error; cause != nil; cause = cause.userInfo[NSUnderlyingErrorKey]) {
        fprintf(stderr, "update error: %s %ld %s\n", cause.domain.UTF8String, (long)cause.code, cause.localizedDescription.UTF8String);
    }
    acknowledgement();
    exit(4);
}
- (void)showDownloadInitiatedWithCancellation:(void (^)(void))cancellation {}
- (void)showDownloadDidReceiveExpectedContentLength:(uint64_t)length {}
- (void)showDownloadDidReceiveDataOfLength:(uint64_t)length {}
- (void)showDownloadDidStartExtractingUpdate { fprintf(stderr,"extracting after signature verification\n"); }
- (void)showExtractionReceivedProgress:(double)progress {}
- (void)showReadyToInstallAndRelaunch:(void (^)(SPUUserUpdateChoice))reply { reply(SPUUserUpdateChoiceInstall); }
- (void)showInstallingUpdateWithApplicationTerminated:(BOOL)terminated retryTerminatingApplication:(void (^)(void))retry {
    fprintf(stderr,"installing (terminated=%d)\n", terminated);
}
- (void)showUpdateInstalledAndRelaunched:(BOOL)relaunched acknowledgement:(void (^)(void))acknowledgement { acknowledgement(); }
- (void)dismissUpdateInstallation {}
@end
int main(void) {
    @autoreleasepool {
        NSApplication *app = NSApplication.sharedApplication;
        Fixture *fixture = [Fixture new];
        app.delegate = fixture;
        [app setActivationPolicy:NSApplicationActivationPolicyAccessory];
        [app run];
    }
    return 0;
}
