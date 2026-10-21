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

/// 目标进程判定。
/// 「文件」App 里点开视频，播放器并不在 com.apple.DocumentsApp 里跑 ——
/// 文件用的是 QuickLook 预览，视频由 com.apple.quicklook.extension.previewUI
/// 这个扩展进程呈现。所以只注入 DocumentsApp 是永远看不到控件的。
static BOOL IVIsTargetProcess(void) {
    NSString *bid = [[NSBundle mainBundle] bundleIdentifier];
    if (bid.length == 0) return NO;

    static NSArray<NSString *> *exact = nil;
    static dispatch_once_t onceTok;
    dispatch_once(&onceTok, ^{
        exact = @[
            @"com.apple.mobileslideshow",                  // 照片
            @"com.apple.DocumentsApp",                     // 文件
            @"com.apple.quicklook.extension.previewUI",    // QuickLook 预览扩展（视频播放器在这）
            @"com.apple.QuickLookUIService",               // 老系统的叫法
            @"com.apple.DocumentManagerUICore",            // 文件选择器
            @"com.apple.PreviewUI",                        // 部分系统版本的叫法
        ];
    });
    if ([exact containsObject:bid]) return YES;

    // 兜底：不同 iOS 版本对 QuickLook 扩展命名有出入，凡是名字里带
    // quicklook 的一律放进来。注入多了不挂控件也不会有副作用。
    if ([bid.lowercaseString containsString:@"quicklook"]) return YES;
    return NO;
}

%ctor {
    // 进程白名单：视频壁纸会让 SpringBoard 里出现全屏 AVPlayerLayer，
    // Filter.plist 拦不住的场景在这里兜底 —— 不是目标进程就完全不启用 hook。
    if (!IVIsTargetProcess()) return;
    %init(_ungrouped);
}
