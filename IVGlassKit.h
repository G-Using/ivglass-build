//
//  IVGlassKit.h
//  IVGlassPlayer — iOS 26 风格玻璃播放控制
//
//  iOS 16 没有 UIGlassEffect，这里用「超薄毛玻璃 + 内高光渐变 + 细描边」
//  模拟 Liquid Glass 的观感。
//

#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

@interface IVGlassView : UIVisualEffectView

/// radius 传 0 时按正方形自动取半径（供圆形按钮用）
- (instancetype)initWithRadius:(CGFloat)radius;

/// 运行期改圆角（胶囊展开时高度会变，半径要跟着变）
- (void)updateCornerRadius:(CGFloat)radius;

@end

#ifdef __cplusplus
extern "C" {
#endif

/// 秒 -> "mm:ss" 或 "mm:ss.CC" / "h:mm:ss"
NSString *IVTimeString(double seconds, BOOL hundredths);

/// 中等强度触感
void IVHaptic(void);

/// SF Symbol，模板渲染（跟随 tintColor）
UIImage * _Nullable IVSymbol(NSString *name, CGFloat pointSize, CGFloat weightValue);

#ifdef __cplusplus
}
#endif

NS_ASSUME_NONNULL_END
