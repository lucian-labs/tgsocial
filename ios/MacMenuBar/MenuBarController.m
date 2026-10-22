// AppKit is isolated in a macOS bundle: the main application remains Catalyst.
#import <AppKit/AppKit.h>
#import <objc/runtime.h>

// Preserve UIKit's window delegate and forward everything except an ordinary close.
@interface TGWindowDelegate : NSProxy <NSWindowDelegate>
@property(nonatomic, weak) id original;
@end

@implementation TGWindowDelegate
- (BOOL)respondsToSelector:(SEL)selector {
    return selector == @selector(windowShouldClose:) || [self.original respondsToSelector:selector];
}
- (NSMethodSignature *)methodSignatureForSelector:(SEL)selector {
    return [self.original methodSignatureForSelector:selector];
}
- (void)forwardInvocation:(NSInvocation *)invocation {
    [invocation invokeWithTarget:self.original];
}
- (BOOL)windowShouldClose:(NSWindow *)window {
    [window orderOut:nil];
    // Keeping the scene alive keeps TDLib and the enabled connector alive too.
    BOOL anotherVisible = NO;
    for (NSWindow *other in NSApp.windows) {
        if (other != window && other.canBecomeMainWindow && other.visible) anotherVisible = YES;
    }
    if (!anotherVisible) [NSApp hide:nil];
    return NO;
}
@end

@interface TGMenuBarController : NSObject
@property(nonatomic, strong) NSStatusItem *item;
@end

@implementation TGMenuBarController
- (instancetype)init {
    if ((self = [super init])) {
        _item = [NSStatusBar.systemStatusBar statusItemWithLength:NSVariableStatusItemLength];
        _item.button.title = @"tg";
        _item.button.toolTip = @"tgsocial";
        [_item.button setAccessibilityLabel:@"tgsocial"];
        NSMenu *menu = [[NSMenu alloc] initWithTitle:@"tgsocial"];
        NSMenuItem *show = [menu addItemWithTitle:@"Open tgsocial" action:@selector(showWindow:) keyEquivalent:@""];
        show.target = self;
        [menu addItem:NSMenuItem.separatorItem];
        NSMenuItem *quit = [menu addItemWithTitle:@"Quit tgsocial" action:@selector(terminate:) keyEquivalent:@"q"];
        quit.target = NSApp;
        _item.menu = menu;
        NSNotificationCenter *center = NSNotificationCenter.defaultCenter;
        [center addObserver:self selector:@selector(windowBecameKey:) name:NSWindowDidBecomeKeyNotification object:nil];
        [center addObserver:self selector:@selector(applicationBecameActive:) name:NSApplicationDidBecomeActiveNotification object:nil];
        for (NSWindow *window in NSApp.windows) [self attach:window];
    }
    return self;
}
- (void)attach:(NSWindow *)window {
    if (!window.canBecomeMainWindow || window.sheetParent || [window isKindOfClass:NSPanel.class]) return;
    TGWindowDelegate *proxy = objc_getAssociatedObject(window, @selector(attach:));
    if ((id)window.delegate == proxy && proxy) return;
    proxy = [TGWindowDelegate alloc];
    proxy.original = window.delegate;
    objc_setAssociatedObject(window, @selector(attach:), proxy, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    window.delegate = proxy;
}
- (void)windowBecameKey:(NSNotification *)notification { [self attach:notification.object]; }
- (void)applicationBecameActive:(NSNotification *)notification {
    for (NSWindow *window in NSApp.windows) {
        if (window.canBecomeMainWindow && window.visible) return;
    }
    [self showWindow:nil];
}
- (void)showWindow:(id)sender {
    for (NSWindow *window in NSApp.windows) {
        if (objc_getAssociatedObject(window, @selector(attach:))) {
            if (window.miniaturized) [window deminiaturize:nil];
            [window makeKeyAndOrderFront:nil];
            break;
        }
    }
    [NSApp activateIgnoringOtherApps:YES];
    [NSApp unhide:nil];
}
@end
