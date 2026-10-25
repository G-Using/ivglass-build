//
//  IVGlassKit.h
//  IVGlassPlayer — iOS 26 风格玻璃播放控制
//
//  iOS 16 没有 UIGlassEffect，这里用「毛玻璃 + 曲面渐变 + 球面高光 + 渐变边缘光」
//  四层叠出 Liquid Glass 的观感。
//

#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

/// 仿 iOS 26 Liquid Glass 的玻璃容器。
///
/// 四层结构（从下往上）：
///   1. UIVisualEffectView 毛玻璃垫底
///   2. 白色薄雾 + 纵向曲面渐变 —— 顶部亮、底部压暗，做出「有厚度」的体积感
///   3. 顶部球面高光（radial）—— 模拟光源打在弧面上的反射
///   4. 1px 渐变描边 —— 左上最亮、中间转弱、右下再亮一次，模拟玻璃折射的边缘光
///
/// 阴影挂在容器自身的 layer 上（内部 blur 单独裁剪），这样圆角不会把阴影一起裁掉。
@interface IVGlassView : UIView

/// 内容层：按钮、文字等加到这里（等价于 UIVisualEffectView.contentView）
@property (nonatomic, readonly) UIView *contentView;

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
