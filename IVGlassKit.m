#import "IVGlassKit.h"
#import <QuartzCore/QuartzCore.h>
#import <math.h>

@implementation IVGlassView {
    CAGradientLayer *_sheen;
}

- (instancetype)initWithRadius:(CGFloat)radius {
    UIBlurEffect *effect = [UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemUltraThinMaterialDark];
    self = [super initWithEffect:effect];
    if (!self) return nil;

    self.layer.cornerCurve = kCACornerCurveContinuous;
    self.layer.cornerRadius = radius;
    self.clipsToBounds = YES;

    // 玻璃边缘：一条 0.7pt 的半透明白描边，是 Liquid Glass 最关键的辨识特征
    self.layer.borderWidth = 0.7;
    self.layer.borderColor = [UIColor colorWithWhite:1.0 alpha:0.16].CGColor;

    // 顶部高光 + 底部压暗，让平面色块产生「曲面玻璃」的体积感
    _sheen = [CAGradientLayer layer];
    _sheen.colors = @[
        (id)[UIColor colorWithWhite:1.0 alpha:0.18].CGColor,
        (id)[UIColor colorWithWhite:1.0 alpha:0.05].CGColor,
        (id)[UIColor colorWithWhite:0.0 alpha:0.10].CGColor
    ];
    _sheen.locations = @[@0.0, @0.52, @1.0];
    _sheen.startPoint = CGPointMake(0.5, 0.0);
    _sheen.endPoint = CGPointMake(0.5, 1.0);
    [self.contentView.layer insertSublayer:_sheen atIndex:0];

    return self;
}

- (void)updateCornerRadius:(CGFloat)radius {
    self.layer.cornerRadius = radius;
}

- (void)layoutSubviews {
    [super layoutSubviews];

    [CATransaction begin];
    [CATransaction setDisableActions:YES];
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
