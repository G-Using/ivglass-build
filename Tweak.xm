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

// 触摸观察通道：只读不消费，用来识别「点画面切换控制层显隐」。
// 比 window 手势更可靠 —— sendEvent 是触摸的唯一入口，收不到才怪。
%hook UIWindow
- (void)sendEvent:(UIEvent *)event {
    %orig;
    if (event.type == UIEventTypeTouches) {
        [[IVPlayerWatcher shared] observeTouchEvent:event inWindow:self];
    }
}
%end

%ctor {
    // 进程白名单：视频壁纸会让 SpringBoard 里出现全屏 AVPlayerLayer，
    // Filter.plist 拦不住的场景在这里兜底 —— 不是目标 App 就完全不启用 hook。
    NSString *bid = [[NSBundle mainBundle] bundleIdentifier];
    if (![bid isEqualToString:@"com.apple.mobileslideshow"] &&
        ![bid isEqualToString:@"com.apple.DocumentsApp"]) {
        return;
    }
    %init(_ungrouped);
}
