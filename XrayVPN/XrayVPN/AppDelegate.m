#import "AppDelegate.h"
#import <SystemConfiguration/SystemConfiguration.h>

@interface AppDelegate ()
@property (nonatomic, strong) NSTask *xrayTask;
@property (nonatomic, assign) BOOL isConnected;
@property (nonatomic, strong) NSMenuItem *toggleItem;
@property (nonatomic, strong) NSMenuItem *statusItem;
@end

@implementation AppDelegate

- (void)applicationDidFinishLaunching:(NSNotification *)aNotification {
    self.isConnected = NO;

    // Create status bar item
    self.statusItem = [[NSStatusBar systemStatusBar] statusItemWithLength:NSVariableStatusItemLength];
    self.statusItem.button.image = [NSImage imageNamed:@"NSNetwork"];
    self.statusItem.button.image.size = NSMakeSize(18, 18);

    // Create menu
    NSMenu *menu = [[NSMenu alloc] init];

    self.statusItem = [menu addItemWithTitle:@"Disconnected" action:nil keyEquivalent:@""];
    self.statusItem.enabled = NO;

    [menu addItem:[NSMenuItem separatorItem]];

    self.toggleItem = [menu addItemWithTitle:@"Connect" action:@selector(toggleConnection:) keyEquivalent:@""];
    self.toggleItem.target = self;

    [menu addItem:[NSMenuItem separatorItem]];

    NSMenuItem *settingsItem = [menu addItemWithTitle:@"Settings..." action:@selector(showSettings:) keyEquivalent:@","];
    settingsItem.target = self;

    [menu addItem:[NSMenuItem separatorItem]];

    NSMenuItem *quitItem = [menu addItemWithTitle:@"Quit" action:@selector(quitApp:) keyEquivalent:@"q"];
    quitItem.target = self;

    self.statusItem.menu = menu;
}

- (void)applicationWillTerminate:(NSNotification *)aNotification {
    if (self.isConnected) {
        [self stopXray];
        [self disableSystemProxy];
    }
}

- (IBAction)toggleConnection:(id)sender {
    if (self.isConnected) {
        [self disconnect];
    } else {
        [self connect];
    }
}

- (void)connect {
    // Check if config exists
    NSString *configPath = [self configPath];
    if (![[NSFileManager defaultManager] fileExistsAtPath:configPath]) {
        NSAlert *alert = [[NSAlert alloc] init];
        alert.messageText = @"No Configuration";
        alert.informativeText = @"Please configure your VPN server in Settings first.";
        [alert addButtonWithTitle:@"OK"];
        [alert runModal];
        return;
    }

    // Ensure Xray is installed
    [self ensureXrayInstalled];

    // Start Xray
    if ([self startXray]) {
        [self enableSystemProxy];
        self.isConnected = YES;
        self.statusItem.title = @"Connected";
        self.toggleItem.title = @"Disconnect";
        self.statusItem.button.image = [NSImage imageNamed:@"NSStatusAvailable"];
        self.statusItem.button.image.size = NSMakeSize(18, 18);
    }
}

- (void)disconnect {
    [self stopXray];
    [self disableSystemProxy];
    self.isConnected = NO;
    self.statusItem.title = @"Disconnected";
    self.toggleItem.title = @"Connect";
    self.statusItem.button.image = [NSImage imageNamed:@"NSNetwork"];
    self.statusItem.button.image.size = NSMakeSize(18, 18);
}

- (BOOL)startXray {
    NSString *xrayPath = [[self appSupportPath] stringByAppendingPathComponent:@"xray"];
    NSString *configPath = [self configPath];

    self.xrayTask = [[NSTask alloc] init];
    [self.xrayTask setLaunchPath:xrayPath];
    [self.xrayTask setArguments:@[@"run", @"-c", configPath]];

    @try {
        [self.xrayTask launch];
        sleep(1); // Give it time to start
        return YES;
    } @catch (NSException *exception) {
        NSLog(@"Failed to start Xray: %@", exception);
        return NO;
    }
}

- (void)stopXray {
    if (self.xrayTask && [self.xrayTask isRunning]) {
        [self.xrayTask terminate];
        self.xrayTask = nil;
    }
}

- (void)ensureXrayInstalled {
    NSString *xrayPath = [[self appSupportPath] stringByAppendingPathComponent:@"xray"];

    if ([[NSFileManager defaultManager] fileExistsAtPath:xrayPath]) {
        return;
    }

    // Download Xray
    NSString *arch = @"amd64";
    if ([[NSProcessInfo processInfo] isOperatingSystemAtLeastVersion:(NSOperatingSystemVersion){12, 0, 0}]) {
        struct utsname systemInfo;
        uname(&systemInfo);
        NSString *machine = [NSString stringWithCString:systemInfo.machine encoding:NSUTF8StringEncoding];
        if ([machine isEqualToString:@"arm64"]) {
            arch = @"arm64-v8a";
        }
    }

    NSString *downloadURL = [NSString stringWithFormat:@"https://github.com/XTLS/Xray-core/releases/download/v1.8.7/Xray-darwin-%@.zip", arch];
    NSString *zipPath = @"/tmp/xray.zip";

    // Use curl to download
    NSTask *downloadTask = [[NSTask alloc] init];
    [downloadTask setLaunchPath:@"/usr/bin/curl"];
    [downloadTask setArguments:@[@"-L", @"-o", zipPath, downloadURL]];
    [downloadTask launch];
    [downloadTask waitUntilExit];

    // Extract
    NSTask *unzipTask = [[NSTask alloc] init];
    [unzipTask setLaunchPath:@"/usr/bin/unzip"];
    [unzipTask setArguments:@[@"-o", zipPath, @"-d", [self appSupportPath]]];
    [unzipTask launch];
    [unzipTask waitUntilExit];

    // Make executable
    [[NSFileManager defaultManager] setAttributes:@{NSFilePosixPermissions: @0755} ofItemAtPath:xrayPath error:nil];

    // Clean up
    [[NSFileManager defaultManager] removeItemAtPath:zipPath error:nil];
}

- (void)enableSystemProxy {
    NSString *script = @"networksetup -setsocksfirewallproxy \"Wi-Fi\" 127.0.0.1 10808 && networksetup -setsocksfirewallproxystate \"Wi-Fi\" on";
    [self runScriptWithAdminPrivileges:script];
}

- (void)disableSystemProxy {
    NSString *script = @"networksetup -setsocksfirewallproxystate \"Wi-Fi\" off";
    [self runScriptWithAdminPrivileges:script];
}

- (void)runScriptWithAdminPrivileges:(NSString *)script {
    NSString *appleScript = [NSString stringWithFormat:@"do shell script \"%@\" with administrator privileges", script];
    NSAppleScript *scriptObject = [[NSAppleScript alloc] initWithSource:appleScript];
    NSDictionary *errorDict = nil;
    [scriptObject executeAndReturnError:&errorDict];
    if (errorDict) {
        NSLog(@"Script error: %@", errorDict);
    }
}

- (IBAction)showSettings:(id)sender {
    // Open settings window with text field for vless:// link
    NSAlert *alert = [[NSAlert alloc] init];
    alert.messageText = @"VPN Settings";
    alert.informativeText = @"Paste your vless:// connection link:";
    [alert addButtonWithTitle:@"Save"];
    [alert addButtonWithTitle:@"Cancel"];

    NSTextField *input = [[NSTextField alloc] initWithFrame:NSMakeRect(0, 0, 400, 24)];

    // Load existing config if available
    NSString *configPath = [self configPath];
    if ([[NSFileManager defaultManager] fileExistsAtPath:configPath]) {
        NSData *data = [NSData dataWithContentsOfFile:configPath];
        NSDictionary *config = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
        if (config) {
            NSString *link = [self vlessLinkFromConfig:config];
            [input setStringValue:link];
        }
    }

    [alert setAccessoryView:input];
    [[alert window] setInitialFirstResponder:input];

    if ([alert runModal] == NSAlertFirstButtonReturn) {
        NSString *vlessLink = [input stringValue];
        if ([self saveVlessLink:vlessLink]) {
            NSAlert *success = [[NSAlert alloc] init];
            success.messageText = @"Configuration saved successfully";
            [success runModal];
        }
    }
}

- (BOOL)saveVlessLink:(NSString *)link {
    if (![link hasPrefix:@"vless://"]) {
        NSAlert *error = [[NSAlert alloc] init];
        error.messageText = @"Invalid link";
        error.informativeText = @"Please enter a valid vless:// link";
        [error runModal];
        return NO;
    }

    // Parse vless link
    NSString *cleaned = [link substringFromIndex:8]; // Remove "vless://"
    NSArray *parts = [cleaned componentsSeparatedByString:@"@"];
    if (parts.count < 2) return NO;

    NSString *uuid = parts[0];
    NSString *rest = parts[1];

    NSArray *hostAndQuery = [rest componentsSeparatedByString:@"?"];
    NSString *hostPort = hostAndQuery[0];
    NSString *query = hostAndQuery.count > 1 ? hostAndQuery[1] : @"";

    NSArray *hostComponents = [hostPort componentsSeparatedByString:@":"];
    NSString *server = hostComponents[0];
    NSString *port = hostComponents.count > 1 ? [[hostComponents[1] componentsSeparatedByString:@"#"][0] : @"443"] : @"443";

    // Parse query parameters
    NSMutableDictionary *params = [NSMutableDictionary dictionary];
    for (NSString *param in [query componentsSeparatedByString:@"&"]) {
        NSArray *kv = [param componentsSeparatedByString:@"="];
        if (kv.count == 2) {
            params[kv[0]] = [kv[1] stringByRemovingPercentEncoding];
        }
    }

    // Generate Xray config
    NSDictionary *config = @{
        @"log": @{@"loglevel": @"warning"},
        @"inbounds": @[@{
            @"listen": @"127.0.0.1",
            @"port": @10808,
            @"protocol": @"socks",
            @"settings": @{@"udp": @YES}
        }],
        @"outbounds": @[@{
            @"protocol": @"vless",
            @"settings": @{
                @"vnext": @[@{
                    @"address": server,
                    @"port": [port intValue],
                    @"users": @[@{
                        @"id": uuid,
                        @"encryption": @"none",
                        @"flow": @"xtls-rprx-vision"
                    }]
                }]
            },
            @"streamSettings": @{
                @"network": @"tcp",
                @"security": @"reality",
                @"realitySettings": @{
                    @"serverName": params[@"sni"] ?: @"",
                    @"fingerprint": @"chrome",
                    @"publicKey": params[@"pbk"] ?: @"",
                    @"shortId": params[@"sid"] ?: @""
                }
            }
        }]
    };

    // Save to file
    NSData *jsonData = [NSJSONSerialization dataWithJSONObject:config options:NSJSONWritingPrettyPrinted error:nil];
    return [jsonData writeToFile:[self configPath] atomically:YES];
}

- (NSString *)vlessLinkFromConfig:(NSDictionary *)config {
    // Reconstruct vless link from config (for display purposes)
    NSDictionary *outbound = config[@"outbounds"][0];
    NSDictionary *vnext = outbound[@"settings"][@"vnext"][0];
    NSDictionary *user = vnext[@"users"][0];
    NSDictionary *reality = outbound[@"streamSettings"][@"realitySettings"];

    return [NSString stringWithFormat:@"vless://%@@%@:%@?security=reality&sni=%@&pbk=%@&sid=%@",
            user[@"id"],
            vnext[@"address"],
            vnext[@"port"],
            reality[@"serverName"],
            reality[@"publicKey"],
            reality[@"shortId"]];
}

- (IBAction)quitApp:(id)sender {
    [NSApp terminate:nil];
}

- (NSString *)appSupportPath {
    NSString *path = [NSHomeDirectory() stringByAppendingPathComponent:@"Library/Application Support/XrayVPN"];
    [[NSFileManager defaultManager] createDirectoryAtPath:path withIntermediateDirectories:YES attributes:nil error:nil];
    return path;
}

- (NSString *)configPath {
    return [[self appSupportPath] stringByAppendingPathComponent:@"config.json"];
}

@end
