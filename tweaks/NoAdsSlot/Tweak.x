#import <UIKit/UIKit.h>
#import <objc/runtime.h>

// ============================================================
// NoAdsSlot — 水果老虎机 (com.flyfish.Slot) 去广告
// 广告栈: Google AdMob (中介) + Pangle(穿山甲) + SKAdNetwork
//
// 设计要点（对照上一版踩的坑改的）：
//  1. 不再只依赖某一个 present 方法签名——先在 presentViewController: 层按
//     **类名前缀**兜底拦截，签名怎么变都能拦住；显式 %hook 只是加速与日志。
//  2. 激励视频发奖改为**可关闭的开关**（默认开）。走服务端校验的游戏会把
//     "白拿奖励"判为作弊，所以留了关闭手段，且每次发奖都打日志便于定位。
//  3. banner 不再只是吞掉 loadRequest（会留白块），同时把视图隐藏。
//  4. 任何一步失败都不影响游戏本体：拦截失败最坏就是照常显示广告。
//
// 开关（root 或 mobile 都能建）：
//   mkdir -p /var/mobile/Documents/wiki.qaq.xosvi/Workspace/noads
//   touch /var/mobile/Documents/wiki.qaq.xosvi/Workspace/noads/no_reward    → 只拦不奖
//   touch /var/mobile/Documents/wiki.qaq.xosvi/Workspace/noads/no_block     → 完全停用拦截（调试）
// v9.12：开关目录跟着 App 数据根走（/var/mobile/Library/NoAdsSlot 是上游共用位置，
//   二改版与上游并存时会被两边互相影响）；旧路径仍然认，免得用户已建的开关失效。
// ============================================================

static NSString *const kNoadsDir = @"/var/mobile/Documents/wiki.qaq.xosvi/Workspace/noads";
static NSString *const kNoadsLegacyDir = @"/var/mobile/Library/NoAdsSlot";

static void noads_log(NSString *fmt, ...) {
    va_list ap;
    va_start(ap, fmt);
    NSString *msg = [[NSString alloc] initWithFormat:fmt arguments:ap];
    va_end(ap);
    NSLog(@"[NoAdsSlot] %@", msg);
}

/// 开关文件：存在 = true。首次检查后缓存，避免每次 present 都 stat
static BOOL noadsFlag(NSString *name, BOOL defaultValue) {
    static NSMutableDictionary<NSString *, NSNumber *> *cache = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ cache = [NSMutableDictionary dictionary]; });
    @synchronized (cache) {
        NSNumber *hit = cache[name];
        if (hit) return hit.boolValue;
        BOOL v = [[NSFileManager defaultManager] fileExistsAtPath:
                  [kNoadsDir stringByAppendingPathComponent:name]]
              || [[NSFileManager defaultManager] fileExistsAtPath:
                  [kNoadsLegacyDir stringByAppendingPathComponent:name]];
        cache[name] = @(v);
        return v;
    }
}

/// 广告 SDK 的类名前缀。只列各 SDK 真正的前缀——
/// 绝不能写 "AL"/"IS"/"BU" 这种短前缀：AL 会命中 Alert…、IS/BU 会误伤大批系统类。
static BOOL noadsIsAdClass(NSString *cls) {
    if (cls.length == 0) return NO;
    static NSArray<NSString *> *prefixes = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        prefixes = @[@"GAD", @"CSJ", @"BUAd", @"BUFullscreen", @"BUInterstitial", @"BUNative",
                     @"PAG", @"MBridge", @"MTG", @"Mintegral",
                     @"ALAd", @"ALInterstitial", @"ALRewarded",
                     @"ISInterstitial", @"ISRewarded", @"ISBanner",
                     @"UnityAds", @"Vungle", @"AppLovin"];
    });
    for (NSString *p in prefixes) {
        if ([cls hasPrefix:p]) return YES;
    }
    return NO;
}

// ---------- 0. 通用兜底：广告 SDK 的视图控制器一律不 present ----------
%hook UIViewController
- (void)presentViewController:(UIViewController *)vc animated:(BOOL)animated completion:(void (^)(void))completion {
    if (noadsFlag(@"no_block", NO) == NO && noadsIsAdClass(NSStringFromClass([vc class]))) {
        noads_log(@"blocked present %@", NSStringFromClass([vc class]));
        // 仍回调 completion，否则调用方可能卡在"正在展示"状态
        if (completion) dispatch_async(dispatch_get_main_queue(), ^{ completion(); });
        return;
    }
    %orig;
}
%end

// ---------- 1. 插屏 ----------
%hook GADInterstitialAd
- (void)presentFromRootViewController:(UIViewController *)vc {
    noads_log(@"blocked GADInterstitialAd present");
}
%end

// ---------- 2. 激励视频：不展示，按开关决定是否立即发奖 ----------
%hook GADRewardedAd
- (void)presentFromRootViewController:(UIViewController *)vc
             userDidEarnRewardHandler:(void (^)(void))handler {
    if (noadsFlag(@"no_reward", NO)) {
        noads_log(@"blocked GADRewardedAd present (reward suppressed)");
        return;
    }
    noads_log(@"blocked GADRewardedAd present, fire reward handler");
    if (handler) {
        dispatch_async(dispatch_get_main_queue(), ^{ handler(); });
    }
}
%end

// ---------- 3. 开屏 ----------
%hook GADAppOpenAd
- (void)presentFromRootViewController:(UIViewController *)vc {
    noads_log(@"blocked GADAppOpenAd present");
}
%end

// ---------- 4. Banner：不加载 + 不占位 ----------
%hook GADBannerView
- (void)loadRequest:(id)request {
    noads_log(@"blocked GADBannerView loadRequest");
    // 只隐藏不缩放：改 frame 会打乱游戏自己算好的 banner 占位布局。
    // 注意：GADBannerView 这里只是前置声明（没引 SDK 头），不能直接点属性，
    // 必须先转成 UIView* —— 否则报 "property 'hidden' cannot be found in forward class"。
    UIView *banner = (UIView *)self;
    dispatch_async(dispatch_get_main_queue(), ^{
        banner.hidden = YES;
        banner.alpha = 0;
    });
}
- (void)loadWithAdResponseString:(NSString *)s {
    noads_log(@"blocked GADBannerView loadWithAdResponseString");
}
%end

%ctor {
    noads_log(@"NoAdsSlot loaded (AdMob/Pangle interceptor v2)");
}
