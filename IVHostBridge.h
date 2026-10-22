//
//  IVHostBridge.h
//  IVGlassPlayer
//
//  把「播放 / 暂停 / 静音」交给宿主自己的状态机，而不是直接操作 AVPlayer。
//

#import <UIKit/UIKit.h>
#import <AVFoundation/AVFoundation.h>

NS_ASSUME_NONNULL_BEGIN

/// 这次播放/暂停是怎么完成的，调用方据此决定要不要兜底。
typedef NS_ENUM(NSInteger, IVHostAction) {
    /// 什么都没找到 —— 调用方自己去操作 player
    IVHostActionNone = 0,
    /// 点了宿主自己的播放/暂停按钮（最可靠，图标和状态一起变）
    IVHostActionButton = 1,
    /// 写了 PUBrowsingVideoPlayer 的状态机（相册）
    IVHostActionStateMachine = 2,
    /// 调了 AVPlayerViewController 的 play / pause（文件 / AVKit）
    IVHostActionAVKit = 3,
};

/// 请求宿主（相册 / 文件 / AVKit）播放或暂停。
///
/// 为什么不能直接 `[player pause]`：
/// 相册的原生控制栏不是 KVO 播放器，它读的是自己的状态机
/// （`PUBrowsingVideoPlayer.desiredPlayState`）。只调 AVPlayer 的话画面是停住了，
/// 但宿主不知道，底部那条栏的播放/暂停图标不会跟着变 —— 看起来就是
/// 「插件暂停了，原生不跟随」，再点原生按钮还会把状态搞反。
///
/// 尝试顺序（前一个成了就不做后面的，避免重复 toggle）：
///   1. 点宿主自己的播放/暂停按钮 —— 和用户手动点完全一样，状态和图标必然一致
///   2. 写 `PUBrowsingVideoPlayer.desiredPlayState`
///   3. 调 `AVPlayerViewController` 的 `play` / `pause`
///
/// @param skip 我们自己的 overlay，绝不能被当成原生按钮点
/// @return 实际生效的方式；`IVHostActionNone` 表示没找到宿主
IVHostAction IVHostSetPlaying(UIWindow * _Nullable win,
                              BOOL wantPlay,
                              AVPlayer * _Nullable player,
                              UIView * _Nullable skip);

/// 同上，静音。原生那条栏的音量图标也归宿主管。
BOOL IVHostSetMuted(UIWindow * _Nullable win, BOOL muted);

NS_ASSUME_NONNULL_END
