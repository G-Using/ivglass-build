//
//  IVHostBridge.m
//  IVGlassPlayer
//

#import "IVHostBridge.h"
#import "IVGlassKit.h"
#import <objc/message.h>
#import <objc/runtime.h>

#pragma mark - 小工具

/// 取属性：先试 getter，再退回 KVC（有些私有类只有 ivar，没有 getter）。
static id IVGetProp(id obj, NSString *key) {
    if (obj == nil || key.length == 0) return nil;

    SEL sel = NSSelectorFromString(key);
    if ([obj respondsToSelector:sel]) {
        @try {
            return ((id (*)(id, SEL))objc_msgSend)(obj, sel);
        } @catch (__unused NSException *e) {
            // 掉下去试 KVC
        }
    }

    @try {
        return [obj valueForKey:key];
    } @catch (__unused NSException *e) {
        return nil;
    }
}

static BOOL IVResponds(id obj, NSString *selName) {
    return obj != nil && [obj respondsToSelector:NSSelectorFromString(selName)];
}

/// 相册的播放状态机：`PUBrowsingVideoPlayer`。
static BOOL IVLooksLikeBrowsingPlayer(id o) {
    if (o == nil) return NO;
    if (!IVResponds(o, @"desiredPlayState")) return NO;
    return IVResponds(o, @"setDesiredPlayState:reason:") ||
           IVResponds(o, @"setDesiredPlayState:");
}

/// 读 `isPlaybackDesired`：1 = 想播, 0 = 想停, -1 = 这个版本没有该属性
static int IVPlaybackDesired(id vp) {
    if (!IVResponds(vp, @"isPlaybackDesired")) return -1;
    @try {
        return ((BOOL (*)(id, SEL))objc_msgSend)(vp, NSSelectorFromString(@"isPlaybackDesired")) ? 1 : 0;
    } @catch (__unused NSException *e) {
        return -1;
    }
}

static BOOL IVSetDesiredPlayState(id vp, long long state) {
    @try {
        if (IVResponds(vp, @"setDesiredPlayState:reason:")) {
            ((void (*)(id, SEL, long long, id))objc_msgSend)(
                vp, NSSelectorFromString(@"setDesiredPlayState:reason:"), state, @"IVGlassPlayer");
            return YES;
        }
        if (IVResponds(vp, @"setDesiredPlayState:")) {
            ((void (*)(id, SEL, long long))objc_msgSend)(
                vp, NSSelectorFromString(@"setDesiredPlayState:"), state);
            return YES;
        }
    } @catch (__unused NSException *e) {
        return NO;
    }
    return NO;
}

/// 设置并自校验：不同 iOS 版本这个枚举的取值不一定一样，
/// 所以写完读一次 `isPlaybackDesired`，对不上就换另一个值再来一次。
static BOOL IVApplyPlayState(id vp, BOOL wantPlay) {
    long long first = wantPlay ? 1 : 0;
    if (!IVSetDesiredPlayState(vp, first)) return NO;

    int got = IVPlaybackDesired(vp);
    if (got >= 0 && ((got == 1) != wantPlay)) {
        long long alt = wantPlay ? 0 : 1;
        IVLog(@"desiredPlayState 映射反了，%lld 不行改 %lld", first, alt);
        IVSetDesiredPlayState(vp, alt);
    }
    return YES;
}

#pragma mark - 视图控制器遍历

static void IVCollectViewControllers(UIViewController *vc, NSMutableArray<UIViewController *> *out, int depth) {
    if (vc == nil || depth > 8 || out.count > 240) return;
    [out addObject:vc];

    for (UIViewController *c in vc.childViewControllers) {
        IVCollectViewControllers(c, out, depth + 1);
    }
    IVCollectViewControllers(vc.presentedViewController, out, depth + 1);
}

static NSArray<UIViewController *> *IVAllViewControllers(UIWindow *win) {
    NSMutableArray<UIViewController *> *out = [NSMutableArray array];

    if (win.rootViewController != nil) {
        IVCollectViewControllers(win.rootViewController, out, 0);
        return out;
    }

    // 扩展进程 / 无主窗口的情况：把所有窗口的根控制器都扫一遍
    for (UIWindow *w in [UIApplication sharedApplication].windows) {
        if (w.rootViewController != nil) {
            IVCollectViewControllers(w.rootViewController, out, 0);
        }
    }
    return out;
}

/// 从某个控制器上摸出相册的播放状态机。
static id IVBrowsingPlayerFrom(UIViewController *vc) {
    if (vc == nil) return nil;

    for (NSString *key in @[ @"browsingViewModel", @"viewModel" ]) {
        id vm = IVGetProp(vc, key);
        if (vm == nil) continue;

        id vp = IVGetProp(vm, @"videoPlayer");
        if (IVLooksLikeBrowsingPlayer(vp)) return vp;
    }

    id vp = IVGetProp(vc, @"videoPlayer");
    if (IVLooksLikeBrowsingPlayer(vp)) return vp;

    return nil;
}

/// 属性名对不上时的兜底：直接扫实例变量，找「长得像播放状态机」的那个对象。
/// 相册不同版本里这个属性叫 `browsingViewModel` / `viewModel` / `_browsingViewModel`…
/// 与其一个个猜，不如把 ivar 翻一遍。
static id IVScanIvarsForPlayer(id obj, int depth) {
    if (obj == nil || depth > 2) return nil;

    unsigned int count = 0;
    Ivar *ivars = class_copyIvarList([obj class], &count);
    if (ivars == NULL) return nil;

    id found = nil;
    for (unsigned int i = 0; i < count && found == nil; i++) {
        const char *type = ivar_getTypeEncoding(ivars[i]);
        if (type == NULL || type[0] != '@') continue;   // 只看对象类型

        id value = nil;
        @try {
            value = object_getIvar(obj, ivars[i]);
        } @catch (__unused NSException *e) {
            continue;
        }
        if (value == nil) continue;

        if (IVLooksLikeBrowsingPlayer(value)) {
            found = value;
            break;
        }

        id nested = IVGetProp(value, @"videoPlayer");
        if (IVLooksLikeBrowsingPlayer(nested)) {
            found = nested;
            break;
        }

        found = IVScanIvarsForPlayer(value, depth + 1);
    }

    free(ivars);
    return found;
}

#pragma mark - 对外

BOOL IVHostSetPlaying(UIWindow *win, BOOL wantPlay, AVPlayer *player) {
    NSArray<UIViewController *> *vcs = IVAllViewControllers(win);

    // 1) 相册：交给 PUBrowsingVideoPlayer，原生那条栏才会跟着刷新
    for (UIViewController *vc in vcs) {
        id vp = IVBrowsingPlayerFrom(vc);
        if (vp == nil) continue;

        if (IVApplyPlayState(vp, wantPlay)) {
            IVLog(@"host bridge: %@ -> %@", NSStringFromClass([vc class]), wantPlay ? @"play" : @"pause");
            return YES;
        }
    }

    // 1b) 属性名对不上：翻 ivar 再找一遍
    for (UIViewController *vc in vcs) {
        id vp = IVScanIvarsForPlayer(vc, 0);
        if (vp == nil) continue;

        if (IVApplyPlayState(vp, wantPlay)) {
            IVLog(@"host bridge(ivar): %@ -> %@", NSStringFromClass([vc class]), wantPlay ? @"play" : @"pause");
            return YES;
        }
    }

    // 2) 文件 / QuickLook：多半是 AVKit 的播放控制器，它自己有 play / pause
    NSString *selName = wantPlay ? @"play" : @"pause";
    for (UIViewController *vc in vcs) {
        NSString *cls = NSStringFromClass([vc class]);
        if ([cls rangeOfString:@"AVPlayerViewController"].location == NSNotFound) continue;
        if (!IVResponds(vc, selName)) continue;

        // 别控错播放器：能读到 player 就必须是同一个
        id vp = IVGetProp(vc, @"player");
        if (vp != nil && vp != (id)player) continue;

        @try {
            ((void (*)(id, SEL))objc_msgSend)(vc, NSSelectorFromString(selName));
            IVLog(@"host bridge: %@ -> %@", cls, selName);
            return YES;
        } @catch (__unused NSException *e) {
            IVLog(@"host bridge: %@ %@ 抛异常", cls, selName);
        }
    }

    IVLog(@"host bridge: 没找到宿主，退回直接操作 player");
    return NO;
}

BOOL IVHostSetMuted(UIWindow *win, BOOL muted) {
    for (UIViewController *vc in IVAllViewControllers(win)) {
        id vp = IVBrowsingPlayerFrom(vc);
        if (vp == nil) continue;
        if (!IVResponds(vp, @"setMuted:")) continue;

        @try {
            ((void (*)(id, SEL, BOOL))objc_msgSend)(vp, NSSelectorFromString(@"setMuted:"), muted);
            return YES;
        } @catch (__unused NSException *e) {
            return NO;
        }
    }
    return NO;
}
