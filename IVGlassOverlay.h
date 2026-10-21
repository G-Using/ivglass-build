//
//  IVGlassOverlay.h
//  IVGlassPlayer
//

#import <UIKit/UIKit.h>
#import <AVFoundation/AVFoundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface IVGlassOverlay : UIView

@property (nonatomic, strong, nullable) AVPlayer *player;

/// YES = 底部胶囊已展开成可拖动的时间轴
@property (nonatomic, assign, readonly, getter=isExpanded) BOOL expanded;

/// 让 overlay 立刻刷新一次布局（窗口尺寸变化 / 旋转时调用）
- (void)relayout;

/// 开始 / 停止 0.08s 的刷新定时器
- (void)startTracking;
- (void)stopTracking;

/// 绑定宿主窗口（安装「点画面切换显隐」的全屏 tap）。
/// tap 挂在 window 上且不消费触摸，因此不会影响相册的左右滑切图。
- (void)bindWindow:(UIWindow *)window;
- (void)unbindWindow;

/// 外部观察到的一次有效点击（来自 window sendEvent 的短按检测）。
/// 与 window tap 互为兜底，内部有去重。
- (void)handleExternalTapAt:(CGPoint)point inView:(UIView *)view;

@end

NS_ASSUME_NONNULL_END
