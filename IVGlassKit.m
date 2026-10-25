#import "IVGlassKit.h"
#import <QuartzCore/QuartzCore.h>
#import <math.h>
#import <objc/runtime.h>

/// 边缘光的线宽：略粗于 1 物理像素，抗锯齿之后才像一条「折射亮边」
static inline CGFloat IVHairline(void) {
    CGFloat s = [UIScreen mainScreen].scale;
    if (!(s > 0.0)) s = 3.0;
    return 2.0 / s;
}

@implementation IVGlassView {
    UIVisualEffectView *_blur;
    UIView             *_contentView;
    UIView             *_tint;
    CAGradientLayer    *_sheen;    // 纵向曲面渐变
    CAGradientLayer    *_spec;     // 顶部球面高光
    CAGradientLayer    *_rim;      // 边缘光
    CAShapeLayer       *_rimMask;
    CGFloat             _radius;
}

@synthesize contentView = _contentView;

- (instancetype)initWithRadius:(CGFloat)radius {
    self = [super initWithFrame:CGRectZero];
    if (!self) return nil;

    _radius = radius;

    self.backgroundColor = [UIColor clearColor];
    // 不裁剪自己：圆角交给内部 blur 裁，阴影才能留在外面
    self.layer.cornerCurve = kCACornerCurveContinuous;
    self.layer.shadowColor = [UIColor colorWithWhite:0.0 alpha:0.34].CGColor;
    self.layer.shadowOpacity = 1.0;
    self.layer.shadowRadius = 22.0;
    self.layer.shadowOffset = CGSizeMake(0.0, 10.0);

    // 1) 毛玻璃底 —— 音量 HUD 同款材质，跟随明暗模式
    UIBlurEffect *effect = [UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemChromeMaterial];
    _blur = [[UIVisualEffectView alloc] initWithEffect:effect];
    _blur.userInteractionEnabled = NO;
    _blur.clipsToBounds = YES;
    _blur.layer.cornerCurve = kCACornerCurveContinuous;
    _blur.layer.cornerRadius = radius;
    [self addSubview:_blur];

    // 2) 白色薄雾 + 曲面渐变（挂在 blur.contentView 上，自动被圆角裁掉）
    // 薄雾要薄：太厚就变成一块实心白条，看不出底下在放视频
    _tint = [[UIView alloc] initWithFrame:CGRectZero];
    _tint.backgroundColor = [UIColor colorWithWhite:1.0 alpha:0.10];
    _tint.userInteractionEnabled = NO;
    [_blur.contentView addSubview:_tint];

    _sheen = [CAGradientLayer layer];
    _sheen.colors = @[
        (id)[UIColor colorWithWhite:1.0 alpha:0.38].CGColor,
        (id)[UIColor colorWithWhite:1.0 alpha:0.03].CGColor,
        (id)[UIColor colorWithWhite:0.0 alpha:0.14].CGColor
    ];
    _sheen.locations = @[@0.0, @0.55, @1.0];
    _sheen.startPoint = CGPointMake(0.5, 0.0);
    _sheen.endPoint = CGPointMake(0.5, 1.0);
    [_blur.contentView.layer addSublayer:_sheen];

    // 3) 顶部球面高光：radial，圆心压在顶边中点
    _spec = [CAGradientLayer layer];
    _spec.type = kCAGradientLayerRadial;
    _spec.colors = @[
        (id)[UIColor colorWithWhite:1.0 alpha:0.42].CGColor,
        (id)[UIColor colorWithWhite:1.0 alpha:0.12].CGColor,
        (id)[UIColor colorWithWhite:1.0 alpha:0.0].CGColor
    ];
    _spec.locations = @[@0.0, @0.42, @1.0];
    // radial 的两个半径由 start→end 的位移决定：横向拉满、纵向往下延伸，
    // 得到一个压在顶边的宽椭圆高光（dx 若为 0 会退化成一条线）
    _spec.startPoint = CGPointMake(0.5, 0.0);
    _spec.endPoint = CGPointMake(1.0, 1.0);
    [_blur.contentView.layer addSublayer:_spec];

    // 4) 边缘光：纵向渐变 —— 上沿白亮、腰身几乎透明、下沿压一道暗边。
    // 这一段是「玻璃」和「白色贴纸」的分水岭：只描白边在浅色画面上完全看不见。
    _rim = [CAGradientLayer layer];
    _rim.colors = @[
        (id)[UIColor colorWithWhite:1.0 alpha:0.92].CGColor,
        (id)[UIColor colorWithWhite:1.0 alpha:0.30].CGColor,
        (id)[UIColor colorWithWhite:1.0 alpha:0.06].CGColor,
        (id)[UIColor colorWithWhite:0.0 alpha:0.06].CGColor,
        (id)[UIColor colorWithWhite:0.0 alpha:0.22].CGColor
    ];
    _rim.locations = @[@0.0, @0.16, @0.40, @0.60, @1.0];
    _rim.startPoint = CGPointMake(0.5, 0.0);
    _rim.endPoint = CGPointMake(0.5, 1.0);

    _rimMask = [CAShapeLayer layer];
    _rimMask.fillColor = [UIColor clearColor].CGColor;
    _rimMask.strokeColor = [UIColor blackColor].CGColor;
    _rimMask.lineWidth = IVHairline();
    _rim.mask = _rimMask;
    [self.layer addSublayer:_rim];

    // 5) 交互内容层：放在描边之上，图标不会被边缘光盖住
    _contentView = [[UIView alloc] initWithFrame:CGRectZero];
    _contentView.backgroundColor = [UIColor clearColor];
    [self addSubview:_contentView];

    return self;
}

- (void)updateCornerRadius:(CGFloat)radius {
    _radius = radius;
    [self setNeedsLayout];
}

- (void)layoutSubviews {
    [super layoutSubviews];

    CGRect b = self.bounds;
    if (b.size.width < 1.0 || b.size.height < 1.0) return;

    // 圆形按钮：半径直接取一半，不依赖外面传的值
    CGFloat r = _radius;
    if (fabs(b.size.width - b.size.height) < 1.0) {
        r = b.size.width / 2.0;
    }
    CGFloat maxR = MIN(b.size.width, b.size.height) / 2.0;
    if (r > maxR) r = maxR;

    CGFloat lw = IVHairline();

    [CATransaction begin];
    [CATransaction setDisableActions:YES];

    _blur.frame = b;
    _tint.frame = b;
    _sheen.frame = b;
    _spec.frame = b;
    _rim.frame = b;
    _contentView.frame = b;

    _blur.layer.cornerRadius = r;
    self.layer.shadowPath = [UIBezierPath bezierPathWithRoundedRect:b cornerRadius:r].CGPath;

    _rimMask.lineWidth = lw;
    UIBezierPath *ring =
        [UIBezierPath bezierPathWithRoundedRect:CGRectInset(b, lw / 2.0, lw / 2.0)
                                   cornerRadius:MAX(0.0, r - lw / 2.0)];
    _rimMask.path = ring.CGPath;

    [CATransaction commit];
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

/// 日志落在哪。
///
/// 以前写死 `/var/mobile/Media/IVGlassPlayer.log`，但相册是沙盒 App，
/// 对那个目录根本没有写权限 —— `writeToFile:error:` 我们传了 nil，
/// 失败也不吭声，结果就是「日志文件压根不存在」，排查时等于瞎子。
///
/// 现在按顺序试几个位置，挑第一个写得进去的：
///   1. App 自己的 tmp（一定写得进去，Filza 里能找到）
///   2. App 的 Documents
///   3. /var/mobile/Media（越狱环境下有的机器能写）
static NSString *IVLogPath(void) {
    static NSString *path = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSMutableArray<NSString *> *cands = [NSMutableArray array];
        NSString *tmp = NSTemporaryDirectory();
        if (tmp.length > 0) [cands addObject:[tmp stringByAppendingPathComponent:@"IVGlassPlayer.log"]];

        NSString *home = NSHomeDirectory();
        if (home.length > 0) {
            [cands addObject:[home stringByAppendingPathComponent:@"Documents/IVGlassPlayer.log"]];
        }
        [cands addObject:@"/var/mobile/Media/IVGlassPlayer.log"];

        NSFileManager *fm = [NSFileManager defaultManager];
        for (NSString *c in cands) {
            // 真写一次探测，别信 fileExists / isWritableFile
            NSData *probe = [@"" dataUsingEncoding:NSUTF8StringEncoding];
            if ([fm createFileAtPath:c contents:probe attributes:nil]) {
                path = c;
                return;
            }
            if ([fm isWritableFileAtPath:c]) {
                path = c;
                return;
            }
        }
    });
    return path;
}

void IVLog(NSString *format, ...) {
    if (format.length == 0) return;

    va_list ap;
    va_start(ap, format);
    NSString *msg = [[NSString alloc] initWithFormat:format arguments:ap];
    va_end(ap);

    NSLog(@"[IVGlass] %@", msg);

    NSDateFormatter *df = [[NSDateFormatter alloc] init];
    df.dateFormat = @"HH:mm:ss.SSS";
    NSString *line = [NSString stringWithFormat:@"[%@] %@\n",
                      [df stringFromDate:[NSDate date]], msg];

    NSString *kLogPath = IVLogPath();
    if (kLogPath.length == 0) return;

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

/// 当前日志文件绝对路径，方便排查时告诉用户去哪找
NSString *IVLogFilePath(void) {
    return IVLogPath();
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
