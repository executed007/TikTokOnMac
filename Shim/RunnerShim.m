// RunnerShim: a small library Catalyst Runner loads into each installed app.
// iOS apps assume things that are not true in a Mac window; this smooths over them.
// Every behaviour is a per-app setting, read at launch from
//   ~/Library/Application Support/CatalystRunner/Settings/<bundle id>.plist
// (missing file or key = default). Catalyst Runner writes that file.
//
//   hideTitleBar           The Mac title strip is drawn over the app's content. Hide it and
//                          report a top inset so controls stay clear of the window buttons.
//   lockCameraOrientation  Apps rotate the camera to match how a phone is held. A Mac has no
//                          such thing, and the result is an upside-down picture. Ignore
//                          rotation requests and report an upright device.
//   cropCameraToPortrait   A Mac camera is landscape; phone apps expect portrait frames and
//                          squash the picture. Hand them the centre 9:16 strip instead.
//   windowSize             "phone" or "tablet" sets the window's size at launch.
//   volume                 0...1. Scales what the app plays (AudioQueue and AudioUnit output).
//                          The Volume menu (⌘↑, ⌘↓, ⌘0) and the on-screen button change it.
//   showVolumeButton       A speaker button in the window's top-right corner with a slider.
//   arrowKeysScrollFeed    Up and Down move a full-screen paged feed by one item, the way a
//                          swipe does, unless a text field has focus.
// Always on: the "deferred start" camera calls throw on macOS; those exceptions are swallowed.
#import <UIKit/UIKit.h>
#import <AVFoundation/AVFoundation.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <AudioToolbox/AudioToolbox.h>
#import <dlfcn.h>
#import <mach-o/dyld.h>
#import <mach-o/loader.h>
#import <mach-o/nlist.h>
#import <os/lock.h>
#import <pwd.h>
#import <sys/mman.h>

static const CGFloat RSTitlebarHeight = 28;
static NSDictionary *RSSettings;

static BOOL RSFlag(NSString *key, BOOL fallback) {
    id value = RSSettings[key];
    return [value respondsToSelector:@selector(boolValue)] ? [value boolValue] : fallback;
}

static NSString *RSSettingsPath;

static void RSLoadSettings(void) {
    struct passwd *user = getpwuid(getuid());           // the real home, not the sandbox container
    NSString *identifier = NSBundle.mainBundle.bundleIdentifier;
    if (!user || !user->pw_dir || !identifier) return;
    RSSettingsPath = [NSString stringWithFormat:@"%s/Library/Application Support/CatalystRunner/Settings/%@.plist",
                      user->pw_dir, identifier];
    RSSettings = [NSDictionary dictionaryWithContentsOfFile:RSSettingsPath];
}

// Writes one setting back, so a change made inside the app is remembered and shows up in
// Catalyst Runner. Catalyst Runner posts the same notification when it saves.
static NSString *const RSSettingsChanged = @"dev.catalyst-runner.settings-changed";

static void RSStoreSetting(NSString *key, id value) {
    if (!RSSettingsPath) return;
    NSMutableDictionary *updated = [([NSDictionary dictionaryWithContentsOfFile:RSSettingsPath] ?: @{}) mutableCopy];
    updated[key] = value;
    RSSettings = updated;
    [NSFileManager.defaultManager createDirectoryAtPath:RSSettingsPath.stringByDeletingLastPathComponent
                            withIntermediateDirectories:YES attributes:nil error:nil];
    [updated writeToFile:RSSettingsPath atomically:YES];
}

// Replaces an instance method, handing the block the original implementation.
static void RSReplace(Class cls, SEL selector, id (^make)(IMP original)) {
    Method method = class_getInstanceMethod(cls, selector);
    if (!method) return;
    IMP replacement = imp_implementationWithBlock(make(method_getImplementation(method)));
    class_replaceMethod(cls, selector, replacement, method_getTypeEncoding(method));
}

#pragma mark - Window

static void RSStyleScene(UIScene *scene) {
    if (![scene isKindOfClass:UIWindowScene.class]) return;
    UIWindowScene *windowScene = (UIWindowScene *)scene;
    if (RSFlag(@"hideTitleBar", YES)) {
        windowScene.titlebar.titleVisibility = UITitlebarTitleVisibilityHidden;
        windowScene.titlebar.toolbar = nil;
    }
    static NSHashTable *sized;
    if (!sized) sized = [NSHashTable weakObjectsHashTable];
    NSString *size = RSSettings[@"windowSize"];
    CGSize wanted = [size isEqual:@"phone"] ? CGSizeMake(430, 932) : [size isEqual:@"tablet"] ? CGSizeMake(1024, 768) : CGSizeZero;
    if (wanted.width > 0 && ![sized containsObject:scene]) {
        [sized addObject:scene];
        if (@available(macCatalyst 16.0, *)) {
            CGRect frame = windowScene.effectiveGeometry.systemFrame;
            UIWindowSceneGeometryPreferencesMac *geometry = [[UIWindowSceneGeometryPreferencesMac alloc]
                initWithSystemFrame:CGRectMake(frame.origin.x, frame.origin.y, wanted.width, wanted.height)];
            [windowScene requestGeometryUpdateWithPreferences:geometry errorHandler:nil];
        }
    }
}

static void RSInstallWindowFixes(void) {
    NSNotificationCenter *center = NSNotificationCenter.defaultCenter;
    for (NSNotificationName name in @[UISceneWillConnectNotification, UISceneDidActivateNotification]) {
        [center addObserverForName:name object:nil queue:NSOperationQueue.mainQueue
                        usingBlock:^(NSNotification *note) { RSStyleScene(note.object); }];
    }
    if (!RSFlag(@"hideTitleBar", YES)) return;

    SEL insets = @selector(safeAreaInsets);
    RSReplace(UIWindow.class, insets, ^id(IMP original) {
        return ^UIEdgeInsets(UIWindow *window) {
            UIEdgeInsets value = ((UIEdgeInsets (*)(id, SEL))original)(window, insets);
            if (value.top < RSTitlebarHeight) value.top = RSTitlebarHeight;
            return value;
        };
    });
    SEL frame = @selector(statusBarFrame);
    RSReplace(UIStatusBarManager.class, frame, ^id(IMP original) {
        return ^CGRect(UIStatusBarManager *manager) {
            CGRect value = ((CGRect (*)(id, SEL))original)(manager, frame);
            if (value.size.height < RSTitlebarHeight) {
                value.size.height = RSTitlebarHeight;
                if (value.size.width == 0) value.size.width = UIScreen.mainScreen.bounds.size.width;
            }
            return value;
        };
    });
}

#pragma mark - Camera: deferred start

static void RSLog(SEL selector, NSException *exception) {
    NSLog(@"[RunnerShim] ignored %@ from %@: %@", exception.name, NSStringFromSelector(selector), exception.reason);
}

// Wraps one void "deferred start" method in @try/@catch. Only the argument shapes these
// methods actually use are handled; anything else is left untouched.
static void RSGuardDeferred(Method method) {
    SEL selector = method_getName(method);
    if (![NSStringFromSelector(selector) localizedCaseInsensitiveContainsString:@"deferredStart"]) return;
    char returns[8];
    method_getReturnType(method, returns, sizeof returns);
    if (returns[0] != 'v') return;
    unsigned int arguments = method_getNumberOfArguments(method) - 2;
    char first = 0;
    if (arguments >= 1) { char type[8]; method_getArgumentType(method, 2, type, sizeof type); first = type[0]; }
    IMP original = method_getImplementation(method);
    id block = nil;
    if (arguments == 0) {
        block = ^void(id object) {
            @try { ((void (*)(id, SEL))original)(object, selector); } @catch (NSException *e) { RSLog(selector, e); }
        };
    } else if (arguments == 1 && (first == 'B' || first == 'c')) {
        block = ^void(id object, BOOL value) {
            @try { ((void (*)(id, SEL, BOOL))original)(object, selector, value); } @catch (NSException *e) { RSLog(selector, e); }
        };
    } else if (arguments == 1 && first == '@') {
        block = ^void(id object, id value) {
            @try { ((void (*)(id, SEL, id))original)(object, selector, value); } @catch (NSException *e) { RSLog(selector, e); }
        };
    } else if (arguments == 2 && first == '@') {
        block = ^void(id object, id value, void *other) {
            @try { ((void (*)(id, SEL, id, void *))original)(object, selector, value, other); } @catch (NSException *e) { RSLog(selector, e); }
        };
    }
    if (block) method_setImplementation(method, imp_implementationWithBlock(block));
}

#pragma mark - Camera: orientation

static void RSInstallOrientationLock(void) {
    SEL orientation = @selector(orientation);
    RSReplace(UIDevice.class, orientation, ^id(IMP original) {
        return ^UIDeviceOrientation(UIDevice *device) { return UIDeviceOrientationPortrait; };
    });
    // Leave the connection as the Mac camera delivers it (upright landscape).
    for (NSString *name in @[@"setVideoOrientation:", @"setVideoRotationAngle:"]) {
        SEL selector = NSSelectorFromString(name);
        Method method = class_getInstanceMethod(AVCaptureConnection.class, selector);
        if (!method) continue;
        char type[8];
        method_getArgumentType(method, 2, type, sizeof type);
        id block = type[0] == 'd' ? (id)^void(id connection, CGFloat angle) {} : (id)^void(id connection, NSInteger value) {};
        method_setImplementation(method, imp_implementationWithBlock(block));
    }
    SEL videoOrientation = @selector(videoOrientation);
    RSReplace(AVCaptureConnection.class, videoOrientation, ^id(IMP original) {
        return ^AVCaptureVideoOrientation(AVCaptureConnection *connection) { return AVCaptureVideoOrientationPortrait; };
    });
}

#pragma mark - Camera: portrait crop

// Returns a new sample buffer holding the centre 9:16 strip of a landscape frame, or NULL
// when the frame is already portrait or in a pixel format this does not handle.
CMSampleBufferRef RSCreatePortraitCrop(CMSampleBufferRef sample) CF_RETURNS_RETAINED;
CMSampleBufferRef RSCreatePortraitCrop(CMSampleBufferRef sample) {
    CVPixelBufferRef source = CMSampleBufferGetImageBuffer(sample);
    if (!source) return NULL;
    size_t width = CVPixelBufferGetWidth(source), height = CVPixelBufferGetHeight(source);
    if (width <= height) return NULL;
    OSType format = CVPixelBufferGetPixelFormatType(source);
    BOOL biplanar = format == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange || format == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange;
    if (!biplanar && format != kCVPixelFormatType_32BGRA) return NULL;

    size_t cropWidth = (size_t)(height * 9.0 / 16.0) & ~(size_t)1;
    size_t left = ((width - cropWidth) / 2) & ~(size_t)1;

    // One pool per output shape; frames from a camera keep the same shape for a whole session.
    static CVPixelBufferPoolRef pool;
    static size_t poolWidth, poolHeight;
    static OSType poolFormat;
    static dispatch_queue_t poolQueue;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ poolQueue = dispatch_queue_create("runner-shim.crop", DISPATCH_QUEUE_SERIAL); });
    __block CVPixelBufferRef target = NULL;
    dispatch_sync(poolQueue, ^{
        if (!pool || poolWidth != cropWidth || poolHeight != height || poolFormat != format) {
            if (pool) CVPixelBufferPoolRelease(pool);
            NSDictionary *attributes = @{
                (id)kCVPixelBufferPixelFormatTypeKey: @(format),
                (id)kCVPixelBufferWidthKey: @(cropWidth),
                (id)kCVPixelBufferHeightKey: @(height),
                (id)kCVPixelBufferIOSurfacePropertiesKey: @{},
                (id)kCVPixelBufferMetalCompatibilityKey: @YES,
            };
            pool = NULL;
            CVPixelBufferPoolCreate(kCFAllocatorDefault, NULL, (__bridge CFDictionaryRef)attributes, &pool);
            poolWidth = cropWidth; poolHeight = height; poolFormat = format;
        }
        if (pool) CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &target);
    });
    if (!target) return NULL;

    CVPixelBufferLockBaseAddress(source, kCVPixelBufferLock_ReadOnly);
    CVPixelBufferLockBaseAddress(target, 0);
    size_t planes = biplanar ? 2 : 1;
    for (size_t plane = 0; plane < planes; plane++) {
        const uint8_t *from = biplanar ? CVPixelBufferGetBaseAddressOfPlane(source, plane) : CVPixelBufferGetBaseAddress(source);
        uint8_t *to = biplanar ? CVPixelBufferGetBaseAddressOfPlane(target, plane) : CVPixelBufferGetBaseAddress(target);
        size_t fromStride = biplanar ? CVPixelBufferGetBytesPerRowOfPlane(source, plane) : CVPixelBufferGetBytesPerRow(source);
        size_t toStride = biplanar ? CVPixelBufferGetBytesPerRowOfPlane(target, plane) : CVPixelBufferGetBytesPerRow(target);
        size_t rows = plane == 1 ? height / 2 : height;
        // Luma: 1 byte per pixel. Interleaved chroma: 2 bytes per 2 pixels. BGRA: 4 bytes per pixel.
        size_t offset = biplanar ? left : left * 4;
        size_t length = biplanar ? cropWidth : cropWidth * 4;
        if (from && to) {
            for (size_t row = 0; row < rows; row++) memcpy(to + row * toStride, from + row * fromStride + offset, length);
        }
    }
    CVPixelBufferUnlockBaseAddress(target, 0);
    CVPixelBufferUnlockBaseAddress(source, kCVPixelBufferLock_ReadOnly);
    CVBufferPropagateAttachments(source, target);

    CMSampleBufferRef result = NULL;
    CMVideoFormatDescriptionRef description = NULL;
    CMSampleTimingInfo timing;
    if (CMVideoFormatDescriptionCreateForImageBuffer(kCFAllocatorDefault, target, &description) == noErr
        && CMSampleBufferGetSampleTimingInfo(sample, 0, &timing) == noErr) {
        CMSampleBufferCreateReadyWithImageBuffer(kCFAllocatorDefault, target, description, &timing, &result);
        if (result) CMPropagateAttachments(sample, result);
    }
    if (description) CFRelease(description);
    CVPixelBufferRelease(target);
    return result;
}

// Stands in for the app's video delegate, cropping each frame before passing it on.
@interface RSCropDelegate : NSProxy <AVCaptureVideoDataOutputSampleBufferDelegate>
@property (nonatomic, weak) id target;
@end

@implementation RSCropDelegate
- (BOOL)respondsToSelector:(SEL)selector { return [self.target respondsToSelector:selector]; }
- (NSMethodSignature *)methodSignatureForSelector:(SEL)selector {
    return [self.target methodSignatureForSelector:selector] ?: [NSMethodSignature signatureWithObjCTypes:"v@:"];
}
- (void)forwardInvocation:(NSInvocation *)invocation {
    id target = self.target;
    if ([target respondsToSelector:invocation.selector]) [invocation invokeWithTarget:target];
}
- (void)captureOutput:(AVCaptureOutput *)output didOutputSampleBuffer:(CMSampleBufferRef)sample fromConnection:(AVCaptureConnection *)connection {
    id<AVCaptureVideoDataOutputSampleBufferDelegate> target = self.target;
    if (![target respondsToSelector:_cmd]) return;
    CMSampleBufferRef cropped = RSCreatePortraitCrop(sample);
    [target captureOutput:output didOutputSampleBuffer:cropped ?: sample fromConnection:connection];
    if (cropped) CFRelease(cropped);
}
@end

static void RSInstallPortraitCrop(void) {
    static const char key = 0;
    SEL setter = @selector(setSampleBufferDelegate:queue:);
    RSReplace(AVCaptureVideoDataOutput.class, setter, ^id(IMP original) {
        return ^void(AVCaptureVideoDataOutput *output, id delegate, dispatch_queue_t queue) {
            RSCropDelegate *proxy = nil;
            if (delegate) {
                proxy = [RSCropDelegate alloc];
                proxy.target = delegate;
            }
            // The output holds its delegate weakly, so keep the stand-in alive alongside it.
            objc_setAssociatedObject(output, &key, proxy, OBJC_ASSOCIATION_RETAIN);
            ((void (*)(id, SEL, id, dispatch_queue_t))original)(output, setter, proxy, queue);
        };
    });
    SEL getter = @selector(sampleBufferDelegate);
    RSReplace(AVCaptureVideoDataOutput.class, getter, ^id(IMP original) {
        return ^id(AVCaptureVideoDataOutput *output) {
            id value = ((id (*)(id, SEL))original)(output, getter);
            RSCropDelegate *proxy = objc_getAssociatedObject(output, &key);
            return (proxy && value == proxy) ? proxy.target : value;
        };
    });
}

#pragma mark - Keyboard: arrow keys move paged feeds

// Some apps silence NSLog, so keyboard diagnostics go to a file in the app's own container:
// <container>/tmp/RunnerShim.log
static void RSDebug(NSString *format, ...) NS_FORMAT_FUNCTION(1, 2);
static void RSDebug(NSString *format, ...) {
    va_list arguments;
    va_start(arguments, format);
    NSString *line = [[NSString alloc] initWithFormat:format arguments:arguments];
    va_end(arguments);
    static NSFileHandle *file;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSString *path = [NSTemporaryDirectory() stringByAppendingPathComponent:@"RunnerShim.log"];
        [NSFileManager.defaultManager createFileAtPath:path contents:nil attributes:nil];
        file = [NSFileHandle fileHandleForWritingAtPath:path];
    });
    [file writeData:[[NSString stringWithFormat:@"%@ %@\n", NSDate.date, line] dataUsingEncoding:NSUTF8StringEncoding]];
}

static UIView *RSFirstResponder(UIView *view) {
    if (view.isFirstResponder) return view;
    for (UIView *child in view.subviews) {
        UIView *found = RSFirstResponder(child);
        if (found) return found;
    }
    return nil;
}

// The largest visible vertical scroll view that fills most of the window: a full-screen
// swipe feed. Paged scroll views win; feeds that snap on their own (no isPagingEnabled)
// count when nothing paged is on screen.
static void RSFindFeed(UIView *view, UIWindow *window, UIScrollView **best, CGFloat *bestScore) {
    if (view.hidden || view.alpha < 0.01) return;
    if ([view isKindOfClass:UIScrollView.class]) {
        UIScrollView *scroll = (UIScrollView *)view;
        CGRect visible = CGRectIntersection([scroll convertRect:scroll.bounds toView:window], window.bounds);
        CGFloat area = CGRectIsNull(visible) ? 0 : visible.size.width * visible.size.height;
        BOOL tall = scroll.contentSize.height > scroll.bounds.size.height * 1.5;
        BOOL fills = visible.size.height > window.bounds.size.height * 0.75 && visible.size.width > window.bounds.size.width * 0.75;
        CGFloat score = scroll.isPagingEnabled ? area * 2 : area;
        if (scroll.isScrollEnabled && tall && fills && score > *bestScore) {
            *best = scroll;
            *bestScore = score;
        }
    }
    for (UIView *child in view.subviews) RSFindFeed(child, window, best, bestScore);
}

static BOOL RSMoveFeed(NSInteger direction) {
    UIWindow *window = nil;
    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if (![scene isKindOfClass:UIWindowScene.class]) continue;
        for (UIWindow *candidate in ((UIWindowScene *)scene).windows) if (candidate.isKeyWindow) window = candidate;
    }
    if (!window) { RSDebug(@"arrow key: no key window"); return NO; }
    UIView *responder = RSFirstResponder(window);
    if ([responder conformsToProtocol:@protocol(UITextInput)]) {                            // typing
        RSDebug(@"arrow key: text field %@ has focus", NSStringFromClass(responder.class));
        return NO;
    }
    UIScrollView *feed = nil;
    CGFloat area = 0;
    RSFindFeed(window, window, &feed, &area);
    if (!feed) { RSDebug(@"arrow key: no full-screen feed on screen"); return NO; }

    id<UIScrollViewDelegate> delegate = feed.delegate;
    void (^settle)(void) = ^{
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.45 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            if ([delegate respondsToSelector:@selector(scrollViewDidEndDecelerating:)]) [delegate scrollViewDidEndDecelerating:feed];
        });
    };
    if ([delegate respondsToSelector:@selector(scrollViewWillBeginDragging:)]) [delegate scrollViewWillBeginDragging:feed];

    // Feeds built from table or collection views: one row per item, so ask for the next row.
    // Apps with their own paging logic keep this, where they would undo a raw offset change.
    CGPoint middle = CGPointMake(CGRectGetMidX(feed.bounds), CGRectGetMidY(feed.bounds));
    NSIndexPath *current = nil, *next = nil;
    if ([feed isKindOfClass:UITableView.class]) {
        UITableView *table = (UITableView *)feed;
        current = [table indexPathForRowAtPoint:middle];
        if (current) {
            NSInteger row = current.row + direction, section = current.section;
            if (row >= 0 && row < [table numberOfRowsInSection:section]) next = [NSIndexPath indexPathForRow:row inSection:section];
            else if (direction > 0 && section + 1 < table.numberOfSections && [table numberOfRowsInSection:section + 1] > 0)
                next = [NSIndexPath indexPathForRow:0 inSection:section + 1];
            else if (direction < 0 && section > 0 && [table numberOfRowsInSection:section - 1] > 0)
                next = [NSIndexPath indexPathForRow:[table numberOfRowsInSection:section - 1] - 1 inSection:section - 1];
        }
        if (!next) RSDebug(@"arrow key: no table row after %@", current);
        if (next) {
            [table scrollToRowAtIndexPath:next atScrollPosition:UITableViewScrollPositionTop animated:YES];
            settle();
            return YES;
        }
    } else if ([feed isKindOfClass:UICollectionView.class]) {
        UICollectionView *collection = (UICollectionView *)feed;
        current = [collection indexPathForItemAtPoint:middle];
        if (current) {
            NSInteger item = current.item + direction, section = current.section;
            if (item >= 0 && item < [collection numberOfItemsInSection:section]) next = [NSIndexPath indexPathForItem:item inSection:section];
            else if (direction > 0 && section + 1 < collection.numberOfSections && [collection numberOfItemsInSection:section + 1] > 0)
                next = [NSIndexPath indexPathForItem:0 inSection:section + 1];
            else if (direction < 0 && section > 0 && [collection numberOfItemsInSection:section - 1] > 0)
                next = [NSIndexPath indexPathForItem:[collection numberOfItemsInSection:section - 1] - 1 inSection:section - 1];
        }
        if (!next) RSDebug(@"arrow key: no collection item after %@", current);
        if (next) {
            [collection scrollToItemAtIndexPath:next atScrollPosition:UICollectionViewScrollPositionTop animated:YES];
            settle();
            return YES;
        }
    }

    // Any other paged scroll view: move by one page height.
    CGFloat page = feed.bounds.size.height;
    CGFloat top = -feed.adjustedContentInset.top;
    CGFloat bottom = MAX(top, feed.contentSize.height + feed.adjustedContentInset.bottom - page);
    CGFloat index = round((feed.contentOffset.y - top) / page);
    CGFloat target = MIN(MAX(top + (index + direction) * page, top), bottom);
    if (fabs(target - feed.contentOffset.y) < 1) return YES;
    [feed setContentOffset:CGPointMake(feed.contentOffset.x, target) animated:YES];
    settle();
    return YES;
}

// Second route: arrow keys as keyboard shortcuts on UIApplication, the last stop of the
// responder chain. Catalyst delivers these even when raw key events go elsewhere.
static void RSInstallArrowKeyCommands(void) {
    SEL down = NSSelectorFromString(@"runnerShimNextItem:"), up = NSSelectorFromString(@"runnerShimPreviousItem:");
    class_addMethod(UIApplication.class, down, imp_implementationWithBlock(^(id app, id sender) { RSMoveFeed(1); }), "v@:@");
    class_addMethod(UIApplication.class, up, imp_implementationWithBlock(^(id app, id sender) { RSMoveFeed(-1); }), "v@:@");
    UIKeyCommand *next = [UIKeyCommand keyCommandWithInput:UIKeyInputDownArrow modifierFlags:0 action:down];
    UIKeyCommand *previous = [UIKeyCommand keyCommandWithInput:UIKeyInputUpArrow modifierFlags:0 action:up];
    if (@available(macCatalyst 15.0, *)) { next.wantsPriorityOverSystemBehavior = YES; previous.wantsPriorityOverSystemBehavior = YES; }
    SEL getter = @selector(keyCommands);
    RSReplace(UIApplication.class, getter, ^id(IMP original) {
        return ^NSArray *(UIApplication *app) {
            NSArray *existing = ((NSArray *(*)(id, SEL))original)(app, getter) ?: @[];
            return [existing arrayByAddingObjectsFromArray:@[next, previous]];
        };
    });
}

// First route: an AppKit key monitor. A Catalyst app runs inside a real NSApplication, and a
// local monitor sees every key press before UIKit does, whatever the app's responders do.
static void RSInstallAppKitMonitor(void) {
    Class event = NSClassFromString(@"NSEvent");
    SEL add = NSSelectorFromString(@"addLocalMonitorForEventsMatchingMask:handler:");
    if (![event respondsToSelector:add]) { RSDebug(@"arrow key: no AppKit, monitor not installed"); return; }
    id (^handler)(id) = ^id(id keyEvent) {
        unsigned short code = ((unsigned short (*)(id, SEL))objc_msgSend)(keyEvent, NSSelectorFromString(@"keyCode"));
        NSUInteger flags = ((NSUInteger (*)(id, SEL))objc_msgSend)(keyEvent, NSSelectorFromString(@"modifierFlags"));
        NSInteger direction = code == 125 ? 1 : code == 126 ? -1 : 0;          // kVK_DownArrow, kVK_UpArrow
        // Command, Option and Control combinations belong to the app and the system.
        if (!direction || flags & ((1UL << 20) | (1UL << 19) | (1UL << 18))) return keyEvent;
        return RSMoveFeed(direction) ? nil : keyEvent;
    };
    static id monitor;
    monitor = ((id (*)(id, SEL, unsigned long long, id))objc_msgSend)(event, add, 1ULL << 10 /* key down */, handler);
    RSDebug(@"arrow key: AppKit monitor %@", monitor ? @"installed" : @"failed");
}

static void RSInstallArrowKeys(void) {
    // AppKit is ready only once the app has finished launching.
    [NSNotificationCenter.defaultCenter addObserverForName:UIApplicationDidFinishLaunchingNotification object:nil
                                                     queue:NSOperationQueue.mainQueue
                                                usingBlock:^(NSNotification *note) { RSInstallAppKitMonitor(); }];
    RSInstallArrowKeyCommands();
    static NSMutableSet<NSNumber *> *handled;
    handled = [NSMutableSet set];
    SEL selector = @selector(sendEvent:);
    RSReplace(UIApplication.class, selector, ^id(IMP original) {
        return ^void(UIApplication *application, UIEvent *event) {
            if (event.type == UIEventTypePresses && [event isKindOfClass:UIPressesEvent.class]) {
                BOOL swallow = NO;
                for (UIPress *press in ((UIPressesEvent *)event).allPresses) {
                    UIKey *key = press.key;
                    if (!key || key.modifierFlags & (UIKeyModifierCommand | UIKeyModifierControl | UIKeyModifierAlternate)) continue;
                    NSInteger direction = key.keyCode == UIKeyboardHIDUsageKeyboardDownArrow ? 1
                                        : key.keyCode == UIKeyboardHIDUsageKeyboardUpArrow ? -1 : 0;
                    if (!direction) continue;
                    NSNumber *code = @(key.keyCode);
                    if (press.phase == UIPressPhaseBegan) {
                        if (RSMoveFeed(direction)) { [handled addObject:code]; swallow = YES; }
                    } else if ([handled containsObject:code]) {
                        swallow = YES;                       // the matching key-up
                        if (press.phase == UIPressPhaseEnded || press.phase == UIPressPhaseCancelled) [handled removeObject:code];
                    }
                }
                if (swallow) return;
            }
            ((void (*)(id, SEL, UIEvent *))original)(application, selector, event);
        };
    });
}

#pragma mark - Volume

// iOS apps leave volume to the phone's buttons, so they play at full level with no control.
// Apps that play through AudioQueue (TikTok does) get a per-app volume: the helper rebinds
// the app's own calls to AudioQueueNewOutput/SetParameter/Dispose and scales the level each
// queue asks for. Only images inside the app bundle are rebound, never system libraries.

static float RSVolume = 1;
static os_unfair_lock RSQueueLock = OS_UNFAIR_LOCK_INIT;
static CFMutableDictionaryRef RSQueues;      // AudioQueueRef -> the volume the app asked for, as a boxed float

static OSStatus (*RSOriginalNewOutput)(const AudioStreamBasicDescription *, AudioQueueOutputCallback, void *,
                                       CFRunLoopRef, CFStringRef, UInt32, AudioQueueRef *);
static OSStatus (*RSOriginalSetParameter)(AudioQueueRef, AudioQueueParameterID, AudioQueueParameterValue);
static OSStatus (*RSOriginalDispose)(AudioQueueRef, Boolean);

static void RSRememberQueue(AudioQueueRef queue, float requested) {
    os_unfair_lock_lock(&RSQueueLock);
    if (!RSQueues) RSQueues = CFDictionaryCreateMutable(NULL, 0, NULL, &kCFTypeDictionaryValueCallBacks);
    CFNumberRef value = CFNumberCreate(NULL, kCFNumberFloatType, &requested);
    CFDictionarySetValue(RSQueues, queue, value);
    CFRelease(value);
    os_unfair_lock_unlock(&RSQueueLock);
}

static OSStatus RSNewOutput(const AudioStreamBasicDescription *format, AudioQueueOutputCallback callback, void *context,
                            CFRunLoopRef runLoop, CFStringRef mode, UInt32 flags, AudioQueueRef *queue) {
    OSStatus status = RSOriginalNewOutput(format, callback, context, runLoop, mode, flags, queue);
    if (status == noErr && queue && *queue) {
        static dispatch_once_t once;
        dispatch_once(&once, ^{ RSDebug(@"volume: controlling the app's audio queues"); });
        RSRememberQueue(*queue, 1);
        RSOriginalSetParameter(*queue, kAudioQueueParam_Volume, RSVolume);
    }
    return status;
}

static OSStatus RSSetParameter(AudioQueueRef queue, AudioQueueParameterID parameter, AudioQueueParameterValue value) {
    if (parameter == kAudioQueueParam_Volume) {
        RSRememberQueue(queue, value);
        value *= RSVolume;
    }
    return RSOriginalSetParameter(queue, parameter, value);
}

static OSStatus RSDispose(AudioQueueRef queue, Boolean immediate) {
    os_unfair_lock_lock(&RSQueueLock);
    if (RSQueues) CFDictionaryRemoveValue(RSQueues, queue);
    os_unfair_lock_unlock(&RSQueueLock);
    return RSOriginalDispose(queue, immediate);
}

static void RSApplyVolume(void) {
    if (!RSOriginalSetParameter) return;
    os_unfair_lock_lock(&RSQueueLock);
    CFIndex count = RSQueues ? CFDictionaryGetCount(RSQueues) : 0;
    const void **keys = calloc(MAX(count, 1), sizeof(void *)), **values = calloc(MAX(count, 1), sizeof(void *));
    if (count) CFDictionaryGetKeysAndValues(RSQueues, keys, values);
    float requested[MAX(count, 1)];
    for (CFIndex index = 0; index < count; index++) CFNumberGetValue(values[index], kCFNumberFloatType, &requested[index]);
    os_unfair_lock_unlock(&RSQueueLock);
    for (CFIndex index = 0; index < count; index++) {
        RSOriginalSetParameter((AudioQueueRef)keys[index], kAudioQueueParam_Volume, requested[index] * RSVolume);
    }
    free(keys);
    free(values);
}

// Apps that play through an output AudioUnit hand it a render callback. The helper slips its
// own callback in front: it calls the app's, then scales the samples it produced.
typedef struct {
    AudioUnit unit;
    AURenderCallback callback;
    void *context;
    _Atomic int format;           // 0 unknown (treated as float), 1 float32, 2 int16, 3 other
} RSRenderTap;

static RSRenderTap RSTaps[32];
static _Atomic int RSTapCount;
static OSStatus (*RSOriginalSetProperty)(AudioUnit, AudioUnitPropertyID, AudioUnitScope, AudioUnitElement, const void *, UInt32);

static RSRenderTap *RSTapFor(AudioUnit unit, BOOL create) {
    int count = RSTapCount;
    for (int index = 0; index < count; index++) if (RSTaps[index].unit == unit) return &RSTaps[index];
    if (!create || count >= 32) return NULL;
    RSTaps[count].unit = unit;
    RSTapCount = count + 1;
    return &RSTaps[count];
}

static OSStatus RSRender(void *context, AudioUnitRenderActionFlags *flags, const AudioTimeStamp *time,
                         UInt32 bus, UInt32 frames, AudioBufferList *data) {
    RSRenderTap *tap = context;
    OSStatus status = tap->callback(tap->context, flags, time, bus, frames, data);
    float volume = RSVolume;
    if (status != noErr || !data || volume > 0.999f) return status;
    int format = tap->format;
    for (UInt32 index = 0; index < data->mNumberBuffers; index++) {
        AudioBuffer *buffer = &data->mBuffers[index];
        if (!buffer->mData) continue;
        if (volume <= 0.0001f) { memset(buffer->mData, 0, buffer->mDataByteSize); continue; }
        if (format == 2) {
            int16_t *samples = buffer->mData;
            for (UInt32 sample = 0; sample < buffer->mDataByteSize / 2; sample++) samples[sample] = (int16_t)(samples[sample] * volume);
        } else if (format <= 1) {
            float *samples = buffer->mData;
            for (UInt32 sample = 0; sample < buffer->mDataByteSize / 4; sample++) samples[sample] *= volume;
        }
    }
    return status;
}

static OSStatus RSSetProperty(AudioUnit unit, AudioUnitPropertyID property, AudioUnitScope scope, AudioUnitElement element,
                              const void *value, UInt32 size) {
    if (property == kAudioUnitProperty_SetRenderCallback && value && size >= sizeof(AURenderCallbackStruct)) {
        const AURenderCallbackStruct *given = value;
        if (given->inputProc && given->inputProc != RSRender) {
            RSRenderTap *tap = RSTapFor(unit, YES);
            if (tap) {
                tap->callback = given->inputProc;
                tap->context = given->inputProcRefCon;
                static dispatch_once_t once;
                dispatch_once(&once, ^{ RSDebug(@"volume: controlling the app's audio unit"); });
                AURenderCallbackStruct wrapped = { RSRender, tap };
                return RSOriginalSetProperty(unit, property, scope, element, &wrapped, sizeof wrapped);
            }
        }
    } else if (property == kAudioUnitProperty_StreamFormat && scope == kAudioUnitScope_Input && value
               && size >= sizeof(AudioStreamBasicDescription)) {
        const AudioStreamBasicDescription *format = value;
        RSRenderTap *tap = RSTapFor(unit, YES);
        if (tap && format->mFormatID == kAudioFormatLinearPCM) {
            BOOL isFloat = format->mFormatFlags & kAudioFormatFlagIsFloat;
            tap->format = isFloat && format->mBitsPerChannel == 32 ? 1 : !isFloat && format->mBitsPerChannel == 16 ? 2 : 3;
        }
    }
    return RSOriginalSetProperty(unit, property, scope, element, value, size);
}

typedef struct { const char *name; void *replacement; void **original; } RSRebinding;

static void RSRebindSection(const struct section_64 *section, intptr_t slide, const struct nlist_64 *symbols,
                            const char *strings, const uint32_t *indirect, const RSRebinding *rebindings, size_t count) {
    const uint32_t *indices = indirect + section->reserved1;
    void **pointers = (void **)(slide + section->addr);
    size_t entries = section->size / sizeof(void *);
    for (size_t entry = 0; entry < entries; entry++) {
        uint32_t index = indices[entry];
        if (index & (INDIRECT_SYMBOL_ABS | INDIRECT_SYMBOL_LOCAL)) continue;
        const char *name = strings + symbols[index].n_un.n_strx;
        if (name[0] != '_') continue;
        for (size_t rebinding = 0; rebinding < count; rebinding++) {
            if (strcmp(name + 1, rebindings[rebinding].name) != 0) continue;
            if (pointers[entry] == rebindings[rebinding].replacement) break;
            if (!*rebindings[rebinding].original) *rebindings[rebinding].original = pointers[entry];
            uintptr_t page = (uintptr_t)&pointers[entry] & ~((uintptr_t)PAGE_SIZE - 1);
            if (mprotect((void *)page, PAGE_SIZE, PROT_READ | PROT_WRITE) == 0) {
                pointers[entry] = rebindings[rebinding].replacement;
            } else {
                RSDebug(@"volume: could not unlock %s for %s (errno %d)", section->sectname, rebindings[rebinding].name, errno);
            }
            break;
        }
    }
}

static const RSRebinding RSAudioRebindings[] = {
    { "AudioQueueNewOutput", (void *)RSNewOutput, (void **)&RSOriginalNewOutput },
    { "AudioQueueSetParameter", (void *)RSSetParameter, (void **)&RSOriginalSetParameter },
    { "AudioQueueDispose", (void *)RSDispose, (void **)&RSOriginalDispose },
    { "AudioUnitSetProperty", (void *)RSSetProperty, (void **)&RSOriginalSetProperty },
};

static void RSRebindImage(const struct mach_header *header, intptr_t slide) {
    Dl_info info, mine;
    if (!dladdr(header, &info) || !info.dli_fname || !strstr(info.dli_fname, ".app/")) return;    // app code only
    if (dladdr((void *)RSRebindImage, &mine) && mine.dli_fbase == info.dli_fbase) return;           // not this library
    const struct mach_header_64 *image = (const struct mach_header_64 *)header;
    const struct segment_command_64 *linkedit = NULL;
    const struct symtab_command *symtab = NULL;
    const struct dysymtab_command *dysymtab = NULL;
    const struct load_command *command = (const struct load_command *)(image + 1);
    for (uint32_t index = 0; index < image->ncmds; index++, command = (const void *)((const char *)command + command->cmdsize)) {
        if (command->cmd == LC_SEGMENT_64 && strcmp(((const struct segment_command_64 *)command)->segname, SEG_LINKEDIT) == 0)
            linkedit = (const struct segment_command_64 *)command;
        else if (command->cmd == LC_SYMTAB) symtab = (const struct symtab_command *)command;
        else if (command->cmd == LC_DYSYMTAB) dysymtab = (const struct dysymtab_command *)command;
    }
    if (!linkedit || !symtab || !dysymtab || !dysymtab->nindirectsyms) {
        return;
    }
    uintptr_t base = (uintptr_t)slide + linkedit->vmaddr - linkedit->fileoff;
    const struct nlist_64 *symbols = (const struct nlist_64 *)(base + symtab->symoff);
    const char *strings = (const char *)(base + symtab->stroff);
    const uint32_t *indirect = (const uint32_t *)(base + dysymtab->indirectsymoff);

    command = (const struct load_command *)(image + 1);
    for (uint32_t index = 0; index < image->ncmds; index++, command = (const void *)((const char *)command + command->cmdsize)) {
        if (command->cmd != LC_SEGMENT_64) continue;
        const struct segment_command_64 *segment = (const struct segment_command_64 *)command;
        if (strcmp(segment->segname, SEG_DATA) != 0 && strcmp(segment->segname, "__DATA_CONST") != 0) continue;
        const struct section_64 *section = (const struct section_64 *)(segment + 1);
        for (uint32_t number = 0; number < segment->nsects; number++, section++) {
            uint32_t type = section->flags & SECTION_TYPE;
            if (type == S_LAZY_SYMBOL_POINTERS || type == S_NON_LAZY_SYMBOL_POINTERS) {
                RSRebindSection(section, slide, symbols, strings, indirect, RSAudioRebindings,
                                sizeof RSAudioRebindings / sizeof *RSAudioRebindings);
            }
        }
    }
}

// A small rounded label in the middle of the window, like the system volume indicator.
static void RSShowVolume(void) {
    UIWindow *window = nil;
    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if (![scene isKindOfClass:UIWindowScene.class]) continue;
        for (UIWindow *candidate in ((UIWindowScene *)scene).windows) if (candidate.isKeyWindow) window = candidate;
    }
    if (!window) return;
    static UIVisualEffectView *badge;
    static UILabel *label;
    static UIImageView *icon;
    if (!badge) {
        badge = [[UIVisualEffectView alloc] initWithEffect:[UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemThickMaterialDark]];
        badge.layer.cornerRadius = 18;
        badge.clipsToBounds = YES;
        badge.userInteractionEnabled = NO;
        icon = [UIImageView new];
        icon.tintColor = UIColor.whiteColor;
        icon.contentMode = UIViewContentModeScaleAspectFit;
        label = [UILabel new];
        label.textColor = UIColor.whiteColor;
        label.font = [UIFont monospacedDigitSystemFontOfSize:17 weight:UIFontWeightSemibold];
        UIStackView *stack = [[UIStackView alloc] initWithArrangedSubviews:@[icon, label]];
        stack.spacing = 10;
        stack.alignment = UIStackViewAlignmentCenter;
        stack.translatesAutoresizingMaskIntoConstraints = NO;
        [badge.contentView addSubview:stack];
        [NSLayoutConstraint activateConstraints:@[
            [stack.centerXAnchor constraintEqualToAnchor:badge.contentView.centerXAnchor],
            [stack.centerYAnchor constraintEqualToAnchor:badge.contentView.centerYAnchor],
            [icon.widthAnchor constraintEqualToConstant:24], [icon.heightAnchor constraintEqualToConstant:24],
        ]];
    }
    int percent = (int)lroundf(RSVolume * 100);
    NSString *symbol = percent == 0 ? @"speaker.slash.fill" : percent < 34 ? @"speaker.wave.1.fill"
                     : percent < 67 ? @"speaker.wave.2.fill" : @"speaker.wave.3.fill";
    icon.image = [UIImage systemImageNamed:symbol];
    label.text = percent == 0 ? @"Muted" : [NSString stringWithFormat:@"%d%%", percent];
    badge.frame = CGRectMake(0, 0, 150, 56);
    badge.center = CGPointMake(CGRectGetMidX(window.bounds), CGRectGetMidY(window.bounds));
    if (badge.superview != window) [window addSubview:badge];
    [window bringSubviewToFront:badge];
    badge.alpha = 1;
    [NSObject cancelPreviousPerformRequestsWithTarget:badge];
    [UIView animateWithDuration:0.4 delay:1.0 options:UIViewAnimationOptionBeginFromCurrentState
                     animations:^{ badge.alpha = 0; } completion:nil];
}

static float RSVolumeBeforeMute = 1;
static void RSRefreshVolumeControls(void);

static void RSSetVolume(float volume, BOOL show) {
    RSVolume = MIN(MAX(volume, 0), 1);
    RSApplyVolume();
    RSStoreSetting(@"volume", @(RSVolume));
    RSRefreshVolumeControls();
    if (show) RSShowVolume();
}

static NSString *RSSpeakerSymbol(float volume) {
    return volume <= 0.0001f ? @"speaker.slash.fill" : volume < 0.34f ? @"speaker.wave.1.fill"
         : volume < 0.67f ? @"speaker.wave.2.fill" : @"speaker.wave.3.fill";
}

#pragma mark - Volume: on-screen control

// A window above the app's own that only takes clicks on its controls; everything else
// falls through to the app underneath. The app can never cover it.
@interface RSOverlayWindow : UIWindow
@end

@implementation RSOverlayWindow
- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
    UIView *view = [super hitTest:point withEvent:event];
    return (view == self || view == self.rootViewController.view) ? nil : view;
}
- (BOOL)canBecomeKeyWindow { return NO; }
@end

// A speaker button in the top-right corner. Clicking it slides out a slider; scrolling over
// it changes the level. It stays faint until the pointer is on it.
@interface RSVolumeControl : UIVisualEffectView
@property (nonatomic, strong) UIButton *button;
@property (nonatomic, strong) UIImageView *icon;
@property (nonatomic, strong) UISlider *slider;
@property (nonatomic, strong) UILabel *label;
@property (nonatomic, strong) NSLayoutConstraint *width;
@property (nonatomic) BOOL expanded, hovering;
@property (nonatomic, strong) NSTimer *collapseTimer;
@end

static NSHashTable<RSVolumeControl *> *RSVolumeControls;
static const CGFloat RSControlSize = 36, RSControlOpen = 220;

@implementation RSVolumeControl

- (instancetype)init {
    self = [super initWithEffect:[UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemMaterialDark]];
    self.contentView.backgroundColor = [UIColor colorWithWhite:0 alpha:0.35];
    self.layer.borderColor = [UIColor colorWithWhite:1 alpha:0.18].CGColor;
    self.layer.borderWidth = 1;
    self.layer.cornerRadius = RSControlSize / 2;
    self.layer.cornerCurve = kCACornerCurveContinuous;
    self.clipsToBounds = YES;
    self.translatesAutoresizingMaskIntoConstraints = NO;
    self.accessibilityLabel = @"Volume";

    _icon = [UIImageView new];
    _icon.tintColor = UIColor.whiteColor;
    _icon.contentMode = UIViewContentModeCenter;
    _icon.translatesAutoresizingMaskIntoConstraints = NO;

    _button = [UIButton buttonWithType:UIButtonTypeCustom];
    _button.translatesAutoresizingMaskIntoConstraints = NO;
    _button.accessibilityLabel = @"Volume";
    [_button addTarget:self action:@selector(toggle) forControlEvents:UIControlEventTouchUpInside];

    _slider = [UISlider new];
    _slider.minimumValue = 0;
    _slider.maximumValue = 1;
    _slider.tintColor = UIColor.whiteColor;
    _slider.translatesAutoresizingMaskIntoConstraints = NO;
    _slider.accessibilityLabel = @"Volume";
    [_slider addTarget:self action:@selector(slid) forControlEvents:UIControlEventValueChanged];

    _label = [UILabel new];
    _label.textColor = UIColor.whiteColor;
    _label.font = [UIFont monospacedDigitSystemFontOfSize:13 weight:UIFontWeightSemibold];
    _label.textAlignment = NSTextAlignmentRight;
    _label.translatesAutoresizingMaskIntoConstraints = NO;

    UIView *content = self.contentView;
    for (UIView *view in @[_slider, _label, _icon, _button]) [content addSubview:view];
    _width = [self.widthAnchor constraintEqualToConstant:RSControlSize];
    [NSLayoutConstraint activateConstraints:@[
        _width,
        [self.heightAnchor constraintEqualToConstant:RSControlSize],
        [_button.trailingAnchor constraintEqualToAnchor:content.trailingAnchor],
        [_button.centerYAnchor constraintEqualToAnchor:content.centerYAnchor],
        [_button.widthAnchor constraintEqualToConstant:RSControlSize],
        [_button.heightAnchor constraintEqualToConstant:RSControlSize],
        [_icon.centerXAnchor constraintEqualToAnchor:_button.centerXAnchor],
        [_icon.centerYAnchor constraintEqualToAnchor:_button.centerYAnchor],
        [_icon.widthAnchor constraintEqualToConstant:24],
        [_icon.heightAnchor constraintEqualToConstant:24],
        [_label.trailingAnchor constraintEqualToAnchor:_button.leadingAnchor constant:-2],
        [_label.centerYAnchor constraintEqualToAnchor:content.centerYAnchor],
        [_label.widthAnchor constraintEqualToConstant:40],
        // Fixed width, hung off the label: when the control closes, the slider slides out of
        // view to the left instead of squeezing the speaker icon.
        [_slider.trailingAnchor constraintEqualToAnchor:_label.leadingAnchor constant:-6],
        [_slider.widthAnchor constraintEqualToConstant:RSControlOpen - 14 - 6 - 40 - 2 - RSControlSize],
        [_slider.centerYAnchor constraintEqualToAnchor:content.centerYAnchor],
    ]];

    UIHoverGestureRecognizer *hover = [[UIHoverGestureRecognizer alloc] initWithTarget:self action:@selector(hovered:)];
    [self addGestureRecognizer:hover];
    UIPanGestureRecognizer *scroll = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(scrolled:)];
    scroll.allowedScrollTypesMask = UIScrollTypeMaskAll;
    scroll.maximumNumberOfTouches = 0;               // scroll wheel and trackpad only, never a drag
    [self addGestureRecognizer:scroll];

    [self refresh];
    [self updateAppearance:NO];
    return self;
}

- (void)refresh {
    if (!self.slider.isTracking) self.slider.value = RSVolume;
    int percent = (int)lroundf(RSVolume * 100);
    self.label.text = [NSString stringWithFormat:@"%d%%", percent];
    UIImageSymbolConfiguration *configuration = [UIImageSymbolConfiguration configurationWithPointSize:15 weight:UIImageSymbolWeightSemibold];
    self.icon.image = [[UIImage systemImageNamed:RSSpeakerSymbol(RSVolume) withConfiguration:configuration]
                       imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate];
    self.accessibilityValue = self.label.text;
}

- (void)updateAppearance:(BOOL)animated {
    void (^changes)(void) = ^{
        self.width.constant = self.expanded ? RSControlOpen : RSControlSize;
        self.slider.alpha = self.label.alpha = self.expanded ? 1 : 0;
        self.alpha = (self.expanded || self.hovering) ? 1 : 0.85;
        [self.superview layoutIfNeeded];
    };
    if (animated) [UIView animateWithDuration:0.22 delay:0 usingSpringWithDamping:0.9 initialSpringVelocity:0
                                      options:UIViewAnimationOptionAllowUserInteraction animations:changes completion:nil];
    else changes();
}

- (void)scheduleCollapse {
    [self.collapseTimer invalidate];
    __weak RSVolumeControl *weakSelf = self;
    self.collapseTimer = [NSTimer scheduledTimerWithTimeInterval:3 repeats:NO block:^(NSTimer *timer) {
        RSVolumeControl *control = weakSelf;
        if (!control || control.hovering || control.slider.isTracking) { [control scheduleCollapse]; return; }
        control.expanded = NO;
        [control updateAppearance:YES];
    }];
}

- (void)toggle {
    self.expanded = !self.expanded;
    [self updateAppearance:YES];
    if (self.expanded) [self scheduleCollapse];
}

- (void)slid {
    RSSetVolume(self.slider.value, NO);
    [self scheduleCollapse];
}

- (void)hovered:(UIHoverGestureRecognizer *)hover {
    self.hovering = hover.state == UIGestureRecognizerStateBegan || hover.state == UIGestureRecognizerStateChanged;
    [self updateAppearance:YES];
}

- (void)scrolled:(UIPanGestureRecognizer *)scroll {
    CGPoint delta = [scroll translationInView:self];
    [scroll setTranslation:CGPointZero inView:self];
    CGFloat step = (fabs(delta.y) > fabs(delta.x) ? -delta.y : delta.x) / 300;   // up or right is louder
    if (step != 0) RSSetVolume(RSVolume + step, NO);
    if (!self.expanded) { self.expanded = YES; [self updateAppearance:YES]; }
    [self scheduleCollapse];
}

@end

static void RSRefreshVolumeControls(void) {
    for (RSVolumeControl *control in RSVolumeControls) [control refresh];
}

static void RSAddVolumeControl(UIWindowScene *scene) {
    static const char key = 0;
    if (!RSFlag(@"showVolumeButton", YES) || objc_getAssociatedObject(scene, &key)) return;
    RSOverlayWindow *overlay = [[RSOverlayWindow alloc] initWithWindowScene:scene];
    overlay.windowLevel = UIWindowLevelNormal + 1;
    overlay.backgroundColor = UIColor.clearColor;
    UIViewController *root = [UIViewController new];
    root.view.backgroundColor = UIColor.clearColor;
    overlay.rootViewController = root;
    RSVolumeControl *control = [RSVolumeControl new];
    [root.view addSubview:control];
    // Top right, under the row where apps usually put Search; clear of the window buttons.
    [NSLayoutConstraint activateConstraints:@[
        [control.trailingAnchor constraintEqualToAnchor:root.view.trailingAnchor constant:-16],
        [control.topAnchor constraintEqualToAnchor:root.view.topAnchor constant:84],
    ]];
    overlay.hidden = NO;
    objc_setAssociatedObject(scene, &key, overlay, OBJC_ASSOCIATION_RETAIN);
    if (!RSVolumeControls) RSVolumeControls = [NSHashTable weakObjectsHashTable];
    [RSVolumeControls addObject:control];
}

static void RSReadVolume(void) {
    id value = RSSettings[@"volume"];
    RSVolume = [value respondsToSelector:@selector(floatValue)] ? MIN(MAX([value floatValue], 0), 1) : 1;
}

static void RSSettingsDidChange(CFNotificationCenterRef center, void *observer, CFNotificationName name,
                                const void *object, CFDictionaryRef info) {
    dispatch_async(dispatch_get_main_queue(), ^{
        RSLoadSettings();
        RSReadVolume();
        RSApplyVolume();
        RSRefreshVolumeControls();
    });
}

// A Volume menu in the app's menu bar: louder, quieter and mute, with ⌘↑, ⌘↓ and ⌘0.
static void RSInstallVolumeMenu(void) {
    SEL louder = NSSelectorFromString(@"runnerShimVolumeUp:"), quieter = NSSelectorFromString(@"runnerShimVolumeDown:");
    SEL mute = NSSelectorFromString(@"runnerShimToggleMute:");
    class_addMethod(UIApplication.class, louder, imp_implementationWithBlock(^(id app, id sender) {
        RSSetVolume(roundf(RSVolume * 10 + 1) / 10, YES);
    }), "v@:@");
    class_addMethod(UIApplication.class, quieter, imp_implementationWithBlock(^(id app, id sender) {
        RSSetVolume(roundf(RSVolume * 10 - 1) / 10, YES);
    }), "v@:@");
    class_addMethod(UIApplication.class, mute, imp_implementationWithBlock(^(id app, id sender) {
        if (RSVolume > 0) { RSVolumeBeforeMute = RSVolume; RSSetVolume(0, YES); }
        else RSSetVolume(RSVolumeBeforeMute > 0 ? RSVolumeBeforeMute : 1, YES);
    }), "v@:@");

    UIMenu *menu = [UIMenu menuWithTitle:@"Volume" image:nil identifier:@"dev.catalyst-runner.volume" options:0 children:@[
        [UIKeyCommand commandWithTitle:@"Louder" image:[UIImage systemImageNamed:@"speaker.wave.3"] action:louder
                                 input:UIKeyInputUpArrow modifierFlags:UIKeyModifierCommand propertyList:nil],
        [UIKeyCommand commandWithTitle:@"Quieter" image:[UIImage systemImageNamed:@"speaker.wave.1"] action:quieter
                                 input:UIKeyInputDownArrow modifierFlags:UIKeyModifierCommand propertyList:nil],
        [UIKeyCommand commandWithTitle:@"Mute" image:[UIImage systemImageNamed:@"speaker.slash"] action:mute
                                 input:@"0" modifierFlags:UIKeyModifierCommand propertyList:nil],
    ]];

    // macOS builds the menu bar by sending buildMenuWithBuilder: to UIApplication, which passes
    // it on to the app delegate. Hooking UIApplication works whatever the delegate is.
    SEL build = @selector(buildMenuWithBuilder:);
    RSReplace(UIApplication.class, build, ^id(IMP original) {
        return ^void(UIApplication *application, id<UIMenuBuilder> builder) {
            ((void (*)(id, SEL, id))original)(application, build, builder);
            if (builder.system == UIMenuSystem.mainSystem && ![builder menuForIdentifier:menu.identifier]) {
                if ([builder menuForIdentifier:UIMenuView]) [builder insertSiblingMenu:menu afterMenuForIdentifier:UIMenuView];
                else [builder insertSiblingMenu:menu beforeMenuForIdentifier:UIMenuWindow];
                RSDebug(@"volume: menu added");
            }
        };
    });
    [UIMenuSystem.mainSystem setNeedsRebuild];
}

static void RSInstallVolume(void) {
    RSReadVolume();
    _dyld_register_func_for_add_image(RSRebindImage);           // also runs for images already loaded
    CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(), NULL, RSSettingsDidChange,
                                    (__bridge CFStringRef)RSSettingsChanged, NULL, CFNotificationSuspensionBehaviorDeliverImmediately);
    [NSNotificationCenter.defaultCenter addObserverForName:UIApplicationDidFinishLaunchingNotification object:nil
                                                     queue:NSOperationQueue.mainQueue
                                                usingBlock:^(NSNotification *note) { RSInstallVolumeMenu(); }];
    [NSNotificationCenter.defaultCenter addObserverForName:UISceneDidActivateNotification object:nil
                                                     queue:NSOperationQueue.mainQueue
                                                usingBlock:^(NSNotification *note) {
        if ([note.object isKindOfClass:UIWindowScene.class]) RSAddVolumeControl(note.object);
    }];
}

// Test hooks, used by Tests/Shim: drive the volume without a running app.
void RSTestSetVolume(float volume) { RSVolume = volume; RSApplyVolume(); }
void RSTestRebindImage(const struct mach_header *header, intptr_t slide) { RSRebindImage(header, slide); }

#pragma mark - Install

__attribute__((constructor)) static void RSInstall(void) {
    RSLoadSettings();
    RSInstallWindowFixes();
    if (RSFlag(@"arrowKeysScrollFeed", YES)) RSInstallArrowKeys();
    RSInstallVolume();
    for (Class cls in @[AVCaptureSession.class, AVCaptureOutput.class, AVCaptureVideoPreviewLayer.class]) {
        unsigned int count = 0;
        Method *methods = class_copyMethodList(cls, &count);
        for (unsigned int index = 0; index < count; index++) RSGuardDeferred(methods[index]);
        free(methods);
    }
    if (RSFlag(@"lockCameraOrientation", YES)) RSInstallOrientationLock();
    if (RSFlag(@"cropCameraToPortrait", YES)) RSInstallPortraitCrop();
}
