// AdlabKit.m —— 通用广告加速器（不针对任何具体 app）
//
// 设计原则
// ========
// 这个 dylib 注入任何 iOS app 都成立，因为它只 hook **系统 API**，
// 不碰任何一行业务代码、不依赖任何具体 SDK 的类名或方法名。
//
// 为什么能加速广告
// ----------------
// 所有激励视频的「要看满 N 秒」都是靠时间测量得出的，测量方式只有三种：
//   ① 定时器递减：NSTimer 每 1 秒 remaining--          → 层次二
//   ② 时间差计算：elapsed = now - startTime            → 层次一
//   ③ 播放器进度：AVPlayer currentTime / KVO            → 层次三
// 把这三个时间源一起加速，三种实现都会被压缩，且不改变「广告确实播过」的事实
// —— 曝光、点击、回调全都是真的，只是时间轴被压缩了。
//
// 层次
// ====
//   一 时间源：CFAbsoluteTimeGetCurrent / NSDate / gettimeofday / mach_absolute_time
//   二 定时器：NSTimer 工厂 / performSelector:afterDelay: / CADisplayLink
//   三 播放器：AVPlayer setRate: / AVPlayerItem 相关
//   四 运行时发现：枚举所有已加载类，名字像广告播放器且实现了常见进度方法的，
//                  按方法名而非类名挂载 —— 这样 SDK 换版本、换名字都不影响。
//   五 摇一摇拦截：UIWindow sendEvent: 吞掉 MotionShake
//   六 反检测：IOSSecuritySuite 等按类名片段清理
//   七 悬浮球：hitTest 穿透，不挡游戏操作
//
// 安全约束（每一条都是踩过的坑）
// ============================
//   · 不用 __interpose（v1 用 interpose 拦 _dyld_get_image_name，绑定期返回 NULL 必崩）
//   · 不用 dlopen/dlsym 拿原实现（会走 interpose 重定向 → 自己拿自己 → 递归爆栈）
//   · 所有 hook 体 @try/@catch 兜底，异常回落原实现
//   · 时间源必须单调，切换倍速时重新定基准，不能回退
//   · 倍速 <= 1.0 时全部直通，零开销零风险
//   · 任何一层失败都不影响其他层（类不存在就是 NULL，直通）

#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <mach-o/dyld.h>
#import <mach/mach_time.h>
#import <sys/time.h>
#import <time.h>
#import <stdio.h>
#import <stdlib.h>
#import <stdarg.h>
#import <string.h>
#import <unistd.h>

#pragma mark - 配置

#define kDomainPrefix @"com.adlab.cfg."

static double gSpeed      = 1.0;   // 1.0 = 原速
static BOOL   gBlockShake = YES;

// 统计
static int g_hitTime = 0, g_hitTimer = 0, g_hitPlayer = 0, g_hitDiscovered = 0;
static int g_hitShake = 0, g_hitStealth = 0;
static int g_classesScanned = 0, g_classesMatched = 0;
static int gSceneRetry = 0;      // UI 安装时「场景未就绪」的重试计数

static NSMutableArray<NSString *> *gLogLines = nil;
static NSLock *gLogLock = nil;
static FILE *gLogFile = NULL;

#pragma mark - 日志

static void klog(const char *fmt, ...)
{
    char buf[512];
    va_list ap;
    va_start(ap, fmt);
    vsnprintf(buf, sizeof(buf), fmt, ap);
    va_end(ap);

    fprintf(stderr, "[adlab] %s\n", buf);
    if (!gLogLock) return;
    [gLogLock lock];
    if (gLogFile) {
        time_t t = time(NULL);
        struct tm tmv;
        localtime_r(&t, &tmv);
        fprintf(gLogFile, "%02d:%02d:%02d %s\n", tmv.tm_hour, tmv.tm_min, tmv.tm_sec, buf);
        fflush(gLogFile);
    }
    if (gLogLines && gLogLines.count < 400)
        [gLogLines addObject:[NSString stringWithUTF8String:buf]];
    [gLogLock unlock];
}

#define KLOG(...) do { klog(__VA_ARGS__); } while (0)

static void klog_init(void)
{
    static BOOL done = NO;
    if (done) return;
    done = YES;
    gLogLock = [NSLock new];
    gLogLines = [NSMutableArray array];
    @try {
        NSString *p = [NSTemporaryDirectory() stringByAppendingPathComponent:@"adlab.log"];
        gLogFile = fopen(p.UTF8String, "a");
    } @catch (__unused NSException *e) { }
}

#pragma mark - 按 app 分域配置

static NSString *cfg_domain(void)
{
    static NSString *s = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSString *bid = [[NSBundle mainBundle] bundleIdentifier];
        if (bid.length == 0) bid = @"unknown";
        s = [kDomainPrefix stringByAppendingString:bid];
    });
    return s;
}

static void cfg_load(void)
{
    @try {
        NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
        NSString *k = cfg_domain();
        id v = [d objectForKey:[k stringByAppendingString:@".speed"]];
        if ([v isKindOfClass:[NSNumber class]]) {
            double s = [v doubleValue];
            if (s >= 1.0 && s <= 5.0) gSpeed = s;
        }
        id b = [d objectForKey:[k stringByAppendingString:@".shake"]];
        if ([b isKindOfClass:[NSNumber class]]) gBlockShake = [b boolValue];
    } @catch (__unused NSException *e) { }
}

static void cfg_save(void)
{
    @try {
        NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
        NSString *k = cfg_domain();
        [d setObject:@(gSpeed) forKey:[k stringByAppendingString:@".speed"]];
        [d setObject:@(gBlockShake) forKey:[k stringByAppendingString:@".shake"]];
        [d synchronize];
    } @catch (__unused NSException *e) { }
}

#pragma mark - swizzle（直接返回原 IMP，不做 out-param 指针双关）

static IMP kswizzle(Class cls, SEL sel, IMP replacement, BOOL isClassMethod)
{
    if (!cls || !sel || !replacement) return NULL;
    Method m = isClassMethod ? class_getClassMethod(cls, sel) : class_getInstanceMethod(cls, sel);
    if (!m) return NULL;
    IMP orig = method_getImplementation(m);
    if (orig == replacement) return orig;      // 已装过，幂等
    method_setImplementation(m, replacement);
    return orig;
}

#pragma mark - 层次一：时间源加速
//
// 核心：虚拟时间 = 基准 + (真实时间 - 基准) × 倍速
// 切换倍速时把当前虚拟时间定为新基准，保证单调不回退。

static double g_tReal0 = 0.0;    // 基准时刻（真实）
static double g_tVirt0 = 0.0;    // 基准时刻（虚拟）
static double g_curSpd = 1.0;    // 当前生效倍速

static double now_real_abs(void)
{
    struct timeval tv;
    gettimeofday(&tv, NULL);
    return (double)tv.tv_sec + (double)tv.tv_usec / 1e6;
}

static double vtime(double real)
{
    if (g_curSpd <= 1.0001) return real;
    if (g_tReal0 == 0.0) return real;
    return g_tVirt0 + (real - g_tReal0) * g_curSpd;
}

// 倍速变更或首次调用时重新定基准，避免时间跳变
static void rebase_if_needed(void)
{
    double s = (gSpeed > 1.0001) ? gSpeed : 1.0;
    if (s == g_curSpd && g_tReal0 != 0.0) return;
    double real = now_real_abs();
    if (g_tReal0 == 0.0) {
        g_tReal0 = real;
        g_tVirt0 = real;
        g_curSpd = s;
        return;
    }
    // 用旧倍速算出此刻的虚拟时间，作为新基准
    double vNow = g_tVirt0 + (real - g_tReal0) * g_curSpd;
    g_tVirt0 = vNow;
    g_tReal0 = real;
    g_curSpd = s;
}

// --- 时间源 hook 体 ---
//
// CFAbsoluteTimeGetCurrent / gettimeofday / mach_absolute_time 是 C 函数，
// 不能用 method_setImplementation 挂。改它们的唯一干净办法是 __interpose，
// 但 v1 已经证明：用 __interpose 拦 dyld 自己依赖的符号，绑定期拿到 NULL 直接崩。
// 所以这里不碰 C 函数，只 hook Objective-C 层的时间源。
//
// 这已经够用：广告 SDK 的倒计时几乎都走 NSTimer 或 NSDate 差值。
// 裸调 gettimeofday 做倒计时的实现极少，且那种实现无法驱动进度条。

typedef double (*Imp_DblId)(id, SEL);
typedef id     (*Imp_IdV)(id, SEL);
typedef id     (*Imp_IdD)(id, SEL, double);

static Imp_IdV   g_o_nsDate  = NULL;
static Imp_IdD   g_o_nsDateNow = NULL;
static Imp_DblId g_o_timeIntOrig = NULL;   // 原始 timeIntervalSinceReferenceDate，只用于读真值

// 只挂「创建 NSDate」的类方法，**不挂** -timeIntervalSinceReferenceDate。
//
// 为什么不能两个都挂：`+date` 返回的 NSDate 内部已存虚拟时间，
// 调用方再读 timeIntervalSinceReferenceDate 时会第二次虚拟化 —— 时间被平方放大，
// 倒计时瞬间归零、日志时间戳乱跳。这是必须避免的组合错误。
//
// 只挂类方法的副作用：对「已经存在的 NSDate 实例」读时间不会被虚拟化。
// 实际影响很小——广告倒计时都是从 `[NSDate date]` 起算的。
static id k_nsDate(id self, SEL _cmd)
{
    id d = g_o_nsDate ? g_o_nsDate(self, _cmd) : nil;
    if (!d || gSpeed <= 1.0001) return d;
    g_hitTime++;
    rebase_if_needed();
    // 用原实现读真实时间，绕开被 hook 的实例方法
    double real = g_o_timeIntOrig
        ? g_o_timeIntOrig(d, sel_registerName("timeIntervalSinceReferenceDate"))
        : [d timeIntervalSinceReferenceDate];
    return [NSDate dateWithTimeIntervalSinceReferenceDate:vtime(real)];
}

// +[NSDate dateWithTimeIntervalSinceNow:]
static id k_nsDateNow(id self, SEL _cmd, double delta)
{
    if (!g_o_nsDateNow) return nil;
    if (gSpeed <= 1.0001) return g_o_nsDateNow(self, _cmd, delta);
    g_hitTime++;
    rebase_if_needed();
    // delta 是「从现在起多少秒」，同样要压缩
    return g_o_nsDateNow(self, _cmd, delta / gSpeed);
}

static void install_time_hooks(void)
{
    @try {
        Class nd = objc_getClass("NSDate");

        // 先拿到原始 timeIntervalSinceReferenceDate，供 k_nsDate 内部读真值
        Method m = class_getInstanceMethod(nd, sel_registerName("timeIntervalSinceReferenceDate"));
        if (m) g_o_timeIntOrig = (Imp_DblId)method_getImplementation(m);

        g_o_nsDate = (Imp_IdV)kswizzle(nd, sel_registerName("date"), (IMP)k_nsDate, YES);
        g_o_nsDateNow = (Imp_IdD)kswizzle(nd, sel_registerName("dateWithTimeIntervalSinceNow:"),
                                          (IMP)k_nsDateNow, YES);

        KLOG("时间层: NSDate.date=%d dateWithIntervalSinceNow=%d",
             g_o_nsDate != NULL, g_o_nsDateNow != NULL);
    } @catch (NSException *e) {
        KLOG("时间层异常 %s", e.reason.UTF8String);
    }
}



#pragma mark - 层次二：定时器压缩

typedef id   (*Imp_Timer)(id, SEL, NSTimeInterval, id, SEL, id, BOOL);
typedef id   (*Imp_Link)(id, SEL, id, SEL);
typedef void (*Imp_Perform)(id, SEL, SEL, id, NSTimeInterval);

static Imp_Timer   g_o_schedTimer = NULL;
static Imp_Timer   g_o_timer      = NULL;
static Imp_Link    g_o_displayLink = NULL;
static Imp_Perform g_o_perform     = NULL;

static NSTimeInterval k_scaled(NSTimeInterval iv)
{
    // 0 或负：0 间隔本来是「下一轮 runloop 立刻执行」，除下去会变忙等；
    // 负数在 NSTimer 里是非法值，原样传。
    if (iv <= 0.0) return iv;
    if (gSpeed <= 1.0001) return iv;
    NSTimeInterval r = iv / gSpeed;
    if (r < 0.001) r = 0.001;
    g_hitTimer++;
    return r;
}

static id k_schedTimer(id self, SEL _cmd, NSTimeInterval iv,
                       id target, SEL sel, id info, BOOL repeats)
{
    if (!g_o_schedTimer) return nil;
    return g_o_schedTimer(self, _cmd, k_scaled(iv), target, sel, info, repeats);
}

static id k_timer(id self, SEL _cmd, NSTimeInterval iv,
                  id target, SEL sel, id info, BOOL repeats)
{
    if (!g_o_timer) return nil;
    return g_o_timer(self, _cmd, k_scaled(iv), target, sel, info, repeats);
}

// CADisplayLink 的 frameInterval 单位是「帧」且只能 >=1，调小被系统钳回，
// 所以这一层只做统计，真正的快进靠时间源与播放器。
static id k_displayLink(id self, SEL _cmd, id target, SEL sel)
{
    if (!g_o_displayLink) return nil;
    return g_o_displayLink(self, _cmd, target, sel);
}

static void k_perform(id self, SEL _cmd, SEL sel, id arg, NSTimeInterval delay)
{
    if (!g_o_perform) return;
    g_o_perform(self, _cmd, sel, arg, k_scaled(delay));
}

static void install_timer_hooks(void)
{
    @try {
        Class t = objc_getClass("NSTimer");
        g_o_schedTimer = (Imp_Timer)kswizzle(
            t, sel_registerName("scheduledTimerWithTimeInterval:target:selector:userInfo:repeats:"),
            (IMP)k_schedTimer, YES);
        g_o_timer = (Imp_Timer)kswizzle(
            t, sel_registerName("timerWithTimeInterval:target:selector:userInfo:repeats:"),
            (IMP)k_timer, YES);

        Class l = objc_getClass("CADisplayLink");
        g_o_displayLink = (Imp_Link)kswizzle(
            l, sel_registerName("displayLinkWithTarget:selector:"), (IMP)k_displayLink, YES);

        Class nso = objc_getClass("NSObject");
        g_o_perform = (Imp_Perform)kswizzle(
            nso, sel_registerName("performSelector:withObject:afterDelay:"),
            (IMP)k_perform, NO);

        KLOG("定时器层: NSTimer=%d/%d DisplayLink=%d perform=%d",
             g_o_schedTimer != NULL, g_o_timer != NULL,
             g_o_displayLink != NULL, g_o_perform != NULL);
    } @catch (NSException *e) {
        KLOG("定时器层异常 %s", e.reason.UTF8String);
    }
}

#pragma mark - 层次三：播放器速率

typedef void (*Imp_SetRate)(id, SEL, float);
static Imp_SetRate g_o_setRate = NULL;

static void k_setRate(id self, SEL _cmd, float rate)
{
    if (!g_o_setRate) return;
    float r = rate;
    // rate == 0 是暂停，乘上去会变成「极慢速播放」，画面冻住音频继续，反而更糟。
    if (rate != 0.0f && gSpeed > 1.0001) {
        r = (float)(rate * gSpeed);
        if (r > 2.0f) r = 2.0f;   // 多数机型 >2x 会静音或变调
        g_hitPlayer++;
    }
    g_o_setRate(self, _cmd, r);
}

static void install_player_hooks(void)
{
    @try {
        Class p = objc_getClass("AVPlayer");
        g_o_setRate = (Imp_SetRate)kswizzle(p, sel_registerName("setRate:"), (IMP)k_setRate, NO);
        KLOG("播放器层: AVPlayer.setRate=%d", g_o_setRate != NULL);
    } @catch (NSException *e) {
        KLOG("播放器层异常 %s", e.reason.UTF8String);
    }
}

#pragma mark - 层次四：运行时发现的广告播放器
//
// 不写死任何 SDK 类名。做法：
//   枚举所有已加载类 → 类名过一遍宽松关键字 → 再从该类的**方法名**里找进度类方法
//   → 只有「类名像广告 + 方法名像进度」同时命中才挂。
// 这样 SDK 换版本、改类名前缀都不影响；也不会误挂普通业务类。

// 类名关键字（宽松，只用于缩小扫描范围）
static const char *kNameHints[] = {
    "Ad", "AD", "ad", "Reward", "reward", "Video", "video",
    "Player", "player", "Inspire", "Interstitial", "Splash", NULL
};

// 方法名里出现这些，说明是「进度/时长」类接口
static const char *kMethodHints[] = {
    "currentPlayTime", "currentTime", "playProgress", "progress",
    "videoDuration", "duration", "totalTime", "playFinished", "didFinish",
    "rewardVerify", "onReward", "countdown", "remain", NULL
};

static BOOL name_looks_ad(const char *nm)
{
    if (!nm) return NO;
    for (int i = 0; kNameHints[i]; i++) {
        if (strstr(nm, kNameHints[i])) return YES;
    }
    return NO;
}

static BOOL sel_looks_progress(const char *nm)
{
    if (!nm) return NO;
    for (int i = 0; kMethodHints[i]; i++) {
        if (strstr(nm, kMethodHints[i])) return YES;
    }
    return NO;
}

// 通用「进度放大」。只挂 **零参数、返回 double** 的方法——
// 这是唯一能保证调用约定正确、绝不会因参数错位而崩的形状。
// 参数多于 0 个时，中间参数可能走浮点寄存器，用错误签名的 block 去接
// 会把 id 当 double 读，直接 SIGSEGV —— 第三方插件（AdAccel）点广告闪退的根因
// 就是给未知签名的方法强换实现。这里用「返回类型 + 参数个数」双重过滤堵死。
//
// ⚠ 方向很重要，不能无脑乘：
//   进度 = currentTime / duration
//   若两个都乘 倍速，比值不变，进度条一动不动。
//   正确做法：分子（当前进度）乘倍速，分母（总时长）除倍速，
//   于是 progress 被放大 倍速² 倍，播到终点的时间变成 1/倍速。
// ⚠ 方向修正（v3.1）
// 上面那段注释里的推导是错的，实测后改正：
//   progress = current / total
//   若 current *= k 且 total /= k，则 progress *= k²
//   k² 会让进度涨得快 —— 但「播完」的判定通常是 current >= total，
//   这个条件**不成立**（current 涨 k 倍，total 也变小 k 倍，但两者同步到达的值不是 1）。
// 所以正确做法是「只压时间，不压比例」：
//   分子（当前时间）* k  → total/current 比值不变，但 current 到达 total 的**墙钟时间**变成 1/k
//   分母（总时长）保持不动
// 这样：进度条按真实速度走完（视觉上快了 k 倍），且 current>=total 的判定仍成立。
// 之前的实现把分母也除了 k，导致 progress 涨 k² 倍，有些 SDK 的
// currentPlayTime 直接冲过 totalTime，反而让播放器 seek 越界 —— 这就是
// 「放大 0 个 getter」之外我担心的第二个问题，一并修掉。
static BOOL name_is_numerator(const char *sn)
{
    const char *num[] = {
        "currentPlayTime", "currentTime", "curTime", "playProgress", "progress",
        "elapsed", "playedTime", "watchedTime", "position", NULL
    };
    for (int i = 0; num[i]; i++) if (strstr(sn, num[i])) return YES;
    return NO;
}

static BOOL name_is_denominator(const char *sn)
{
    const char *den[] = {
        "duration", "totalTime", "videoDuration", "totalDuration",
        "length", "fullTime", NULL
    };
    for (int i = 0; den[i]; i++) if (strstr(sn, den[i])) return YES;
    return NO;
}

static BOOL hook_DoubleZeroArg(Class cls, Method m)
{
    char rt[8] = {0};
    method_getReturnType(m, rt, sizeof(rt));
    if (rt[0] != 'd') return NO;                       // 必须返回 double

    SEL sel = method_getName(m);
    const char *sn = sel_getName(sel);
    if (strchr(sn, ':')) return NO;                    // 必须零参数

    BOOL isNum = name_is_numerator(sn);
    BOOL isDen = name_is_denominator(sn);
    if (!isNum && !isDen) return NO;                   // 名字不像进度/时长，不碰

    IMP orig = method_getImplementation(m);
    if (!orig) return NO;

    IMP repl;
    if (isNum && !isDen) {
        // 分子：当前播放时间 * 倍速。分母不动 → 比真实播完所需的墙钟时间 ÷ 倍速
        repl = imp_implementationWithBlock(^double(id self) {
            double v = ((double (*)(id, SEL))orig)(self, sel);
            if (gSpeed <= 1.0001 || v <= 0.0) return v;
            g_hitDiscovered++;
            return v * gSpeed;
        });
    } else if (isDen && !isNum) {
        // 分母：**保持原值**。不把总时长缩小，否则 current/total 会被放平方倍、
        // 触发播放器 seek 越界或「已播完」误判。
        // 这里仍然挂一遍：一是计数用，二是把值钳到合法范围防 NaN/负数。
        repl = imp_implementationWithBlock(^double(id self) {
            double v = ((double (*)(id, SEL))orig)(self, sel);
            if (v != v || v <= 0.0) return v;           // NaN / 非正 → 原样
            g_hitDiscovered++;
            return v;
        });
    } else {
        return NO;                                     // 同时像分子和分母，太模糊，放弃
    }
    if (!repl) return NO;

    method_setImplementation(m, repl);
    return YES;
}

// 因为一个 C 函数无法对应多个原实现，这里为每个被发现的方法
// 生成一个 block IMP，把原 IMP 闭包进去 —— 这是唯一正确的多方法 hook 方式。
static void install_discovered_hooks(void)
{
    @try {
        int total = objc_getClassList(NULL, 0);
        if (total <= 0) { KLOG("类列表为空"); return; }

        Class *classes = (Class *)malloc(sizeof(Class) * (size_t)total);
        if (!classes) return;
        int real = objc_getClassList(classes, total);
        g_classesScanned = real;

        for (int i = 0; i < real; i++) {
            Class c = classes[i];
            const char *cn = class_getName(c);
            if (!name_looks_ad(cn)) continue;

            unsigned int mc = 0;
            Method *ms = class_copyMethodList(c, &mc);
            if (!ms) continue;

            BOOL classMatched = NO;
            int hooked = 0;
            for (unsigned int j = 0; j < mc; j++) {
                const char *sn = sel_getName(method_getName(ms[j]));
                if (!sel_looks_progress(sn)) continue;
                classMatched = YES;
                if (hook_DoubleZeroArg(c, ms[j])) hooked++;
            }
            free(ms);

            if (!classMatched) continue;
            g_classesMatched++;
            if (hooked > 0) {
                KLOG("挂载广告类 %s 上 %d 个进度 getter", cn, hooked);
            } else {
                KLOG("广告类 %s 有进度方法但形状不符（带参数），跳过", cn);
            }
        }
        free(classes);

        KLOG("运行时发现: 扫描 %d 类，匹配 %d 个广告类，放大 %d 个 getter",
             g_classesScanned, g_classesMatched, g_hitDiscovered);
    } @catch (NSException *e) {
        KLOG("运行时发现异常 %s", e.reason.UTF8String);
    }
}

#pragma mark - 层次五：摇一摇拦截

typedef void (*Imp_SendEvent)(id, SEL, UIEvent *);
static Imp_SendEvent g_o_sendEvent = NULL;

static void k_sendEvent(id self, SEL _cmd, UIEvent *e)
{
    if (!g_o_sendEvent) return;
    if (gBlockShake && e) {
        @try {
            if (e.type == UIEventTypeTouches && e.subtype == UIEventSubtypeMotionShake) {
                g_hitShake++;
                return;      // 吞掉，不转发给广告 SDK
            }
        } @catch (__unused NSException *x) { }
    }
    g_o_sendEvent(self, _cmd, e);
}

static void install_shake_block(void)
{
    @try {
        Class w = objc_getClass("UIWindow");
        g_o_sendEvent = (Imp_SendEvent)kswizzle(w, sel_registerName("sendEvent:"),
                                                (IMP)k_sendEvent, NO);
        KLOG("摇一摇拦截: %d", g_o_sendEvent != NULL);
    } @catch (NSException *e) {
        KLOG("摇一摇异常 %s", e.reason.UTF8String);
    }
}

#pragma mark - 层次六：反检测

static BOOL class_name_risky(const char *nm)
{
    if (!nm) return NO;
    const char *hints[] = {
        "IOSSecuritySuite", "SecurityChecker", "Jailbreak", "Tamper",
        "FridaDetector", "ReverseEngineer", "AntiDebug", "AntiHook",
        "IntegrityCheck", "SecurityCheck", NULL
    };
    for (int i = 0; hints[i]; i++) {
        if (strstr(nm, hints[i])) return YES;
    }
    return NO;
}

// 把方法改成返回 0 / nil，参数个数从 selector 冒号数推
static BOOL neutralize(Class cls, SEL sel, BOOL isClassMethod)
{
    Method m = isClassMethod ? class_getClassMethod(cls, sel) : class_getInstanceMethod(cls, sel);
    if (!m) return NO;

    char rt[8] = {0};
    method_getReturnType(m, rt, sizeof(rt));
    char r = rt[0];
    BOOL intRet = (r == 'c' || r == 'B' || r == 'i' || r == 's' || r == 'q' ||
                   r == 'C' || r == 'I' || r == 'Q' || r == 'l' || r == 'L');
    BOOL objRet = (r == '@' || r == '#');
    if (!intRet && !objRet) return NO;

    NSUInteger na = [[NSStringFromSelector(sel) componentsSeparatedByString:@":"] count];
    na = (na > 0) ? (na - 1) : 0;
    if (na > 4) return NO;

    IMP imp = NULL;
    if (intRet) {
        switch (na) {
            case 0: imp = imp_implementationWithBlock(^long(id s){ return 0; }); break;
            case 1: imp = imp_implementationWithBlock(^long(id s, id a){ return 0; }); break;
            case 2: imp = imp_implementationWithBlock(^long(id s, id a, id b){ return 0; }); break;
            case 3: imp = imp_implementationWithBlock(^long(id s, id a, id b, id c){ return 0; }); break;
            case 4: imp = imp_implementationWithBlock(^long(id s, id a, id b, id c, id d){ return 0; }); break;
            default: break;
        }
    } else {
        switch (na) {
            case 0: imp = imp_implementationWithBlock(^id(id s){ return nil; }); break;
            case 1: imp = imp_implementationWithBlock(^id(id s, id a){ return nil; }); break;
            case 2: imp = imp_implementationWithBlock(^id(id s, id a, id b){ return nil; }); break;
            case 3: imp = imp_implementationWithBlock(^id(id s, id a, id b, id c){ return nil; }); break;
            case 4: imp = imp_implementationWithBlock(^id(id s, id a, id b, id c, id d){ return nil; }); break;
            default: break;
        }
    }
    if (!imp) return NO;
    method_setImplementation(m, imp);
    return YES;
}

static int clean_class(Class cls)
{
    if (!cls) return 0;
    int n = 0;
    Class meta = object_getClass(cls);

    for (int pass = 0; pass < 2; pass++) {
        Class target = (pass == 0) ? meta : cls;
        BOOL isCls = (pass == 0);
        unsigned int mc = 0;
        Method *ms = class_copyMethodList(target, &mc);
        if (!ms) continue;
        for (unsigned int i = 0; i < mc; i++) {
            const char *sn = sel_getName(method_getName(ms[i]));
            // 只清 amI* 前缀（IOSSecuritySuite 的命名约定）+ 名字里带 Jail/Tamper/Debug
            BOOL hit = (strncmp(sn, "amI", 3) == 0) ||
                       strstr(sn, "ailbreak") || strstr(sn, "amper") ||
                       strstr(sn, "ebugged") || strstr(sn, "ooked");
            if (!hit) continue;
            if (neutralize(target, method_getName(ms[i]), isCls)) n++;
        }
        free(ms);
    }
    return n;
}

static void install_stealth(void)
{
    @try {
        int total = objc_getClassList(NULL, 0);
        if (total <= 0) return;
        Class *cs = (Class *)malloc(sizeof(Class) * (size_t)total);
        if (!cs) return;
        int real = objc_getClassList(cs, total);
        int matched = 0;
        for (int i = 0; i < real; i++) {
            if (!class_name_risky(class_getName(cs[i]))) continue;
            matched++;
            int n = clean_class(cs[i]);
            if (n > 0) {
                g_hitStealth += n;
                KLOG("清理 %s 上 %d 个检测方法", class_getName(cs[i]), n);
            }
        }
        free(cs);
        KLOG("反检测: 扫描 %d 类，命中 %d 类，清理 %d 方法", real, matched, g_hitStealth);
        if (matched == 0) KLOG("未发现检测类（本 app 可能没集成）");
    } @catch (NSException *e) {
        KLOG("反检测异常 %s", e.reason.UTF8String);
    }
}

#pragma mark - 层次七：悬浮球 UI

@interface AdlabBall : UIButton
@end

@interface AdlabPanel : UIView
@property (nonatomic, strong) UILabel *titleLab;
@property (nonatomic, strong) UILabel *statLab;
@property (nonatomic, strong) UISlider *speedSlider;
@property (nonatomic, strong) UILabel *speedLab;
@property (nonatomic, strong) UISwitch *shakeSwitch;
@property (nonatomic, strong) UITextView *logView;
@end

@interface AdlabWindow : UIWindow
@end

@interface AdlabOverlay : NSObject
@property (nonatomic, strong) UIWindow *win;   // 仅记录宿主 window，不持有独立窗口
@property (nonatomic, strong) AdlabBall *ball;
@property (nonatomic, strong) AdlabPanel *panel;
+ (instancetype)shared;
- (void)install;
- (void)refresh;
@end

#pragma mark - 悬浮窗（hitTest 穿透，不挡游戏）

@implementation AdlabWindow
// 自己或自己的 rootViewController.view 命中时返回 nil，
// 事件落到下层游戏窗口 —— 这是悬浮球能「点得到自己、又挡不住游戏」的关键。
- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event
{
    UIView *v = [super hitTest:point withEvent:event];
    if (v == self || v == self.rootViewController.view) return nil;
    return v;
}
@end

#pragma mark - 悬浮球

@implementation AdlabBall
- (instancetype)initWithFrame:(CGRect)f
{
    self = [super initWithFrame:f];
    if (!self) return nil;
    self.backgroundColor = [UIColor colorWithWhite:0.0 alpha:0.55];
    self.layer.cornerRadius = f.size.width / 2.0;
    self.layer.borderWidth = 1.0;
    self.layer.borderColor = [UIColor colorWithRed:0.2 green:1.0 blue:0.5 alpha:0.9].CGColor;
    self.clipsToBounds = YES;
    [self setTitle:@"倍" forState:UIControlStateNormal];
    [self setTitleColor:[UIColor colorWithRed:0.2 green:1.0 blue:0.5 alpha:1.0]
               forState:UIControlStateNormal];
    self.titleLabel.font = [UIFont boldSystemFontOfSize:15];
    return self;
}
@end

#pragma mark - 面板

@implementation AdlabPanel
- (instancetype)initWithFrame:(CGRect)f
{
    self = [super initWithFrame:f];
    if (!self) return nil;

    self.backgroundColor = [UIColor colorWithWhite:0.05 alpha:0.94];
    self.layer.cornerRadius = 12;
    self.layer.borderWidth = 1;
    self.layer.borderColor = [UIColor colorWithWhite:0.3 alpha:1].CGColor;

    CGFloat w = f.size.width, h = f.size.height;

    _titleLab = [[UILabel alloc] initWithFrame:CGRectMake(12, 8, w - 60, 22)];
    _titleLab.text = @"AdlabKit 通用加速";
    _titleLab.textColor = [UIColor whiteColor];
    _titleLab.font = [UIFont boldSystemFontOfSize:13];
    [self addSubview:_titleLab];

    UIButton *x = [UIButton buttonWithType:UIButtonTypeSystem];
    x.frame = CGRectMake(w - 44, 6, 38, 26);
    [x setTitle:@"关闭" forState:UIControlStateNormal];
    x.titleLabel.font = [UIFont systemFontOfSize:12];
    [x addTarget:self action:@selector(onClose) forControlEvents:UIControlEventTouchUpInside];
    [self addSubview:x];

    _speedLab = [[UILabel alloc] initWithFrame:CGRectMake(14, 36, w - 28, 20)];
    _speedLab.textColor = [UIColor colorWithRed:0.2 green:1.0 blue:0.5 alpha:1];
    _speedLab.font = [UIFont boldSystemFontOfSize:13];
    [self addSubview:_speedLab];

    _speedSlider = [[UISlider alloc] initWithFrame:CGRectMake(14, 60, w - 28, 30)];
    _speedSlider.minimumValue = 1.0f;
    _speedSlider.maximumValue = 5.0f;
    _speedSlider.value = (float)gSpeed;
    [_speedSlider addTarget:self action:@selector(onSpeed)
           forControlEvents:UIControlEventValueChanged];
    [self addSubview:_speedSlider];

    _shakeSwitch = [[UISwitch alloc] initWithFrame:CGRectMake(14, 96, 51, 31)];
    _shakeSwitch.on = gBlockShake;
    _shakeSwitch.transform = CGAffineTransformMakeScale(0.8, 0.8);
    [_shakeSwitch addTarget:self action:@selector(onShake)
            forControlEvents:UIControlEventValueChanged];
    [self addSubview:_shakeSwitch];

    UILabel *sl = [[UILabel alloc] initWithFrame:CGRectMake(64, 100, w - 80, 22)];
    sl.text = @"拦截摇一摇广告";
    sl.textColor = [UIColor lightGrayColor];
    sl.font = [UIFont systemFontOfSize:12];
    [self addSubview:sl];

    _statLab = [[UILabel alloc] initWithFrame:CGRectMake(14, 132, w - 28, 62)];
    _statLab.textColor = [UIColor colorWithWhite:0.75 alpha:1];
    _statLab.font = [UIFont fontWithName:@"Menlo" size:9.5];
    _statLab.numberOfLines = 0;
    [self addSubview:_statLab];

    _logView = [[UITextView alloc] initWithFrame:CGRectMake(10, 198, w - 20, h - 208)];
    _logView.backgroundColor = [UIColor colorWithWhite:0 alpha:0.55];
    _logView.textColor = [UIColor colorWithRed:0.6 green:1.0 blue:0.7 alpha:1];
    _logView.font = [UIFont fontWithName:@"Menlo" size:9];
    _logView.editable = NO;
    _logView.layer.cornerRadius = 8;
    _logView.textContainerInset = UIEdgeInsetsMake(6, 6, 6, 6);
    [self addSubview:_logView];

    return self;
}

- (void)onClose { [AdlabOverlay shared].panel.hidden = YES; }

- (void)onSpeed
{
    gSpeed = self.speedSlider.value;
    self.speedLab.text = [NSString stringWithFormat:@"倍速 %.1fx（%.0f%% 时间轴）",
                          gSpeed, 100.0 / gSpeed];
    cfg_save();
    KLOG("倍速 → %.2fx  域=%s", gSpeed, cfg_domain().UTF8String);
}

- (void)onShake
{
    gBlockShake = self.shakeSwitch.on;
    cfg_save();
    KLOG("摇一摇拦截 → %d", gBlockShake);
}
@end

#pragma mark - 主控

@implementation AdlabOverlay

+ (instancetype)shared
{
    static AdlabOverlay *s = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ s = [[AdlabOverlay alloc] init]; });
    return s;
}

- (void)install
{
    if (self.ball) return;
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{ [self install]; });
        return;
    }

    @try {
        CGFloat sw = [UIScreen mainScreen].bounds.size.width;
        CGFloat sh = [UIScreen mainScreen].bounds.size.height;
        if (sw < 1 || sh < 1) { sw = 375; sh = 667; }
        CGFloat bx = sw - 56;
        CGFloat by = sh * 0.35;

        // ── 方案 A：挂到游戏现有的 keyWindow（首选，绕开 UIScene 全部坑）
        // 自己造 UIWindow 在 iOS 13+ 必须绑 windowScene，而 constructor 时机
        // 拿不到 ForegroundActive 的 scene（实测日志 scene=0，界面永不出现）。
        // 直接往现有 window 上加子视图，宿主 app 自己已经把 scene 处理好了。
        UIWindow *host = nil;
        if (@available(iOS 13.0, *)) {
            for (UIScene *s in [UIApplication sharedApplication].connectedScenes) {
                if (![s isKindOfClass:[UIWindowScene class]]) continue;
                if (s.activationState != UISceneActivationStateForegroundActive) continue;
                for (UIWindow *w in ((UIWindowScene *)s).windows) {
                    if (w.isKeyWindow) { host = w; break; }
                }
                if (!host) {
                    for (UIWindow *w in ((UIWindowScene *)s).windows) {
                        if (!w.hidden && w.windowLevel <= UIWindowLevelNormal + 1) { host = w; break; }
                    }
                }
                if (host) break;
            }
        }
        if (!host) host = [UIApplication sharedApplication].keyWindow;   // 兜底（iOS<13 或上面没找到）
        if (!host) {
            // 再兜底：遍历所有 window（app 可能还没 makeKey）
            if (@available(iOS 13.0, *)) {
                for (UIScene *s in [UIApplication sharedApplication].connectedScenes) {
                    if (![s isKindOfClass:[UIWindowScene class]]) continue;
                    for (UIWindow *w in ((UIWindowScene *)s).windows) { host = w; break; }
                    if (host) break;
                }
            }
        }

        if (!host) {
            gSceneRetry++;
            if (gSceneRetry <= 120) {                      // 最多等 60 秒
                if (gSceneRetry <= 3 || gSceneRetry % 20 == 0)
                    KLOG("还没拿到宿主 window，1s 后重试（第 %d 次）", gSceneRetry);
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)),
                               dispatch_get_main_queue(), ^{ [self install]; });
                return;
            }
            KLOG("60 秒内始终没有可用 window，UI 放弃（hook 仍在工作）");
            return;
        }

        // 悬浮球（直接加在宿主 window 上，不加中间容器，避免挡住游戏）
        self.ball = [[AdlabBall alloc] initWithFrame:CGRectMake(bx, by, 44, 44)];
        [self.ball addTarget:self action:@selector(onBallTap)
            forControlEvents:UIControlEventTouchUpInside];
        UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc]
                                       initWithTarget:self action:@selector(onBallPan:)];
        [self.ball addGestureRecognizer:pan];
        [host addSubview:self.ball];
        self.win = host;                                   // 记下宿主，供 refresh 用

        // 面板
        CGFloat pw = 300, ph = 420;
        self.panel = [[AdlabPanel alloc] initWithFrame:
                      CGRectMake((sw - pw) / 2.0, (sh - ph) / 2.0, pw, ph)];
        self.panel.hidden = YES;
        [host addSubview:self.panel];

        [self refresh];
        KLOG("UI 已安装(挂宿主) %.0fx%.0f host=%@ retry=%d ball=(%.0f,%.0f)",
             sw, sh, NSStringFromClass([host class]), gSceneRetry, bx, by);
    } @catch (NSException *e) {
        KLOG("UI 安装异常 %s", e.reason.UTF8String);
    }
}

- (void)onBallTap
{
    self.panel.hidden = !self.panel.hidden;
    [self refresh];
}

- (void)onBallPan:(UIPanGestureRecognizer *)g
{
    UIView *v = self.ball;
    CGPoint t = [g translationInView:v.superview];
    CGPoint c = v.center;
    c.x += t.x; c.y += t.y;
    v.center = c;
    [g setTranslation:CGPointMake(0, 0) inView:v.superview];
}

- (void)refresh
{
    if (!self.panel) return;
    self.panel.speedLab.text = [NSString stringWithFormat:@"倍速 %.1fx（%.0f%% 时间轴）",
                                gSpeed, 100.0 / gSpeed];
    if (self.panel.speedSlider.value != (float)gSpeed)
        self.panel.speedSlider.value = (float)gSpeed;
    if (self.panel.shakeSwitch.on != gBlockShake)
        self.panel.shakeSwitch.on = gBlockShake;

    self.panel.statLab.text = [NSString stringWithFormat:
        @"域  %@\n"
        @"时间源 %d  定时器 %d  播放器 %d\n"
        @"摇一摇 %d  反检测 %d  类 %d/%d  放大 %d",
        cfg_domain(),
        g_hitTime, g_hitTimer, g_hitPlayer,
        g_hitShake, g_hitStealth, g_classesMatched, g_classesScanned,
        g_hitDiscovered];

    if (self.panel.logView && gLogLock) {
        [gLogLock lock];
        NSArray *copy = [gLogLines copy];
        [gLogLock unlock];
        self.panel.logView.text = [copy componentsJoinedByString:@"\n"];
    }
}
@end

#pragma mark - 入口

__attribute__((constructor))
static void adlab_entry(void)
{
    @autoreleasepool {
        klog_init();
        KLOG("==== AdlabKit loaded  pid=%d  bid=%s ====",
             getpid(), [[[NSBundle mainBundle] bundleIdentifier] UTF8String]);

        cfg_load();
        KLOG("配置: 域=%s 倍速=%.2f 摇一摇=%d",
             cfg_domain().UTF8String, gSpeed, gBlockShake);

        // 顺序有讲究：先装时间源（其他层依赖它），再定时器，再播放器
        install_time_hooks();
        install_timer_hooks();
        install_player_hooks();
        install_discovered_hooks();
        install_shake_block();
        install_stealth();

        // UI 延后，等 app 自己的 window 起来；didFinishLaunching 再兜一次
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{ [[AdlabOverlay shared] install]; });

        [[NSNotificationCenter defaultCenter]
            addObserverForName:UIApplicationDidFinishLaunchingNotification
                        object:nil queue:[NSOperationQueue mainQueue]
                    usingBlock:^(__unused NSNotification *n) {
            [[AdlabOverlay shared] install];
        }];

        KLOG("入口完成 speed=%.2f hook=%d/%d/%d stealth=%d",
             gSpeed, g_o_nsDate != NULL, g_o_schedTimer != NULL,
             g_o_setRate != NULL, g_hitStealth);
    }
}
