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

/// 给「别人家的视图」（如相册顶部时间胶囊）原地套一层玻璃质感：
/// 保留原 view 与其内容，只在其下层插一块毛玻璃 + 描边 + 高光，并把它改成圆角。
/// 只调 layer / 插 subview，不替换对象，避免破坏宿主内部引用。
void IVGlassStyleExistingView(UIView * _Nonnull view, CGFloat cornerRadius);

#ifdef __cplusplus
extern "C" {
#endif

/// 秒 -> "mm:ss" 或 "mm:ss.CC" / "h:mm:ss"
NSString *IVTimeString(double seconds, BOOL hundredths);

/// 中等强度触感
void IVHaptic(void);

/// SF Symbol，模板渲染（跟随 tintColor）
UIImage * _Nullable IVSymbol(NSString *name, CGFloat pointSize, CGFloat weightValue);

/// 落盘日志：/var/mobile/Documents/IVGlassPlayer.log（「文件」App 里能直接看）
void IVLog(NSString * _Nonnull format, ...) NS_FORMAT_FUNCTION(1, 2);

#ifdef __cplusplus
}
#endif

NS_ASSUME_NONNULL_END
