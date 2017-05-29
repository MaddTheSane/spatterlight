/*
 * Application -- the main application controller
 */

#import "main.h"

#ifdef DEBUG
#define NSLog(FORMAT, ...) fprintf(stderr,"%s\n", [[NSString stringWithFormat:FORMAT, ##__VA_ARGS__] UTF8String]);
#else
#define NSLog(...)
#endif

@implementation AppDelegate

NSArray *gGameFileTypes;
NSDictionary *gExtMap;
NSDictionary *gFormatMap;

- (void) awakeFromNib
{
    NSLog(@"appdel: awakeFromNib");
    
    gGameFileTypes = [[NSArray alloc] initWithObjects:
	@"d$$", @"dat", @"sna",
	@"advsys", @"quill",
	@"l9", @"mag", @"a3c", @"acd", @"agx", @"gam", @"t3", @"hex", @"taf",
	@"z3", @"z4", @"z5", @"z7", @"z8", @"ulx",
	@"blb", @"blorb", @"glb", @"gblorb", @"zlb", @"zblorb",
	nil];
    
    gExtMap = [[NSDictionary alloc] initWithObjectsAndKeys:
	@"alan2", @"acd",
	@"alan3", @"a3c",
	@"agility", @"d$$",
	NULL];
    
    gFormatMap = [[NSDictionary alloc] initWithObjectsAndKeys:
	@"scare",	@"adrift",
	@"advsys",	@"advsys",
	@"agility",	@"agt",
	@"glulxe",      @"glulx",
	@"hugo",	@"hugo",
	@"level9",	@"level9",
	@"magnetic",	@"magscrolls",
	@"unquill",     @"quill",
	@"tadsr",	@"tads2",
	@"tadsr",	@"tads3",
	@"frotz",	@"zcode",
	NULL];
    
    prefctl = [[Preferences alloc] initWithWindowNibName: @"PrefsWindow"];
    libctl = [[LibController alloc] initWithWindowNibName: @"LibraryWindow"];
    [libctl loadLibrary];
 }

- (void) dealloc
{
    NSLog(@"appdel: dealloc");
    [libctl release];
    [prefctl release];
    [super dealloc];
}

- (IBAction) showPrefs: (id)sender
{
    NSLog(@"appdel: showPrefs");
    [prefctl showWindow: nil];
}

- (IBAction) showLibrary: (id)sender
{
    NSLog(@"appdel: showLibrary");
    [libctl showWindow: nil];
}

- (IBAction) showHelpFile: (id)sender
{
    NSLog(@"appdel: showHelpFile('%@')", [sender title]);
    id title = [sender title];
    id pathname = [[NSBundle mainBundle] resourcePath];
    id filename = [NSString stringWithFormat: @"%@/docs/%@.rtf", pathname, title];
    [[NSWorkspace sharedWorkspace] openFile: filename];
}

/*
 * Forward some menu commands to libctl even if its window is closed.
 */

- (IBAction) addGamesToLibrary: (id)sender
{
    [libctl showWindow: sender];
    [libctl addGamesToLibrary: sender];
}

- (IBAction) importMetadata: (id)sender
{
    [libctl showWindow: sender];
    [libctl importMetadata: sender];
}

- (IBAction) exportMetadata: (id)sender
{
    [libctl showWindow: sender];
    [libctl exportMetadata: sender];
}

- (IBAction) deleteLibrary: (id)sender
{
    [libctl deleteLibrary: sender];
}

/*
 * Open and play game directly.
 */

- (IBAction) openDocument: (id)sender
{
    NSLog(@"appdel: openDocument");
    
    NSURL *directory = [NSURL fileURLWithPath:[[NSUserDefaults standardUserDefaults] objectForKey: @"GameDirectory"] isDirectory:YES];
    NSOpenPanel *panel;

    if (filePanel)
    {
	[filePanel makeKeyAndOrderFront: nil];
    }
    else
    {
        panel = [[NSOpenPanel openPanel] retain];

        panel.allowedFileTypes = gGameFileTypes;
        panel.directoryURL = directory;
        NSLog(@"directory = %@", directory);
        [panel beginWithCompletionHandler:^(NSInteger result){
            if (result == NSFileHandlingPanelOKButton) {
                NSURL*  theDoc = [[panel URLs] objectAtIndex:0];
                {
                    NSString *pathString = [[theDoc path] stringByDeletingLastPathComponent];
                    NSLog(@"directory = %@", directory);
                    if ([[[theDoc path] pathExtension] isEqualToString: @"sav"])
                        [[NSUserDefaults standardUserDefaults] setObject: pathString forKey: @"SaveDirectory"];
                    else
                        [[NSUserDefaults standardUserDefaults] setObject: pathString forKey: @"GameDirectory"];

                    [self application: NSApp openFile: [theDoc path]];
                }
            }
        }];
    }
    filePanel = nil;
}

- (BOOL) application: (NSApplication*)theApp openFile: (NSString *)path
{
    NSLog(@"appdel: openFile '%@'", path);
    
    if ([[[path pathExtension] lowercaseString] isEqualToString: @"ifiction"])
    {
	[libctl importMetadataFromFile: path];
    }
    else
    {
	[libctl importAndPlayGame: path];
    }
    
    return YES;
}

- (BOOL) applicationOpenUntitledFile: (NSApplication*)theApp
{
    NSLog(@"appdel: applicationOpenUntitledFile");
    [self showLibrary: nil];
    return YES;
}

- (NSApplicationTerminateReply) applicationShouldTerminate: (NSApplication *)app
{
    NSArray *windows = [app windows];
    int count = [windows count];
    int alive = 0;
    
    NSLog(@"appdel: applicationShouldTerminate");
    
    while (count--)
    {
        NSWindow *window = [windows objectAtIndex: count];
	id glkctl = [window delegate];
	if ([glkctl isKindOfClass: [GlkController class]] && [glkctl isAlive])
	    alive ++;
    }
    
    NSLog(@"appdel: windows=%d alive=%d", [windows count], alive);
    
    if (alive > 0)
    {
	NSString *msg = @"You still have one game running.\nAny unsaved progress will be lost.";
	if (alive > 1)
	    msg = [NSString stringWithFormat: @"You have %d games running.\nAny unsaved progress will be lost.", alive];
	int choice = NSRunAlertPanel(@"Do you really want to quit?", msg, @"Quit", NULL, @"Cancel");
	if (choice == NSAlertOtherReturn)
	    return NSTerminateCancel;
    }
    
    return NSTerminateNow;
}

- (void) applicationWillTerminate: (NSNotification*)notification
{
    [libctl saveLibrary:self];
}

@end
