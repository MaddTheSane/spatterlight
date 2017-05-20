/*
 * Preferences is a combined singleton / window controller.
 */

#define TAG_SPACES_GAME 0
#define TAG_SPACES_ONE 1
#define TAG_SPACES_TWO 2

@interface Preferences : NSWindowController
{
    IBOutlet NSButton *btnInputFont, *btnBufferFont, *btnGridFont;
    IBOutlet NSColorWell *clrInputFg, *clrBufferFg, *clrGridFg;
    IBOutlet NSColorWell *clrBufferBg, *clrGridBg;
    IBOutlet NSTextField *txtBufferMargin, *txtGridMargin, *txtLeading;
    IBOutlet NSTextField *txtRows, *txtCols;
    IBOutlet NSButton *btnSmartQuotes;
    IBOutlet NSButton *btnSpaceFormat;
    IBOutlet NSButton *btnEnableGraphics;
    IBOutlet NSButton *btnEnableSound;
    IBOutlet NSButton *btnEnableStyles;
    IBOutlet NSButton *btnUseScreenFonts;
    NSFont **selfontp;
}

+ (void) rebuildTextAttributes;

+ (NSSize) defaultWindowSize;

- (IBAction) changeColor: (id)sender;
- (IBAction) showFontPanel: (id)sender;
- (IBAction) changeFont: (id)sender;
- (IBAction) changeMargin: (id)sender;
- (IBAction) changeLeading: (id)sender;
- (IBAction) changeSmartQuotes: (id)sender;
- (IBAction) changeSpaceFormatting: (id)sender;
- (IBAction) changeDefaultSize: (id)sender;
- (IBAction) changeEnableGraphics: (id)sender;
- (IBAction) changeEnableSound: (id)sender;
- (IBAction) changeEnableStyles: (id)sender;
- (IBAction) changeUseScreenFonts: (id)sender;

+ (NSColor*) gridBackground;
+ (NSColor*) gridForeground;
+ (NSColor*) bufferBackground;
+ (NSColor*) bufferForeground;
+ (NSColor*) inputColor;


+ (NSColor*) foregroundColor: (int)number;
+ (NSColor*) backgroundColor: (int)number;

+ (float) lineHeight;
+ (float) charWidth;
+ (int) gridMargins;
+ (int) bufferMargins;
+ (float) leading;

+ (int) stylesEnabled;
+ (int) smartQuotes;
+ (int) spaceFormat;

+ (int) graphicsEnabled;
+ (int) soundEnabled;
+ (int) useScreenFonts;

+ (NSDictionary*) attributesForGridStyle: (int)style;
+ (NSDictionary*) attributesForBufferStyle: (int)style;

@end
