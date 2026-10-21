#import "IVGlassOverlay.h"
#import "IVGlassKit.h"
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

@interface IVGlassOverlay () {
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
    BOOL         _centersVisible;
    BOOL         _manualHide;
    NSTimer     *_tickTimer;
    NSTimer     *_hideCenterTimer;
    NSTimer     *_collapseTimer;
}
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
    _centersVisible = NO;

    return self;
}

- (void)dealloc {
    [_tickTimer invalidate];
    [_hideCenterTimer invalidate];
    [_collapseTimer invalidate];
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

    // 手势
    UILongPressGestureRecognizer *lp =
        [[UILongPressGestureRecognizer alloc] initWithTarget:self action:@selector(onPillLongPress:)];
    lp.minimumPressDuration = 0.32;
    lp.allowableMovement = 14.0;
    lp.cancelsTouchesInView = NO;
    [_pill addGestureRecognizer:lp];

    UIPanGestureRecognizer *pan =
        [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(onPillPan:)];
    pan.cancelsTouchesInView = NO;
    pan.maximumNumberOfTouches = 1;
    [_pill addGestureRecognizer:pan];

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
    _centerWrap.alpha = 0.0;
    _centerWrap.userInteractionEnabled = YES;
    _centerWrap.transform = CGAffineTransformMakeScale(0.86, 0.86);
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

    CGFloat safeBottom = 34.0;
    UIWindow *win = self.window;
    if (win) safeBottom = win.safeAreaInsets.bottom;

    [self layoutPillWithWidth:W height:H safeBottom:safeBottom];
    [self layoutCenterWithWidth:W height:H];
    [self applyProgressValue];
}

- (void)layoutPillWithWidth:(CGFloat)W height:(CGFloat)H safeBottom:(CGFloat)safeBottom {
    CGFloat pillH = _expanded ? kPillHExpanded : kPillHCompact;
    CGFloat pillW = MIN(W - kPillSide * 2.0, kPillMaxWidth);
    CGFloat pillX = (W - pillW) / 2.0;
    CGFloat gap   = _expanded ? 42.0 : 26.0;   // 往上抬，别压着 home 横条
    CGFloat pillY = H - safeBottom - pillH - gap;

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

- (void)layoutCenterWithWidth:(CGFloat)W height:(CGFloat)H {
    CGFloat sideD = 68.0;
    CGFloat midD  = 84.0;
    CGFloat gap   = 26.0;

    CGFloat scale = MIN(1.0, MIN(W, H) / 400.0);
    scale = MAX(0.62, scale);

    sideD *= scale;
    midD  *= scale;
    gap   *= scale;

    CGFloat totalW = sideD * 2.0 + midD + gap * 2.0;
    CGFloat originX = (W - totalW) / 2.0;
    CGFloat midY = H / 2.0;

    _centerWrap.frame = CGRectMake(originX - gap * 0.4,
                                   midY - midD / 2.0 - gap * 0.4,
                                   totalW + gap * 0.8,
                                   midD + gap * 0.8);

    // 内部坐标相对 centerWrap
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

    CGFloat knobD = _expanded ? 16.0 : 0.0;
    if (_expanded && knobD > 0.0) {
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

- (void)onPlayPause {
    AVPlayer *p = self.player;
    if (!p) return;

    if ([self isPlaying]) {
        [p pause];
    } else {
        [p play];
    }
    IVHaptic();
    [self updatePlayState];

    _manualHide = NO;
    if (!_expanded) {
        [self showCenters:YES autoHide:[self isPlaying]];
    }
}

- (void)onToggleMute {
    AVPlayer *p = self.player;
    if (!p) return;
    p.muted = !p.muted;
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

    _manualHide = NO;
    [self showCenters:YES autoHide:YES];
}

#pragma mark - 中央按钮显隐

- (void)showCenters:(BOOL)animated autoHide:(BOOL)autoHide {
    _centersVisible = YES;
    [_hideCenterTimer invalidate];
    _hideCenterTimer = nil;

    __weak typeof(self) ws = self;
    [UIView animateWithDuration:animated ? 0.15 : 0.0
                          delay:0.0
                        options:UIViewAnimationOptionBeginFromCurrentState
                     animations:^{
        __strong typeof(ws) s = ws;
        if (!s) return;
        s->_centerWrap.alpha = 1.0;
        s->_centerWrap.transform = CGAffineTransformIdentity;
    } completion:nil];

    if (autoHide) {
        _hideCenterTimer = [NSTimer scheduledTimerWithTimeInterval:4.5
                                                            target:self
                                                          selector:@selector(onCenterHideTimer)
                                                          userInfo:nil
                                                           repeats:NO];
    }
}

- (void)hideCenters:(BOOL)animated {
    _centersVisible = NO;
    [_hideCenterTimer invalidate];
    _hideCenterTimer = nil;

    __weak typeof(self) ws = self;
    [UIView animateWithDuration:animated ? 0.13 : 0.0
                          delay:0.0
                        options:UIViewAnimationOptionBeginFromCurrentState
                     animations:^{
        __strong typeof(ws) s = ws;
        if (!s) return;
        s->_centerWrap.alpha = 0.0;
        s->_centerWrap.transform = CGAffineTransformMakeScale(0.92, 0.92);
    } completion:nil];
}

- (void)onCenterHideTimer {
    _hideCenterTimer = nil;
    if (_expanded) return;              // 展开态保持显示
    if (![self isPlaying]) return;      // 暂停时保持显示
    if (_manualHide) return;
    [self hideCenters:YES];
}

#pragma mark - 手势

- (void)onPillTap:(UITapGestureRecognizer *)g {
    CGPoint p = [g locationInView:_pill];

    // 点在按钮上时交给按钮，不要误触发
    if (!_expanded) {
        if (CGRectContainsPoint(_playBtn.frame, p)) return;
        if (CGRectContainsPoint(_muteBtn.frame, p)) return;
    }

    if (_centersVisible) {
        _manualHide = YES;
        [self hideCenters:YES];
    } else {
        _manualHide = NO;
        [self showCenters:YES autoHide:[self isPlaying]];
    }
}

- (void)onPillLongPress:(UILongPressGestureRecognizer *)g {
    if (g.state == UIGestureRecognizerStateBegan) {
        IVHaptic();
        [self setExpanded:YES animated:YES];
        [self showCenters:YES autoHide:NO];
    } else if (g.state == UIGestureRecognizerStateEnded ||
               g.state == UIGestureRecognizerStateCancelled) {
        [self scheduleCollapse];
    }
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
            [self showCenters:YES autoHide:NO];
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

    if (expanded) {
        _manualHide = NO;
    }

    if (!animated) {
        [self setNeedsLayout];
        [self layoutIfNeeded];
        return;
    }

    __weak typeof(self) ws = self;
    [UIView animateWithDuration:0.30
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
    _collapseTimer = [NSTimer scheduledTimerWithTimeInterval:1.4
                                                      target:self
                                                    selector:@selector(onCollapseTimer)
                                                    userInfo:nil
                                                     repeats:NO];
}

- (void)onCollapseTimer {
    _collapseTimer = nil;
    if (_dragging) return;
    [self setExpanded:NO animated:YES];
    if (![self isPlaying]) return;
    [self showCenters:YES autoHide:YES];
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

    [self showCenters:YES autoHide:YES];
}

- (void)stopTracking {
    [_tickTimer invalidate];
    _tickTimer = nil;
    [_hideCenterTimer invalidate];
    _hideCenterTimer = nil;
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

    [self updatePlayState];
    [self updateMuteState];

    // 暂停时中央按钮常显（除非用户主动收起过）
    if (!_centersVisible && !_expanded && !_manualHide && ![self isPlaying]) {
        [self showCenters:YES autoHide:NO];
    }
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

- (BOOL)pointInside:(CGPoint)point withEvent:(UIEvent *)event {
    if (self.hidden || self.alpha < 0.05) return NO;

    for (UIView *v in self.subviews) {
        if (v.hidden || v.alpha < 0.05) continue;
        if (!v.userInteractionEnabled) continue;
        if (CGRectContainsPoint(v.frame, point)) return YES;
    }
    return NO;
}

@end
