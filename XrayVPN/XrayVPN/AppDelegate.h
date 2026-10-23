#import <Cocoa/Cocoa.h>

@interface AppDelegate : NSObject <NSApplicationDelegate>

@property (weak) IBOutlet NSMenu *statusMenu;
@property (strong, nonatomic) NSStatusItem *statusItem;

- (IBAction)toggleConnection:(id)sender;
- (IBAction)showSettings:(id)sender;
- (IBAction)quitApp:(id)sender;

@end
