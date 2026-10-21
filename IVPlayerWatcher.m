#import "IVPlayerWatcher.h"
#import "IVGlassOverlay.h"
#import <math.h>

/// 是否尝试压掉系统自带的播放控件（播放/进度条）。
/// 如果在你机器上误伤了画面，把这里改成 NO 重新打包即可。
static const BOOL kHideNativeChrome = YES;

#pragma mark - 原生控件指纹

static BOOL IVNameLooksLikeChrome(NSString *name) {
    if (name.length == 0) return NO;
    if ([name hasPrefix:@"IV"]) return NO;          // 自己人
    if ([name hasPrefix:@"_UI"]) return NO;          // UIKit 内部视图，不碰
    if ([name hasPrefix:@"UI"]) return NO;

    static NSArray<NSString *> *keys = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        keys = @[ @"PlaybackControl", @"PlaybackScrub", @"Scrubber",
                  @"TimelineScrub", @"PlayPauseButton", @"PlayButtonTile",
                  @"PlayerControls", @"VideoControlsView" ];
    });

    for (NSString *k in keys) {
        if ([name rangeOfString:k options:NSCaseInsensitiveSearch].location != NSNotFound) {
            return YES;
        }
    }
    return NO;
}

/// 递归收集「看起来像原生播放控件」的视图；命中后不再往子层钻。
static void IVCollectChrome(UIView *root, UIView *skip, CGFloat maxDim,
                            NSMutableArray<UIView *> *out, int depth);

static void IVCollectChrome(UIView *root, UIView *skip, CGFloat maxDim,
                            NSMutableArray<UIView *> *out, int depth) {
    if (root == nil || depth > 8 || out.count >= 20) return;

    for (UIView *v in root.subviews) {
        if (v == skip || v == nil) continue;

        CGSize sz = v.bounds.size;
        BOOL sane = (sz.width > 1.0 && sz.height > 1.0 &&
                     sz.height <= maxDim && sz.width <= maxDim * 2.0);

        if (sane && IVNameLooksLikeChrome(NSStringFromClass([v class]))) {
            if (!v.hidden && v.alpha > 0.03) {
                [out addObject:v];
            }
            continue;
        }

        if (v.subviews.count > 0) {
            IVCollectChrome(v, skip, maxDim, out, depth + 1);
        }
    }
}

#pragma mark - 窗口定位

/// CALayer 没有 window 属性：沿 superlayer 走到根层，再到各 UIWindowScene 里比对。
static NSArray<UIWindow *> *IVAllWindows(void) {
    NSMutableArray<UIWindow *> *arr = [NSMutableArray array];
    UIApplication *app = [UIApplication sharedApplication];
    for (UIScene *sc in app.connectedScenes) {
        if (![sc isKindOfClass:[UIWindowScene class]]) continue;
        UIWindowScene *ws = (UIWindowScene *)sc;
        [arr addObjectsFromArray:ws.windows];
    }
    return arr;
}

static UIWindow *IVWindowForLayer(CALayer *layer) {
    if (layer == nil) return nil;

    CALayer *root = layer;
    int guard = 0;
    while (root.superlayer != nil && guard < 128) {
        root = root.superlayer;
        guard++;
    }

    for (UIWindow *w in IVAllWindows()) {
        if (w.layer == root) return w;
    }

    id del = layer.delegate;
    if ([del isKindOfClass:[UIView class]]) {
        return ((UIView *)del).window;
    }
    return nil;
}

#pragma mark -

@interface IVPlayerWatcher () {
    NSHashTable<AVPlayerLayer *> *_layers;
    IVGlassOverlay               *_overlay;
    UIWindow                     *_hostWindow;
    NSTimer                      *_scanTimer;
}
@end

@implementation IVPlayerWatcher

+ (instancetype)shared {
    static IVPlayerWatcher *inst = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        inst = [[IVPlayerWatcher alloc] init];
    });
    return inst;
}

- (instancetype)init {
    self = [super init];
    if (!self) return nil;
    _layers = [NSHashTable weakObjectsHashTable];
    return self;
}

#pragma mark - 注册

- (void)noteLayer:(AVPlayerLayer *)layer {
    if (!layer) return;
    @synchronized (self) {
        [_layers addObject:layer];
    }
    [self ensureScanning];
}

- (void)forgetLayer:(AVPlayerLayer *)layer {
    if (!layer) return;
    @synchronized (self) {
        [_layers removeObject:layer];
    }
}

- (void)ensureScanning {
    if (_scanTimer) return;

    __weak typeof(self) ws = self;
    _scanTimer = [NSTimer scheduledTimerWithTimeInterval:0.45
                                                 repeats:YES
                                                   block:^(NSTimer *t) {
        __strong typeof(ws) s = ws;
        if (!s) {
            [t invalidate];
            return;
        }
        [s scan];
    }];
}

#pragma mark - 扫描

- (void)scan {
    NSArray<AVPlayerLayer *> *snapshot = nil;
    @synchronized (self) {
        snapshot = [_layers allObjects];
    }

    if (snapshot.count == 0 && _overlay == nil) {
        [_scanTimer invalidate];
        _scanTimer = nil;
        return;
    }

    AVPlayerLayer *best = nil;
    CGFloat bestArea = 0.0;
    UIWindow *bestWindow = nil;

    for (AVPlayerLayer *l in snapshot) {
        if (l == nil) continue;
        if (l.player == nil) continue;

        UIWindow *win = IVWindowForLayer(l);
        if (win == nil) continue;

        CGSize lb = l.bounds.size;
        if (lb.width < 2.0 || lb.height < 2.0) continue;

        CGSize screen = win.bounds.size;
        if (screen.width < 2.0 || screen.height < 2.0) continue;

        // 换算到窗口坐标，判断占用面积
        CGRect r = [l convertRect:l.bounds toLayer:win.layer];
        CGFloat area = fabs(r.size.width * r.size.height);
        CGFloat screenArea = screen.width * screen.height;

        BOOL wideEnough = (fabs(r.size.width) >= screen.width * 0.62);
        BOOL bigEnough  = (area >= screenArea * 0.26);

        if (!wideEnough || !bigEnough) continue;

        if (area > bestArea) {
            bestArea = area;
            best = l;
            bestWindow = win;
        }
    }

    if (best == nil || bestWindow == nil) {
        [self teardownOverlay];
        return;
    }

    [self mountOverlayForLayer:best inWindow:bestWindow];

    if (kHideNativeChrome) {
        [self suppressNativeChromeForLayer:best inWindow:bestWindow];
    }
}

#pragma mark - 挂载 / 卸载

- (void)mountOverlayForLayer:(AVPlayerLayer *)layer inWindow:(UIWindow *)win {
    if (_overlay != nil && (_hostWindow != win || _overlay.superview != win)) {
        [self teardownOverlay];
    }

    if (_overlay == nil) {
        IVGlassOverlay *ov = [[IVGlassOverlay alloc] initWithFrame:win.bounds];
        ov.player = layer.player;
        [win addSubview:ov];
        [ov startTracking];

        _overlay = ov;
        _hostWindow = win;
    } else {
        _overlay.player = layer.player;
    }

    if (!CGRectEqualToRect(_overlay.frame, win.bounds)) {
        _overlay.frame = win.bounds;
        [_overlay relayout];
    }

    if ([win.subviews lastObject] != _overlay) {
        [win bringSubviewToFront:_overlay];
    }
}

- (void)teardownOverlay {
    if (_overlay == nil) return;
    [_overlay stopTracking];
    [_overlay removeFromSuperview];
    _overlay = nil;
    _hostWindow = nil;
}

#pragma mark - 压掉原生控件

- (void)suppressNativeChromeForLayer:(AVPlayerLayer *)layer inWindow:(UIWindow *)win {
    id del = layer.delegate;
    UIView *videoView = nil;
    if ([del isKindOfClass:[UIView class]]) {
        videoView = (UIView *)del;
    }

    CGFloat maxDim = MAX(win.bounds.size.width, win.bounds.size.height) * 0.45;

    NSMutableArray<UIView *> *hits = [NSMutableArray array];
    IVCollectChrome(win, videoView, maxDim, hits, 0);

    for (UIView *v in hits) {
        if (v.alpha > 0.03) {
            v.alpha = 0.0;
        }
    }
}

@end
