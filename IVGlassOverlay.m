#import "IVGlassOverlay.h"
#import "IVGlassKit.h"
#import "IVHostBridge.h"
#import <QuartzCore/QuartzCore.h>
#import <math.h>

#pragma mark - 尺寸常量

static const CGFloat kPillHCompact  = 46.0;   // 常态胶囊高度
static const CGFloat kPillHExpanded = 74.0;   // 展开后高度
static const CGFloat kPillSide      = 12.0;   // 左右距屏幕边缘
static const CGFloat kPillMaxWidth  = 560.0;  // 横屏时不要拉满
static const CGFloat kCompactButton = 30.0;   // 胶囊里的播放 / 静音小圆钮
static const CGFloat kTickInterval  = 0.08;

/// 浅玻璃上的墨色（音量 HUD 的图标就是这种深灰）
static inline UIColor *IVInk(void)      { return [UIColor colorWithWhite:0.10 alpha:0.85]; }
static inline UIColor *IVInkSoft(void)  { return [UIColor colorWithWhite:0.10 alpha:0.50]; }
static inline UIColor *IVTrackTint(void){ return [UIColor colorWithWhite:0.10 alpha:0.14]; }
static inline UIColor *IVFillTint(void) { return [UIColor colorWithWhite:0.10 alpha:0.75]; }

@interface IVGlassOverlay () <UIGestureRecognizerDelegate> {
    // 底部胶囊
    IVGlassView *_pill;
    UIView      *_track;
    UIView      *_fill;
    UIView      *_knob;
    UIButton    *_playBtn;
    UIButton    *_muteBtn;
    UILabel     *_lblLeft;
    UILabel     *_lblRight;

    // 中央按钮组
    UIView      *_centerWrap;
    IVGlassView *_backCircle;
    IVGlassView *_playCircle;
    IVGlassView *_fwdCircle;
    UIButton    *_backBtn;
    UIButton    *_playBig;
    UIButton    *_fwdBtn;

    // 状态
    double       _currentValue;    // 0..1
    BOOL         _dragging;
    BOOL         _chromeVisible;   // 唯一开关：胶囊 + 中央按钮永远同进同出
    CGRect       _videoRect;       // 画面区域（overlay 坐标系）
    BOOL         _hasVideoRect;
    BOOL         _stateValid;      // 播放/静音图标的缓存校验位
    BOOL         _lastPlaying;
    BOOL         _lastMuted;
    BOOL         _endHandled;      // 已经处理过「播到结尾」，避免每次 tick 重复触发
    NSTimer     *_tickTimer;
    NSTimer     *_collapseTimer;

    // 全屏点击切换
    UIWindow                *_boundWindow;
    UITapGestureRecognizer  *_winTap;
    NSTimeInterval           _lastTapTime;
}
/// 播放 / 暂停：优先交给宿主状态机，保证原生那条控制栏跟着变
- (void)setPlayingViaHost:(BOOL)wantPlay;
/// 播/暂停之后的自查，attempt 只是防死循环
- (void)verifyPlayState:(BOOL)wantPlay attempt:(int)attempt action:(IVHostAction)action;
@end

@implementation IVGlassOverlay

#pragma mark - 生命周期

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (!self) return nil;

    self.backgroundColor = [UIColor clearColor];
    self.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    self.clipsToBounds = NO;

    [self buildPill];
    [self buildCenter];

    _currentValue = 0.0;
    _expanded = NO;
    _chromeVisible = YES;    // 整体默认可见
    _hasVideoRect = NO;
    _videoRect = CGRectZero;
    _lastTapTime = 0.0;

    IVLog(@"=== IVGlassPlayer 0.6.5 overlay init ===");

    return self;
}

- (void)dealloc {
    [_tickTimer invalidate];
    [_collapseTimer invalidate];
    if (_winTap != nil) {
        [_winTap.view removeGestureRecognizer:_winTap];
        _winTap = nil;
    }
}

#pragma mark - 全屏点击切换（挂在 window 上，不消费触摸）

- (void)bindWindow:(UIWindow *)window {
    if (window == nil) return;
    if (_winTap != nil && _boundWindow == window) return;

    [self unbindWindow];
    _boundWindow = window;

    UITapGestureRecognizer *t =
        [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(onWindowTap:)];
    t.cancelsTouchesInView = NO;   // 关键：不吞触摸，相册的 swipe 照常
    t.delaysTouchesEnded = NO;
    t.delegate = self;
    [window addGestureRecognizer:t];
    _winTap = t;

    IVLog(@"bindWindow ok: %@ (gesture count=%lu)",
          NSStringFromClass([window class]), (unsigned long)window.gestureRecognizers.count);
}

- (void)unbindWindow {
    if (_winTap != nil) {
        [_winTap.view removeGestureRecognizer:_winTap];
        _winTap = nil;
    }
    _boundWindow = nil;
}

/// 关键：允许和相册自己的全屏 tap 同时识别。
/// UIKit 默认手势互斥，相册那个 tap 在更深的视图上、优先级更高，
/// 不返回 YES 的话我们这个 window 级 tap 永远不会触发。
- (BOOL)gestureRecognizer:(UIGestureRecognizer *)gestureRecognizer
shouldRecognizeSimultaneouslyWithGestureRecognizer:(UIGestureRecognizer *)otherGestureRecognizer {
    return YES;
}

/// 只接「画面空白处」的点击：按钮、导航栏、工具栏、自己的控件都放过。
- (BOOL)gestureRecognizer:(UIGestureRecognizer *)gestureRecognizer
       shouldReceiveTouch:(UITouch *)touch {
    if (gestureRecognizer != _winTap) return YES;

    UIView *v = touch.view;
    if (v == nil) {
        IVLog(@"shouldReceiveTouch: view=nil -> NO");
        return NO;
    }
    if (v == self || [v isDescendantOfView:self]) {
        IVLog(@"shouldReceiveTouch: %@ 是自己的控件 -> NO", NSStringFromClass([v class]));
        return NO;
    }

    // 只查近 8 层：相册深层容器常常是 UIControl 子类，
    // 查太深会把整块画面点击一起否掉（这是上一版点不动的主因之一）。
    UIView *p = v;
    int guard = 0;
    while (p != nil && guard < 8) {
        if ([p isKindOfClass:[UIControl class]]) {
            IVLog(@"shouldReceiveTouch: 命中 UIControl %@ -> NO", NSStringFromClass([p class]));
            return NO;
        }
        if ([p isKindOfClass:[UINavigationBar class]]) return NO;
        if ([p isKindOfClass:[UIToolbar class]]) return NO;
        if ([p isKindOfClass:[UITabBar class]]) return NO;
        p = p.superview;
        guard++;
    }

    IVLog(@"shouldReceiveTouch: %@ -> YES", NSStringFromClass([v class]));
    return YES;
}

- (void)onWindowTap:(UITapGestureRecognizer *)g {
    if (g.state != UIGestureRecognizerStateEnded) return;
    IVLog(@"onWindowTap fire");
    CGPoint p = [g locationInView:self];
    [self handleExternalTapAt:p inView:self];
}

/// 兜底入口：window tap 和 sendEvent 观察都会调到这里，靠时间戳去重。
- (void)handleExternalTapAt:(CGPoint)point inView:(UIView *)view {
    NSTimeInterval now = [NSProcessInfo processInfo].systemUptime;
    // 去重窗口要足够宽：window 手势和 sendEvent 观察是两条独立通道，
    // 间隔可能拉到 300ms 以上，窗口太窄就会切成「消失又出现」。
    if (now - _lastTapTime < 0.45) {
        IVLog(@"tap deduped (dt=%.3f)", now - _lastTapTime);
        return;
    }
    _lastTapTime = now;

    CGPoint p = (view == self) ? point : [self convertPoint:point fromView:view];

    // 落在自己的控件上不处理（按钮/胶囊自己会响应）
    if (_chromeVisible && _pill.alpha > 0.05 && CGRectContainsPoint(_pill.frame, p)) {
        IVLog(@"tap on pill ignored");
        return;
    }
    if (_chromeVisible && _centerWrap.alpha > 0.05 && CGRectContainsPoint(_centerWrap.frame, p)) {
        IVLog(@"tap on centers ignored");
        return;
    }

    IVLog(@"tap -> toggle chrome (was %d)", _chromeVisible);
    [self setChromeVisible:!_chromeVisible animated:YES];
}

- (void)setChromeVisible:(BOOL)visible animated:(BOOL)animated {
    IVLog(@"setChromeVisible:%d (current=%d)", visible, _chromeVisible);
    _chromeVisible = visible;

    // 要收起时先把展开态复位：否则下次显出来还挂在拉长的时间轴上，
    // 位置和形态都跟用户上次看到的对不上 —— 这就是「错位」的观感来源。
    if (!visible && _expanded) {
        [self setExpanded:NO animated:NO];
    }

    _centerWrap.userInteractionEnabled = visible;

    // 注意：这里不做 early-return。胶囊和中央按钮必须每次都按同一个值落 alpha，
    // 中途被别的动画打断过一次就可能一个到 0、一个停在 0.3，之后再也对不齐。
    //
    // 也不要给 _centerWrap 加 scale 动画：它带着 transform 时，layoutSubviews
    // 里再设 frame 会被 UIKit 反算 center，于是「淡出时整组往右挪一下」。
    // 纯 alpha 过渡没有这个问题。
    __weak typeof(self) ws = self;
    [UIView animateWithDuration:animated ? 0.18 : 0.0
                          delay:0.0
                        options:UIViewAnimationOptionBeginFromCurrentState
                     animations:^{
        __strong typeof(ws) s = ws;
        if (!s) return;
        s->_pill.alpha = visible ? 1.0 : 0.0;
        s->_centerWrap.alpha = visible ? 1.0 : 0.0;
    } completion:nil];
}

#pragma mark - 画面区域同步

/// 由 watcher 每次扫描时喂进来：视频 layer 在窗口里的矩形。
/// 控件按这块区域居中/靠底，而不是死按整窗算。
- (void)syncToVideoRect:(CGRect)rect {
    CGRect win = self.bounds;
    if (CGRectIsEmpty(win)) return;

    CGRect local = CGRectZero;
    BOOL ok = NO;

    if (!CGRectIsEmpty(rect) && !CGRectIsNull(rect)) {
        local = (self.window != nil) ? [self convertRect:rect fromView:self.window] : rect;
        CGRect clip = CGRectIntersection(local, win);
        if (!CGRectIsNull(clip) && !CGRectIsEmpty(clip)) {
            CGFloat cov = (clip.size.width * clip.size.height) /
                          MAX(1.0, win.size.width * win.size.height);
            // 只有「基本铺满屏幕」的画面区域才值得照着排版；
            // 小窗视频退回整窗，避免控件缩到画面里挤成一团
            if (cov >= 0.55) {
                local = clip;
                ok = YES;
            }
        }
    }

    if (_hasVideoRect == ok && CGRectEqualToRect(_videoRect, local)) return;

    _hasVideoRect = ok;
    _videoRect = ok ? local : win;
    [self setNeedsLayout];
}

/// 当前排版参照的区域
- (CGRect)contentArea {
    if (_hasVideoRect && !CGRectIsEmpty(_videoRect)) return _videoRect;
    return self.bounds;
}

#pragma mark - 构建：底部胶囊

- (void)buildPill {
    _pill = [[IVGlassView alloc] initWithRadius:kPillHCompact / 2.0];
    _pill.userInteractionEnabled = YES;
    [self addSubview:_pill];

    // 进度槽
    _track = [[UIView alloc] initWithFrame:CGRectZero];
    _track.backgroundColor = IVTrackTint();
    _track.layer.cornerRadius = 2.0;
    _track.clipsToBounds = NO;
    _track.userInteractionEnabled = NO;
    [_pill.contentView addSubview:_track];

    // 进度填充
    _fill = [[UIView alloc] initWithFrame:CGRectZero];
    _fill.backgroundColor = IVFillTint();
    _fill.layer.cornerRadius = 2.0;
    _fill.userInteractionEnabled = NO;
    [_track addSubview:_fill];

    // 拖动圆点（展开时可见）
    _knob = [[UIView alloc] initWithFrame:CGRectZero];
    _knob.backgroundColor = [UIColor colorWithWhite:0.08 alpha:0.95];
    _knob.layer.cornerRadius = 8.0;
    _knob.layer.shadowColor = [UIColor blackColor].CGColor;
    _knob.layer.shadowOpacity = 0.22;
    _knob.layer.shadowRadius = 4.0;
    _knob.layer.shadowOffset = CGSizeMake(0, 1);
    _knob.hidden = YES;
    _knob.userInteractionEnabled = NO;
    [_pill.contentView addSubview:_knob];

    // 播放 / 暂停（小）
    _playBtn = [UIButton buttonWithType:UIButtonTypeCustom];
    _playBtn.tintColor = IVInk();
    _playBtn.userInteractionEnabled = YES;
    [_playBtn addTarget:self action:@selector(onPlayPause) forControlEvents:UIControlEventTouchUpInside];
    [_pill.contentView addSubview:_playBtn];

    // 静音
    _muteBtn = [UIButton buttonWithType:UIButtonTypeCustom];
    _muteBtn.tintColor = IVInkSoft();
    _muteBtn.userInteractionEnabled = YES;
    [_muteBtn addTarget:self action:@selector(onToggleMute) forControlEvents:UIControlEventTouchUpInside];
    [_pill.contentView addSubview:_muteBtn];

    // 时间标签
    _lblLeft = [[UILabel alloc] initWithFrame:CGRectZero];
    _lblLeft.font = [UIFont monospacedDigitSystemFontOfSize:13.0 weight:UIFontWeightSemibold];
    _lblLeft.textColor = IVInk();
    _lblLeft.textAlignment = NSTextAlignmentLeft;
    _lblLeft.hidden = YES;
    _lblLeft.userInteractionEnabled = NO;
    [_pill.contentView addSubview:_lblLeft];

    _lblRight = [[UILabel alloc] initWithFrame:CGRectZero];
    _lblRight.font = [UIFont monospacedDigitSystemFontOfSize:12.0 weight:UIFontWeightMedium];
    _lblRight.textColor = IVInkSoft();
    _lblRight.textAlignment = NSTextAlignmentRight;
    _lblRight.hidden = YES;
    _lblRight.userInteractionEnabled = NO;
    [_pill.contentView addSubview:_lblRight];

    // 只有一个 pan：按住胶囊拖动 = 展开 + seek（无长按门槛，跟手）
    UIPanGestureRecognizer *pan =
        [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(onPillPan:)];
    pan.cancelsTouchesInView = NO;
    pan.maximumNumberOfTouches = 1;
    [_pill addGestureRecognizer:pan];

    // 点胶囊空白处切换中央按钮
    UITapGestureRecognizer *tap =
        [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(onPillTap:)];
    tap.cancelsTouchesInView = NO;
    [_pill addGestureRecognizer:tap];

    [self updatePlayState];
    [self updateMuteState];
}

#pragma mark - 构建：中央按钮组

- (void)buildCenter {
    _centerWrap = [[UIView alloc] initWithFrame:CGRectZero];
    _centerWrap.backgroundColor = [UIColor clearColor];
    _centerWrap.alpha = 1.0;
    _centerWrap.userInteractionEnabled = YES;
    [self addSubview:_centerWrap];

    _backCircle = [[IVGlassView alloc] initWithRadius:34.0];
    _fwdCircle  = [[IVGlassView alloc] initWithRadius:34.0];
    _playCircle = [[IVGlassView alloc] initWithRadius:42.0];

    for (IVGlassView *c in @[_backCircle, _playCircle, _fwdCircle]) {
        c.userInteractionEnabled = YES;
        [_centerWrap addSubview:c];
    }

    _backBtn = [UIButton buttonWithType:UIButtonTypeCustom];
    _backBtn.tintColor = IVInk();
    [_backBtn addTarget:self action:@selector(onRewind) forControlEvents:UIControlEventTouchUpInside];
    [_backCircle.contentView addSubview:_backBtn];

    _playBig = [UIButton buttonWithType:UIButtonTypeCustom];
    _playBig.tintColor = IVInk();
    [_playBig addTarget:self action:@selector(onPlayPause) forControlEvents:UIControlEventTouchUpInside];
    [_playCircle.contentView addSubview:_playBig];

    _fwdBtn = [UIButton buttonWithType:UIButtonTypeCustom];
    _fwdBtn.tintColor = IVInk();
    [_fwdBtn addTarget:self action:@selector(onForward) forControlEvents:UIControlEventTouchUpInside];
    [_fwdCircle.contentView addSubview:_fwdBtn];
}

#pragma mark - 布局

- (void)relayout {
    [self setNeedsLayout];
    [self layoutIfNeeded];
}

- (void)layoutSubviews {
    [super layoutSubviews];

    CGFloat W = self.bounds.size.width;
    CGFloat H = self.bounds.size.height;
    if (W < 1.0 || H < 1.0) return;

    CGRect area = [self contentArea];

    CGFloat safeBottom = 34.0;
    UIWindow *win = self.window;
    if (win) safeBottom = win.safeAreaInsets.bottom;

    // 胶囊永远贴着屏幕底部（它要对齐相册自己的操作栏），
    // 只有中央按钮组跟着画面区域居中 —— 画面有黑边时按钮才不会偏到黑边里去
    [self layoutPillWithWidth:W height:H safeBottom:safeBottom];
    [self layoutCenterWithWidth:W area:area];
    [self applyProgressValue];
}

- (void)layoutPillWithWidth:(CGFloat)W height:(CGFloat)H safeBottom:(CGFloat)safeBottom {
    CGFloat pillH = _expanded ? kPillHExpanded : kPillHCompact;
    CGFloat pillW = MIN(W - kPillSide * 2.0, kPillMaxWidth);
    CGFloat pillX = (W - pillW) / 2.0;
    // 抬到相册底部那排缩略图条（可滑动选择的那排）上方，不压原生操作栏。
    // 126 还是偏高，按截图红框位置再往下 22pt。
    CGFloat gap   = _expanded ? 124.0 : 104.0;
    CGFloat pillY = H - safeBottom - pillH - gap;

    CGFloat minY = (self.safeAreaInsets.top > 0.0 ? self.safeAreaInsets.top : 0.0) + 8.0;
    if (pillY < minY) pillY = minY;

    _pill.frame = CGRectMake(pillX, pillY, pillW, pillH);
    [_pill updateCornerRadius:pillH / 2.0];

    CGFloat trackH = _expanded ? 8.0 : 4.0;
    CGFloat trackY = (pillH - trackH) / 2.0;
    CGFloat trackR = trackH / 2.0;

    if (_expanded) {
        _playBtn.hidden = YES;
        _muteBtn.hidden = YES;
        _lblLeft.hidden = NO;
        _lblRight.hidden = NO;
        _knob.hidden = NO;

        _lblLeft.font  = [UIFont monospacedDigitSystemFontOfSize:15.0 weight:UIFontWeightSemibold];
        _lblRight.font = [UIFont monospacedDigitSystemFontOfSize:13.0 weight:UIFontWeightMedium];

        CGFloat pad  = 22.0;
        CGFloat lblW = 78.0;
        _lblLeft.frame  = CGRectMake(pad, 0.0, lblW, pillH);
        _lblRight.frame = CGRectMake(pillW - pad - lblW, 0.0, lblW, pillH);

        CGFloat tx = pad + lblW + 10.0;
        CGFloat tw = pillW - tx * 2.0;
        _track.frame = CGRectMake(tx, trackY, tw, trackH);
    } else {
        _playBtn.hidden = NO;
        _muteBtn.hidden = NO;
        _lblLeft.hidden = YES;
        _lblRight.hidden = YES;
        _knob.hidden = YES;

        CGFloat b = kCompactButton;
        CGFloat by = (pillH - b) / 2.0;
        _playBtn.frame = CGRectMake(8.0, by, b, b);
        _muteBtn.frame = CGRectMake(pillW - 8.0 - b, by, b, b);

        CGFloat tx = 8.0 + b + 11.0;
        CGFloat tw = pillW - tx - 11.0 - b - 8.0;
        _track.frame = CGRectMake(tx, trackY, tw, trackH);
    }

    _track.layer.cornerRadius = trackR;
    _fill.layer.cornerRadius = trackR;

    // 小圆钮图标
    CGFloat iconPt = 17.0;
    [_playBtn setImage:IVSymbol([self isPlaying] ? @"pause.fill" : @"play.fill", iconPt, UIFontWeightBold)
              forState:UIControlStateNormal];
    [_muteBtn setImage:IVSymbol([self isMuted] ? @"speaker.slash.fill" : @"speaker.wave.2.fill",
                                iconPt - 1.0, UIFontWeightSemibold)
              forState:UIControlStateNormal];

    [self applyProgressValue];
}

- (void)layoutCenterWithWidth:(CGFloat)W area:(CGRect)area {
    CGFloat sideD = 68.0;
    CGFloat midD  = 84.0;
    CGFloat gap   = 26.0;

    CGFloat scale = MIN(1.0, MIN(W, self.bounds.size.height) / 400.0);
    scale = MAX(0.62, scale);

    sideD *= scale;
    midD  *= scale;
    gap   *= scale;

    CGFloat totalW = sideD * 2.0 + midD + gap * 2.0;
    CGFloat originX = (W - totalW) / 2.0;
    // 居中到「画面」而不是「整窗」：视频被 letterbox 时按钮才会跟着画面走
    CGFloat midY = CGRectIsEmpty(area) ? self.bounds.size.height / 2.0 : CGRectGetMidY(area);

    // 排版前先把 transform 复位：带着非单位 transform 去设 frame，
    // UIKit 会按 frame/transform 反算 center，位置就会漂。
    _centerWrap.transform = CGAffineTransformIdentity;
    _centerWrap.frame = CGRectMake(originX - gap * 0.4,
                                   midY - midD / 2.0 - gap * 0.4,
                                   totalW + gap * 0.8,
                                   midD + gap * 0.8);

    CGFloat baseX = gap * 0.4;
    CGFloat baseY = gap * 0.4;

    _backCircle.frame = CGRectMake(baseX, baseY + (midD - sideD) / 2.0, sideD, sideD);
    _playCircle.frame = CGRectMake(baseX + sideD + gap, baseY, midD, midD);
    _fwdCircle.frame  = CGRectMake(baseX + sideD + gap + midD + gap,
                                   baseY + (midD - sideD) / 2.0, sideD, sideD);

    _backBtn.frame  = CGRectMake(0.0, 0.0, sideD, sideD);
    _playBig.frame  = CGRectMake(0.0, 0.0, midD, midD);
    _fwdBtn.frame   = CGRectMake(0.0, 0.0, sideD, sideD);

    CGFloat sideIcon = 26.0 * scale;
    CGFloat midIcon  = 32.0 * scale;

    [_backBtn setImage:IVSymbol(@"gobackward.15", sideIcon, UIFontWeightSemibold)
              forState:UIControlStateNormal];
    [_fwdBtn setImage:IVSymbol(@"goforward.15", sideIcon, UIFontWeightSemibold)
             forState:UIControlStateNormal];
    [_playBig setImage:IVSymbol([self isPlaying] ? @"pause.fill" : @"play.fill", midIcon, UIFontWeightBold)
              forState:UIControlStateNormal];
}

#pragma mark - 进度条

- (void)applyProgressValue {
    CGFloat trackW = _track.bounds.size.width;
    CGFloat trackH = _track.bounds.size.height;
    if (trackW < 1.0) return;

    double v = _currentValue;
    if (!isfinite(v)) v = 0.0;
    if (v < 0.0) v = 0.0;
    if (v > 1.0) v = 1.0;

    CGFloat fillW = trackW * (CGFloat)v;
    _fill.frame = CGRectMake(0.0, 0.0, MAX(0.0, fillW), trackH);

    if (_expanded) {
        CGFloat knobD = 16.0;
        // _knob 挂在胶囊 contentView 上，x 要加上进度槽自身的偏移
        CGFloat cx = _track.frame.origin.x + fillW;
        CGFloat cy = _track.frame.origin.y + trackH / 2.0;
        _knob.frame = CGRectMake(cx - knobD / 2.0, cy - knobD / 2.0, knobD, knobD);
        _knob.layer.cornerRadius = knobD / 2.0;
    }
}

#pragma mark - 播放状态

- (BOOL)isPlaying {
    AVPlayer *p = self.player;
    if (!p) return NO;
    AVPlayerTimeControlStatus s = p.timeControlStatus;
    return (s == AVPlayerTimeControlStatusPlaying) ||
           (s == AVPlayerTimeControlStatusWaitingToPlayAtSpecifiedRate);
}

- (BOOL)isMuted {
    AVPlayer *p = self.player;
    return p ? p.muted : NO;
}

- (double)mediaDuration {
    AVPlayerItem *item = self.player.currentItem;
    if (!item) return 0.0;
    CMTime d = item.duration;
    if (!CMTIME_IS_NUMERIC(d)) return 0.0;
    double s = CMTimeGetSeconds(d);
    return (isfinite(s) && s > 0.0) ? s : 0.0;
}

/// 是否已经播到结尾（播放结束时相册会停在最后一帧，player 仍是 paused 状态）
- (BOOL)isAtEnd {
    AVPlayer *p = self.player;
    if (!p) return NO;
    double dur = [self mediaDuration];
    if (dur <= 0.5) return NO;
    double cur = CMTimeGetSeconds(p.currentTime);
    if (!isfinite(cur) || cur < 0.0) return NO;
    return (cur >= dur - 0.30);
}

- (void)updatePlayState {
    UIImage *small = IVSymbol([self isPlaying] ? @"pause.fill" : @"play.fill",
                              17.0, UIFontWeightBold);
    [_playBtn setImage:small forState:UIControlStateNormal];

    CGFloat midIcon = 32.0 * MAX(0.62, MIN(1.0, MIN(self.bounds.size.width, self.bounds.size.height) / 400.0));
    UIImage *big = IVSymbol([self isPlaying] ? @"pause.fill" : @"play.fill",
                            midIcon, UIFontWeightBold);
    [_playBig setImage:big forState:UIControlStateNormal];
}

- (void)updateMuteState {
    UIImage *img = IVSymbol([self isMuted] ? @"speaker.slash.fill" : @"speaker.wave.2.fill",
                            16.0, UIFontWeightSemibold);
    [_muteBtn setImage:img forState:UIControlStateNormal];
}

#pragma mark - 动作

/// 播放 / 暂停统一入口。
///
/// 直接 `[player pause]` 的问题是：画面停住了，但相册自己的状态机
/// （`PUBrowsingVideoPlayer.desiredPlayState`）还认为在播，
/// 底部那条原生控制栏就不会把图标切成「播放」—— 用户看到的就是
/// 「插件暂停了，原生不跟随」。
///
/// 现在优先**点原生那个播放/暂停按钮**：效果和用户手指点下去完全一样，
/// 宿主状态和图标一起变，不存在"两边不一致"的中间态。
/// 找不到按钮才退回状态机 / 直接操作 player。
- (void)setPlayingViaHost:(BOOL)wantPlay {
    AVPlayer *p = self.player;
    if (!p) return;

    UIWindow *win = _boundWindow ?: self.window;
    IVHostAction action = IVHostSetPlaying(win, wantPlay, p, self);

    if (action == IVHostActionNone) {
        if (wantPlay) [p play]; else [p pause];
    }

    // 0.35s 后自查：状态没变成想要的样子就补一刀。
    // 不看 isPlaying（播到结尾时 rate 也是 0，会被误判），直接看 rate。
    __weak typeof(self) ws = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.35 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        __strong typeof(ws) s = ws;
        if (s == nil) return;
        if (s.player == nil) return;
        [s verifyPlayState:wantPlay attempt:0 action:action];
    });
}

- (void)verifyPlayState:(BOOL)wantPlay attempt:(int)attempt action:(IVHostAction)action {
    AVPlayer *p = self.player;
    if (p == nil) return;

    if ((p.rate > 0.0) == wantPlay) {
        [self updatePlayState];
        return;
    }

    // 只有「压根没找到宿主」才值得再点一次按钮。
    // 已经点过（Button / StateMachine / AVKit）却仍没生效时再点一次很危险：
    // 相册那个按钮是 toggle，再点一下正好把状态切回去，视频自己又播起来。
    if (attempt == 0 && action == IVHostActionNone) {
        IVHostAction again = IVHostSetPlaying(_boundWindow ?: self.window, wantPlay, p, self);
        if (again != IVHostActionNone) {
            IVLog(@"宿主第一次没生效，换 %ld 再来一次", (long)again);
            __weak typeof(self) ws = self;
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.30 * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{
                __strong typeof(ws) s = ws;
                if (s != nil) [s verifyPlayState:wantPlay attempt:1 action:again];
            });
            return;
        }
    }

    IVLog(@"宿主没生效（want=%d action=%ld attempt=%d），直接操作 player",
          wantPlay, (long)action, attempt);
    if (wantPlay) [p play]; else [p pause];
    [self updatePlayState];
}

- (void)onPlayPause {
    AVPlayer *p = self.player;
    if (!p) return;

    if ([self isPlaying]) {
        [self setPlayingViaHost:NO];
    } else if ([self isAtEnd]) {
        // 播完之后点播放 = 从头再放一遍（而不是卡在结尾原地不动）
        _currentValue = 0.0;
        [self applyProgressValue];
        __weak typeof(self) ws = self;
        [p seekToTime:kCMTimeZero
      toleranceBefore:kCMTimeZero
           toleranceAfter:kCMTimeZero
        completionHandler:^(BOOL finished) {
            (void)finished;
            __strong typeof(ws) s = ws;
            if (s == nil) return;
            [s setPlayingViaHost:YES];
        }];
    } else {
        [self setPlayingViaHost:YES];
    }
    IVHaptic();
    [self updatePlayState];
}

- (void)onToggleMute {
    AVPlayer *p = self.player;
    if (!p) return;

    BOOL target = !p.muted;
    // 静音同理：走宿主的 setMuted:，原生那条栏的音量图标才会跟着换
    if (!IVHostSetMuted(_boundWindow ?: self.window, target)) {
        p.muted = target;
    }
    IVHaptic();
    [self updateMuteState];
}

- (void)onRewind {
    [self seekBy:-15.0];
}

- (void)onForward {
    [self seekBy:15.0];
}

- (void)seekBy:(double)delta {
    AVPlayer *p = self.player;
    if (!p) return;

    double dur = [self mediaDuration];
    double cur = CMTimeGetSeconds(p.currentTime);
    if (!isfinite(cur) || cur < 0.0) cur = 0.0;

    double target = cur + delta;
    if (target < 0.0) target = 0.0;
    if (dur > 0.5 && target > dur - 0.05) target = dur - 0.05;

    [p seekToTime:CMTimeMakeWithSeconds(target, 600)
        toleranceBefore:CMTimeMakeWithSeconds(0.06, 600)
         toleranceAfter:CMTimeMakeWithSeconds(0.06, 600)
      completionHandler:^(BOOL finished) { (void)finished; }];

    if (dur > 0.0) _currentValue = target / dur;
    [self applyProgressValue];
    IVHaptic();
}

#pragma mark - 中央按钮显隐（点画面切换）

#pragma mark - 控制层显隐

/// 点胶囊空白处 = 点画面：整组一起收 / 一起出。
/// 以前这里是独立的 _centersVisible，点一下胶囊只藏中间按钮、胶囊自己留着，
/// 之后再点画面又会两个一起出来 —— 两套状态互相踩，就成了「显示和隐藏不在一起」。
- (void)toggleCenters {
    if (_expanded) {
        // 展开态（正在拖时间轴）不隐藏，避免手指还在拖控件就没了
        return;
    }
    [self setChromeVisible:!_chromeVisible animated:YES];
}

#pragma mark - 手势

/// 点胶囊空白处（非按钮区）切换中央按钮显隐
- (void)onPillTap:(UITapGestureRecognizer *)g {
    if (g.state != UIGestureRecognizerStateEnded) return;
    CGPoint p = [g locationInView:_pill];

    if (!_expanded) {
        if (CGRectContainsPoint(_playBtn.frame, p)) return;
        if (CGRectContainsPoint(_muteBtn.frame, p)) return;
    }
    [self toggleCenters];
}

- (void)onPillPan:(UIPanGestureRecognizer *)g {
    if (!self.player) return;

    if (g.state == UIGestureRecognizerStateBegan) {
        [_collapseTimer invalidate];
        _collapseTimer = nil;

        double dur = [self mediaDuration];
        if (dur <= 0.0) return;

        if (!_expanded) {
            IVHaptic();
            [self setExpanded:YES animated:YES];
        }
        _dragging = YES;
        [self updateFromPlayerTime];
    } else if (g.state == UIGestureRecognizerStateChanged) {
        if (!_dragging) return;

        CGFloat trackW = _track.bounds.size.width;
        if (trackW < 1.0) return;

        CGPoint t = [g translationInView:_pill];
        _currentValue += (double)(t.x / trackW);
        if (_currentValue < 0.0) _currentValue = 0.0;
        if (_currentValue > 1.0) _currentValue = 1.0;
        [g setTranslation:CGPointZero inView:_pill];

        [self applyProgressValue];
        [self refreshTimeLabelsForRatio:_currentValue];

        double dur = [self mediaDuration];
        if (dur > 0.0) {
            double target = dur * _currentValue;
            [self.player seekToTime:CMTimeMakeWithSeconds(target, 600)
                    toleranceBefore:CMTimeMakeWithSeconds(0.4, 600)
                     toleranceAfter:CMTimeMakeWithSeconds(0.4, 600)
                  completionHandler:^(BOOL finished) { (void)finished; }];
        }
    } else if (g.state == UIGestureRecognizerStateEnded ||
               g.state == UIGestureRecognizerStateCancelled) {
        if (_dragging) {
            double dur = [self mediaDuration];
            if (dur > 0.0) {
                double target = dur * _currentValue;
                [self.player seekToTime:CMTimeMakeWithSeconds(target, 600)
                        toleranceBefore:CMTimeMakeWithSeconds(0.03, 600)
                         toleranceAfter:CMTimeMakeWithSeconds(0.03, 600)
                      completionHandler:^(BOOL finished) { (void)finished; }];
            }
            _dragging = NO;
        }
        [self scheduleCollapse];
    }
}

- (void)updateFromPlayerTime {
    AVPlayer *p = self.player;
    if (!p) return;
    double dur = [self mediaDuration];
    if (dur <= 0.0) return;
    double cur = CMTimeGetSeconds(p.currentTime);
    if (!isfinite(cur) || cur < 0.0) cur = 0.0;
    _currentValue = cur / dur;
    [self applyProgressValue];
}

#pragma mark - 展开 / 收起

- (void)setExpanded:(BOOL)expanded animated:(BOOL)animated {
    if (_expanded == expanded) return;
    _expanded = expanded;

    if (!animated) {
        [self setNeedsLayout];
        [self layoutIfNeeded];
        return;
    }

    __weak typeof(self) ws = self;
    [UIView animateWithDuration:0.28
                          delay:0.0
         usingSpringWithDamping:0.82
          initialSpringVelocity:0.4
                        options:UIViewAnimationOptionBeginFromCurrentState
                     animations:^{
        __strong typeof(ws) s = ws;
        if (!s) return;
        CGFloat sb = s.window ? s.window.safeAreaInsets.bottom : 34.0;
        [s layoutPillWithWidth:s.bounds.size.width
                        height:s.bounds.size.height
                    safeBottom:sb];
    } completion:nil];
}

- (void)scheduleCollapse {
    [_collapseTimer invalidate];
    _collapseTimer = nil;
    _collapseTimer = [NSTimer scheduledTimerWithTimeInterval:1.6
                                                      target:self
                                                    selector:@selector(onCollapseTimer)
                                                    userInfo:nil
                                                     repeats:NO];
}

- (void)onCollapseTimer {
    _collapseTimer = nil;
    if (_dragging) return;
    [self setExpanded:NO animated:YES];
}

#pragma mark - 定时刷新

- (void)startTracking {
    [_tickTimer invalidate];
    __weak typeof(self) ws = self;
    _tickTimer = [NSTimer scheduledTimerWithTimeInterval:kTickInterval
                                                 repeats:YES
                                                   block:^(NSTimer *t) {
        __strong typeof(ws) s = ws;
        if (!s) {
            [t invalidate];
            return;
        }
        [s tick];
    }];
}

- (void)stopTracking {
    [_tickTimer invalidate];
    _tickTimer = nil;
    [_collapseTimer invalidate];
    _collapseTimer = nil;
}

- (void)tick {
    if (!self.player) return;

    double dur = [self mediaDuration];
    double cur = CMTimeGetSeconds(self.player.currentTime);
    if (!isfinite(cur) || cur < 0.0) cur = 0.0;

    if (!_dragging) {
        if (dur > 0.0) {
            _currentValue = cur / dur;
        } else {
            _currentValue = 0.0;
        }
        [self applyProgressValue];
        [self refreshTimeLabelsForRatio:(dur > 0.0 ? cur / dur : 0.0)
                                current:cur
                               duration:dur];
    }

    [self holdBeforeNaturalEndWithCurrent:cur duration:dur];
    [self handleEndStateWithCurrent:cur duration:dur];
    [self refreshIconsIfNeeded];
}

/// 结尾保护：相册一播到「真正的结尾」，就会把播放器换成静帧、退回原生界面，
/// 我们的控件随之被整块拆掉 —— 这时候再点画面也唤不回来（实测如此）。
/// 所以在最后一小段主动暂停并停在末帧附近，让「播放结束」这个事件永不发生：
/// 控件留在原地，用户点播放再由 onPlayPause 把进度 seek 回 0 重播。
- (void)holdBeforeNaturalEndWithCurrent:(double)cur duration:(double)dur {
    AVPlayer *p = self.player;
    if (!p) return;
    if (dur <= 2.0) return;             // 太短的片子别折腾
    if (p.rate <= 0.0) return;          // 已经暂停 / 被别的逻辑停了
    if (cur < dur - 0.30) return;       // 还没到窗口期

    [p pause];

    double target = dur - 0.05;
    if (target < 0.0) target = 0.0;
    [p seekToTime:CMTimeMakeWithSeconds(target, 600)
        toleranceBefore:CMTimeMakeWithSeconds(0.02, 600)
         toleranceAfter:CMTimeMakeWithSeconds(0.02, 600)
      completionHandler:^(BOOL finished) { (void)finished; }];

    IVLog(@"held before natural end at %.3f/%.3f", cur, dur);
}

/// 播到结尾时把控制层「叫回来」。
/// 相册在播完后会把自己的控制栏收掉、画面尺寸也可能变，导致中间的
/// 播放/快退/快进要么被藏起来、要么被排到屏幕外，用户就没法点重播了。
/// 这里一次性恢复显隐 + 按整窗重排，保证结尾一定能看到那三个按钮。
- (void)handleEndStateWithCurrent:(double)cur duration:(double)dur {
    BOOL atEnd = (dur > 0.5 && cur >= dur - 0.20);

    if (atEnd) {
        if (_endHandled) return;
        _endHandled = YES;

        _hasVideoRect = NO;
        _videoRect = self.bounds;
        [self setNeedsLayout];
        [self layoutIfNeeded];

        if (!_chromeVisible) {
            [self setChromeVisible:YES animated:YES];
        }
        IVLog(@"playback end: chrome restored (replay available)");
        return;
    }

    if (dur > 0.5 && cur < dur - 1.0) {
        _endHandled = NO;   // 重新开始播放，允许下次再触发
    }
}

/// 0.08s 一次地重设图标是白费 GPU 合成，状态不变就跳过
- (void)refreshIconsIfNeeded {
    BOOL playing = [self isPlaying];
    BOOL muted = [self isMuted];
    if (_stateValid && playing == _lastPlaying && muted == _lastMuted) return;

    _stateValid = YES;
    _lastPlaying = playing;
    _lastMuted = muted;

    [self updatePlayState];
    [self updateMuteState];
}

- (void)refreshTimeLabelsForRatio:(double)ratio {
    double dur = [self mediaDuration];
    [self refreshTimeLabelsForRatio:ratio current:dur * ratio duration:dur];
}

- (void)refreshTimeLabelsForRatio:(double)ratio current:(double)cur duration:(double)dur {
    (void)ratio;
    if (!_expanded) return;

    _lblLeft.text = IVTimeString(cur, YES);

    if (dur > 0.0) {
        double remain = dur - cur;
        if (remain < 0.0) remain = 0.0;
        _lblRight.text = [NSString stringWithFormat:@"-%@", IVTimeString(remain, NO)];
    } else {
        _lblRight.text = @"--:--";
    }
}

#pragma mark - 触摸穿透

- (BOOL)interceptsPoint:(CGPoint)point inWindow:(UIWindow *)window {
    if (window == nil) return NO;
    if (self.hidden || self.alpha < 0.05) return NO;
    if (!_chromeVisible) return NO;

    CGPoint p = [self convertPoint:point fromView:window];
    if (_pill.alpha > 0.05 && CGRectContainsPoint(_pill.frame, p)) return YES;
    if (_centerWrap.alpha > 0.05 && CGRectContainsPoint(_centerWrap.frame, p)) return YES;
    return NO;
}

/// 只在 pill / 中央按钮组上命中，画面其余区域穿透（保留相册原生 swipe 切图）。
- (BOOL)pointInside:(CGPoint)point withEvent:(UIEvent *)event {
    if (self.hidden || self.alpha < 0.05) return NO;

    if (_chromeVisible && !_centerWrap.hidden &&
        _centerWrap.alpha > 0.05 && CGRectContainsPoint(_centerWrap.frame, point)) {
        return YES;
    }
    if (_chromeVisible && _pill.alpha > 0.05 &&
        CGRectContainsPoint(_pill.frame, point)) {
        return YES;
    }
    return NO;
}

@end
