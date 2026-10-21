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

/// 同步「视频画面」在窗口坐标系里的矩形。
/// 控件会以这块区域为基准居中 / 靠底，而不是死按整窗计算 —— 视频被
/// letterbox（上下黑边）或没有铺满屏幕时，这样就不会再错位。
/// 传 CGRectZero 表示「没有可用画面区域」，退回按整窗排版。
- (void)syncToVideoRect:(CGRect)rect;

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

/// 控制层整体显隐（底部胶囊 + 中央按钮一起）
@property (nonatomic, assign, readonly) BOOL chromeVisible;
- (void)setChromeVisible:(BOOL)visible animated:(BOOL)animated;

/// 窗口坐标系里的某个点是否落在自己的控件上。
/// 用来区分「在画面上横向拖动切图」和「按住胶囊拖时间轴」。
- (BOOL)interceptsPoint:(CGPoint)point inWindow:(UIWindow *)window;

@end

NS_ASSUME_NONNULL_END
