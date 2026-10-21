#import "IVPlayerWatcher.h"
#import "IVGlassOverlay.h"
#import "IVGlassKit.h"
#import <math.h>

/// 是否尝试压掉系统自带的播放控件（播放/进度条）。
/// 如果在你机器上误伤了画面，把这里改成 NO 重新打包即可。
static const BOOL kHideNativeChrome = YES;

/// 是否给顶部时间胶囊套玻璃。
static const BOOL kGlassTopCapsule = YES;

#pragma mark - 原生控件指纹

static BOOL IVNameLooksLikeChrome(NSString *name) {
    if (name.length == 0) return NO;
    if ([name hasPrefix:@"IV"]) return NO;          // 自己人
    if ([name hasPrefix:@"_UI"]) return NO;          // UIKit 内部视图，不碰
    if ([name hasPrefix:@"UI"]) return NO;

    // 【硬排除】相册底部那排「可滑动的缩略图条」就是 scrubber 家族，
    // 用户明说要它，压掉就变成一条空白。这里先挡掉，再看白名单。
    static NSArray<NSString *> *banned = nil;
    static dispatch_once_t once2;
    dispatch_once(&once2, ^{
        banned = @[ @"Scrub", @"Filmstrip", @"FilmStrip", @"ThumbnailStrip" ];
    });
    for (NSString *k in banned) {
        if ([name rangeOfString:k options:NSCaseInsensitiveSearch].location != NSNotFound) {
            return NO;
        }
    }

    static NSArray<NSString *> *keys = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        keys = @[ @"PlaybackControl", @"PlayPauseButton", @"PlayButtonTile",
                  @"PlayerControls", @"VideoControlsView" ];
    });

    for (NSString *k in keys) {
        if ([name rangeOfString:k options:NSCaseInsensitiveSearch].location != NSNotFound) {
            return YES;
        }
    }
    return NO;
}

/// 图层是否真的“露在屏幕上”：自身与所有祖先都不能被隐藏 / 透明化。
/// 相册翻页时会把整页做成一个不可见的快照，只看 bounds 是认不出来的。
static BOOL IVLayerIsVisible(AVPlayerLayer *layer) {
    if (layer == nil) return NO;
    if (layer.hidden) return NO;
    if (layer.opacity < 0.02) return NO;

    CALayer *cur = layer.superlayer;
    int guard = 0;
    while (cur != nil && guard < 64) {
        if (cur.hidden || cur.opacity < 0.02) return NO;
        cur = cur.superlayer;
        guard++;
    }
    return YES;
}

#pragma mark - 遮挡检测（几何判断抓不到的那一半）

/// 子树里是否存在「一块铺满屏幕的静态图像」——也就是另一张照片页。
/// 相册翻页时旧页不会被移出层级，只是被新页盖住：几何上它仍然全屏，
/// 所以只能靠「它上面压着一个有内容的全屏兄弟」来判定它已经不在前台。
static BOOL IVSubtreeShowsStaticImage(UIView *v, UIWindow *win, int depth, int *budget) {
    if (v == nil || depth > 6 || budget == NULL || *budget <= 0) return NO;
    (*budget)--;
    if (v.hidden || v.alpha < 0.30) return NO;

    CGFloat winArea = win.bounds.size.width * win.bounds.size.height;
    if (winArea < 1.0) return NO;

    CGRect f = [v convertRect:v.bounds toView:win];
    CGFloat area = f.size.width * f.size.height;

    if (area >= winArea * 0.45) {
        // 有画面内容（UIImageView / 直接 setContents 的自绘视图）
        if (v.layer.contents != nil) return YES;

        CGColorRef bg = v.backgroundColor.CGColor;
        if (bg != NULL && CGColorGetAlpha(bg) > 0.9 && v.subviews.count == 0) return YES;
    }

    for (UIView *s in v.subviews) {
        if (IVSubtreeShowsStaticImage(s, win, depth + 1, budget)) return YES;
    }
    return NO;
}

/// 播放是否已经到结尾。
/// 播完之后相册会停在最后一帧（往往是一张静止的快照），player 变 paused ——
/// 这时候遮挡判定会误以为「已经切到别的照片」，把 overlay 拆掉，
/// 于是用户再点画面就什么也唤不出来。结尾状态必须豁免。
static BOOL IVPlayerNearEnd(AVPlayer *p) {
    if (p == nil) return NO;
    AVPlayerItem *item = p.currentItem;
    if (item == nil) return NO;

    CMTime d = item.duration;
    if (!CMTIME_IS_NUMERIC(d)) return NO;
    double ds = CMTimeGetSeconds(d);
    if (ds <= 0.2) return NO;

    double cs = CMTimeGetSeconds(p.currentTime);
    if (!isfinite(cs) || cs < 0.0) return NO;

    return (cs >= ds - 0.40);
}

/// 在视频视图之上，找有没有一个「盖住大半个屏幕、而且里面是一张静态图」的兄弟视图。
static UIView *IVPageOccluder(UIView *videoView, UIWindow *win) {
    if (videoView == nil || win == nil) return nil;

    UIView *child = videoView;
    UIView *parent = videoView.superview;
    int guard = 0;

    while (parent != nil && guard < 24) {
        NSArray<UIView *> *subs = parent.subviews;
        NSUInteger idx = [subs indexOfObjectIdenticalTo:child];
        if (idx != NSNotFound) {
            for (NSUInteger i = idx + 1; i < subs.count; i++) {
                UIView *sib = subs[i];
                if (sib.hidden || sib.alpha < 0.5) continue;

                CGRect f = [sib convertRect:sib.bounds toView:win];
                if (f.size.width < win.bounds.size.width * 0.85) continue;
                if (f.size.height < win.bounds.size.height * 0.55) continue;

                int budget = 1200;   // 这次扫描的视图访问预算，防止极端层级下卡主线程
                if (IVSubtreeShowsStaticImage(sib, win, 0, &budget)) return sib;
            }
        }

        if (parent == win) break;
        child = parent;
        parent = parent.superview;
        guard++;
    }
    return nil;
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
    AVPlayerLayer                *_boundLayer;      // overlay 当前绑定的是哪个 layer（弱引用，别拖住它）
    NSTimer                      *_scanTimer;
    // 被我们压掉 alpha 的原生控件：view -> 原始 alpha。
    // 必须记下来，卸载 overlay 时还原 —— 否则切到照片后底部工具栏会一直是透明的。
    NSMapTable<UIView *, NSNumber *> *_suppressed;
    CGRect                        _syncedVideoRect;
    // 遮挡判定：被别的页面盖住的那个 layer，以及连续命中的次数（防瞬时快照误判）
    __weak AVPlayerLayer         *_occludedLayer;
    int                           _occludedScans;
    // 翻页手势期间先把控制层藏起来，松手后再恢复
    NSTimer                      *_reshowTimer;
    BOOL                          _hiddenByDrag;
}

- (void)scan;
- (void)mountOverlayForLayer:(AVPlayerLayer *)layer
                    inWindow:(UIWindow *)win
                   videoRect:(CGRect)videoRect;
- (void)restoreNativeChrome;
- (void)scheduleReshowIfNeeded;
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
    _suppressed = [NSMapTable weakToStrongObjectsMapTable];
    _syncedVideoRect = CGRectZero;
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
    // 0.45s 太慢：滑走之后 overlay 还会在照片上赖将近半秒。
    // 0.18s 足以做到肉眼「跟着翻页一起消失」，而开销只是一次很小的数组遍历。
    _scanTimer = [NSTimer scheduledTimerWithTimeInterval:0.18
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

    // ---- 第一道：几何筛选，收集候选 ----
    NSMutableArray<AVPlayerLayer *> *cands   = [NSMutableArray array];
    NSMutableArray<NSValue *>        *rects   = [NSMutableArray array];
    NSMutableArray<NSValue *>        *wins    = [NSMutableArray array];
    NSMutableArray<NSNumber *>       *areas   = [NSMutableArray array];

    for (AVPlayerLayer *l in snapshot) {
        if (l == nil) continue;
        if (l.player == nil) continue;
        if (!IVLayerIsVisible(l)) continue;

        UIWindow *win = IVWindowForLayer(l);
        if (win == nil) continue;

        CGSize lb = l.bounds.size;
        if (lb.width < 2.0 || lb.height < 2.0) continue;

        CGSize screen = win.bounds.size;
        if (screen.width < 2.0 || screen.height < 2.0) continue;

        // 换算到窗口坐标，并且——关键——裁到窗口可视区域内再判断。
        CGRect r = [l convertRect:l.bounds toLayer:win.layer];
        CGRect clip = CGRectIntersection(r, win.bounds);
        if (CGRectIsNull(clip) || CGRectIsEmpty(clip)) continue;

        CGFloat layerArea = fabs(r.size.width * r.size.height);
        if (layerArea < 1.0) continue;

        CGFloat clipArea = fabs(clip.size.width * clip.size.height);
        CGFloat screenArea = screen.width * screen.height;

        // 1) 得是「一块像样的全屏画面」，侧边预览 / 缩略图不算
        if (layerArea < screenArea * 0.18) continue;

        // 2) 得基本完整地摆在屏幕上。相册左右翻页时整页被平移出去，
        //    这一比值会立刻掉下来 —— 于是滑到照片的瞬间 overlay 就会卸载，
        //    而不会像原来那样跟着照片一起留在屏幕上。
        //    阈值取 0.72 而不是 0.95：画面若是 aspect-fill 会有轻微溢出，
        //    卡太死会让某些视频根本不挂控件。
        if (clipArea / layerArea < 0.72) continue;

        // 3) 横向要够宽（排除竖条形的画中画）
        if (clip.size.width < screen.width * 0.50) continue;

        // 4) 中心得大致落在屏幕中线上：翻页过半后整页已经偏了，这里直接否掉
        CGFloat cx = CGRectGetMidX(clip);
        if (fabs(cx - CGRectGetMidX(win.bounds)) > screen.width * 0.20) continue;

        [cands addObject:l];
        [rects addObject:[NSValue valueWithCGRect:r]];
        [wins  addObject:[NSValue valueWithNonretainedObject:win]];
        [areas addObject:@(clipArea)];
    }

    if (cands.count == 0) {
        [self teardownOverlay];
        return;
    }

    // ---- 第二道：遮挡判定 ----
    // 相册翻页结束后，旧视频页并没有被移出层级、也依然全屏，纯几何判断抓不到。
    // 但它上面会压着新页（一张铺满屏幕的静态图），从这里认。
    // 按面积从大到小试，取第一个「没有被压住」的候选 —— 这样视频滑到视频时
    // 能自动切到新那一个，而不是抱着后面那个已经看不见的。
    NSMutableArray<NSNumber *> *order = [NSMutableArray array];
    for (NSUInteger i = 0; i < cands.count; i++) [order addObject:@(i)];
    [order sortUsingComparator:^NSComparisonResult(NSNumber *a, NSNumber *b) {
        CGFloat av = [areas[a.unsignedIntegerValue] doubleValue];
        CGFloat bv = [areas[b.unsignedIntegerValue] doubleValue];
        if (av > bv) return NSOrderedAscending;
        if (av < bv) return NSOrderedDescending;
        return NSOrderedSame;
    }];

    AVPlayerLayer *best = nil;
    UIWindow *bestWindow = nil;
    CGRect bestRect = CGRectZero;

    for (NSNumber *idx in order) {
        NSUInteger i = idx.unsignedIntegerValue;
        AVPlayerLayer *l = cands[i];
        UIWindow *w = [wins[i] nonretainedObjectValue];

        UIView *vv = nil;
        if ([l.delegate isKindOfClass:[UIView class]]) vv = (UIView *)l.delegate;

        // 只在「播放器已暂停」时判定：切页时相册一定会暂停；正在播的时候
        // 上层的过渡快照会造成误杀，所以播放中直接认为它在前台。
        // 播完停在最后一帧时也必须豁免（IVPlayerNearEnd），否则结尾画面会被
        // 当成「被别的照片盖住」，overlay 拆掉后再点画面就唤不出来了。
        if (vv != nil && l.player.rate == 0.0 && !IVPlayerNearEnd(l.player)) {
            UIView *occluder = IVPageOccluder(vv, w);
            if (occluder != nil) {
                IVLog(@"skip occluded layer (%@ under %@)",
                      NSStringFromClass([vv class]), NSStringFromClass([occluder class]));
                continue;
            }
        }

        best = l;
        bestWindow = w;
        bestRect = [rects[i] CGRectValue];
        break;
    }

    if (best == nil) {
        // 所有候选都被别的页面盖住了：说明已经不在视频页，只是 player 还活着。
        // 连续两次命中才动手，避开翻页动画里的瞬时快照。
        _occludedScans++;
        if (_occludedScans >= 2) {
            if (_overlay != nil) IVLog(@"teardown: every candidate layer is occluded");
            _occludedLayer = cands.firstObject;
            [self teardownOverlay];
        }
        return;
    }

    _occludedScans = 0;
    _occludedLayer = nil;

    [self mountOverlayForLayer:best inWindow:bestWindow videoRect:bestRect];

    if (kGlassTopCapsule) {
        IVGlassTopCapsules(bestWindow, bestWindow, 0);
    }

    if (kHideNativeChrome) {
        [self suppressNativeChromeForLayer:best inWindow:bestWindow];
    }
}

#pragma mark - 触摸观察（点画面切换的兜底通道）

- (void)observeTouchEvent:(UIEvent *)event inWindow:(UIWindow *)window {
    if (_overlay == nil) return;
    if (window != _hostWindow) return;

    NSSet<UITouch *> *touches = [event allTouches];
    if (touches.count != 1) return;

    UITouch *t = touches.anyObject;
    if (t == nil) return;

    static UITouch *sTracked = nil;
    static CGPoint sStart = {0.0, 0.0};
    static NSTimeInterval sStartTime = 0.0;
    static BOOL sOnOwnControl = NO;

    if (t.phase == UITouchPhaseBegan) {
        sTracked = t;
        sStart = [t locationInView:window];
        sStartTime = t.timestamp;
        sOnOwnControl = [_overlay interceptsPoint:sStart inWindow:window];
        return;
    }

    if (t.phase == UITouchPhaseCancelled) {
        if (sTracked == t) sTracked = nil;
        [self scheduleReshowIfNeeded];
        return;
    }

    if (t.phase == UITouchPhaseMoved) {
        if (sTracked != t || sOnOwnControl || _hiddenByDrag) return;

        CGPoint p = [t locationInView:window];
        CGFloat dx = p.x - sStart.x;
        CGFloat dy = p.y - sStart.y;

        // 手指一横向拖开就先把控制层收起来。
        // 相册翻页时视频内容会跟着手走，而 overlay 挂在 window 上不会动，
        // 不收起来就会看到按钮「飘在」正在滑入的那张照片上 —— 这就是所谓的错位。
        if (fabs(dx) > 12.0 && fabs(dx) > fabs(dy)) {
            _hiddenByDrag = YES;
            IVGlassOverlay *ov = _overlay;
            dispatch_async(dispatch_get_main_queue(), ^{
                [ov setChromeVisible:NO animated:YES];
            });
        }
        return;
    }

    if (t.phase != UITouchPhaseEnded) return;
    if (sTracked != t) return;

    sTracked = nil;

    CGPoint end = [t locationInView:window];
    CGFloat dx = fabs(end.x - sStart.x);
    CGFloat dy = fabs(end.y - sStart.y);
    NSTimeInterval dt = t.timestamp - sStartTime;

    // 短按 + 几乎无位移 = tap（滑动切图不会被判成 tap）
    if (dx > 14.0 || dy > 14.0 || dt > 0.35) {
        [self scheduleReshowIfNeeded];
        return;
    }

    IVGlassOverlay *ov = _overlay;
    dispatch_async(dispatch_get_main_queue(), ^{
        [ov handleExternalTapAt:end inView:window];
    });
}

#pragma mark - 挂载 / 卸载

/// 翻页结束后把控制层恢复出来（仅在还停留在视频页时才有意义）。
/// 延迟 0.65s：这期间若已切到照片，遮挡判定会把 overlay 卸掉，这里就什么都不做。
- (void)scheduleReshowIfNeeded {
    if (!_hiddenByDrag) return;
    _hiddenByDrag = NO;

    [_reshowTimer invalidate];
    __weak typeof(self) ws = self;
    _reshowTimer = [NSTimer scheduledTimerWithTimeInterval:0.65
                                                   repeats:NO
                                                     block:^(NSTimer *t) {
        __strong typeof(ws) s = ws;
        if (!s) return;
        s->_reshowTimer = nil;
        IVGlassOverlay *ov = s->_overlay;
        if (ov == nil) return;
        [ov setChromeVisible:YES animated:YES];
    }];
}

- (void)mountOverlayForLayer:(AVPlayerLayer *)layer
                    inWindow:(UIWindow *)win
                   videoRect:(CGRect)videoRect {
    BOOL needRebuild = NO;

    if (_overlay != nil) {
        if (_hostWindow != win) {
            needRebuild = YES;
        } else if (_boundLayer != layer || _overlay.player != layer.player) {
            // 换了一个播放器（上一个视频关掉、开了下一个），或者同一个 layer 换了 player：
            // 必须当成新的一次挂载，控制层重新回到「可见」。
            needRebuild = YES;
        } else if (_overlay.superview != win) {
            // 只是从层级里掉了（相册重排视图时会发生）。
            // 注意：绝不能在这里重建 —— 新建的 overlay 默认可见，
            // 会把用户刚点隐藏的控制层「自己弹回来」。
            [win addSubview:_overlay];
            IVLog(@"overlay re-attached, chromeVisible=%d", _overlay.chromeVisible);
        }
    }

    if (needRebuild) {
        // 同一个播放器重建才保留显隐状态；换了播放器就恢复可见
        BOOL samePlayer = (_overlay != nil && _overlay.player == layer.player);
        BOOL wasVisible = samePlayer ? _overlay.chromeVisible : YES;
        [self teardownOverlay];

        IVGlassOverlay *ov = [[IVGlassOverlay alloc] initWithFrame:win.bounds];
        ov.player = layer.player;
        [ov syncToVideoRect:videoRect];
        [win addSubview:ov];
        [ov bindWindow:win];
        [ov startTracking];
        [ov setChromeVisible:wasVisible animated:NO];

        _overlay = ov;
        _hostWindow = win;
        _boundLayer = layer;

        IVLog(@"overlay rebuilt: win=%@ visible=%d samePlayer=%d",
              NSStringFromClass([win class]), wasVisible, samePlayer);
    } else if (_overlay == nil) {
        IVGlassOverlay *ov = [[IVGlassOverlay alloc] initWithFrame:win.bounds];
        ov.player = layer.player;
        [ov syncToVideoRect:videoRect];
        [win addSubview:ov];
        [ov bindWindow:win];
        [ov startTracking];

        _overlay = ov;
        _hostWindow = win;
        _boundLayer = layer;

        IVLog(@"overlay mounted: win=%@ bounds=%@", NSStringFromClass([win class]),
              NSStringFromCGRect(win.bounds));
    } else {
        _overlay.player = layer.player;
        _boundLayer = layer;
        [_overlay bindWindow:win];
    }

    if (!CGRectEqualToRect(_overlay.frame, win.bounds)) {
        _overlay.frame = win.bounds;
        [_overlay relayout];
    }

    // 画面区域跟着视频走：控件按画面居中/靠底，而不是死按整窗算 —— 这是「错位」的另一半原因
    if (!CGRectEqualToRect(_syncedVideoRect, videoRect)) {
        _syncedVideoRect = videoRect;
        [_overlay syncToVideoRect:videoRect];
    }

    if ([win.subviews lastObject] != _overlay) {
        [win bringSubviewToFront:_overlay];
    }
}

- (void)teardownOverlay {
    [self restoreNativeChrome];

    [_reshowTimer invalidate];
    _reshowTimer = nil;
    _hiddenByDrag = NO;
    // 注意：不要在这里重置 _occludedScans —— 遮挡期间每次扫描都会走 teardown，
    // 一重置就会变成「卸载→重挂→卸载」的闪烁。它只在 scan 判定「未被遮挡」时归零。

    if (_overlay == nil) {
        _boundLayer = nil;
        _syncedVideoRect = CGRectZero;
        return;
    }
    [_overlay unbindWindow];
    [_overlay stopTracking];
    [_overlay removeFromSuperview];
    _overlay = nil;
    _hostWindow = nil;
    _boundLayer = nil;
    _syncedVideoRect = CGRectZero;
}

#pragma mark - 顶部胶囊玻璃化

/// 判断一个 view 是不是「顶部时间胶囊」：
/// 位于窗口上半部、高度在 24~48pt 之间、宽度明显大于高度（胶囊横长条）、
/// 含一个 UILabel 子视图（时间文字）、且带圆角。
static BOOL IVLooksLikeTopCapsule(UIView *v, UIWindow *win) {
    if (v == nil || win == nil) return NO;
    if (v.hidden || v.alpha < 0.5) return NO;

    CGRect f = [v convertRect:v.bounds toView:win];
    CGFloat W = win.bounds.size.width;
    CGFloat H = win.bounds.size.height;
    if (CGRectIsEmpty(f)) return NO;

    // 顶部区域：y 在 safe 区顶部 ~ 屏高 18% 之间
    CGFloat top = win.safeAreaInsets.top;
    if (f.origin.y < top - 4.0) return NO;
    if (f.origin.y > H * 0.20) return NO;

    CGFloat w = f.size.width, h = f.size.height;
    if (h < 22.0 || h > 52.0) return NO;
    if (w < h * 2.2) return NO;         // 胶囊：宽远大于高
    if (w > W * 0.85) return NO;

    // 有圆角（胶囊特征）
    if (v.layer.cornerRadius < h * 0.3) return NO;

    // 含 UILabel（时间文字）
    for (UIView *s in v.subviews) {
        if ([s isKindOfClass:[UILabel class]]) return YES;
    }
    return NO;
}

static void IVGlassTopCapsules(UIView *root, UIWindow *win, int depth) {
    if (root == nil || depth > 10) return;
    for (UIView *v in root.subviews) {
        if (v == nil || v.hidden) continue;
        if (IVLooksLikeTopCapsule(v, win)) {
            IVGlassStyleExistingView(v, v.bounds.size.height / 2.0);
            continue;   // 命中后不再往里钻
        }
        IVGlassTopCapsules(v, win, depth + 1);
    }
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
        // 记下原始 alpha，卸载时还原
        if ([_suppressed objectForKey:v] == nil) {
            [_suppressed setObject:@(v.alpha) forKey:v];
        }
        if (v.alpha > 0.03) {
            v.alpha = 0.0;
        }
    }
}

/// 把被压掉的原生控件恢复原样。
/// 少了这一步，从视频滑到照片后，相册底部那排操作栏会永久透明。
- (void)restoreNativeChrome {
    if (_suppressed.count == 0) return;

    for (UIView *v in _suppressed) {
        NSNumber *orig = [_suppressed objectForKey:v];
        if (v != nil && orig != nil) {
            v.alpha = orig.doubleValue;
        }
    }
    [_suppressed removeAllObjects];
}

@end
