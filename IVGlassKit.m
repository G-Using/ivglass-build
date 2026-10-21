#import "IVGlassKit.h"
#import <QuartzCore/QuartzCore.h>
#import <math.h>
#import <objc/runtime.h>

@implementation IVGlassView {
    CAGradientLayer *_sheen;
    UIView          *_tint;
}

- (instancetype)initWithRadius:(CGFloat)radius {
    // 音量 HUD 同款材质：跟随明暗模式，浅色环境下呈浅灰白玻璃
    UIBlurEffect *effect = [UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemChromeMaterial];
    self = [super initWithEffect:effect];
    if (!self) return nil;

    self.layer.cornerCurve = kCACornerCurveContinuous;
    self.layer.cornerRadius = radius;
    self.clipsToBounds = YES;

    // 玻璃边缘：细白描边
    self.layer.borderWidth = 0.7;
    self.layer.borderColor = [UIColor colorWithWhite:1.0 alpha:0.55].CGColor;

    // 白色提亮层，贴近音量条的浅玻璃观感
    _tint = [[UIView alloc] initWithFrame:CGRectZero];
    _tint.backgroundColor = [UIColor colorWithWhite:1.0 alpha:0.30];
    _tint.userInteractionEnabled = NO;
    [_tint.layer removeFromSuperlayer];
    [self.contentView addSubview:_tint];

    // 顶部高光 + 底部压暗，让平面色块产生「曲面玻璃」的体积感
    _sheen = [CAGradientLayer layer];
    _sheen.colors = @[
        (id)[UIColor colorWithWhite:1.0 alpha:0.35].CGColor,
        (id)[UIColor colorWithWhite:1.0 alpha:0.08].CGColor,
        (id)[UIColor colorWithWhite:0.0 alpha:0.06].CGColor
    ];
    _sheen.locations = @[@0.0, @0.52, @1.0];
    _sheen.startPoint = CGPointMake(0.5, 0.0);
    _sheen.endPoint = CGPointMake(0.5, 1.0);
    [self.contentView.layer addSublayer:_sheen];

    return self;
}

- (void)updateCornerRadius:(CGFloat)radius {
    self.layer.cornerRadius = radius;
}

- (void)layoutSubviews {
    [super layoutSubviews];

    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    _tint.frame = self.bounds;
    _sheen.frame = self.bounds;
    [CATransaction commit];

    // 圆形按钮：半径跟高度走，避免布局后圆角还是旧值
    if (fabs(self.bounds.size.width - self.bounds.size.height) < 1.0 &&
        self.bounds.size.width > 1.0) {
        CGFloat r = self.bounds.size.width / 2.0;
        if (fabs(self.layer.cornerRadius - r) > 0.5) {
            self.layer.cornerRadius = r;
        }
    }
}

@end

NSString *IVTimeString(double seconds, BOOL hundredths) {
    if (!isfinite(seconds) || seconds < 0.0) seconds = 0.0;

    long total = (long)seconds;
    long h = total / 3600;
    long m = (total % 3600) / 60;
    long s = total % 60;

    if (h > 0) {
        return [NSString stringWithFormat:@"%ld:%02ld:%02ld", h, m, s];
    }
    if (hundredths) {
        long cs = lround((seconds - (double)total) * 100.0);
        if (cs > 99) cs = 99;
        if (cs < 0) cs = 0;
        return [NSString stringWithFormat:@"%02ld:%02ld.%02ld", m, s, cs];
    }
    return [NSString stringWithFormat:@"%02ld:%02ld", m, s];
}

void IVHaptic(void) {
    UIImpactFeedbackGenerator *gen =
        [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleMedium];
    [gen prepare];
    [gen impactOccurred];
}

UIImage * _Nullable IVSymbol(NSString *name, CGFloat pointSize, CGFloat weightValue) {
    if (name.length == 0) return nil;
    UIImageSymbolConfiguration *cfg =
        [UIImageSymbolConfiguration configurationWithPointSize:pointSize
                                                        weight:(UIImageSymbolWeight)weightValue];
    UIImage *img = [UIImage systemImageNamed:name withConfiguration:cfg];
    return [img imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate];
}

#pragma mark - 落盘日志

void IVLog(NSString *format, ...) {
    if (format.length == 0) return;

    va_list ap;
    va_start(ap, format);
    NSString *msg = [[NSString alloc] initWithFormat:format arguments:ap];
    va_end(ap);

    NSDateFormatter *df = [[NSDateFormatter alloc] init];
    df.dateFormat = @"HH:mm:ss.SSS";
    NSString *line = [NSString stringWithFormat:@"[%@] %@\n",
                      [df stringFromDate:[NSDate date]], msg];

    static NSString *const kLogPath = @"/var/mobile/Media/IVGlassPlayer.log";
    NSFileManager *fm = [NSFileManager defaultManager];

    if (![fm fileExistsAtPath:kLogPath]) {
        [line writeToFile:kLogPath atomically:YES
                 encoding:NSUTF8StringEncoding error:nil];
        return;
    }

    // 超过 256KB 直接重开，避免无限增长
    NSDictionary *attrs = [fm attributesOfItemAtPath:kLogPath error:nil];
    if ([[attrs objectForKey:NSFileSize] unsignedLongLongValue] > 256 * 1024) {
        [line writeToFile:kLogPath atomically:YES
                 encoding:NSUTF8StringEncoding error:nil];
        return;
    }

    NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:kLogPath];
    if (fh == nil) return;
    @try {
        [fh seekToEndOfFile];
        [fh writeData:[line dataUsingEncoding:NSUTF8StringEncoding]];
        [fh closeFile];
    } @catch (__unused NSException *ex) {
        // 写日志失败不影响主流程
    }
}

#pragma mark - 给现有视图套玻璃

void IVGlassStyleExistingView(UIView *view, CGFloat cornerRadius) {
    if (view == nil) return;

    // 只处理一次：用关联标记，避免每帧扫描重复插层
    static const void *kIVGlassAppliedKey = &kIVGlassAppliedKey;
    if (objc_getAssociatedObject(view, kIVGlassAppliedKey) != nil) {
        return;
    }

    CALayer *layer = view.layer;
    layer.cornerCurve = kCACornerCurveContinuous;
    layer.cornerRadius = cornerRadius;
    layer.masksToBounds = YES;
    layer.borderWidth = 0.7;
    layer.borderColor = [UIColor colorWithWhite:1.0 alpha:0.55].CGColor;

    // 毛玻璃垫底：盖在 view 自身背景之上、内容之下（音量 HUD 同款浅玻璃）
    UIBlurEffect *eff = [UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemChromeMaterial];
    UIVisualEffectView *blur = [[UIVisualEffectView alloc] initWithEffect:eff];
    blur.userInteractionEnabled = NO;
    blur.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    blur.frame = view.bounds;
    [view insertSubview:blur atIndex:0];

    // 顶部高光
    CAGradientLayer *sheen = [CAGradientLayer layer];
    sheen.frame = view.bounds;
    sheen.colors = @[
        (id)[UIColor colorWithWhite:1.0 alpha:0.35].CGColor,
        (id)[UIColor colorWithWhite:1.0 alpha:0.08].CGColor,
        (id)[UIColor colorWithWhite:0.0 alpha:0.06].CGColor
    ];
    sheen.locations = @[@0.0, @0.5, @1.0];
    sheen.startPoint = CGPointMake(0.5, 0.0);
    sheen.endPoint = CGPointMake(0.5, 1.0);
    [view.layer insertSublayer:sheen atIndex:0];

    // 原背景若是纯色胶囊，压淡让毛玻璃透出来
    if (view.backgroundColor != nil) {
        view.backgroundColor = [view.backgroundColor colorWithAlphaComponent:0.15];
    }

    objc_setAssociatedObject(view, kIVGlassAppliedKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}
