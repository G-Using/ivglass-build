//
//  IVHostBridge.m
//  IVGlassPlayer
//

#import "IVHostBridge.h"
#import "IVGlassKit.h"
#import <objc/message.h>
#import <objc/runtime.h>

#pragma mark - 小工具

/// 取属性。三道保险，任何一道不过就返回 nil：
///   1. 对象得真的响应这个 selector（否则退回 KVC）
///   2. 方法签名的返回值必须是对象类型 `@`
///      —— 拿 id 的 ABI 去调一个返回结构体 / 标量的方法，
///         ARC 会把返回值头几个字节当成对象指针去 retain，直接 SIGBUS
///   3. 取到的指针得指向一个真实存在的对象
static id IVGetProp(id obj, NSString *key) {
    if (obj == nil || key.length == 0) return nil;

    SEL sel = NSSelectorFromString(key);
    if ([obj respondsToSelector:sel]) {
        @try {
            NSMethodSignature *sig = [obj methodSignatureForSelector:sel];
            const char *ret = sig != NULL ? sig.methodReturnType : NULL;
            if (ret != NULL && ret[0] == '@') {
                id value = ((id (*)(id, SEL))objc_msgSend)(obj, sel);
                return (value != nil && object_getClass(value) != Nil) ? value : nil;
            }
        } @catch (__unused NSException *e) {
            // 掉下去走 KVC
        }
    }

    // KVC 这条路安全：标量会自动装箱成 NSNumber，不会被误当对象指针
    @try {
        id value = [obj valueForKey:key];
        return (value != nil && object_getClass(value) != Nil) ? value : nil;
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

/// 读 `isPlaybackDesired`：1 = 想播, 0 = 想停, -1 = 没有该属性
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
    UIApplication *app = [UIApplication sharedApplication];
    if (app == nil) return out;
    for (UIWindow *w in app.windows) {
        if (w.rootViewController != nil) {
            IVCollectViewControllers(w.rootViewController, out, 0);
        }
    }
    return out;
}

/// 从某个控制器上摸出相册的播放状态机。
///
/// 只按属性名找，**不翻实例变量**。
/// 0.7.0 翻过：拿到一个 `@` 类型的 ivar 就递归进去继续找，结果撞上
/// NSNumber 这类 tagged pointer —— 它没有真实内存，`object_getIvar`
/// 从指针位里读出垃圾，ARC 一 retain 就 SIGBUS（MobileSlideShow 闪退）。
/// 相册这几个版本 `browsingViewModel` / `viewModel` 至少有一个在，
/// 犯不上为多兼容一点去冒崩进程的险。
static id IVBrowsingPlayerFrom(UIViewController *vc) {
    if (vc == nil) return nil;

    static NSArray<NSString *> *vmKeys = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        vmKeys = @[ @"browsingViewModel", @"viewModel", @"oneUpViewModel" ];
    });

    for (NSString *key in vmKeys) {
        id vm = IVGetProp(vc, key);
        if (vm == nil) continue;

        id vp = IVGetProp(vm, @"videoPlayer");
        if (IVLooksLikeBrowsingPlayer(vp)) return vp;
    }

    id vp = IVGetProp(vc, @"videoPlayer");
    if (IVLooksLikeBrowsingPlayer(vp)) return vp;

    return nil;
}

#pragma mark - 对外

BOOL IVHostSetPlaying(UIWindow *win, BOOL wantPlay, AVPlayer *player) {
    @try {
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

        // 2) 文件 / QuickLook：多半是 AVKit 的播放控制器，它自己有 play / pause
        NSString *selName = wantPlay ? @"play" : @"pause";
        for (UIViewController *vc in vcs) {
            NSString *cls = NSStringFromClass([vc class]);
            if ([cls rangeOfString:@"AVPlayerViewController"].location == NSNotFound) continue;
            if (!IVResponds(vc, selName)) continue;

            // 别控错播放器：能读到 player 就必须是同一个
            id vp = IVGetProp(vc, @"player");
            if (vp != nil && vp != (id)player) continue;

            ((void (*)(id, SEL))objc_msgSend)(vc, NSSelectorFromString(selName));
            IVLog(@"host bridge: %@ -> %@", cls, selName);
            return YES;
        }
    } @catch (__unused NSException *e) {
        IVLog(@"host bridge 异常：%@", e.reason);
        return NO;
    }

    IVLog(@"host bridge: 没找到宿主，退回直接操作 player");
    return NO;
}

BOOL IVHostSetMuted(UIWindow *win, BOOL muted) {
    @try {
        for (UIViewController *vc in IVAllViewControllers(win)) {
            id vp = IVBrowsingPlayerFrom(vc);
            if (vp == nil) continue;
            if (!IVResponds(vp, @"setMuted:")) continue;

            ((void (*)(id, SEL, BOOL))objc_msgSend)(vp, NSSelectorFromString(@"setMuted:"), muted);
            return YES;
        }
    } @catch (__unused NSException *e) {
        IVLog(@"host bridge(静音) 异常：%@", e.reason);
    }
    return NO;
}
