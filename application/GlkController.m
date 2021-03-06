#import "main.h"
#import "InfoController.h"

#include <sys/time.h>

#ifdef DEBUG
#define NSLog(FORMAT, ...) fprintf(stderr,"%s\n", [[NSString stringWithFormat:FORMAT, ##__VA_ARGS__] UTF8String])
#else
#define NSLog(...)
#endif

#define MINTIMER 5 /* Transparent wants this */

static const char *msgnames[] =
{
    "NOREPLY",
    "OKAY", "ERROR", "HELLO", "PROMPTOPEN", "PROMPTSAVE",
    "NEWWIN", "DELWIN", "SIZWIN", "CLRWIN",
    "MOVETO", "PRINT",
    "MAKETRANSPARENT", "STYLEHINT", "CLEARHINT", "STYLEMEASURE", "SETBGND", "SETTITLE",
    "TIMER", "INITCHAR", "CANCELCHAR", "INITLINE", "CANCELLINE", "SETECHO", "TERMINATORS", "INITMOUSE", "CANCELMOUSE",
    "FILLRECT", "FINDIMAGE", "LOADIMAGE", "SIZEIMAGE",
    "DRAWIMAGE", "FLOWBREAK", "NEWCHAN", "DELCHAN",
    "FINDSOUND", "LOADSOUND", "SETVOLUME", "PLAYSOUND", "STOPSOUND",
    "SETLINK", "INITLINK", "CANCELLINK", "EVTHYPER",
    "NEXTEVENT", "EVTARRANGE", "EVTLINE", "EVTKEY",
    "EVTMOUSE", "EVTTIMER", "EVTSOUND", "EVTVOLUME", "EVTPREFS"
};

@implementation GlkHelperView

- (BOOL) isFlipped
{
    return YES;
}

- (BOOL) isOpaque
{
    return YES;
}

- (void) drawRect: (NSRect)rect
{
    [[NSColor whiteColor] set];
    NSRectFill(rect);
}

- (void) setFrame: (NSRect)frame
{
    [super setFrame: frame];
    if (![self inLiveResize])
        [delegate contentDidResize: frame];
}

- (void) viewDidEndLiveResize
{
    [delegate contentDidResize: [self frame]];
}

@end

@implementation GlkController

/*
 * This is the real initializer.
 */

#pragma mark Initialization

- (void) runTerp: (NSString*)terpname
    withGameFile: (NSString*)gamefile_
            IFID: (NSString*)gameifid_
            info: (NSDictionary*)gameinfo_
{
    NSLog(@"glkctl: runterp %@ %@", terpname, gamefile_);

    NSSize defsize = [Preferences defaultWindowSize];

    gamefile = gamefile_;
    gameifid = gameifid_;
    gameinfo = gameinfo_;

    /* Setup our own stuff */
    {
        queue = [[NSMutableArray alloc] init];

        waitforevent = NO;
        waitforfilename = NO;
        dead = NO;

        windowdirty = NO;

        lastimageresno = -1;
        lastsoundresno = -1;
        lastimage = nil;
        lastsound = nil;
    }

    /* Setup Cocoa stuff */
    {
        [[self window] setRepresentedFilename: gamefile];
        [[self window] setTitle: gameinfo[@"title"]];
        [[self window] setContentSize: defsize];

        // Clamp to max screen size
        defsize.height = self.window.frame.size.height;
        defsize.width = self.window.frame.size.width;
        [self.window setContentSize: defsize];

        [[NSNotificationCenter defaultCenter]
         addObserver: self
         selector: @selector(notePreferencesChanged:)
		       name: @"PreferencesChanged"
         object: nil];
    }

    /* Fork the interpreter process */
    {
        NSString *terppath;
        NSPipe *readpipe;
        NSPipe *sendpipe;

        terppath = [[NSBundle mainBundle] pathForAuxiliaryExecutable: terpname];
        readpipe = [NSPipe pipe];
        sendpipe = [NSPipe pipe];
        readfh = [readpipe fileHandleForReading];
        sendfh = [sendpipe fileHandleForWriting];

        task = [[NSTask alloc] init];
        [task setCurrentDirectoryPath: NSHomeDirectory()];


        [task setStandardOutput: readpipe];
        [task setStandardInput: sendpipe];

#ifdef TEE_TERP_OUTPUT
        [task setLaunchPath: @"/bin/bash"];

        NSString *cmdline = @" "; //@"\"";
        cmdline = [cmdline stringByAppendingString:terppath];
        cmdline = [cmdline stringByAppendingString:@" \""];
        cmdline = [cmdline stringByAppendingString:gamefile];

        cmdline = [cmdline stringByAppendingString:@"\" | tee -a ~/Desktop/Spatterlight\\ "];

        NSDateFormatter *formatter = [[NSDateFormatter alloc] init];
        [formatter setDateFormat:@"yyyy-MM-dd HH.mm"];
        NSString *stringFromDate = [formatter stringFromDate:[NSDate date]];

        stringFromDate = [stringFromDate stringByReplacingOccurrencesOfString:@" " withString:@"\\ "];
        cmdline = [cmdline stringByAppendingString:stringFromDate];
        cmdline = [cmdline stringByAppendingString:@".txt"];

        [task setArguments: @[ @"-c", cmdline ]];
#else

        [task setLaunchPath: terppath];
        [task setArguments: @[gamefile]];

#endif //TEE_TERP_OUTPUT

        [[NSNotificationCenter defaultCenter]
         addObserver: self
         selector: @selector(noteTaskDidTerminate:)
		       name: NSTaskDidTerminateNotification
         object: task];

        [[NSNotificationCenter defaultCenter]
         addObserver: self
         selector: @selector(noteDataAvailable:)
		       name: NSFileHandleDataAvailableNotification
         object: readfh];

        [task launch];

        [readfh waitForDataInBackgroundAndNotify];
    }

    /* Send a prefs and an arrange event first thing */
    {
        GlkEvent *gevent;

        gevent = [[GlkEvent alloc] initPrefsEvent];
        [self queueEvent: gevent];

        gevent = [[GlkEvent alloc] initArrangeWidth: defsize.width height: defsize.height];
        [self queueEvent: gevent];
    }

	soundNotificationsTimer = [NSTimer scheduledTimerWithTimeInterval: 2.0 target: self selector: @selector(keepAlive:) userInfo: nil repeats: YES];
}

- (void) keepAlive: (NSTimer *)timer
{
	[readfh waitForDataInBackgroundAndNotify];
}

- (void) windowWillClose: (id)sender
{
    NSLog(@"glkctl: windowWillClose");

    [[self window] setDelegate: nil];

    [[NSNotificationCenter defaultCenter] removeObserver: self];

    if (timer)
    {
        NSLog(@"glkctl: force stop the timer");
        [timer invalidate];
        timer = nil;
    }

	if (soundNotificationsTimer)
	{
		NSLog(@"glkctl: force stop the sound notifications timer");
		[soundNotificationsTimer invalidate];
		soundNotificationsTimer = nil;
	}

    if (task)
    {
        NSLog(@"glkctl: force stop the interpreter");
        [task terminate];
        task = nil;
    }
}

/*
 *
 */

#pragma mark Cocoa glue


- (IBAction) showGameInfo: (id)sender
{
    showInfoForFile(gamefile, gameinfo);
}

- (IBAction) revealGameInFinder: (id)sender
{
    [[NSWorkspace sharedWorkspace] selectFile: gamefile inFileViewerRootedAtPath: @""];
}

- (BOOL) isAlive
{
    return !dead;
}

- (id) windowWithNum: (int)index
{
    if (gwindows[index])
        return gwindows[index];
    else
        return nil;
}

- (NSRect) windowWillUseStandardFrame: (NSWindow*)window defaultFrame:(NSRect)defaultFrame
{
    NSLog(@"glkctl: windowWillUseStandardFrame");

    NSRect frame = [window frame];
    defaultFrame.origin.x = frame.origin.x;
    defaultFrame.size.width = frame.size.width;
    return defaultFrame;
}

- (void) contentDidResize: (NSRect)frame
{
    //NSLog(@"glkctl: contentDidResize");

    if (dead)
        for (NSInteger i = 0; i < MAXWIN; i++)
            if (gwindows[i]) // && [gwindows[i] isKindOfClass:[GlkTextBufferWindow class]])
                [gwindows[i] setFrame:frame];

    GlkEvent *gevent;
    gevent = [[GlkEvent alloc] initArrangeWidth: frame.size.width height: frame.size.height];
    [self queueEvent: gevent];
}

- (void) closeAlertDidFinish: (id)alert rc: (int)rc ctx: (void*)ctx
{
    if (rc == NSAlertFirstButtonReturn)
    {
        [self close];
    }
}

- (BOOL) windowShouldClose: (id)sender
{
    NSLog(@"glkctl: windowShouldClose");

    NSAlert *alert;

    if (dead)
        return YES;

    alert = [[NSAlert alloc] init];
    [alert setMessageText: @"Do you want to abandon the game?"];
    [alert setInformativeText: @"Any unsaved progress will be lost."];
    [alert addButtonWithTitle: @"Close"];
    [alert addButtonWithTitle: @"Cancel"];

    [alert beginSheetModalForWindow: [self window]
                      modalDelegate: self
                     didEndSelector: @selector(closeAlertDidFinish:rc:ctx:)
                        contextInfo: NULL];

    return NO;
}

- (void) flushDisplay
{
    int i;

    for (i = 0; i < MAXWIN; i++)
        if (gwindows[i])
            [gwindows[i] flushDisplay];

    if (windowdirty)
    {
        [contentView setNeedsDisplay: YES];
        windowdirty = NO;
    }
}

- (void) guessFocus
{
    id focuswin;
    int i;

//    NSLog(@"glkctl guessFocus");

    focuswin = [[self window] firstResponder];
    while (focuswin)
    {
        if ([focuswin isKindOfClass: [NSView class]])
        {
            if ([focuswin isKindOfClass: [GlkWindow class]])
                break;
            else
                focuswin = [focuswin superview];
        }
        else
            focuswin = nil;
    }

    //if (focuswin)
      //  NSLog(@"window %ld has focus", (long)[(GlkWindow*)focuswin name]);

    if (focuswin && [focuswin wantsFocus])
        return;

    //NSLog(@"glkctl guessing new window to focus on");

    for (i = 0; i < MAXWIN; i++)
    {
        if (gwindows[i] && gwindows[i].wantsFocus)
        {
            [gwindows[i] grabFocus];
            return;
        }
    }
}

- (void) markLastSeen
{
    int i;
    for (i = 0; i < MAXWIN; i++)
        if (gwindows[i])
            [gwindows[i] markLastSeen];
}

- (void) performScroll
{
    int i;
    for (i = 0; i < MAXWIN; i++)
        if (gwindows[i])
            [gwindows[i] performScroll];
}

/*
 *
 */

#pragma mark Preference and style hint glue

- (void) notePreferencesChanged: (id)sender
{
    NSLog(@"glkctl: notePreferencesChanged");
    int i;

    GlkEvent *gevent;

    NSRect frame = [contentView frame];

    gevent = [[GlkEvent alloc] initArrangeWidth: frame.size.width height: frame.size.height];
    [self queueEvent: gevent];

    gevent = [[GlkEvent alloc] initPrefsEvent];
    [self queueEvent: gevent];

    for (i = 0; i < MAXWIN; i++)
        if (gwindows[i])
            [gwindows[i] prefsDidChange];
}


- (void) handleChangeTitle:(char*)buf length: (int)len
{
	NSString *str = [@(buf) substringToIndex: len];

	//    _game.metadata.title = str;
	self.window.title = str;
	NSLog(@"Change title request: %@", str);
}


/*
 *
 */

#pragma mark Glk requests

- (void) handleOpenPrompt: (int)fileusage
{
    NSURL *directory = [NSURL fileURLWithPath:[[NSUserDefaults standardUserDefaults] objectForKey: @"SaveDirectory"] isDirectory:YES];

    NSInteger sendfd = [sendfh fileDescriptor];

    // Create and configure the panel.
    NSOpenPanel* panel = [NSOpenPanel openPanel];

    waitforfilename = YES; /* don't interrupt */

    if (fileusage == fileusage_SavedGame)
        [panel setPrompt: @"Restore"];
    panel.directoryURL = directory;

    // Display the panel attached to the document's window.
    [panel beginSheetModalForWindow:[self window] completionHandler:^(NSInteger result){

        const char *s;
        struct message reply;

        if (result == NSFileHandlingPanelOKButton)
        {
            NSURL*  theDoc = [panel URLs][0];

            [[NSUserDefaults standardUserDefaults] setObject: [[theDoc path] stringByDeletingLastPathComponent] forKey: @"SaveDirectory"];
            s = [theDoc.path UTF8String];
        }
        else
            s = "";

        reply.cmd = OKAY;
        reply.len = (int)strlen(s);

        write((int)sendfd, &reply, sizeof(struct message));
        if (reply.len)
            write((int)sendfd, s, reply.len);
    }];

    waitforfilename = NO; /* we're all done, resume normal processing */

    [readfh waitForDataInBackgroundAndNotify];

}

- (void) handleSavePrompt: (int)fileusage
{
    NSURL *directory = [NSURL fileURLWithPath:[[NSUserDefaults standardUserDefaults] objectForKey: @"SaveDirectory"] isDirectory:YES];
    NSSavePanel *panel = [NSSavePanel savePanel];
    NSString *prompt;
    NSString *ext;
    NSString *filename;
    NSString *date;

    waitforfilename = YES; /* don't interrupt */

    switch (fileusage)
    {
        case fileusage_Data: prompt = @"Save data file: "; ext = @"glkdata"; filename = @"Data"; break;
        case fileusage_SavedGame: prompt = @"Save game: "; ext = @"glksave"; break;
        case fileusage_Transcript: prompt = @"Save transcript: "; ext = @"txt"; filename = @"Transcript of "; break;
        case fileusage_InputRecord: prompt = @"Save recording: "; ext = @"rec"; filename = @"Recordning of "; break;
        default: prompt = @"Save: "; ext = nil; break;
    }

    //[panel setNameFieldLabel: prompt];
    if (ext)
        panel.allowedFileTypes=@[ext];
    panel.directoryURL = directory;

    panel.extensionHidden=NO;
    [panel setCanCreateDirectories:YES];

    if (fileusage == fileusage_Transcript || fileusage == fileusage_InputRecord)
        filename = [filename stringByAppendingString:gameinfo[@"title"]];
    
    if (fileusage == fileusage_SavedGame)
    {
        NSDateFormatter *formatter = [[NSDateFormatter alloc] init];
        [formatter setDateFormat:@" yyyy-MM-dd HH.mm"];
        date = [formatter stringFromDate:[NSDate date]];


        filename = [gameinfo[@"title"] stringByAppendingString:date];
    }

    if (ext)
        filename = [filename stringByAppendingPathExtension: ext];

    if (filename)
        [panel setNameFieldStringValue:filename];

    [panel beginSheetModalForWindow:[self window] completionHandler:^(NSInteger result){
        struct message reply;
        NSInteger sendfd = [sendfh fileDescriptor];
        const char *s;

        if (result == NSFileHandlingPanelOKButton)
        {
            NSURL*  theFile = [panel URL];
            [[NSUserDefaults standardUserDefaults] setObject: [[theFile path] stringByDeletingLastPathComponent] forKey: @"SaveDirectory"];
            s = [theFile.path UTF8String];
        }
        else
            s = "";

        reply.cmd = OKAY;
        reply.len = (int)strlen(s);

        write((int)sendfd, &reply, sizeof(struct message));
        if (reply.len)
            write((int)sendfd, s, reply.len);
    }];

    waitforfilename = NO; /* we're all done, resume normal processing */

    [readfh waitForDataInBackgroundAndNotify];
}

- (NSInteger) handleNewWindowOfType: (NSInteger)wintype
{
    NSInteger i, k;

    for (i = 0; i < MAXWIN; i++)
        if (gwindows[i] == nil)
            break;

    if (i == MAXWIN)
        return -1;

    switch (wintype)
    {
        case wintype_TextGrid:
            gwindows[i] = [[GlkTextGridWindow alloc] initWithGlkController: self name: i];
            [contentView addSubview: gwindows[i]];

            for (k = 0; k < style_NUMSTYLES; k++)
            {
                [gwindows[i] setStyle: k
                           windowType: wintype_TextGrid
                               enable: styleuse[0][k]
                                value: styleval[0][k]];

            }
            return i;

        case wintype_TextBuffer:
            gwindows[i] = [[GlkTextBufferWindow alloc] initWithGlkController: self name: i];
            [contentView addSubview: gwindows[i]];

            for (k = 0; k < style_NUMSTYLES; k++)
            {
                [gwindows[i] setStyle: k
                           windowType: wintype_TextBuffer
                               enable: styleuse[1][k]
                                value: styleval[1][k]];
            }
            return i;

        case wintype_Graphics:
            gwindows[i] = [[GlkGraphicsWindow alloc] initWithGlkController: self name: i];
            [contentView addSubview: gwindows[i]];
            return i;
    }

    return -1;
}

- (int) handleNewSoundChannel
{
//    int i;
//
//    for (i = 0; i < MAXSND; i++)
//        if (gchannels[i] == nil)
//            break;
//
//    if (i == MAXSND)
//        return -1;
//
//    //gchannels[i] = [[GlkSoundChannel alloc] initWithGlkController: self name: i];
//
    return MAXSND;
}

- (void) handleSetTimer: (int)millisecs
{
    if (timer)
    {
        [timer invalidate];
        timer = nil;
    }

    if (millisecs > 0)
    {
        if (millisecs < MINTIMER)
        {
            NSLog(@"glkctl: too small timer interval (%d); increasing to %d", millisecs, MINTIMER);
            millisecs = MINTIMER;
        }

        timer = [NSTimer scheduledTimerWithTimeInterval: millisecs/1000.0
                                                 target: self
                                               selector: @selector(noteTimerTick:)
                                               userInfo: 0
                                                repeats: YES];
    }
}

- (void) noteTimerTick: (id)sender
{
    if (waitforevent)
    {
        GlkEvent *gevent = [[GlkEvent alloc] initTimerEvent];
        [self queueEvent: gevent];
    }
}

- (void) handleLoadSoundNumber: (int)resno from: (char*)buffer length: (int)length
{
    lastsoundresno = -1;

    if (lastsound)
    {
        lastsound = nil;
    }

    lastsound = [[NSData alloc] initWithBytes: buffer length: length];
    if (lastsound)
        lastsoundresno = resno;
}

- (void) handleLoadImageNumber: (int)resno from: (char*)buffer length: (int)length
{
    lastimageresno = -1;

    if (lastimage)
    {
        lastimage = nil;
    }

    NSData *data = [[NSData alloc] initWithBytesNoCopy: buffer length: length freeWhenDone: NO];
    if (!data)
        return;

    NSArray * reps = [NSBitmapImageRep imageRepsWithData:data];

    NSSize size = NSZeroSize;

    for (NSImageRep * imageRep in reps) {
        if (imageRep.pixelsWide > size.width) size.width = imageRep.pixelsWide;
        if (imageRep.pixelsHigh > size.height) size.height = imageRep.pixelsHigh;
    }

    lastimage = [[NSImage alloc] initWithSize:size];

    if (!lastimage)
    {
        NSLog(@"glkctl: failed to decode image");
        return;
    }

    [lastimage addRepresentations:reps];

    NSData *tiffdata = lastimage.TIFFRepresentation;

    lastimage = [[NSImage alloc] initWithData:tiffdata];
    lastimage.size = size;

    lastimageresno = resno;
}


- (void) handleStyleHintOnWindowType: (int)wintype style: (int)style hint:(int)hint value:(int)value
{
    if (style < 0 || style >= style_NUMSTYLES)
        return;

    if (wintype == wintype_AllTypes)
    {
        styleuse[0][style][hint] = YES;
        styleval[0][style][hint] = value;
        styleuse[1][style][hint] = YES;
        styleval[1][style][hint] = value;
    }
    else if (wintype == wintype_TextGrid)
    {
        styleuse[0][style][hint] = YES;
        styleval[0][style][hint] = value;
    }
    else if (wintype == wintype_TextBuffer)
    {
        styleuse[1][style][hint] = YES;
        styleval[1][style][hint] = value;
    }

}

NSInteger colorToInteger(NSColor *color)
{
    CGFloat r, g, b, a;
    uint32_t buf[3];
    NSInteger i;
    color = [color colorUsingColorSpaceName: NSCalibratedRGBColorSpace];

    [color getRed:&r green:&g blue:&b alpha:&a];

    buf[0] = (int)(r * 255);
    buf[1] = (int)(g * 255);
    buf[2] = (int)(b * 255);

    i = buf[2] + (buf[1] << 8) + (buf[0] << 16);
    return i;
}


- (BOOL) handleStyleMeasureOnWin: (GlkWindow*)gwindow style: (int)style hint:(int)hint result:(NSInteger *)result
{
    if (styleuse[1][style_Normal][stylehint_TextColor])
        NSLog(@"styleuse[1][style_Normal][stylehint_TextColor] is true. Value:%ld", (long)styleval[1][style_Normal][stylehint_TextColor]);

    if ([gwindow getStyleVal:style hint:hint value:result])
        return YES;
    else
    {
        if (hint == stylehint_TextColor)
        {
            if ([gwindow isKindOfClass: [GlkTextBufferWindow class]])
                *result = colorToInteger([Preferences bufferForeground]);
            else
                *result = colorToInteger([Preferences gridForeground]);

            return YES;
        }
        if (hint == stylehint_BackColor)
        {
            if ([gwindow isKindOfClass: [GlkTextBufferWindow class]])
                *result = colorToInteger([Preferences bufferBackground]);
            else
                *result = colorToInteger([Preferences gridBackground]);

            return YES;
        }

    }
    return NO;
}


- (void) handleClearHintOnWindowType: (int)wintype style: (int)style hint:(int)hint
{
    if (style < 0 || style >= style_NUMSTYLES)
        return;

    if (wintype == wintype_AllTypes)
    {
        styleuse[0][style][hint] = NO;
        styleuse[1][style][hint] = NO;
    }
    else if (wintype == wintype_TextGrid)
    {
        styleuse[0][style][hint] = NO;
    }
    else if (wintype == wintype_TextBuffer)
    {
        styleuse[1][style][hint] = NO;
    }
}

- (void) handlePrintOnWindow: (GlkWindow*)gwindow style: (int)style buffer: (unichar*)buf length: (int)len
{
    NSString *str;

    if ([gwindow isKindOfClass: [GlkTextBufferWindow class]] && (style & 0xff) != style_Preformatted)
    {
        GlkTextBufferWindow *textwin = (GlkTextBufferWindow*) gwindow;
        NSInteger smartquotes = [Preferences smartQuotes];
        NSInteger spaceformat = [Preferences spaceFormat];
        NSInteger lastchar = textwin.lastchar;
        NSInteger spaced = 0;
        NSInteger i;

        for (i = 0; i < len; i++)
        {
            /* turn (punct sp sp) into (punct sp) */
            if (spaceformat)
            {
                if (buf[i] == '.' || buf[i] == '!' || buf[i] == '?')
                    spaced = 1;
                else if (buf[i] == ' ' && spaced == 1)
                    spaced = 2;
                else if (buf[i] == ' ' && spaced == 2)
                {
                    memmove(buf+i, buf+i+1, (len - (i + 1)) * sizeof(unichar));
                    len --;
                    i--;
                    spaced = 0;
                }
                else
                {
                    spaced = 0;
                }
            }

            if (smartquotes && buf[i] == '`')
                buf[i] = 0x2018;

            else if (smartquotes && buf[i] == '\'')
            {
                if (lastchar == ' ' || lastchar == '\n')
                    buf[i] = 0x2018;
                else
                    buf[i] = 0x2019;
            }

            else if (smartquotes && buf[i] == '"')
            {
                if (lastchar == ' ' || lastchar == '\n')
                    buf[i] = 0x201c;
                else
                    buf[i] = 0x201d;
            }

            else if (smartquotes && i > 1 && buf[i-1] == '-' && buf[i] == '-')
            {
                memmove(buf+i, buf+i+1, (len - (i + 1)) * sizeof(unichar));
                len --;
                i--;
                buf[i] = 0x2013;
            }

            else if (smartquotes && i > 1 && buf[i-1] == 0x2013 && buf[i] == '-')
            {
                memmove(buf+i, buf+i+1, (len - (i + 1)) * sizeof(unichar));
                len --;
                i--;
                buf[i] = 0x2014;
            }

            lastchar = buf[i];
        }

        len = (int)i;
    }

    str = [NSString stringWithCharacters: buf length: len];

    [gwindow putString: str style: style];
}

- (void) handleSoundNotification: (NSInteger)notify withSound:(NSInteger)sound
{
	GlkEvent *gev = [[GlkEvent alloc] initSoundNotify:notify withSound:sound];
	[self queueEvent:gev];
}

- (void) handleVolumeNotification: (NSInteger)notify
{
	GlkEvent *gev = [[GlkEvent alloc] initVolumeNotify:notify];
	[self queueEvent:gev];
}

- (void) handleSetTerminatorsOnWindow:(GlkWindow*)gwindow	buffer: (glui32 *)buf length: (glui32)len
{
	NSMutableDictionary *myDict = gwindow.pendingTerminators;
	NSNumber *key;
	NSArray *keys = [myDict allKeys];

	for (key in keys)	{
		myDict[key] = @(NO);
	}

//	NSLog(@"handleSetTerminatorsOnWindow: %ld length: %u", (long)gwindow.name, len );

	for (NSInteger i = 0; i < len; i++)
	{
		key = @(buf[i]);
		id terminator_setting = myDict[key];
		if (terminator_setting)
		{
			myDict[key] = @(YES);
		}
		else NSLog(@"Illegal line terminator request: %u", buf[i]);
	}
	gwindow.terminatorsPending = YES;
}

- (BOOL) handleRequest: (struct message *)req reply: (struct message *)ans buffer: (char *)buf
{
    //NSLog(@"glkctl: incoming request %s", msgnames[req->cmd]);

    NSInteger result;

    switch (req->cmd)
    {
        case HELLO:
            ans->cmd = OKAY;
            ans->a1 = (int)[Preferences graphicsEnabled];
            ans->a2 = (int)[Preferences soundEnabled];
            break;

        case NEXTEVENT:
            [self flushDisplay];

            if ([queue count])
            {
                GlkEvent *gevent;
                gevent = queue[0];
                //NSLog(@"glkctl: writing queued event %s", msgnames[[gevent type]]);

                [gevent writeEvent: [sendfh fileDescriptor]];
                [queue removeObjectAtIndex: 0];
                return NO; /* keep reading ... we sent the reply */
            }
            else
            {
                //No queued events.

                if (!req->a1)
                {
                    //Argument 1 is FALSE. No waiting for more events. Send a dummy reply to hand over to the interpreter immediately.
                    ans->cmd = OKAY;
                    break;
                }
            }

            [self guessFocus];

            waitforevent = YES;
            return YES; /* stop reading ... terp is waiting for reply */

        case PROMPTOPEN:
            [self handleOpenPrompt: req->a1];
            return YES; /* stop reading ... terp is waiting for reply */

        case PROMPTSAVE:
            [self handleSavePrompt: req->a1];
            return YES; /* stop reading ... terp is waiting for reply */

        case STYLEHINT:
            [self handleStyleHintOnWindowType:req->a1 style:req->a2 hint:req->a3 value:req->a4];
            break;

        case STYLEMEASURE:
            result = 0;
            ans->cmd = OKAY;
            ans->a1 = [self handleStyleMeasureOnWin:gwindows[req->a1] style:req->a2 hint:req->a3 result:&result];
            ans->a2 = (int)result;
            break;

        case CLEARHINT:
            [self handleClearHintOnWindowType:req->a1 style:req->a2 hint:req->a3];
            break;

            /*
             * Create and destroy windows and channels
             */

#pragma mark Create and destroy windows and sound channels

        case NEWWIN:
            ans->cmd = OKAY;
            ans->a1 = (int)[self handleNewWindowOfType: req->a1];
//            NSLog(@"glkctl newwin %d (type %d)", ans->a1, req->a1);
            break;

        case NEWCHAN:
            ans->cmd = OKAY;
            ans->a1 = [self handleNewSoundChannel];
            break;

        case DELWIN:
            NSLog(@"glkctl delwin %d", req->a1);
            if (req->a1 >= 0 && req->a1 < MAXWIN && gwindows[req->a1])
            {
                [gwindows[req->a1] removeFromSuperview];
                gwindows[req->a1] = nil;
            }
            else
                NSLog(@"delwin: something went wrong.");

            break;

        case DELCHAN:
//            if (req->a1 >= 0 && req->a1 < MAXSND && gchannels[req->a1])
//            {
//                gchannels[req->a1] = nil;
//            }
            break;

            /*
             * Load images; load and play sounds
             */

#pragma mark Load images; load and play sounds

        case FINDIMAGE:
            ans->cmd = OKAY;
            ans->a1 = lastimageresno == req->a1;
            break;

        case FINDSOUND:
            ans->cmd = OKAY;
            ans->a1 = lastsoundresno == req->a1;
            break;

        case LOADIMAGE:
            buf[req->len] = 0;
            [self handleLoadImageNumber: req->a1 from: buf length: req->len];
            break;

        case SIZEIMAGE:
            ans->cmd = OKAY;
            ans->a1 = 0;
            ans->a2 = 0;
            if (lastimage)
            {
                NSSize size;
                size = lastimage.size;
                ans->a1 = size.width;
                ans->a2 = size.height;
            }
            break;

        case LOADSOUND:
            buf[req->len] = 0;
            [self handleLoadSoundNumber: req->a1 from: buf length: req->len];
            break;

        case SETVOLUME:
//            if (req->a1 >= 0 && req->a1 < MAXSND && gchannels[req->a1])
//            {
//                [gchannels[req->a1] setVolume: req->a2];
//            }
            break;

        case PLAYSOUND:
//            if (req->a1 >= 0 && req->a1 < MAXSND && gchannels[req->a1])
//            {
//                if (lastsound)
//                    [gchannels[req->a1] play: lastsound repeats: req->a2 notify: req->a3];
//            }
            break;

        case STOPSOUND:
//            if (req->a1 >= 0 && req->a1 < MAXSND && gchannels[req->a1])
//            {
//                [gchannels[req->a1] stop];
//            }
            break;

            /*
             * Window sizing, printing, drawing, etc...
             */

#pragma mark Window sizing, printing, drawing …

        case SIZWIN:
//            NSLog(@"glkctl sizwin %d: %d x %d", req->a1, req->a4-req->a2, req->a5-req->a3);
            if (req->a1 >= 0 && req->a1 < MAXWIN && gwindows[req->a1])
            {
                int x0, y0, x1, y1;
                NSRect rect;
                x0 = req->a2;
                y0 = req->a3;
                x1 = req->a4;
                y1 = req->a5;
                rect = NSMakeRect(x0, y0, x1 - x0, y1 - y0);
                [gwindows[req->a1] setFrame: rect];
                windowdirty = YES;
            }
            else
                NSLog(@"sizwin: something went wrong.");

            break;

        case CLRWIN:
            if (req->a1 >= 0 && req->a1 < MAXWIN && gwindows[req->a1])
            {
//				NSLog(@"glkctl: CLRWIN %d.", req->a1);
                [gwindows[req->a1] clear];
            }
            break;

		case SETBGND:
			if (req->a1 >= 0 && req->a1 < MAXWIN && gwindows[req->a1])
			{
				if (![gwindows[req->a1] isKindOfClass:[GlkGraphicsWindow class]])
				{
					NSLog(@"glkctl: SETBGND: ERROR win %d is not a graphics window.", req->a1);
					break;
				}

				[gwindows[req->a1] setBgColor: req->a2];
			}
			break;

		case DRAWIMAGE:
			if (req->a1 >= 0 && req->a1 < MAXWIN && gwindows[req->a1])
			{
				if (lastimage)
				{
					[gwindows[req->a1] drawImage: lastimage
											val1: req->a2
											val2: req->a3
										   width: req->a4
										  height: req->a5];
				}
			}
			break;

        case FILLRECT:
            if (req->a1 >= 0 && req->a1 < MAXWIN && gwindows[req->a1])
            {
                int realcount = req->len / sizeof (struct fillrect);
                if (realcount == req->a2)
                {
                    [gwindows[req->a1] fillRects: (struct fillrect *)buf count: req->a2];
                }
            }
            break;

		case PRINT:
			if (req->a1 >= 0 && req->a1 < MAXWIN && gwindows[req->a1])
			{
				[self handlePrintOnWindow: gwindows[req->a1]
									style: req->a2
								   buffer: (unichar*)buf
								   length: req->len / sizeof(unichar)];
			}
			break;

		case MOVETO:
			if (req->a1 >= 0 && req->a1 < MAXWIN && gwindows[req->a1])
			{
				int x = req->a2;
				int y = req->a3;
				if (x < 0) x = 10000;
				if (y < 0) y = 10000;
				[gwindows[req->a1] moveToColumn: x row: y];
			}
			break;

		case SETECHO:
			if (req->a1 >= 0 && req->a1 < MAXWIN && gwindows[req->a1] && [gwindows[req->a1] isKindOfClass: [GlkTextBufferWindow class]])
				[(GlkTextBufferWindow *)gwindows[req->a1] echo:(req->a2 != 0)];
			break;

            /*
             * Request and cancel events
             */

		case TERMINATORS:
			[self handleSetTerminatorsOnWindow: gwindows[req->a1]
										buffer: (glui32 *)buf
										length: req->a2];
			break;

		case FLOWBREAK:
			NSLog(@"glkctl: WEE! WE GOT A FLOWBREAK! ^^;");
			if (req->a1 >= 0 && req->a1 < MAXWIN && gwindows[req->a1])
			{
				[gwindows[req->a1] flowBreak];
			}
			break;

#pragma mark Request and cancel events

        case INITLINE:
//            NSLog(@"glkctl INITLINE %d", req->a1);
            [self performScroll];
            if (req->a1 >= 0 && req->a1 < MAXWIN && gwindows[req->a1])
            {
                [gwindows[req->a1] initLine: [[NSString alloc]
                                               initWithData: [NSData dataWithBytes: buf
                                                                            length: req->len]
                                               encoding: NSUTF8StringEncoding]];

            }
            break;

        case CANCELLINE:
//            NSLog(@"glkctl CANCELLINE %d", req->a1);
            ans->cmd = OKAY;
            if (req->a1 >= 0 && req->a1 < MAXWIN && gwindows[req->a1])
            {
                const char *str = [[gwindows[req->a1] cancelLine] UTF8String];
                strlcpy(buf, str, GLKBUFSIZE);
                ans->len = (int)strlen(buf);
            }
            break;

        case INITCHAR:
            [self performScroll];
//            NSLog(@"glkctl initchar %d", req->a1);
            if (req->a1 >= 0 && req->a1 < MAXWIN && gwindows[req->a1])
                [gwindows[req->a1] initChar];
            break;

        case CANCELCHAR:
//            NSLog(@"glkctl CANCELCHAR %d", req->a1);
            if (req->a1 >= 0 && req->a1 < MAXWIN && gwindows[req->a1])
                [gwindows[req->a1] cancelChar];
            break;

        case INITMOUSE:
//            NSLog(@"glkctl initmouse %d", req->a1);
            [self performScroll];
            if (req->a1 >= 0 && req->a1 < MAXWIN && gwindows[req->a1])
                [gwindows[req->a1] initMouse];
            break;

        case CANCELMOUSE:
            if (req->a1 >= 0 && req->a1 < MAXWIN && gwindows[req->a1])
                [gwindows[req->a1] cancelMouse];
            break;

		case SETLINK:
			//            NSLog(@"glkctl set hyperlink %d in window %d", req->a2, req->a1);
			if (req->a1 >= 0 && req->a1 < MAXWIN && gwindows[req->a1])
			{
				[gwindows[req->a1] setHyperlink:req->a2];
			}
			break;

		case INITLINK:
			//            NSLog(@"glkctl request hyperlink event in window %d", req->a1);
            [self performScroll];
			if (req->a1 >= 0 && req->a1 < MAXWIN && gwindows[req->a1])
			{
				[gwindows[req->a1] initHyperlink];
			}
			break;

		case CANCELLINK:
			//            NSLog(@"glkctl cancel hyperlink event in window %d", req->a1);
			if (req->a1 >= 0 && req->a1 < MAXWIN && gwindows[req->a1])
			{
				[gwindows[req->a1] cancelHyperlink];
			}
			break;

        case TIMER:
            [self handleSetTimer: req->a1];
            break;

		case EVTSOUND:
			NSLog(@"glkctl EVTSOUND %d, %d. Send it back to where it came from.", req->a2, req->a3);
			[self handleSoundNotification: req->a3 withSound:req->a2];
			break;

		case EVTVOLUME:
			NSLog(@"glkctl EVTVOLUME %d. Send it back where it came.", req->a3);
			[self handleVolumeNotification: req->a3];
			break;


            /*
             * Hugo specifics (hugo doesn't use glk to arrange windows)
             */

#pragma mark Non-standard Glk extensions stuff

        case MAKETRANSPARENT:
            if (req->a1 >= 0 && req->a1 < MAXWIN && gwindows[req->a1])
                [gwindows[req->a1] makeTransparent];
            break;

		case SETTITLE:
			[self handleChangeTitle: (char*)buf
							 length: req->len];
			break;


            /*
             * HTML-TADS specifics will go here.
             */

        default:
            NSLog(@"glkctl: unhandled request (%d)", req->cmd);
    }

    return NO; /* keep reading */
}

/*
 *
 */

#pragma mark Interpreter glue

static NSString *signalToName(NSTask *task)
{
    switch ([task terminationStatus])
    {
        case 1: return @"sighup";
        case 2: return @"sigint";
        case 3: return @"sigquit";
        case 4: return @"sigill";
        case 6: return @"sigabrt";
        case 8: return @"sigfpe";
        case 9: return @"sigkill";
        case 10: return @"sigbus";
        case 11: return @"sigsegv";
        case 13: return @"sigpipe";
        case 15: return @"sigterm";
        default:
            return [NSString stringWithFormat: @"%d", [task terminationStatus]];
    }
}

static BOOL pollMoreData(int fd)
{
    struct timeval timeout;
    fd_set set;
    FD_ZERO(&set);
    FD_SET(fd, &set);
    timeout.tv_sec = 0;
    timeout.tv_usec = 0;
    return select(fd + 1, &set, NULL, NULL, &timeout) == 1;
}

- (void) noteTaskDidTerminate: (id)sender
{
    NSLog(@"glkctl: noteTaskDidTerminate");

    int i;

    dead = YES;

    if (timer)
    {
        [timer invalidate];
        timer = nil;
    }

    if (task && [task terminationStatus] != 0)
    {
        NSAlert *alert;

        alert = [NSAlert alertWithMessageText: @"The game has unexpectedly terminated."
                                defaultButton: @"Oops"
                              alternateButton: nil
                                  otherButton: nil
                    informativeTextWithFormat: @"Error code: %@.", signalToName(task)];

        [alert beginSheetModalForWindow: [self window]
                          modalDelegate: nil
                         didEndSelector: nil
                            contextInfo: nil];
    }

    [self performScroll];

    for (i = 0; i < MAXWIN; i++)
        if (gwindows[i])
            [gwindows[i] terpDidStop];

//    for (i = 0; i < MAXSND; i++)
//        if (gchannels[i])
//            [gchannels[i] stop];

    [[self window] setTitle:
     [[[self window] title] stringByAppendingString: @" (finished)"]];

    task = nil;

    // [self setDocumentEdited: NO];
}

- (void) queueEvent: (GlkEvent*)gevent
{
    if (waitforfilename)
    {
        [queue addObject: gevent];
    }
    else if (waitforevent)
    {
        [gevent writeEvent: [sendfh fileDescriptor]];
        waitforevent = NO;
        [readfh waitForDataInBackgroundAndNotify];
    }
    else
    {
        [queue addObject: gevent];
    }
}

- (void) noteDataAvailable: (id)sender
{
    // NSLog(@"glkctl: noteDataAvailable");

    struct message request;
    struct message reply;
    char minibuf[GLKBUFSIZE + 1];
    char *maxibuf;
    char *buf;
    NSInteger n, t;
    BOOL stop;

    NSInteger readfd = [readfh fileDescriptor];
    NSInteger sendfd = [sendfh fileDescriptor];

again:

    buf = minibuf;
    maxibuf = NULL;

    n = read((int)readfd, &request, sizeof(struct message));
    if (n < sizeof(struct message))
    {
        if (n < 0)
            NSLog(@"glkctl: could not read message header");
        else
            NSLog(@"glkctl: connection closed");
        return;
    }

    /* this should only happen when sending resources */
    if (request.len > GLKBUFSIZE)
    {
        maxibuf = malloc(request.len);
        if (!maxibuf)
        {
            NSLog(@"glkctl: out of memory for message (%d bytes)", request.len);
            return;
        }
        buf = maxibuf;
    }

    if (request.len)
    {
        n = 0;
        while (n < request.len)
        {
            t = read((int)readfd, buf + n, request.len - n);
            if (t <= 0)
            {
                NSLog(@"glkctl: could not read message body");
                if (maxibuf)
                    free(maxibuf);
                return;
            }
            n += t;
        }
    }

    memset(&reply, 0, sizeof reply);

    stop = [self handleRequest: &request reply: &reply buffer: buf];

    if (reply.cmd > NOREPLY)
    {
        write((int)sendfd, &reply, sizeof(struct message));
        if (reply.len)
            write((int)sendfd, buf, reply.len);
    }

    if (maxibuf)
        free(maxibuf);

    /* if stop, don't read or wait for more data */
    if (stop)
        return;

    if (pollMoreData((int)readfd))
        goto again;
    else
        [readfh waitForDataInBackgroundAndNotify];
}

@end
