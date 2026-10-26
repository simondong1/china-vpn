#import <Cocoa/Cocoa.h>

@interface AppDelegate : NSObject <NSApplicationDelegate>

- (IBAction)toggleConnection:(id)sender;
- (IBAction)showConfigurationPrompt:(id)sender;
- (IBAction)quitApp:(id)sender;

@end
