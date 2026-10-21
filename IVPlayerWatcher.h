//
//  IVPlayerWatcher.h
//  IVGlassPlayer
//
//  通过 hook -[AVPlayerLayer setPlayer:] 拿到播放器，
//  再判断「这个 layer 是不是正在全屏播放」，是就挂上玻璃控制层。
//

#import <UIKit/UIKit.h>
#import <AVFoundation/AVFoundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface IVPlayerWatcher : NSObject

+ (instancetype)shared;

- (void)noteLayer:(AVPlayerLayer *)layer;
- (void)forgetLayer:(AVPlayerLayer *)layer;

/// 观察 window 的触摸事件，识别「短按无位移」用于切换控制层显隐。
/// 只观察不消费，不会影响相册自己的手势。
- (void)observeTouchEvent:(UIEvent *)event inWindow:(UIWindow *)window;

@end

NS_ASSUME_NONNULL_END
