//
//  IVHostBridge.h
//  IVGlassPlayer
//
//  把「播放 / 暂停 / 静音」交给宿主自己的状态机，而不是直接操作 AVPlayer。
//

#import <UIKit/UIKit.h>
#import <AVFoundation/AVFoundation.h>

NS_ASSUME_NONNULL_BEGIN

/// 请求宿主（相册 / 文件 / AVKit）播放或暂停。
///
/// 为什么不能直接 `[player pause]`：
/// 相册的原生控制栏不是 KVO 播放器，它读的是自己的状态机
/// （`PUBrowsingVideoPlayer.desiredPlayState`）。只调 AVPlayer 的话画面是停住了，
/// 但宿主不知道，底部那条栏的播放/暂停图标不会跟着变 —— 看起来就是
/// 「插件暂停了，原生不跟随」，再点原生按钮还会把状态搞反。
///
/// @return YES 表示已经交给宿主；NO 表示没找到宿主，调用方应自行操作 player。
BOOL IVHostSetPlaying(UIWindow * _Nullable win, BOOL wantPlay, AVPlayer * _Nullable player);

/// 同上，静音。原生那条栏的音量图标也归宿主管。
BOOL IVHostSetMuted(UIWindow * _Nullable win, BOOL muted);

/// 让原生控制栏的播放/暂停图标跟上 wantPlay。
///
/// 相册那条栏的图标不一定跟着 `desiredPlayState` 走（实测就不跟），
/// 所以最后补一刀：找到那个原生播放/暂停按钮，读它的无障碍标签判断它
/// 以为自己在播还是暂停，不一致就 `sendActionsForControlEvents:` 点它一下。
/// 此时真实播放状态已经是 wantPlay，它那一下只会把图标纠正过来，不会改状态。
///
/// @return YES 表示找到了按钮并处理了（或本来就一致）。
BOOL IVHostSyncPlayPauseIcon(UIWindow * _Nullable win, BOOL wantPlay, UIView * _Nullable skip);

NS_ASSUME_NONNULL_END
