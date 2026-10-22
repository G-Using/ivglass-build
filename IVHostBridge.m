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
    if (IVResponds(o, @"desiredPlayState") || IVResponds(o, @"setDesiredPlayState:reason:")) {
        return IVResponds(o, @"setDesiredPlayState:reason:") ||
               IVResponds(o, @"setDesiredPlayState:");
    }
    return NO;
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

/// 在宿主的 changes 块里改状态。
///
/// `PUViewModel` 的 setter **只能在 `performChanges:` 的块里调用**。
/// 在外面直接 `setDesiredPlayState:` 会命中 `-[PUViewModel assertInsideChangesBlock]`，
/// 抛 NSException —— 真机上直接 abort，整个相册闪退（崩溃栈就是这个）。
/// 所以哪怕枚举值猜对了，不走这个块也一定失败：异常被 @try 吞掉，
/// 状态没变、图标不动，表现就是「点了没反应」。
static BOOL IVPerformChanges(id vp, void (^changes)(void)) {
    if (changes == nil || !IVResponds(vp, @"performChanges:")) return NO;
    @try {
        ((void (*)(id, SEL, id))objc_msgSend)(vp, NSSelectorFromString(@"performChanges:"), changes);
        return YES;
    } @catch (__unused NSException *e) {
        IVLog(@"performChanges: 抛异常 %@", e.reason);
        return NO;
    }
}

/// 让状态机切到 wantPlay。
///
/// 只能在 `performChanges:` 里改（见上）。枚举取值各版本不一定一样，
/// 所以每写一次就用 `isPlaybackDesired` 校验一次，对不上就换下一个候选。
///
/// 候选顺序按实测：iOS 16.5 上 `desiredPlayState` 暂停是 0、播放是 1
/// （暂停时读到的就是 `desired=0 playState=2`），2 才是那个不确定的兜底值。
///
/// **故意不把「1=播放」放进暂停的候选里**：宁可判失败让上层去点按钮，
/// 也不能因为试探而把视频重新放起来。
static BOOL IVApplyPlayState(id vp, BOOL wantPlay) {
    if (!IVResponds(vp, @"performChanges:")) {
        IVLog(@"%@ 没有 performChanges:，不能直接改它的状态",
              NSStringFromClass([vp class]));
        return NO;
    }

    long long cands[2];
    int n = 0;
    if (wantPlay) {
        cands[n++] = 1;
        cands[n++] = 2;
    } else {
        cands[n++] = 0;
        cands[n++] = 2;
    }

    for (int i = 0; i < n; i++) {
        long long v = cands[i];

        BOOL ok = IVPerformChanges(vp, ^{
            IVSetDesiredPlayState(vp, v);
        });
        if (!ok) continue;

        int got = IVPlaybackDesired(vp);
        if (got < 0) {
            IVLog(@"isPlaybackDesired 读不到，判失败");
            return NO;
        }
        if ((got == 1) == wantPlay) {
            if (i > 0) IVLog(@"desiredPlayState 得用 %lld 才生效", v);
            return YES;
        }
        IVLog(@"desiredPlayState=%lld 没生效（isPlaybackDesired=%d），换下一个", v, got);
    }
    return NO;
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
    static NSArray<NSString *> *playerKeys = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        vmKeys = @[ @"browsingViewModel", @"viewModel", @"oneUpViewModel",
                    @"photoBrowserViewModel", @"videoViewModel", @"assetViewModel" ];
        playerKeys = @[ @"videoPlayer", @"videoPlayerModel", @"player", @"videoController" ];
    });

    for (NSString *key in vmKeys) {
        id vm = IVGetProp(vc, key);
        if (vm == nil) continue;

        for (NSString *pk in playerKeys) {
            id vp = IVGetProp(vm, pk);
            if (IVLooksLikeBrowsingPlayer(vp)) return vp;
        }
        // 有些版本 viewModel 自己就是状态机
        if (IVLooksLikeBrowsingPlayer(vm)) return vm;
    }

    for (NSString *pk in playerKeys) {
        id vp = IVGetProp(vc, pk);
        if (IVLooksLikeBrowsingPlayer(vp)) return vp;
    }

    return nil;
}

#pragma mark - 原生播放/暂停按钮

/// 取无障碍文本（按钮的图标状态就写在这里）。
/// 相册的按钮经常是「容器 UIControl + 里面一个图标 view」，
/// 所以往里挖三层。
static NSString *IVAccessibilityText(UIView *v, int depth) {
    if (v == nil || depth > 3) return nil;

    NSString *s = v.accessibilityLabel;
    if (s.length > 0) return s;
    s = v.accessibilityValue;
    if (s.length > 0) return s;

    for (UIView *sub in v.subviews) {
        NSString *t = IVAccessibilityText(sub, depth + 1);
        if (t.length > 0) return t;
    }
    return nil;
}

/// 1 = 它认为自己正在播（所以按钮的文字是「暂停」）
/// 0 = 它认为自己已暂停（按钮写的是「播放」）
/// -1 = 判断不了 / 不是播放暂停按钮
static int IVThinksPlayingFromText(NSString *text) {
    if (text.length == 0) return -1;

    NSString *t = text.lowercaseString;

    // 这些控件身上也常带「播放」二字，但点下去不是播/暂停：
    // 进度条、音量、全屏、编辑、分享……一律排掉，宁可不动。
    static NSArray<NSString *> *banned = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        banned = @[ @"replay", @"airplay", @"display",
                    @"进度", @"進度", @"progress", @"seek",
                    @"时间", @"時間", @"时长", @"時長", @"duration", @"timecode",
                    @"音量", @"volume", @"静音", @"mute",
                    @"全屏", @"畫中畫", @"画中画", @"fullscreen", @"full screen", @"pip",
                    @"编辑", @"編輯", @"edit", @"分享", @"share",
                    @"返回", @"back", @"关闭", @"關閉", @"close", @"完成", @"done",
                    @"删除", @"刪除", @"delete", @"收藏", @"favorite", @"更多", @"more",
                    @"信息", @"資訊", @"info", @"位置", @"location", @"实况", @"原況", @"live" ];
    });
    for (NSString *b in banned) {
        if ([t containsString:b]) return -1;
    }

    // 先判「暂停」：「暂停」里没有「播放」，但先判更稳，也不受语言包差异影响
    if ([t containsString:@"暂停"] || [t containsString:@"暫停"] || [t containsString:@"pause"]) return 1;
    if ([t containsString:@"播放"] || [t containsString:@"play"] ||
        [t containsString:@"继续"] || [t containsString:@"繼續"]) return 0;
    return -1;
}

/// 文本是不是干脆就是「播放」/「暂停」这种，越纯越可信
static BOOL IVTextIsExactlyPlayPause(NSString *text) {
    static NSSet<NSString *> *exact = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        exact = [NSSet setWithArray:@[ @"播放", @"暂停", @"暫停", @"继续", @"繼續",
                                       @"play", @"pause", @"resume" ]];
    });
    NSString *t = [text.lowercaseString stringByTrimmingCharactersInSet:
                   [NSCharacterSet whitespaceAndNewlineCharacterSet]];
    return [exact containsObject:t];
}

static void IVCollectControls(UIView *root, UIView *skip, int depth,
                              int *budget, NSMutableArray<UIControl *> *out) {
    if (root == nil || depth > 40 || budget == NULL || *budget <= 0 || out.count >= 96) return;
    (*budget)--;
    if (root == skip) return;                 // 我们自己的 overlay 绝不算

    if ([root isKindOfClass:[UIControl class]]) {
        [out addObject:(UIControl *)root];
    }
    for (UIView *s in root.subviews) {
        IVCollectControls(s, skip, depth + 1, budget, out);
    }
}

/// 要搜的窗口：调用方给的、我们自己所在的，再加上 App 的所有窗口。
/// 相册有时把我们挂在自己的窗口上，只搜 `win` 是搜不到原生那套 chrome 的。
static NSArray<UIWindow *> *IVSearchWindows(UIWindow *win, UIView *skip) {
    NSMutableArray<UIWindow *> *out = [NSMutableArray arrayWithCapacity:4];

    if (win != nil) [out addObject:win];
    UIWindow *own = skip.window;
    if (own != nil && ![out containsObject:own]) [out addObject:own];

    for (UIWindow *w in [UIApplication sharedApplication].windows) {
        if (w != nil && ![out containsObject:w]) [out addObject:w];
    }
    return out;
}

/// 找宿主那个播放/暂停按钮。
///
/// 不再要求类名里带 `play`（相册的按钮类名不一定带），也不要求
/// `allTargets` 非空（`addAction:forControlEvents:` 绑的按钮 `allTargets` 是空的，
/// 但 `sendActionsForControlEvents:` 照样能触发）。判断依据只剩
/// **无障碍文本是「播放」还是「暂停」**——这个骗不了人。
static UIControl *IVFindPlayPauseControl(UIWindow *win, UIView *skip, BOOL wantPlay, int *thinksOut) {
    NSMutableArray<UIControl *> *all = [NSMutableArray array];
    int budget = 6000;
    for (UIWindow *w in IVSearchWindows(win, skip)) {
        if (budget <= 0 || all.count >= 96) break;
        IVCollectControls(w, skip, 0, &budget, all);
    }

    UIControl *best = nil;
    int bestScore = -1;
    int bestThinks = -1;
    NSMutableString *report = [NSMutableString string];

    for (UIControl *c in all) {
        NSString *text = IVAccessibilityText(c, 0);
        int thinks = IVThinksPlayingFromText(text);
        BOOL visible = (c.window != nil && !c.hidden && c.alpha > 0.05);

        if (report.length < 900) {
            [report appendFormat:@"\n      · %@  label=%@  thinks=%d  %@",
                                   NSStringFromClass([c class]), text ?: @"—", thinks,
                                   visible ? @"可见" : @"隐藏"];
        }

        if (thinks < 0) continue;
        if (c.bounds.size.width < 8.0 || c.bounds.size.height < 8.0) continue;

        NSString *low = NSStringFromClass([c class]).lowercaseString;
        int score = 0;
        if ((thinks == 1) != wantPlay) score += 8;          // 状态不一致的优先纠它
        if (visible) score += 4;                            // 看得见的优先（隐藏的也能点，只是次选）
        if (IVTextIsExactlyPlayPause(text)) score += 6;      // 「播放」/「暂停」这种最纯
        if ([low containsString:@"play"]) score += 2;

        if (score > bestScore) {
            bestScore = score;
            best = c;
            bestThinks = thinks;
        }
    }

    if (thinksOut != NULL) *thinksOut = bestThinks;

    if (best == nil) {
        static int dumps = 0;
        if (dumps < 3) {                 // 日志别刷屏
            dumps++;
            IVLog(@"icon sync: 没找到播放/暂停按钮，扫了 %lu 个控件：%@",
                  (unsigned long)all.count, report.length > 0 ? report : @"(空)");
        }
    }
    return best;
}

#pragma mark - 对外

IVHostAction IVHostSetPlaying(UIWindow *win, BOOL wantPlay, AVPlayer *player, UIView *skip) {
    @try {
        NSArray<UIViewController *> *vcs = IVAllViewControllers(win);

        // ── 1. 相册：PUBrowsingVideoPlayer 的状态机 ────────────────────
        //    相册底部那个播放/暂停是 **UIBarButtonItem**（由
        //    PUPlayPauseBarItemsController 管），根本不是 UIView ——
        //    在视图树里按类名/无障碍标签找，永远找不到。
        //    所以相册只能走状态机，而且必须包在 performChanges: 里。
        id hit = nil;
        UIViewController *hitVC = nil;

        for (UIViewController *vc in vcs) {
            id vp = IVBrowsingPlayerFrom(vc);
            if (vp == nil) continue;

            if (hit == nil) { hit = vp; hitVC = vc; }

            // 能读到 avPlayer 的才是「当前这个」，优先挑和我们手上 player 同一个的
            id ap = IVGetProp(vp, @"avPlayer");
            if (ap != nil) {
                if (player != nil && ap == (id)player) { hit = vp; hitVC = vc; break; }
                hit = vp;
                hitVC = vc;
            }
        }

        if (hit != nil) {
            IVLog(@"host bridge: 状态机 %@（在 %@ 上）当前 desiredPlayState=%lld",
                  NSStringFromClass([hit class]), NSStringFromClass([hitVC class]),
                  IVCurrentDesiredPlayState(hit));

            if (IVApplyPlayState(hit, wantPlay)) {
                IVLog(@"host bridge: 状态机 -> %@", wantPlay ? @"play" : @"pause");
                return IVHostActionStateMachine;
            }
            IVLog(@"host bridge: 状态机没生效，继续找按钮");
        }

        // ── 2. 视图树里的播放/暂停按钮（文件 / AVKit）─────────────────
        //    和用户手指点下去一样的路径，状态和图标必然一起变。
        int thinks = -1;
        UIControl *btn = IVFindPlayPauseControl(win, skip, wantPlay, &thinks);
        if (btn != nil) {
            IVLog(@"host bridge: 找到原生按钮 %@ label=%@ thinks=%d want=%d",
                  NSStringFromClass([btn class]), IVAccessibilityText(btn, 0), thinks, wantPlay);

            if ((thinks == 1) != wantPlay) {
                [btn sendActionsForControlEvents:UIControlEventTouchUpInside];
                IVLog(@"host bridge: 已点击原生按钮 -> %@", wantPlay ? @"play" : @"pause");
                return IVHostActionButton;
            }
            IVLog(@"host bridge: 原生图标已经一致，不用点");
            return IVHostActionNone;
        }

        // ── 3. AVKit 的播放控制器 ──────────────────────────────────────
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
            return IVHostActionAVKit;
        }
    } @catch (__unused NSException *e) {
        IVLog(@"host bridge 异常：%@", e.reason);
        return IVHostActionNone;
    }

    IVLog(@"host bridge: 没找到宿主，退回直接操作 player");
    return IVHostActionNone;
}

BOOL IVHostSetMuted(UIWindow *win, BOOL muted) {
    @try {
        for (UIViewController *vc in IVAllViewControllers(win)) {
            id vp = IVBrowsingPlayerFrom(vc);
            if (vp == nil) continue;
            if (!IVResponds(vp, @"setMuted:")) continue;

            // 同样必须在 performChanges: 里改，否则命中 PUViewModel 的断言
            BOOL ok = IVPerformChanges(vp, ^{
                ((void (*)(id, SEL, BOOL))objc_msgSend)(vp, NSSelectorFromString(@"setMuted:"), muted);
            });
            if (ok) return YES;
        }
    } @catch (__unused NSException *e) {
        IVLog(@"host bridge(静音) 异常：%@", e.reason);
    }
    return NO;
}
