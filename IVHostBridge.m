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

/// 读当前的 desiredPlayState（纯诊断用）
static long long IVCurrentDesiredPlayState(id vp) {
    if (!IVResponds(vp, @"desiredPlayState")) return -1;
    @try {
        return ((long long (*)(id, SEL))objc_msgSend)(vp, NSSelectorFromString(@"desiredPlayState"));
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

#pragma mark - 原生播放/暂停按钮（图标纠偏）

static NSString *IVAccessibilityText(UIView *v) {
    NSString *s = v.accessibilityLabel;
    if (s.length == 0) s = v.accessibilityValue;
    if (s.length > 0) return s;

    for (UIView *sub in v.subviews) {
        NSString *t = sub.accessibilityLabel;
        if (t.length > 0) return t;
    }
    return nil;
}

/// 1 = 它认为自己正在播（所以按钮写的是「暂停」）
/// 0 = 它认为自己已暂停（按钮写的是「播放」）
/// -1 = 判断不了
static int IVControlThinksPlaying(UIControl *c) {
    NSString *text = IVAccessibilityText(c);
    if (text.length == 0) return -1;

    NSString *t = text.lowercaseString;
    if ([t containsString:@"replay"] || [t containsString:@"airplay"] || [t containsString:@"display"]) {
        return -1;
    }
    if ([t containsString:@"暂停"] || [t containsString:@"暫停"] || [t containsString:@"pause"]) return 1;
    if ([t containsString:@"播放"] || [t containsString:@"play"] || [t containsString:@"继续"]) return 0;
    return -1;
}

static UIControl *IVFindPlayPauseControl(UIView *root, UIView *skip, int depth, int *budget) {
    if (root == nil || depth > 30 || budget == NULL || *budget <= 0) return nil;
    (*budget)--;
    if (root == skip) return nil;                 // 我们自己的 overlay 绝不算
    if (root.hidden || root.alpha < 0.05) return nil;

    if ([root isKindOfClass:[UIControl class]]) {
        NSString *cls = NSStringFromClass([root class]);
        NSString *low = cls.lowercaseString;
        BOOL nameHit = [low containsString:@"playpause"] ||
                       [low containsString:@"playbutton"] ||
                       ([low containsString:@"play"] && ![low containsString:@"replay"]);
        if (nameHit && root.window != nil &&
            root.bounds.size.width > 1.0 && root.bounds.size.height > 1.0) {
            UIControl *c = (UIControl *)root;
            if (c.allTargets.count > 0) return c;
        }
    }

    for (UIView *s in root.subviews) {
        UIControl *r = IVFindPlayPauseControl(s, skip, depth + 1, budget);
        if (r != nil) return r;
    }
    return nil;
}

/// 当前最该用的那个窗口。
/// 不用 `keyWindow` —— 它在 iOS 13 就被标记废弃，多 scene 下还只返回全局随便一个，
/// 编译期又会因为 `-Werror,-Wdeprecated-declarations` 直接失败。
/// 这里遍历窗口，优先 key window，退而求其次取第一个可见且有根控制器的。
static UIWindow *IVActiveWindow(void) {
    UIApplication *app = [UIApplication sharedApplication];
    if (app == nil) return nil;                 // 扩展进程里没有 UIApplication

    UIWindow *fallback = nil;
    for (UIWindow *w in app.windows) {
        if (w.hidden) continue;
        if (w.isKeyWindow) return w;
        if (fallback == nil && w.rootViewController != nil) fallback = w;
    }
    return fallback;
}

BOOL IVHostSyncPlayPauseIcon(UIWindow *win, BOOL wantPlay, UIView *skip) {
    UIWindow *target = win;
    if (target == nil) {
        target = skip.window;                   // 我们自己所在的窗口一定是对的
    }
    if (target == nil) {
        target = IVActiveWindow();
    }
    if (target == nil) return NO;

    int budget = 4000;
    UIControl *c = IVFindPlayPauseControl(target, skip, 0, &budget);
    if (c == nil) {
        IVLog(@"icon sync: 没找到原生播放/暂停按钮");
        return NO;
    }

    int thinks = IVControlThinksPlaying(c);
    IVLog(@"icon sync: %@ label=%@ thinks=%d want=%d",
          NSStringFromClass([c class]), IVAccessibilityText(c), thinks, wantPlay);

    if (thinks < 0) return NO;                      // 判断不了就别乱点
    if ((thinks == 1) == wantPlay) return YES;      // 图标已经是对的

    // 真实播放状态此时已经是 wantPlay，它那一下只会把图标纠正过来
    [c sendActionsForControlEvents:UIControlEventTouchUpInside];
    IVLog(@"icon sync: 已点击 %@ 纠正图标", NSStringFromClass([c class]));
    return YES;
}

#pragma mark - 对外

BOOL IVHostSetPlaying(UIWindow *win, BOOL wantPlay, AVPlayer *player) {
    @try {
        NSArray<UIViewController *> *vcs = IVAllViewControllers(win);

        // 排查用：把控制器链打出来，日志里能直接看到是哪个 App / 哪个版本的结构
        NSMutableString *chain = [NSMutableString string];
        for (UIViewController *vc in vcs) {
            if (chain.length > 400) { [chain appendString:@"…"]; break; }
            [chain appendFormat:@"%@ ", NSStringFromClass([vc class])];
        }
        IVLog(@"host bridge: 扫到 %lu 个控制器: %@", (unsigned long)vcs.count, chain);

        // 1) 相册：交给 PUBrowsingVideoPlayer，原生那条栏才会跟着刷新
        for (UIViewController *vc in vcs) {
            id vp = IVBrowsingPlayerFrom(vc);
            if (vp == nil) continue;

            IVLog(@"host bridge: 找到 %@ (在 %@ 上)，当前 desiredPlayState=%lld",
                  NSStringFromClass([vp class]), NSStringFromClass([vc class]),
                  IVCurrentDesiredPlayState(vp));

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
