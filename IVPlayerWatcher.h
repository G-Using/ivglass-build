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

@end

NS_ASSUME_NONNULL_END
