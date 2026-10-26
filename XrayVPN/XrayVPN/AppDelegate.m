#import "AppDelegate.h"
#import <arpa/inet.h>
#import <sys/utsname.h>

static NSString * const kXrayVersion = @"v26.10.21";
static NSInteger const kSocksPort = 10808;

@interface AppDelegate ()
@property (nonatomic, strong) NSStatusItem *statusBarItem;
@property (nonatomic, strong) NSMenuItem *statusMenuItem;
@property (nonatomic, strong) NSMenuItem *toggleMenuItem;
@property (nonatomic, strong) NSMenuItem *configurationMenuItem;
@property (nonatomic, strong) NSTask *xrayTask;
@property (nonatomic, strong) NSWindow *settingsWindow;
@property (nonatomic, strong) NSTextField *linkField;
@property (nonatomic, strong) NSTextField *configurationHeadingField;
@property (nonatomic, strong) NSButton *configurationSaveButton;
@property (nonatomic, strong) NSTextField *settingsStatusField;
@property (nonatomic, strong) NSMutableDictionary<NSString *, NSDictionary *> *proxyBackups;
@property (nonatomic, copy) NSString *publicIP;
@property (nonatomic, assign) BOOL isConnected;
@property (nonatomic, assign) BOOL isTransitioning;
- (void)updateConfigurationLabels;
@end

@implementation AppDelegate

- (void)applicationDidFinishLaunching:(NSNotification *)notification {
    self.proxyBackups = [NSMutableDictionary dictionary];
    self.statusBarItem = [[NSStatusBar systemStatusBar] statusItemWithLength:NSVariableStatusItemLength];
    self.statusBarItem.button.image = [self statusImageConnected:NO];
    self.statusBarItem.button.image.template = YES;
    self.statusBarItem.button.toolTip = @"DongVPN";

    NSMenu *menu = [[NSMenu alloc] initWithTitle:@"DongVPN"];
    self.statusMenuItem = [menu addItemWithTitle:@"Disconnected" action:nil keyEquivalent:@""];
    self.statusMenuItem.enabled = NO;
    [menu addItem:[NSMenuItem separatorItem]];

    self.toggleMenuItem = [menu addItemWithTitle:@"Connect" action:@selector(toggleConnection:) keyEquivalent:@""];
    self.toggleMenuItem.target = self;
    [menu addItem:[NSMenuItem separatorItem]];

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

    if ([self savedLink].length == 0) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self showConfigurationPrompt:nil];
        });
    }
}

- (void)applicationWillTerminate:(NSNotification *)notification {
    [self disconnectSilently];
}

- (IBAction)toggleConnection:(id)sender {
    if (self.isTransitioning) return;
    self.isConnected ? [self disconnect] : [self connect];
}

- (void)connect {
    self.isTransitioning = YES;
    [self updateStatusTitle:@"Connecting..." connected:NO];

    NSError *error = nil;
    NSString *link = [self savedLink];
    NSDictionary *connection = [self connectionFromVLESSLink:link error:&error];
    if (!connection) {
        self.isTransitioning = NO;
        [self updateStatusTitle:@"Disconnected" connected:NO];
        [self showError:@"VPN configuration is missing or invalid." detail:error.localizedDescription ?: @"Choose VPN Configuration from the DongVPN menu."];
        return;
    }

    if (![self writeXrayConfigForConnection:connection error:&error]) {
        self.isTransitioning = NO;
        [self updateStatusTitle:@"Disconnected" connected:NO];
        [self showError:@"Could not prepare Xray." detail:error.localizedDescription];
        return;
    }
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSError *backgroundError = nil;
        BOOL ready = [self ensureXrayInstalled:&backgroundError] && [self startXray:&backgroundError];
        NSString *verifiedIP = nil;
        if (ready) ready = [self verifyTunnelAndGetPublicIP:&verifiedIP error:&backgroundError];
        dispatch_async(dispatch_get_main_queue(), ^{
            if (!ready) {
                [self stopXray];
                self.isTransitioning = NO;
                [self updateStatusTitle:@"Disconnected" connected:NO];
                [self showConnectionFailure:backgroundError.localizedDescription];
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
            [self updateStatusTitle:[NSString stringWithFormat:@"Connected - %@", verifiedIP] connected:YES];
        });
    });
}

- (void)disconnect {
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
    NSDictionary *config = @{
        @"log": @{ @"loglevel": @"warning" },
        @"inbounds": @[@{
            @"listen": @"127.0.0.1", @"port": @(kSocksPort), @"protocol": @"socks",
            @"settings": @{ @"udp": @YES }
        }],
        @"outbounds": @[@{
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
        }]
    };
    NSData *data = [NSJSONSerialization dataWithJSONObject:config options:NSJSONWritingPrettyPrinted error:error];
    BOOL written = data && [data writeToFile:[self configPath] options:NSDataWritingAtomic error:error];
    if (written) [[NSFileManager defaultManager] setAttributes:@{NSFilePosixPermissions: @0600} ofItemAtPath:[self configPath] error:NULL];
    return written;
}

- (BOOL)ensureXrayInstalled:(NSError **)error {
    NSString *xrayPath = [self xrayPath];
    if ([[NSFileManager defaultManager] isExecutableFileAtPath:xrayPath]) return YES;

    struct utsname systemInfo;
    uname(&systemInfo);
    NSString *machine = [NSString stringWithUTF8String:systemInfo.machine] ?: @"x86_64";
    BOOL isAppleSilicon = [machine isEqualToString:@"arm64"];
    NSString *resourceName = isAppleSilicon ? @"xray-arm64" : @"xray-x86_64";
    NSString *bundledPath = [[[NSBundle mainBundle] resourcePath] stringByAppendingPathComponent:resourceName];
    if ([[NSFileManager defaultManager] isExecutableFileAtPath:bundledPath]) {
        if (![[NSFileManager defaultManager] copyItemAtPath:bundledPath toPath:xrayPath error:error]) return NO;
        for (NSString *dataFile in @[@"geoip.dat", @"geosite.dat"]) {
            NSString *source = [[[NSBundle mainBundle] resourcePath] stringByAppendingPathComponent:dataFile];
            NSString *destination = [[self appSupportPath] stringByAppendingPathComponent:dataFile];
            if ([[NSFileManager defaultManager] fileExistsAtPath:source] && ![[NSFileManager defaultManager] fileExistsAtPath:destination]) {
                [[NSFileManager defaultManager] copyItemAtPath:source toPath:destination error:NULL];
            }
        }
        return [[NSFileManager defaultManager] setAttributes:@{NSFilePosixPermissions: @0755} ofItemAtPath:xrayPath error:error];
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
            if (!strongSelf || strongSelf.isTransitioning || !strongSelf.isConnected) return;
            strongSelf.isConnected = NO;
            strongSelf.publicIP = nil;
            [strongSelf restoreSystemProxy:NULL];
            [strongSelf updateStatusTitle:@"Disconnected" connected:NO];
            [strongSelf showError:@"Xray stopped unexpectedly." detail:@"The macOS proxy was restored."];
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
    NSTask *task = [self taskWithLaunchPath:@"/usr/bin/curl" arguments:@[
        @"--fail", @"--silent", @"--show-error",
        @"--connect-timeout", @"8", @"--max-time", @"20",
        @"--socks5-hostname", [NSString stringWithFormat:@"127.0.0.1:%ld", (long)kSocksPort],
        @"https://api.ipify.org"
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
    NSMutableArray<NSString *> *commands = [NSMutableArray array];
    for (NSString *service in services) {
        NSDictionary *backup = [self socksProxySettingsForService:service];
        if (!backup) continue;
        self.proxyBackups[service] = backup;
        [commands addObject:[NSString stringWithFormat:@"/usr/sbin/networksetup -setsocksfirewallproxy %@ 127.0.0.1 %ld", [self shellQuote:service], (long)kSocksPort]];
        [commands addObject:[NSString stringWithFormat:@"/usr/sbin/networksetup -setsocksfirewallproxystate %@ on", [self shellQuote:service]]];
    }
    NSData *backupData = [NSJSONSerialization dataWithJSONObject:self.proxyBackups options:0 error:error];
    if (!backupData || ![backupData writeToFile:[self proxyBackupPath] options:NSDataWritingAtomic error:error]) {
        [self.proxyBackups removeAllObjects];
        return NO;
    }
    if (commands.count == 0 || ![self runAdminCommands:commands error:error]) {
        [self restoreSystemProxy:NULL];
        return NO;
    }
    return YES;
}

- (BOOL)restoreSystemProxy:(NSError **)error {
    NSMutableArray<NSString *> *commands = [NSMutableArray array];
    [self.proxyBackups enumerateKeysAndObjectsUsingBlock:^(NSString *service, NSDictionary *backup, BOOL *stop) {
        NSString *server = backup[@"server"];
        NSString *port = backup[@"port"];
        if (server.length > 0 && port.length > 0) {
            [commands addObject:[NSString stringWithFormat:@"/usr/sbin/networksetup -setsocksfirewallproxy %@ %@ %@", [self shellQuote:service], [self shellQuote:server], [self shellQuote:port]]];
        }
        NSString *state = [backup[@"enabled"] boolValue] ? @"on" : @"off";
        [commands addObject:[NSString stringWithFormat:@"/usr/sbin/networksetup -setsocksfirewallproxystate %@ %@", [self shellQuote:service], state]];
    }];
    BOOL success = commands.count == 0 || [self runAdminCommands:commands error:error];
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

- (NSString *)savedLink {
    NSData *data = [NSData dataWithContentsOfFile:[self linkPath]];
    if (data) return [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];

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
