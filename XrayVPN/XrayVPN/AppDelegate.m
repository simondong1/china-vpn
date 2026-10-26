#import "AppDelegate.h"
#import <ServiceManagement/ServiceManagement.h>
#import <arpa/inet.h>
#import <signal.h>
#import <sys/utsname.h>
#import <sys/xattr.h>

static NSString * const kXrayVersion = @"v26.10.21";
static NSInteger const kSocksPort = 10808;
static NSInteger const kMaxXrayRestarts = 3;
static NSString * const kWantsConnectionKey = @"WantsConnection";
static NSString * const kDidSetUpLoginItemKey = @"DidSetUpLoginItem";
static NSString * const kDidShowWelcomeKey = @"DidShowWelcome";
static NSString * const kMovedArgument = @"--moved-to-applications";

@interface AppDelegate () <NSMenuDelegate>
@property (nonatomic, strong) NSStatusItem *statusBarItem;
@property (nonatomic, strong) NSMenuItem *statusMenuItem;
@property (nonatomic, strong) NSMenuItem *toggleMenuItem;
@property (nonatomic, strong) NSMenuItem *loginItemMenuItem;
@property (nonatomic, strong) NSMenuItem *configurationMenuItem;
@property (nonatomic, strong) NSPopover *statusPopover;
@property (nonatomic, strong) NSTask *xrayTask;
@property (nonatomic, strong) NSWindow *settingsWindow;
@property (nonatomic, strong) NSTextField *linkField;
@property (nonatomic, strong) NSTextField *configurationHeadingField;
@property (nonatomic, strong) NSButton *configurationSaveButton;
@property (nonatomic, strong) NSTextField *settingsStatusField;
@property (nonatomic, strong) NSMutableDictionary<NSString *, NSDictionary *> *proxyBackups;
@property (nonatomic, strong) NSMutableArray *signalSources;
@property (nonatomic, copy) NSString *publicIP;
@property (nonatomic, assign) BOOL isConnected;
@property (nonatomic, assign) BOOL isTransitioning;
@property (nonatomic, assign) BOOL isWaitingToRetry;
@property (nonatomic, assign) NSInteger connectGeneration;
@property (nonatomic, assign) NSInteger retryAttempt;
@property (nonatomic, assign) NSInteger xrayRestartCount;
- (void)updateConfigurationLabels;
@end

@implementation AppDelegate

- (void)applicationDidFinishLaunching:(NSNotification *)notification {
    if ([self moveToApplicationsIfNeeded]) return;
    [self installTerminationSignalHandlers];
    [self stopStaleXray];

    self.proxyBackups = [NSMutableDictionary dictionary];
    self.statusBarItem = [[NSStatusBar systemStatusBar] statusItemWithLength:NSVariableStatusItemLength];
    self.statusBarItem.button.image = [self statusImageConnected:NO];
    self.statusBarItem.button.image.template = YES;
    self.statusBarItem.button.toolTip = @"DongVPN";

    NSMenu *menu = [[NSMenu alloc] initWithTitle:@"DongVPN"];
    menu.delegate = self;
    self.statusMenuItem = [menu addItemWithTitle:@"Disconnected" action:nil keyEquivalent:@""];
    self.statusMenuItem.enabled = NO;
    [menu addItem:[NSMenuItem separatorItem]];

    self.toggleMenuItem = [menu addItemWithTitle:@"Connect" action:@selector(toggleConnection:) keyEquivalent:@""];
    self.toggleMenuItem.target = self;
    [menu addItem:[NSMenuItem separatorItem]];

    self.loginItemMenuItem = [menu addItemWithTitle:@"Open at Login" action:@selector(toggleLoginItem:) keyEquivalent:@""];
    self.loginItemMenuItem.target = self;
    self.loginItemMenuItem.hidden = ![self supportsLoginItem];

    self.configurationMenuItem = [menu addItemWithTitle:@"Add VPN Configuration..." action:@selector(showConfigurationPrompt:) keyEquivalent:@""];
    self.configurationMenuItem.target = self;
    if ([self savedLink].length > 0) self.configurationMenuItem.title = @"Change VPN Configuration...";
    [menu addItem:[NSMenuItem separatorItem]];

    NSMenuItem *quitItem = [menu addItemWithTitle:@"Quit DongVPN" action:@selector(quitApp:) keyEquivalent:@"q"];
    quitItem.target = self;
    self.statusBarItem.menu = menu;

    NSData *backupData = [NSData dataWithContentsOfFile:[self proxyBackupPath]];
    NSDictionary *savedBackups = backupData ? [NSJSONSerialization JSONObjectWithData:backupData options:0 error:NULL] : nil;
    if ([savedBackups isKindOfClass:[NSDictionary class]] && savedBackups.count > 0) {
        [self.proxyBackups addEntriesFromDictionary:savedBackups];
        NSError *error = nil;
        if (![self restoreSystemProxy:&error]) {
            dispatch_async(dispatch_get_main_queue(), ^{
                [self showError:@"DongVPN restored after an interrupted session." detail:error.localizedDescription ?: @"Previous macOS proxy settings could not be restored."];
            });
        }
    }

    __weak AppDelegate *weakSelf = self;
    [[NSWorkspace sharedWorkspace].notificationCenter addObserverForName:NSWorkspaceDidWakeNotification object:nil queue:[NSOperationQueue mainQueue] usingBlock:^(NSNotification *note) {
        AppDelegate *strongSelf = weakSelf;
        if (strongSelf.isWaitingToRetry) [strongSelf connectAutomatically:YES announce:NO];
    }];

    [self setUpLoginItemOnFirstLaunch];

    if ([self savedLink].length == 0) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self showConfigurationPrompt:nil];
        });
    } else if ([self wantsConnection]) {
        BOOL firstLaunch = ![[NSUserDefaults standardUserDefaults] boolForKey:kDidShowWelcomeKey];
        [[NSUserDefaults standardUserDefaults] setBool:YES forKey:kDidShowWelcomeKey];
        [self connectAutomatically:YES announce:firstLaunch];
    }
}

- (BOOL)applicationShouldHandleReopen:(NSApplication *)sender hasVisibleWindows:(BOOL)flag {
    if ([self savedLink].length == 0) {
        [self showConfigurationPrompt:nil];
    } else if (!self.isConnected && !self.isTransitioning && !self.isWaitingToRetry) {
        [self setWantsConnection:YES];
        [self connectAutomatically:NO announce:YES];
    } else {
        [self showStatusPopover];
    }
    return NO;
}

- (void)applicationWillTerminate:(NSNotification *)notification {
    [self disconnectSilently];
}

- (BOOL)moveToApplicationsIfNeeded {
    NSString *bundlePath = [NSBundle mainBundle].bundlePath;
    NSString *userApplications = [NSHomeDirectory() stringByAppendingPathComponent:@"Applications"];
    if ([bundlePath hasPrefix:@"/Applications/"] || [bundlePath hasPrefix:[userApplications stringByAppendingString:@"/"]]) return NO;
    if ([[NSProcessInfo processInfo].arguments containsObject:kMovedArgument]) return NO;

    NSFileManager *fileManager = [NSFileManager defaultManager];
    NSString *folder = [fileManager isWritableFileAtPath:@"/Applications"] ? @"/Applications" : userApplications;
    [fileManager createDirectoryAtPath:folder withIntermediateDirectories:YES attributes:nil error:NULL];
    NSString *destination = [folder stringByAppendingPathComponent:bundlePath.lastPathComponent];

    for (NSRunningApplication *app in [NSRunningApplication runningApplicationsWithBundleIdentifier:[NSBundle mainBundle].bundleIdentifier]) {
        if ([app isEqual:[NSRunningApplication currentApplication]]) continue;
        pid_t pid = app.processIdentifier;
        [app terminate];
        for (int i = 0; i < 50 && kill(pid, 0) == 0; i++) [NSThread sleepForTimeInterval:0.1];
    }
    [fileManager removeItemAtPath:destination error:NULL];
    if (![fileManager copyItemAtPath:bundlePath toPath:destination error:NULL]) return NO;

    // Gatekeeper translocates quarantined apps on every launch, which would break the login item.
    NSTask *unquarantine = [self taskWithLaunchPath:@"/usr/bin/xattr" arguments:@[@"-d", @"-r", @"com.apple.quarantine", destination]];
    [unquarantine launch];
    [unquarantine waitUntilExit];
    NSTask *open = [self taskWithLaunchPath:@"/usr/bin/open" arguments:@[@"-n", destination, @"--args", kMovedArgument]];
    [open launch];
    [open waitUntilExit];
    if (open.terminationStatus != 0) return NO;
    [NSApp terminate:nil];
    return YES;
}

- (void)installTerminationSignalHandlers {
    self.signalSources = [NSMutableArray array];
    for (NSNumber *signalNumber in @[@(SIGTERM), @(SIGINT), @(SIGHUP)]) {
        signal(signalNumber.intValue, SIG_IGN);
        dispatch_source_t source = dispatch_source_create(DISPATCH_SOURCE_TYPE_SIGNAL, signalNumber.unsignedLongValue, 0, dispatch_get_main_queue());
        dispatch_source_set_event_handler(source, ^{
            [NSApp terminate:nil];
        });
        dispatch_resume(source);
        [self.signalSources addObject:source];
    }
}

- (void)stopStaleXray {
    NSString *pattern = [NSString stringWithFormat:@"^%@ run", [NSRegularExpression escapedPatternForString:[self xrayPath]]];
    NSTask *task = [self taskWithLaunchPath:@"/usr/bin/pkill" arguments:@[@"-f", pattern]];
    [task launch];
    [task waitUntilExit];
}

- (BOOL)wantsConnection {
    NSNumber *value = [[NSUserDefaults standardUserDefaults] objectForKey:kWantsConnectionKey];
    return value ? value.boolValue : YES;
}

- (void)setWantsConnection:(BOOL)wantsConnection {
    [[NSUserDefaults standardUserDefaults] setBool:wantsConnection forKey:kWantsConnectionKey];
}

- (BOOL)supportsLoginItem {
    if (@available(macOS 13.0, *)) return YES;
    return NO;
}

- (BOOL)isLoginItemEnabled {
    if (@available(macOS 13.0, *)) return [SMAppService mainAppService].status == SMAppServiceStatusEnabled;
    return NO;
}

- (void)setUpLoginItemOnFirstLaunch {
    if ([[NSUserDefaults standardUserDefaults] boolForKey:kDidSetUpLoginItemKey]) return;
    [[NSUserDefaults standardUserDefaults] setBool:YES forKey:kDidSetUpLoginItemKey];
    if (@available(macOS 13.0, *)) [[SMAppService mainAppService] registerAndReturnError:NULL];
}

- (IBAction)toggleLoginItem:(id)sender {
    if (@available(macOS 13.0, *)) {
        NSError *error = nil;
        SMAppService *service = [SMAppService mainAppService];
        BOOL changed = [self isLoginItemEnabled] ? [service unregisterAndReturnError:&error] : [service registerAndReturnError:&error];
        if (!changed) [self showError:@"Could not change Open at Login." detail:error.localizedDescription];
    }
}

- (void)menuWillOpen:(NSMenu *)menu {
    [self.statusPopover close];
    self.loginItemMenuItem.state = [self isLoginItemEnabled] ? NSControlStateValueOn : NSControlStateValueOff;
}

- (void)showStatusPopover {
    NSString *title = @"DongVPN is off";
    NSString *detail = @"Click the network icon in the menu bar to connect.";
    if (self.isConnected) {
        title = @"DongVPN is connected";
        detail = [NSString stringWithFormat:@"Your internet traffic now goes through %@. Click the network icon anytime to disconnect.", self.publicIP];
    } else if (self.isWaitingToRetry) {
        title = @"DongVPN is reconnecting";
        detail = @"The VPN server isn't reachable yet. DongVPN keeps trying automatically.";
    } else if (self.isTransitioning) {
        title = @"DongVPN is connecting";
        detail = @"This usually takes a few seconds.";
    }

    NSView *view = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 320, 96)];
    NSTextField *heading = [NSTextField labelWithString:title];
    heading.font = [NSFont boldSystemFontOfSize:13];
    heading.frame = NSMakeRect(16, 66, 288, 18);
    [view addSubview:heading];
    NSTextField *body = [NSTextField wrappingLabelWithString:detail];
    body.frame = NSMakeRect(16, 10, 288, 52);
    [view addSubview:body];
    NSViewController *controller = [[NSViewController alloc] init];
    controller.view = view;

    [self.statusPopover close];
    NSPopover *popover = [[NSPopover alloc] init];
    popover.behavior = NSPopoverBehaviorApplicationDefined;
    // An animated popover ignores close while it is still animating in, which leaves it stuck on screen.
    popover.animates = NO;
    popover.contentViewController = controller;
    self.statusPopover = popover;
    [popover showRelativeToRect:self.statusBarItem.button.bounds ofView:self.statusBarItem.button preferredEdge:NSRectEdgeMinY];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(8 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        [popover close];
    });
}

- (IBAction)toggleConnection:(id)sender {
    if (self.isTransitioning) return;
    BOOL turnOff = self.isConnected || self.isWaitingToRetry;
    [self setWantsConnection:!turnOff];
    turnOff ? [self disconnect] : [self connectAutomatically:NO announce:NO];
}

- (void)connectAutomatically:(BOOL)automatic announce:(BOOL)announce {
    self.connectGeneration++;
    self.isWaitingToRetry = NO;
    self.isTransitioning = YES;
    [self updateStatusTitle:@"Connecting..." connected:NO];

    NSError *error = nil;
    NSDictionary *connection = [self connectionFromVLESSLink:[self savedLink] error:&error];
    if (!connection) {
        self.isTransitioning = NO;
        [self updateStatusTitle:@"Disconnected" connected:NO];
        [self showError:@"VPN configuration is missing or invalid." detail:error.localizedDescription ?: @"Choose VPN Configuration from the DongVPN menu."];
        return;
    }

    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSError *backgroundError = nil;
        BOOL ready = [self ensureXrayInstalled:&backgroundError]
            && [self writeXrayConfigForConnection:connection error:&backgroundError]
            && [self startXray:&backgroundError];
        NSString *verifiedIP = nil;
        if (ready) ready = [self verifyTunnelAndGetPublicIP:&verifiedIP error:&backgroundError];
        dispatch_async(dispatch_get_main_queue(), ^{
            if (!ready) {
                [self stopXray];
                self.isTransitioning = NO;
                if (automatic && [self wantsConnection]) {
                    [self scheduleAutomaticRetry];
                    if (announce) [self showStatusPopover];
                } else {
                    [self updateStatusTitle:@"Disconnected" connected:NO];
                    [self showConnectionFailure:backgroundError.localizedDescription];
                }
                return;
            }
            NSError *proxyError = nil;
            if (![self enableSystemProxy:&proxyError]) {
                [self stopXray];
                self.isTransitioning = NO;
                [self updateStatusTitle:@"Disconnected" connected:NO];
                [self showConnectionFailure:[NSString stringWithFormat:@"Could not enable the macOS proxy. %@", proxyError.localizedDescription ?: @""]];
                return;
            }
            self.isConnected = YES;
            self.publicIP = verifiedIP;
            self.isTransitioning = NO;
            self.retryAttempt = 0;
            self.xrayRestartCount = 0;
            [self updateStatusTitle:[NSString stringWithFormat:@"Connected - %@", verifiedIP] connected:YES];
            if (announce) [self showStatusPopover];
        });
    });
}

- (void)scheduleAutomaticRetry {
    self.isWaitingToRetry = YES;
    NSInteger delay = MIN(30, 5 << MIN(self.retryAttempt, 3));
    self.retryAttempt++;
    [self updateStatusTitle:@"Reconnecting..." connected:NO];
    self.toggleMenuItem.title = @"Cancel";
    NSInteger generation = self.connectGeneration;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        if (generation != self.connectGeneration || !self.isWaitingToRetry) return;
        [self connectAutomatically:YES announce:NO];
    });
}

- (void)handleUnexpectedXrayExit {
    if (self.xrayRestartCount < kMaxXrayRestarts) {
        self.xrayRestartCount++;
        if ([self startXray:NULL]) return;
    }
    self.isConnected = NO;
    self.publicIP = nil;
    self.xrayTask = nil;
    [self restoreSystemProxy:NULL];
    [self scheduleAutomaticRetry];
}

- (void)disconnect {
    self.connectGeneration++;
    self.isWaitingToRetry = NO;
    self.isTransitioning = YES;
    [self stopXray];
    NSError *error = nil;
    if (![self restoreSystemProxy:&error]) {
        [self showError:@"Could not restore the previous proxy settings." detail:error.localizedDescription];
    }
    self.isConnected = NO;
    self.publicIP = nil;
    self.isTransitioning = NO;
    [self updateStatusTitle:@"Disconnected" connected:NO];
}

- (void)disconnectSilently {
    [self stopXray];
    if (self.proxyBackups.count > 0) [self restoreSystemProxy:NULL];
    self.isConnected = NO;
    self.publicIP = nil;
}

- (void)updateStatusTitle:(NSString *)title connected:(BOOL)connected {
    self.statusMenuItem.title = title;
    self.toggleMenuItem.title = connected ? @"Disconnect" : @"Connect";
    self.statusBarItem.button.image = [self statusImageConnected:connected];
    self.statusBarItem.button.image.template = YES;
    self.statusBarItem.button.toolTip = connected && self.publicIP.length > 0 ? [NSString stringWithFormat:@"DongVPN - %@", self.publicIP] : @"DongVPN";
}

- (NSImage *)statusImageConnected:(BOOL)connected {
    if (@available(macOS 11.0, *)) {
        return [NSImage imageWithSystemSymbolName:(connected ? @"network" : @"network.slash") accessibilityDescription:@"DongVPN"];
    }
    return [NSImage imageNamed:NSImageNameNetwork];
}

- (BOOL)writeXrayConfigForConnection:(NSDictionary *)connection error:(NSError **)error {
    NSMutableArray *rules = [NSMutableArray arrayWithObject:@{
        @"type": @"field", @"outboundTag": @"direct",
        @"ip": @[@"10.0.0.0/8", @"100.64.0.0/10", @"127.0.0.0/8", @"169.254.0.0/16", @"172.16.0.0/12", @"192.168.0.0/16", @"::1/128", @"fc00::/7", @"fe80::/10"]
    }];
    NSFileManager *fileManager = [NSFileManager defaultManager];
    if ([fileManager fileExistsAtPath:[[self appSupportPath] stringByAppendingPathComponent:@"geosite.dat"]]) {
        [rules addObject:@{ @"type": @"field", @"outboundTag": @"direct", @"domain": @[@"geosite:cn"] }];
    }
    if ([fileManager fileExistsAtPath:[[self appSupportPath] stringByAppendingPathComponent:@"geoip.dat"]]) {
        [rules addObject:@{ @"type": @"field", @"outboundTag": @"direct", @"ip": @[@"geoip:cn"] }];
    }
    NSDictionary *config = @{
        @"log": @{ @"loglevel": @"warning" },
        @"inbounds": @[@{
            @"listen": @"127.0.0.1", @"port": @(kSocksPort), @"protocol": @"socks",
            @"settings": @{ @"udp": @YES }
        }],
        @"routing": @{ @"domainStrategy": @"AsIs", @"rules": rules },
        @"outbounds": @[@{
            @"tag": @"proxy",
            @"protocol": @"vless",
            @"settings": @{ @"vnext": @[@{
                @"address": connection[@"server"], @"port": connection[@"port"],
                @"users": @[@{
                    @"id": connection[@"uuid"], @"encryption": @"none", @"flow": connection[@"flow"]
                }]
            }] },
            @"streamSettings": @{
                @"network": connection[@"network"], @"security": @"reality",
                @"realitySettings": @{
                    @"serverName": connection[@"sni"], @"fingerprint": connection[@"fingerprint"],
                    @"publicKey": connection[@"publicKey"], @"shortId": connection[@"shortID"]
                }
            }
        }, @{ @"tag": @"direct", @"protocol": @"freedom" }]
    };
    NSData *data = [NSJSONSerialization dataWithJSONObject:config options:NSJSONWritingPrettyPrinted error:error];
    BOOL written = data && [data writeToFile:[self configPath] options:NSDataWritingAtomic error:error];
    if (written) [[NSFileManager defaultManager] setAttributes:@{NSFilePosixPermissions: @0600} ofItemAtPath:[self configPath] error:NULL];
    return written;
}

- (BOOL)ensureXrayInstalled:(NSError **)error {
    NSFileManager *fileManager = [NSFileManager defaultManager];
    NSString *xrayPath = [self xrayPath];
    struct utsname systemInfo;
    uname(&systemInfo);
    NSString *machine = [NSString stringWithUTF8String:systemInfo.machine] ?: @"x86_64";
    BOOL isAppleSilicon = [machine isEqualToString:@"arm64"];
    NSString *resourceName = isAppleSilicon ? @"xray-arm64" : @"xray-x86_64";
    NSString *resources = [[NSBundle mainBundle] resourcePath];
    if ([fileManager isExecutableFileAtPath:[resources stringByAppendingPathComponent:resourceName]]) {
        NSDictionary<NSString *, NSString *> *files = @{ resourceName: @"xray", @"geoip.dat": @"geoip.dat", @"geosite.dat": @"geosite.dat" };
        for (NSString *name in files) {
            NSString *source = [resources stringByAppendingPathComponent:name];
            NSString *destination = [[self appSupportPath] stringByAppendingPathComponent:files[name]];
            if (![fileManager fileExistsAtPath:source]) continue;
            if (![fileManager contentsEqualAtPath:source andPath:destination]) {
                [fileManager removeItemAtPath:destination error:NULL];
                if (![fileManager copyItemAtPath:source toPath:destination error:error]) return NO;
            }
            // A browser-downloaded app passes its quarantine flag to copied files, and Gatekeeper
            // blocks quarantined unsigned executables outside the user-approved app bundle.
            removexattr(destination.fileSystemRepresentation, "com.apple.quarantine", 0);
        }
        return [fileManager setAttributes:@{NSFilePosixPermissions: @0755} ofItemAtPath:xrayPath error:error];
    }
    if ([fileManager isExecutableFileAtPath:xrayPath]) {
        removexattr(xrayPath.fileSystemRepresentation, "com.apple.quarantine", 0);
        return YES;
    }

    NSString *asset = isAppleSilicon ? @"Xray-macos-arm64-v8a.zip" : @"Xray-macos-64.zip";
    NSString *url = [NSString stringWithFormat:@"https://github.com/XTLS/Xray-core/releases/download/%@/%@", kXrayVersion, asset];
    NSString *zipPath = [[self appSupportPath] stringByAppendingPathComponent:@"xray-download.zip"];

    NSTask *download = [self taskWithLaunchPath:@"/usr/bin/curl" arguments:@[@"--fail", @"--location", @"--silent", @"--show-error", @"--output", zipPath, url]];
    [download launch];
    [download waitUntilExit];
    if (download.terminationStatus != 0) {
        [[NSFileManager defaultManager] removeItemAtPath:zipPath error:NULL];
        if (error) *error = [NSError errorWithDomain:@"XrayVPN" code:10 userInfo:@{NSLocalizedDescriptionKey: @"The Xray download failed. Check your internet connection and try again."}];
        return NO;
    }

    NSTask *unzip = [self taskWithLaunchPath:@"/usr/bin/unzip" arguments:@[@"-oq", zipPath, @"-d", [self appSupportPath]]];
    [unzip launch];
    [unzip waitUntilExit];
    [[NSFileManager defaultManager] removeItemAtPath:zipPath error:NULL];
    if (unzip.terminationStatus != 0 || ![[NSFileManager defaultManager] fileExistsAtPath:xrayPath]) {
        if (error) *error = [NSError errorWithDomain:@"XrayVPN" code:11 userInfo:@{NSLocalizedDescriptionKey: @"The Xray archive did not contain a usable binary."}];
        return NO;
    }
    return [[NSFileManager defaultManager] setAttributes:@{NSFilePosixPermissions: @0755} ofItemAtPath:xrayPath error:error];
}

- (BOOL)startXray:(NSError **)error {
    NSString *xrayPath = [self xrayPath];
    NSString *configPath = [self configPath];
    NSTask *check = [self taskWithLaunchPath:xrayPath arguments:@[@"run", @"-test", @"-c", configPath]];
    NSPipe *checkPipe = [NSPipe pipe];
    check.standardOutput = checkPipe;
    check.standardError = checkPipe;
    [check launch];
    [check waitUntilExit];
    if (check.terminationStatus != 0) {
        NSData *data = [checkPipe.fileHandleForReading readDataToEndOfFile];
        NSString *message = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] ?: @"Xray rejected the configuration.";
        if (error) *error = [NSError errorWithDomain:@"XrayVPN" code:12 userInfo:@{NSLocalizedDescriptionKey: [message stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]]}];
        return NO;
    }

    self.xrayTask = [self taskWithLaunchPath:xrayPath arguments:@[@"run", @"-c", configPath]];
    self.xrayTask.standardOutput = [NSFileHandle fileHandleWithNullDevice];
    self.xrayTask.standardError = [NSFileHandle fileHandleWithNullDevice];
    __weak AppDelegate *weakSelf = self;
    self.xrayTask.terminationHandler = ^(NSTask *task) {
        dispatch_async(dispatch_get_main_queue(), ^{
            AppDelegate *strongSelf = weakSelf;
            if (!strongSelf || strongSelf.isTransitioning || !strongSelf.isConnected || task != strongSelf.xrayTask) return;
            [strongSelf handleUnexpectedXrayExit];
        });
    };
    [self.xrayTask launch];
    [NSThread sleepForTimeInterval:0.5];
    if (!self.xrayTask.isRunning) {
        if (error) *error = [NSError errorWithDomain:@"XrayVPN" code:13 userInfo:@{NSLocalizedDescriptionKey: @"Xray exited immediately. Check the configuration and try again."}];
        self.xrayTask = nil;
        return NO;
    }
    return YES;
}

- (BOOL)verifyTunnelAndGetPublicIP:(NSString **)publicIP error:(NSError **)error {
    for (NSString *url in @[@"https://api.ipify.org", @"https://checkip.amazonaws.com"]) {
        if ([self fetchPublicIP:publicIP fromURL:url error:error]) return YES;
    }
    return NO;
}

- (BOOL)fetchPublicIP:(NSString **)publicIP fromURL:(NSString *)url error:(NSError **)error {
    NSTask *task = [self taskWithLaunchPath:@"/usr/bin/curl" arguments:@[
        @"--fail", @"--silent", @"--show-error",
        @"--connect-timeout", @"8", @"--max-time", @"15",
        @"--socks5-hostname", [NSString stringWithFormat:@"127.0.0.1:%ld", (long)kSocksPort],
        url
    ]];
    NSPipe *outputPipe = [NSPipe pipe];
    NSPipe *errorPipe = [NSPipe pipe];
    task.standardOutput = outputPipe;
    task.standardError = errorPipe;
    [task launch];
    [task waitUntilExit];

    NSData *outputData = [outputPipe.fileHandleForReading readDataToEndOfFile];
    NSData *errorData = [errorPipe.fileHandleForReading readDataToEndOfFile];
    NSString *output = [[NSString alloc] initWithData:outputData encoding:NSUTF8StringEncoding] ?: @"";
    NSString *errorOutput = [[NSString alloc] initWithData:errorData encoding:NSUTF8StringEncoding] ?: @"";
    NSString *ip = [output stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    struct in_addr ipv4;
    struct in6_addr ipv6;
    BOOL isValidIP = inet_pton(AF_INET, ip.UTF8String, &ipv4) == 1 || inet_pton(AF_INET6, ip.UTF8String, &ipv6) == 1;
    if (task.terminationStatus != 0 || !isValidIP) {
        NSString *curlError = [errorOutput stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        NSString *detail = curlError.length > 0 ? curlError : (ip.length > 0 ? ip : @"No response was received through the VPN tunnel.");
        if (error) *error = [NSError errorWithDomain:@"DongVPN" code:40 userInfo:@{NSLocalizedDescriptionKey: detail}];
        return NO;
    }
    if (publicIP) *publicIP = ip;
    return YES;
}

- (void)stopXray {
    if (self.xrayTask.isRunning) {
        [self.xrayTask terminate];
        [self.xrayTask waitUntilExit];
    }
    self.xrayTask = nil;
}

- (BOOL)enableSystemProxy:(NSError **)error {
    NSArray<NSString *> *services = [self networkServices];
    if (services.count == 0) {
        if (error) *error = [NSError errorWithDomain:@"XrayVPN" code:20 userInfo:@{NSLocalizedDescriptionKey: @"No macOS network service was found."}];
        return NO;
    }
    [self.proxyBackups removeAllObjects];
    NSMutableArray<NSArray<NSString *> *> *commands = [NSMutableArray array];
    for (NSString *service in services) {
        NSDictionary *backup = [self socksProxySettingsForService:service];
        if (!backup) continue;
        self.proxyBackups[service] = backup;
        [commands addObject:@[@"-setsocksfirewallproxy", service, @"127.0.0.1", [NSString stringWithFormat:@"%ld", (long)kSocksPort]]];
        [commands addObject:@[@"-setsocksfirewallproxystate", service, @"on"]];
    }
    NSData *backupData = [NSJSONSerialization dataWithJSONObject:self.proxyBackups options:0 error:error];
    if (!backupData || ![backupData writeToFile:[self proxyBackupPath] options:NSDataWritingAtomic error:error]) {
        [self.proxyBackups removeAllObjects];
        return NO;
    }
    if (commands.count == 0 || ![self runNetworkSetupCommands:commands error:error]) {
        [self restoreSystemProxy:NULL];
        return NO;
    }
    return YES;
}

- (BOOL)restoreSystemProxy:(NSError **)error {
    NSMutableArray<NSArray<NSString *> *> *commands = [NSMutableArray array];
    [self.proxyBackups enumerateKeysAndObjectsUsingBlock:^(NSString *service, NSDictionary *backup, BOOL *stop) {
        NSString *server = backup[@"server"];
        NSString *port = backup[@"port"];
        BOOL hadServer = server.length > 0 && port.length > 0;
        [commands addObject:@[@"-setsocksfirewallproxy", service, hadServer ? server : @"", hadServer ? port : @""]];
        NSString *state = [backup[@"enabled"] boolValue] ? @"on" : @"off";
        [commands addObject:@[@"-setsocksfirewallproxystate", service, state]];
    }];
    BOOL success = commands.count == 0 || [self runNetworkSetupCommands:commands error:error];
    if (success) {
        [self.proxyBackups removeAllObjects];
        [[NSFileManager defaultManager] removeItemAtPath:[self proxyBackupPath] error:NULL];
    }
    return success;
}

- (NSArray<NSString *> *)networkServices {
    NSTask *task = [self taskWithLaunchPath:@"/usr/sbin/networksetup" arguments:@[@"-listallnetworkservices"]];
    NSPipe *pipe = [NSPipe pipe];
    task.standardOutput = pipe;
    [task launch];
    [task waitUntilExit];
    NSString *output = [[NSString alloc] initWithData:pipe.fileHandleForReading.readDataToEndOfFile encoding:NSUTF8StringEncoding];
    NSMutableArray *services = [NSMutableArray array];
    [output enumerateLinesUsingBlock:^(NSString *line, BOOL *stop) {
        if (line.length > 0 && ![line hasPrefix:@"An asterisk"] && ![line hasPrefix:@"*"]) [services addObject:line];
    }];
    return services;
}

- (NSDictionary *)socksProxySettingsForService:(NSString *)service {
    NSTask *task = [self taskWithLaunchPath:@"/usr/sbin/networksetup" arguments:@[@"-getsocksfirewallproxy", service]];
    NSPipe *pipe = [NSPipe pipe];
    task.standardOutput = pipe;
    [task launch];
    [task waitUntilExit];
    NSString *output = [[NSString alloc] initWithData:pipe.fileHandleForReading.readDataToEndOfFile encoding:NSUTF8StringEncoding];
    if (task.terminationStatus != 0) return nil;
    NSMutableDictionary *result = [NSMutableDictionary dictionary];
    [output enumerateLinesUsingBlock:^(NSString *line, BOOL *stop) {
        NSArray *parts = [line componentsSeparatedByString:@": "];
        if (parts.count < 2) return;
        NSString *key = [parts[0] isKindOfClass:[NSString class]] ? (NSString *)parts[0] : @"";
        NSString *value = [line substringFromIndex:key.length + 2];
        if ([key isEqualToString:@"Enabled"]) result[@"enabled"] = @([value isEqualToString:@"Yes"]);
        if ([key isEqualToString:@"Server"]) result[@"server"] = value;
        if ([key isEqualToString:@"Port"]) result[@"port"] = value;
    }];
    return result[@"enabled"] != nil ? result : nil;
}

- (BOOL)runNetworkSetupCommands:(NSArray<NSArray<NSString *> *> *)commands error:(NSError **)error {
    BOOL succeeded = YES;
    for (NSArray<NSString *> *arguments in commands) {
        NSTask *task = [self taskWithLaunchPath:@"/usr/sbin/networksetup" arguments:arguments];
        NSPipe *pipe = [NSPipe pipe];
        task.standardOutput = pipe;
        task.standardError = pipe;
        [task launch];
        NSData *data = [pipe.fileHandleForReading readDataToEndOfFile];
        [task waitUntilExit];
        NSString *output = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] ?: @"";
        if (task.terminationStatus != 0 || [output containsString:@"** Error"]) {
            succeeded = NO;
            break;
        }
    }
    if (succeeded) return YES;

    // networksetup is entitled to change network settings without a password on administrator accounts;
    // other accounts may be refused and need an administrator to approve.
    NSMutableArray<NSString *> *shellCommands = [NSMutableArray array];
    for (NSArray<NSString *> *arguments in commands) {
        NSMutableArray<NSString *> *parts = [NSMutableArray arrayWithObject:@"/usr/sbin/networksetup"];
        for (NSString *argument in arguments) [parts addObject:[self shellQuote:argument]];
        [shellCommands addObject:[parts componentsJoinedByString:@" "]];
    }
    return [self runAdminCommands:shellCommands error:error];
}

- (BOOL)runAdminCommands:(NSArray<NSString *> *)commands error:(NSError **)error {
    NSString *shell = [commands componentsJoinedByString:@" && "];
    NSString *source = [NSString stringWithFormat:@"do shell script \"%@\" with administrator privileges", [self escapeAppleScriptString:shell]];
    NSAppleScript *script = [[NSAppleScript alloc] initWithSource:source];
    NSDictionary *scriptError = nil;
    [script executeAndReturnError:&scriptError];
    if (scriptError) {
        if (error) *error = [NSError errorWithDomain:@"XrayVPN" code:21 userInfo:@{NSLocalizedDescriptionKey: scriptError[NSAppleScriptErrorMessage] ?: @"macOS rejected the network settings change."}];
        return NO;
    }
    return YES;
}

- (NSTask *)taskWithLaunchPath:(NSString *)path arguments:(NSArray<NSString *> *)arguments {
    NSTask *task = [[NSTask alloc] init];
    task.launchPath = path;
    task.arguments = arguments;
    task.currentDirectoryPath = [self appSupportPath];
    return task;
}

- (NSString *)shellQuote:(NSString *)value {
    return [NSString stringWithFormat:@"'%@'", [value stringByReplacingOccurrencesOfString:@"'" withString:@"'\\''"]];
}

- (NSString *)escapeAppleScriptString:(NSString *)value {
    NSString *escaped = [value stringByReplacingOccurrencesOfString:@"\\" withString:@"\\\\"];
    return [escaped stringByReplacingOccurrencesOfString:@"\"" withString:@"\\\""];
}

- (NSDictionary *)connectionFromVLESSLink:(NSString *)link error:(NSError **)error {
    if (link.length == 0) {
        if (error) *error = [NSError errorWithDomain:@"XrayVPN" code:29 userInfo:@{NSLocalizedDescriptionKey: @"Paste a complete vless:// link."}];
        return nil;
    }
    NSString *trimmed = [link stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    NSURLComponents *components = [NSURLComponents componentsWithString:trimmed];
    if (!components || ![components.scheme.lowercaseString isEqualToString:@"vless"] || components.user.length == 0 || components.host.length == 0) {
        if (error) *error = [NSError errorWithDomain:@"XrayVPN" code:30 userInfo:@{NSLocalizedDescriptionKey: @"Paste a complete vless:// link."}];
        return nil;
    }
    NSMutableDictionary *query = [NSMutableDictionary dictionary];
    for (NSURLQueryItem *item in components.queryItems) {
        if (item.name.length > 0 && item.value) query[item.name.lowercaseString] = item.value;
    }
    NSString *security = [query[@"security"] isKindOfClass:[NSString class]] ? (NSString *)query[@"security"] : @"reality";
    id rawNetwork = query[@"type"];
    NSString *networkValue = [rawNetwork isKindOfClass:[NSString class]] ? (NSString *)rawNetwork : @"tcp";
    NSString *network = networkValue.lowercaseString;
    NSString *sni = query[@"sni"];
    NSString *publicKey = query[@"pbk"];
    NSString *shortID = query[@"sid"];
    if (![security.lowercaseString isEqualToString:@"reality"] || ![network.lowercaseString isEqualToString:@"tcp"] || sni.length == 0 || publicKey.length == 0 || shortID.length == 0) {
        if (error) *error = [NSError errorWithDomain:@"XrayVPN" code:31 userInfo:@{NSLocalizedDescriptionKey: @"This app supports VLESS + REALITY over TCP with sni, pbk, and sid parameters."}];
        return nil;
    }
    NSString *uuid = [components.user stringByRemovingPercentEncoding] ?: components.user;
    if (![[NSUUID alloc] initWithUUIDString:uuid]) {
        if (error) *error = [NSError errorWithDomain:@"XrayVPN" code:32 userInfo:@{NSLocalizedDescriptionKey: @"The VLESS user ID is not a valid UUID."}];
        return nil;
    }
    NSInteger port = components.port.integerValue;
    if (port <= 0 || port > 65535) port = 443;
    return @{
        @"uuid": uuid,
        @"server": components.host,
        @"port": @(port),
        @"flow": query[@"flow"] ?: @"",
        @"network": network,
        @"fingerprint": query[@"fp"] ?: @"chrome",
        @"sni": sni,
        @"publicKey": publicKey,
        @"shortID": shortID
    };
}

- (IBAction)showConfigurationPrompt:(id)sender {
    if (!self.settingsWindow) [self buildSettingsWindow];
    [self loadSettingsIntoWindow];
    [self.settingsWindow makeKeyAndOrderFront:nil];
    [NSApp activateIgnoringOtherApps:YES];
}

- (void)buildSettingsWindow {
    NSRect frame = NSMakeRect(0, 0, 540, 270);
    self.settingsWindow = [[NSWindow alloc] initWithContentRect:frame styleMask:(NSWindowStyleMaskTitled | NSWindowStyleMaskClosable) backing:NSBackingStoreBuffered defer:NO];
    self.settingsWindow.title = @"Add VPN Configuration";
    self.settingsWindow.releasedWhenClosed = NO;
    NSView *content = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, frame.size.width, frame.size.height)];
    self.settingsWindow.contentView = content;

    NSTextField *heading = [NSTextField labelWithString:@"Add VPN Configuration"];
    heading.font = [NSFont boldSystemFontOfSize:18];
    heading.frame = NSMakeRect(28, 220, 484, 24);
    [content addSubview:heading];
    self.configurationHeadingField = heading;
    NSTextField *help = [NSTextField wrappingLabelWithString:@"Paste the vless:// link for your VPN. DongVPN saves it automatically; macOS asks for approval when you connect."];
    help.frame = NSMakeRect(28, 172, 484, 36);
    [content addSubview:help];

    self.linkField = [self textFieldAt:NSMakeRect(28, 124, 484, 30) placeholder:@"vless://..." inView:content];
    self.linkField.editable = YES;
    self.linkField.bezeled = YES;
    self.linkField.drawsBackground = YES;

    self.settingsStatusField = [NSTextField labelWithString:@""];
    self.settingsStatusField.frame = NSMakeRect(28, 34, 250, 22);
    self.settingsStatusField.textColor = [NSColor secondaryLabelColor];
    [content addSubview:self.settingsStatusField];
    NSButton *cancel = [NSButton buttonWithTitle:@"Cancel" target:self action:@selector(cancelSettings:)];
    cancel.frame = NSMakeRect(292, 28, 82, 32);
    [content addSubview:cancel];
    self.configurationSaveButton = [NSButton buttonWithTitle:@"Add Configuration" target:self action:@selector(saveSettings:)];
    self.configurationSaveButton.frame = NSMakeRect(370, 28, 148, 32);
    self.configurationSaveButton.keyEquivalent = @"\r";
    [content addSubview:self.configurationSaveButton];
}

- (NSTextField *)textFieldAt:(NSRect)frame placeholder:(NSString *)placeholder inView:(NSView *)view {
    NSTextField *field = [[NSTextField alloc] initWithFrame:frame];
    field.placeholderString = placeholder;
    field.editable = NO;
    field.selectable = YES;
    field.bezeled = NO;
    field.drawsBackground = NO;
    [view addSubview:field];
    return field;
}

- (void)loadSettingsIntoWindow {
    self.linkField.stringValue = [self savedLink] ?: @"";
    self.settingsStatusField.stringValue = @"";
    [self updateConfigurationLabels];
}

- (void)saveSettings:(id)sender {
    NSError *error = nil;
    NSDictionary *connection = [self connectionFromVLESSLink:self.linkField.stringValue error:&error];
    if (!connection) {
        self.settingsStatusField.stringValue = error.localizedDescription;
        self.settingsStatusField.textColor = [NSColor systemRedColor];
        return;
    }
    NSData *linkData = [[self.linkField.stringValue stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]] dataUsingEncoding:NSUTF8StringEncoding];
    if (![self writeXrayConfigForConnection:connection error:&error] || ![linkData writeToFile:[self linkPath] options:NSDataWritingAtomic error:&error]) {
        self.settingsStatusField.stringValue = error.localizedDescription ?: @"Could not save settings.";
        self.settingsStatusField.textColor = [NSColor systemRedColor];
        return;
    }
    [[NSFileManager defaultManager] setAttributes:@{NSFilePosixPermissions: @0600} ofItemAtPath:[self linkPath] error:NULL];
    self.settingsStatusField.stringValue = @"Configuration saved.";
    self.settingsStatusField.textColor = [NSColor systemGreenColor];
    [self updateConfigurationLabels];
    [self.settingsWindow orderOut:nil];

    if (self.isTransitioning) return;
    if (self.isConnected) [self disconnect];
    [self setWantsConnection:YES];
    [self connectAutomatically:NO announce:YES];
}

- (void)updateConfigurationLabels {
    BOOL hasConfiguration = [self savedLink].length > 0;
    NSString *title = hasConfiguration ? @"Change VPN Configuration" : @"Add VPN Configuration";
    self.configurationMenuItem.title = [title stringByAppendingString:@"..."];
    self.settingsWindow.title = title;
    self.configurationHeadingField.stringValue = title;
    self.configurationSaveButton.title = hasConfiguration ? @"Save Configuration" : @"Add Configuration";
}

- (void)cancelSettings:(id)sender {
    [self.settingsWindow orderOut:nil];
}

- (NSString *)bundledLink {
    NSString *path = [[NSBundle mainBundle] pathForResource:@"default" ofType:@"vless"];
    NSString *link = path ? [NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding error:NULL] : nil;
    link = [link stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    return link.length > 0 ? link : nil;
}

- (NSString *)savedLink {
    NSData *data = [NSData dataWithContentsOfFile:[self linkPath]];
    if (data) return [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];

    NSString *bundled = [self bundledLink];
    if (bundled) return bundled;

    NSData *configData = [NSData dataWithContentsOfFile:[self configPath]];
    NSDictionary *config = configData ? [NSJSONSerialization JSONObjectWithData:configData options:0 error:NULL] : nil;
    NSArray *outbounds = [config[@"outbounds"] isKindOfClass:[NSArray class]] ? config[@"outbounds"] : nil;
    NSDictionary *outbound = outbounds.count > 0 ? outbounds[0] : nil;
    NSArray *vnextList = [outbound[@"settings"][@"vnext"] isKindOfClass:[NSArray class]] ? outbound[@"settings"][@"vnext"] : nil;
    NSDictionary *vnext = vnextList.count > 0 ? vnextList[0] : nil;
    NSArray *users = [vnext[@"users"] isKindOfClass:[NSArray class]] ? vnext[@"users"] : nil;
    NSDictionary *user = users.count > 0 ? users[0] : nil;
    NSDictionary *stream = outbound[@"streamSettings"];
    NSDictionary *reality = stream[@"realitySettings"];
    if (!vnext || !user || !reality) return nil;

    NSURLComponents *components = [[NSURLComponents alloc] init];
    components.scheme = @"vless";
    components.user = user[@"id"];
    components.host = vnext[@"address"];
    components.port = vnext[@"port"];
    components.queryItems = @[
        [NSURLQueryItem queryItemWithName:@"encryption" value:@"none"],
        [NSURLQueryItem queryItemWithName:@"flow" value:user[@"flow"] ?: @""],
        [NSURLQueryItem queryItemWithName:@"security" value:@"reality"],
        [NSURLQueryItem queryItemWithName:@"sni" value:reality[@"serverName"] ?: @""],
        [NSURLQueryItem queryItemWithName:@"fp" value:reality[@"fingerprint"] ?: @"chrome"],
        [NSURLQueryItem queryItemWithName:@"pbk" value:reality[@"publicKey"] ?: @""],
        [NSURLQueryItem queryItemWithName:@"sid" value:reality[@"shortId"] ?: @""],
        [NSURLQueryItem queryItemWithName:@"type" value:stream[@"network"] ?: @"tcp"]
    ];
    return components.string;
}

- (void)showError:(NSString *)message detail:(NSString *)detail {
    NSAlert *alert = [[NSAlert alloc] init];
    alert.messageText = message;
    alert.informativeText = detail ?: @"";
    [alert addButtonWithTitle:@"OK"];
    [alert runModal];
}

- (void)showConnectionFailure:(NSString *)detail {
    NSAlert *alert = [[NSAlert alloc] init];
    alert.messageText = @"DongVPN could not connect";
    alert.informativeText = [NSString stringWithFormat:@"%@\n\nPlease email simondong0919@gmail.com for help.", detail ?: @"The tunnel did not return a public IP address."];
    [alert addButtonWithTitle:@"Email Support"];
    [alert addButtonWithTitle:@"OK"];
    if ([alert runModal] == NSAlertFirstButtonReturn) {
        NSURLComponents *mail = [[NSURLComponents alloc] init];
        mail.scheme = @"mailto";
        mail.path = @"simondong0919@gmail.com";
        mail.queryItems = @[
            [NSURLQueryItem queryItemWithName:@"subject" value:@"DongVPN connection help"],
            [NSURLQueryItem queryItemWithName:@"body" value:[NSString stringWithFormat:@"DongVPN could not connect or verify the VPN connection.\n\n%@", detail ?: @"No public IP response was received."]]
        ];
        if (mail.URL) [[NSWorkspace sharedWorkspace] openURL:mail.URL];
    }
}

- (NSString *)appSupportPath {
    NSString *path = [NSHomeDirectory() stringByAppendingPathComponent:@"Library/Application Support/XrayVPN"];
    [[NSFileManager defaultManager] createDirectoryAtPath:path withIntermediateDirectories:YES attributes:nil error:NULL];
    [[NSFileManager defaultManager] setAttributes:@{NSFilePosixPermissions: @0700} ofItemAtPath:path error:NULL];
    return path;
}

- (NSString *)configPath {
    return [[self appSupportPath] stringByAppendingPathComponent:@"config.json"];
}

- (NSString *)linkPath {
    return [[self appSupportPath] stringByAppendingPathComponent:@"connection.vless"];
}

- (NSString *)proxyBackupPath {
    return [[self appSupportPath] stringByAppendingPathComponent:@"proxy-backup.json"];
}

- (NSString *)xrayPath {
    return [[self appSupportPath] stringByAppendingPathComponent:@"xray"];
}

- (IBAction)quitApp:(id)sender {
    [NSApp terminate:nil];
}

@end
