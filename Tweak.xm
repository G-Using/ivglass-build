//
//  Tweak.xm
//  IVGlassPlayer
//
//  只做一件事：捕获 AVPlayerLayer 上的 player。
//  真正的工作全部在 IVPlayerWatcher 里，由主线程的定时扫描驱动，
//  %ctor 阶段不执行任何耗时逻辑（避免触发启动看门狗）。
//

#import <AVFoundation/AVFoundation.h>
#import <UIKit/UIKit.h>
#import "IVPlayerWatcher.h"

%hook AVPlayerLayer

- (void)setPlayer:(AVPlayer *)player {
    %orig;

    __weak AVPlayerLayer *weakLayer = self;
    BOOL attached = (player != nil);

    dispatch_async(dispatch_get_main_queue(), ^{
        AVPlayerLayer *layer = weakLayer;
        if (layer == nil) return;

        if (attached) {
            [[IVPlayerWatcher shared] noteLayer:layer];
        } else {
            [[IVPlayerWatcher shared] forgetLayer:layer];
        }
    });
}

%end
