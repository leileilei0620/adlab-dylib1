// ============================================================================
//  adlab · 悬浮助手 dylib  (爷爷的农院日记 / com.maobei.yydiary 1.0.9)
//
//  v2 —— 修掉 v1 注入后闪退的全部根因
//  ---------------------------------------------------------------------------
//  v1 的致命缺陷（按严重度）：
//
//   [崩1·必崩] __interpose 拦 _dyld_get_image_name
//        dyld 绑定阶段就生效，但 gOrigDyldImageName 要等 constructor 才赋值
//        → 这中间任何调用都返回 NULL → dyld / objc runtime / dlopen 立刻崩。
//
//   [崩2·必崩] adlab_fopen 在重入路径 return NULL
//        resolve_fopen_original() 里调 dlopen，dlopen 内部又调 fopen →
//        重入保护挡住 → orig_fopen 仍是 NULL → 给 dlopen 返回 NULL → 内部状态损坏。
//
//   [崩3·高概率] NSClassFromString(@"IOSSecuritySuite") 恒为 nil
//        IOSSecuritySuite 是 Swift 模块，运行时类名是
//        _TtC16IOSSecuritySuite16SecurityChecker 这类 mangled 名。
//        结果 amITampered 一次都没被清 → TrollFools 重签后必然返回 true → 主动退出。
//
//   [漏4] Cocos 走的是实例方法 -[NSData initWithContentsOfFile:]
//        v1 只 swizzle 了类方法 +dataWithContentsOfFile:，即使不崩也 reads=0。
//
//   [漏5] 悬浮窗吃掉了全部触摸
//        window.rootViewController.view 命中空白处会吞事件，
//        下面游戏窗口再也收不到点击 → "装上了但点不动"。
//
//  v2 的策略变化：
//   1) 彻底删掉 3 个 __interpose 表。全局 interpose 对本场景是负收益：
//      污染整个进程、生效时机不可控、原始实现还要靠 dlsym 去绕自己。
//   2) 首选「磁盘直改」：constructor 里直接把 assets/main/index.js 打补丁写回去。
//      TrollStore/TrollFools 注入的 app 带 no-sandbox + platform-application，
//      对自己的 bundle 有写权限。成功的话一个 hook 都不装，零风险。
//   3) 磁盘直改失败才装 NSData/NSString/NSFileManager 的 method swizzle。
//      swizzle 拿到的原始 IMP 是真实现，天然不递归、不返回 NULL。
//   4) stealth 改成 objc_getClassList 全类遍历 + 名字片段匹配，
//      清掉所有 amI* 开头的方法（类方法与实例方法都清）。
//   5) 所有 hook 体 @try/@catch，异常一律回落原实现。
//   6) 悬浮窗改成 hitTest 穿透：只有球和面板区域吃事件，其余透传给游戏。
// ============================================================================

#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <stdio.h>
#import <stdlib.h>
#import <string.h>
#import <stdarg.h>
#import <unistd.h>
#import <fcntl.h>
#import <errno.h>
#import <limits.h>
#import <time.h>
#import <sys/types.h>
#import <sys/stat.h>
#import <mach-o/dyld.h>
#import <dispatch/dispatch.h>

#pragma mark - 配置

static NSString *const kTargetSuffix = @"assets/main/index.js";

// 锚点必须是数组（const char x[]），不能是指针（const char *x）。
// 下面的编译期断言依赖 sizeof 拿到字符串真实长度；指针的 sizeof 恒为 8。
static const char kAnchorOld[] =
    "i.reflection.callStaticMethod(\"ViewController\",\"showInspireAd:\",JSON.stringify(l))";

static const char kAnchorNew[] =
    "this.onRewardAdShowCall(),this.onRewardAdVerifyCall(),this.onRewardAdCloseCall(1) ";

// 编译期硬断言：两个锚点都必须是 82 字节。
// sizeof(数组) 含末尾 NUL，所以要减 1。
typedef char adlab_assert_old_len[(sizeof(kAnchorOld) - 1 == 82) ? 1 : -1];
typedef char adlab_assert_new_len[(sizeof(kAnchorNew) - 1 == 82) ? 1 : -1];
typedef char adlab_assert_equal_len[
    (sizeof(kAnchorOld) == sizeof(kAnchorNew)) ? 1 : -1];

#pragma mark - 全局状态

static BOOL gForceReward = YES;
static BOOL gVerbose     = YES;
static BOOL gDiskPatched = NO;   // 磁盘直改是否成功
static BOOL gHooksInstalled = NO;

static int gPatchHits   = 0;   // 累计替换成功次数
static int gReadHits    = 0;   // 目标文件被读取次数
static int gViaNSData   = 0;
static int gViaNSString = 0;
static int gViaFileMgr  = 0;
static int gStealthHits = 0;   // 被清掉的安全检测方法数
static int gInstallRetry = 0;  // UI 安装因 windowScene 缺失而重试的次数
static BOOL gNativeObserverInstalled = NO;  // install 可能被重试/多次调用，swizzle 必须幂等

static NSMutableArray<NSString *> *gLogLines = nil;
static NSLock *gLogLock = nil;
static FILE *gLogFile = NULL;

#pragma mark - 日志

static void adlab_log_raw(const char *msg)
{
    if (!msg) return;
    fprintf(stderr, "[adlab] %s\n", msg);
    if (gLogFile) {
        time_t t = time(NULL);
        struct tm tmv;
        localtime_r(&t, &tmv);
        fprintf(gLogFile, "%02d:%02d:%02d %s\n",
                tmv.tm_hour, tmv.tm_min, tmv.tm_sec, msg);
        fflush(gLogFile);
    }
}

static void adlab_log_init(void)
{
    if (gLogLock) return;
    gLogLock = [NSLock new];
    gLogLines = [NSMutableArray array];

    @try {
        NSString *dir = NSTemporaryDirectory();
        if (dir.length) {
            NSString *p = [dir stringByAppendingPathComponent:@"adlab.log"];
            gLogFile = fopen(p.UTF8String, "a");
        }
    } @catch (__unused NSException *e) { }
}

static void ALogv(NSString *fmt, ...)
{
    if (!gVerbose || !fmt) return;
    va_list ap;
    va_start(ap, fmt);
    NSString *s = [[NSString alloc] initWithFormat:fmt arguments:ap];
    va_end(ap);
    if (!s) return;

    adlab_log_raw(s.UTF8String);

    if (!gLogLock) { gLogLock = [NSLock new]; gLogLines = [NSMutableArray array]; }
    [gLogLock lock];
    if (!gLogLines) gLogLines = [NSMutableArray array];
    [gLogLines addObject:s];
    while (gLogLines.count > 300) [gLogLines removeObjectAtIndex:0];
    [gLogLock unlock];
}

#define ALOG(...) ALogv(__VA_ARGS__)

#pragma mark - 锚点替换

// 等长替换：anchor / repl 长度必须相同，否则拒绝（避免破坏文件结构）。
static int adlab_patch_buf(unsigned char *buf, size_t len)
{
    const size_t alen = sizeof(kAnchorOld) - 1;
    const size_t rlen = sizeof(kAnchorNew) - 1;
    if (alen != rlen || !buf || len < alen) return 0;

    int hits = 0;
    size_t last = len - alen;
    for (size_t i = 0; i <= last; i++) {
        if (buf[i] != (unsigned char)kAnchorOld[0]) continue;
        if (memcmp(buf + i, kAnchorOld, alen) == 0) {
            memcpy(buf + i, kAnchorNew, rlen);
            hits++;
            i += alen - 1;
        }
    }
    return hits;
}

// 文件里是否已经打过补丁（第二次启动时靠这个判断，避免误报 MISS）
static BOOL adlab_buf_already_patched(const unsigned char *buf, size_t len)
{
    const size_t nlen = sizeof(kAnchorNew) - 1;
    if (!buf || len < nlen) return NO;
    return memmem(buf, len, kAnchorNew, nlen) != NULL;
}

static BOOL adlab_path_matches(NSString *p)
{
    if (![p isKindOfClass:[NSString class]]) return NO;
    if (p.length < kTargetSuffix.length) return NO;
    return [p hasSuffix:kTargetSuffix];
}

#pragma mark - 路径定位

// 取主 app 的 bundle 路径。
// 优先用 _NSGetExecutablePath：拿到的是 /var/containers/Bundle/Application/<UUID>/xxx.app/xxx，
// 去掉最后一段就是 .app 目录。比 [NSBundle mainBundle] 更稳（dylib 场景下两者通常一致）。
static NSString *adlab_app_bundle_path(void)
{
    @try {
        char exe[PATH_MAX] = {0};
        uint32_t sz = sizeof(exe);
        if (_NSGetExecutablePath(exe, &sz) == 0 && exe[0]) {
            NSString *s = [NSString stringWithUTF8String:exe];
            if (s.length > 1) return [s stringByDeletingLastPathComponent];
        }
    } @catch (__unused NSException *e) { }

    @try {
        NSString *b = [[NSBundle mainBundle] bundlePath];
        if (b.length > 1) return b;
    } @catch (__unused NSException *e) { }

    return nil;
}

#pragma mark - 磁盘直改（首选方案）

// 把 bundle 里的 index.js 读出来、打补丁、写回去。
// 成功返回 YES —— 此时完全不需要任何 hook，进程里不留痕迹。
static BOOL adlab_patch_on_disk(void)
{
    NSString *bundle = adlab_app_bundle_path();
    if (!bundle) { ALOG(@"bundle path 取不到"); return NO; }

    NSString *js = [bundle stringByAppendingPathComponent:kTargetSuffix];
    ALOG(@"target js = %@", js);

    // 此处还没装任何 hook，用系统原生的读文件接口是安全的
    NSData *raw = nil;
    @try {
        raw = [NSData dataWithContentsOfFile:js];
    } @catch (NSException *e) {
        ALOG(@"读文件异常 %@", e.reason);
        return NO;
    }

    if (!raw || raw.length < 1024) {
        ALOG(@"读文件失败或过小 (len=%lu)", (unsigned long)raw.length);
        return NO;
    }

    const unsigned char *bytes = (const unsigned char *)raw.bytes;

    if (adlab_buf_already_patched(bytes, raw.length)) {
        ALOG(@"磁盘上已是补丁版（%lu B），跳过", (unsigned long)raw.length);
        gPatchHits += 1;      // 记一次，UI 上能看出已生效
        return YES;
    }

    NSMutableData *m = [raw mutableCopy];
    int hits = adlab_patch_buf((unsigned char *)m.mutableBytes, m.length);
    if (hits <= 0) {
        ALOG(@"磁盘直改：锚点 MISS（size=%lu）—— 可能不是这份文件",
             (unsigned long)raw.length);
        return NO;
    }

    // 备份原始文件，方便回滚
    NSString *bak = [js stringByAppendingString:@".adlab_orig"];
    @try {
        if (![[NSFileManager defaultManager] fileExistsAtPath:bak]) {
            NSError *e1 = nil;
            [raw writeToFile:bak options:NSDataWritingAtomic error:&e1];
            if (e1) ALOG(@"备份失败（不影响主流程）%@", e1.localizedDescription);
        }
    } @catch (__unused NSException *e) { }

    NSError *err = nil;
    BOOL ok = NO;
    @try {
        ok = [m writeToFile:js options:NSDataWritingAtomic error:&err];
    } @catch (NSException *e) {
        ALOG(@"写文件异常 %@", e.reason);
        return NO;
    }

    if (!ok) {
        ALOG(@"磁盘直改失败（不可写）：%@", err.localizedDescription);
        return NO;
    }

    gPatchHits += hits;
    ALOG(@"磁盘直改成功 hits=%d size=%lu", hits, (unsigned long)m.length);
    return YES;
}

#pragma mark - 通用 swizzle 助手

// 返回被替换掉的原始 IMP（没有该方法则返回 NULL）。
// 不写成 out-parameter：把函数指针变量的地址强转成 IMP* 再写，属于
// 指针类型双关，开 -O2 后可能被优化掉。直接返回原始 IMP 最干净。
static IMP adlab_swizzle(Class cls, SEL sel, IMP replacement, BOOL isClassMethod)
{
    if (!cls || !sel || !replacement) return NULL;
    Method m = isClassMethod ? class_getClassMethod(cls, sel)
                             : class_getInstanceMethod(cls, sel);
    if (!m) return NULL;
    IMP orig = method_getImplementation(m);
    method_setImplementation(m, replacement);
    return orig;
}

// 把一份 NSData 换成打过补丁的副本；没有锚点则返回 nil。
static NSData *adlab_patched_copy(NSData *src)
{
    if (![src isKindOfClass:[NSData class]]) return nil;
    if (src.length < 1024) return nil;

    @try {
        NSMutableData *m = [src mutableCopy];
        if (!m) return nil;
        int hits = adlab_patch_buf((unsigned char *)m.mutableBytes, m.length);
        if (hits <= 0) {
            if (adlab_buf_already_patched((const unsigned char *)src.bytes, src.length)) {
                return nil;   // 已经打过了，原样返回
            }
            ALOG(@"通道命中但锚点 MISS（size=%lu）", (unsigned long)src.length);
            return nil;
        }
        gPatchHits += hits;
        ALOG(@"内存补丁 hits=%d size=%lu", hits, (unsigned long)m.length);
        return m;
    } @catch (NSException *e) {
        ALOG(@"补丁异常 %@", e.reason);
        return nil;
    }
}

#pragma mark - 读通道（仅在磁盘直改失败时启用）

typedef id      (*Imp_Id_Path)(id, SEL, NSString *);
typedef id      (*Imp_Id_Path_Opts)(id, SEL, NSString *, NSDataReadingOptions, NSError **);
typedef id      (*Imp_Id_Path_Enc)(id, SEL, NSString *, NSUInteger, NSError **);

static Imp_Id_Path        g_o_dataWithFile       = NULL;
static Imp_Id_Path_Opts   g_o_dataWithFileOpts   = NULL;
static Imp_Id_Path_Opts   g_o_dataInitFileOpts   = NULL;
static Imp_Id_Path        g_o_dataInitFile       = NULL;
static Imp_Id_Path_Enc    g_o_strWithFileEnc     = NULL;
static Imp_Id_Path_Enc    g_o_strInitFileEnc     = NULL;
static Imp_Id_Path        g_o_contentsAtPath     = NULL;

// 记录一次命中（只在路径匹配时调用）
static void adlab_note_read(const char *tag)
{
    gReadHits++;
    ALOG(@"读通道命中 via=%s", tag);
}

// ---- +[NSData dataWithContentsOfFile:] ----
static id adlab_dataWithFile(id self, SEL _cmd, NSString *path)
{
    if (!g_o_dataWithFile) return nil;
    if (!adlab_path_matches(path)) return g_o_dataWithFile(self, _cmd, path);
    @try {
        gViaNSData++; adlab_note_read("NSData+file");
        id raw = g_o_dataWithFile(self, _cmd, path);
        id p = adlab_patched_copy(raw);
        return p ?: raw;
    } @catch (__unused NSException *e) {
        return g_o_dataWithFile(self, _cmd, path);
    }
}

// ---- +[NSData dataWithContentsOfFile:options:error:] ----
static id adlab_dataWithFileOpts(id self, SEL _cmd, NSString *path,
                                 NSDataReadingOptions opts, NSError **err)
{
    if (!g_o_dataWithFileOpts) return nil;
    if (!adlab_path_matches(path))
        return g_o_dataWithFileOpts(self, _cmd, path, opts, err);
    @try {
        gViaNSData++; adlab_note_read("NSData+file:opts");
        id raw = g_o_dataWithFileOpts(self, _cmd, path, opts, err);
        id p = adlab_patched_copy(raw);
        return p ?: raw;
    } @catch (__unused NSException *e) {
        return g_o_dataWithFileOpts(self, _cmd, path, opts, err);
    }
}

// ---- -[NSData initWithContentsOfFile:]  ← Cocos 实际走的这条 ----
static id adlab_dataInitFile(id self, SEL _cmd, NSString *path)
{
    if (!g_o_dataInitFile) return nil;
    if (!adlab_path_matches(path)) return g_o_dataInitFile(self, _cmd, path);
    @try {
        gViaNSData++; adlab_note_read("NSData-init");
        id raw = g_o_dataInitFile(self, _cmd, path);
        id p = adlab_patched_copy(raw);
        // init 返回不同对象在 ObjC 里是合法且常见的写法
        return p ?: raw;
    } @catch (__unused NSException *e) {
        return g_o_dataInitFile(self, _cmd, path);
    }
}

// ---- -[NSData initWithContentsOfFile:options:error:] ----
static id adlab_dataInitFileOpts(id self, SEL _cmd, NSString *path,
                                 NSDataReadingOptions opts, NSError **err)
{
    if (!g_o_dataInitFileOpts) return nil;
    if (!adlab_path_matches(path))
        return g_o_dataInitFileOpts(self, _cmd, path, opts, err);
    @try {
        gViaNSData++; adlab_note_read("NSData-init:opts");
        id raw = g_o_dataInitFileOpts(self, _cmd, path, opts, err);
        id p = adlab_patched_copy(raw);
        return p ?: raw;
    } @catch (__unused NSException *e) {
        return g_o_dataInitFileOpts(self, _cmd, path, opts, err);
    }
}

// ---- +[NSString stringWithContentsOfFile:encoding:error:] ----
// 这个通道拿到的已经是解码后的 NSString，字节补丁不再适用。
// 但它说明 app 确实读了目标文件 —— 记一笔，真正生效靠 NSData 那条。
static id adlab_strWithFileEnc(id self, SEL _cmd, NSString *path,
                               NSUInteger enc, NSError **err)
{
    if (!g_o_strWithFileEnc) return nil;
    if (adlab_path_matches(path)) {
        gViaNSString++; adlab_note_read("NSString+file");
        ALOG(@"NSString 通道读到目标文件（enc=%lu），由 NSData 通道兜底",
             (unsigned long)enc);
    }
    return g_o_strWithFileEnc(self, _cmd, path, enc, err);
}

// ---- -[NSString initWithContentsOfFile:encoding:error:] ----
static id adlab_strInitFileEnc(id self, SEL _cmd, NSString *path,
                               NSUInteger enc, NSError **err)
{
    if (!g_o_strInitFileEnc) return nil;
    if (adlab_path_matches(path)) {
        gViaNSString++; adlab_note_read("NSString-init");
    }
    return g_o_strInitFileEnc(self, _cmd, path, enc, err);
}

// ---- -[NSFileManager contentsAtPath:] ----
static id adlab_contentsAtPath(id self, SEL _cmd, NSString *path)
{
    if (!g_o_contentsAtPath) return nil;
    if (!adlab_path_matches(path)) return g_o_contentsAtPath(self, _cmd, path);
    @try {
        gViaFileMgr++; adlab_note_read("NSFileManager");
        id raw = g_o_contentsAtPath(self, _cmd, path);
        id p = adlab_patched_copy(raw);
        return p ?: raw;
    } @catch (__unused NSException *e) {
        return g_o_contentsAtPath(self, _cmd, path);
    }
}

static void adlab_install_read_hooks(void)
{
    if (gHooksInstalled) return;
    gHooksInstalled = YES;

    @try {
        Class nsd = [NSData class];
        g_o_dataWithFile =
            (Imp_Id_Path)adlab_swizzle(nsd, @selector(dataWithContentsOfFile:),
                                       (IMP)adlab_dataWithFile, YES);
        g_o_dataInitFileOpts =
            (Imp_Id_Path_Opts)adlab_swizzle(nsd, @selector(initWithContentsOfFile:options:error:),
                                            (IMP)adlab_dataInitFileOpts, NO);
        g_o_dataInitFile =
            (Imp_Id_Path)adlab_swizzle(nsd, @selector(initWithContentsOfFile:),
                                       (IMP)adlab_dataInitFile, NO);
        // +dataWithContentsOfFile:options:error: 与 -initWithContentsOfFile:options:error:
        // 共用同一个 IMP 槽位不安全，单独存一份。
        g_o_dataWithFileOpts =
            (Imp_Id_Path_Opts)adlab_swizzle(nsd, @selector(dataWithContentsOfFile:options:error:),
                                            (IMP)adlab_dataWithFileOpts, YES);
    } @catch (NSException *e) {
        ALOG(@"NSData swizzle 异常 %@", e.reason);
    }

    @try {
        Class nss = [NSString class];
        g_o_strWithFileEnc =
            (Imp_Id_Path_Enc)adlab_swizzle(nss, @selector(stringWithContentsOfFile:encoding:error:),
                                           (IMP)adlab_strWithFileEnc, YES);
        g_o_strInitFileEnc =
            (Imp_Id_Path_Enc)adlab_swizzle(nss, @selector(initWithContentsOfFile:encoding:error:),
                                           (IMP)adlab_strInitFileEnc, NO);
    } @catch (NSException *e) {
        ALOG(@"NSString swizzle 异常 %@", e.reason);
    }

    @try {
        Class nsf = [NSFileManager class];
        g_o_contentsAtPath =
            (Imp_Id_Path)adlab_swizzle(nsf, @selector(contentsAtPath:),
                                       (IMP)adlab_contentsAtPath, NO);
    } @catch (NSException *e) {
        ALOG(@"NSFileManager swizzle 异常 %@", e.reason);
    }

    ALOG(@"读通道已装好 (NSData=%d NSString=%d FileMgr=%d)",
         g_o_dataWithFile != NULL, g_o_strWithFileEnc != NULL,
         g_o_contentsAtPath != NULL);
}

#pragma mark - 反检测

// 把一个方法改成"永远返回 false / nil"。
// 返回类型从 encoding 取，参数个数从 selector 的冒号数量取 —— 不解析 encoding 里的参数部分，
// 因为那是结构化数据（含 { } " " 等），自己解析容易出错。
static BOOL adlab_neutralize_method(Class cls, SEL sel, BOOL isClassMethod)
{
    Method m = isClassMethod ? class_getClassMethod(cls, sel)
                             : class_getInstanceMethod(cls, sel);
    if (!m) return NO;

    char retbuf[8] = {0};
    method_getReturnType(m, retbuf, sizeof(retbuf));
    char ret = retbuf[0];

    BOOL intRet = (ret == 'c' || ret == 'B' || ret == 'i' || ret == 's' ||
                   ret == 'q' || ret == 'C' || ret == 'I' || ret == 'Q' ||
                   ret == 'l' || ret == 'L');
    BOOL objRet = (ret == '@' || ret == '#');
    if (!intRet && !objRet) return NO;

    NSUInteger nargs = [[NSStringFromSelector(sel)
                         componentsSeparatedByString:@":"] count];
    nargs = (nargs > 0) ? (nargs - 1) : 0;
    if (nargs > 4) return NO;

    IMP imp = NULL;
    if (intRet) {
        switch (nargs) {
            case 0: imp = imp_implementationWithBlock(^long (id _s) { return 0; }); break;
            case 1: imp = imp_implementationWithBlock(^long (id _s, id _a) { return 0; }); break;
            case 2: imp = imp_implementationWithBlock(^long (id _s, id _a, id _b) { return 0; }); break;
            case 3: imp = imp_implementationWithBlock(^long (id _s, id _a, id _b, id _c) { return 0; }); break;
            case 4: imp = imp_implementationWithBlock(^long (id _s, id _a, id _b, id _c, id _d) { return 0; }); break;
            default: break;
        }
    } else {
        switch (nargs) {
            case 0: imp = imp_implementationWithBlock(^id (id _s) { return nil; }); break;
            case 1: imp = imp_implementationWithBlock(^id (id _s, id _a) { return nil; }); break;
            case 2: imp = imp_implementationWithBlock(^id (id _s, id _a, id _b) { return nil; }); break;
            case 3: imp = imp_implementationWithBlock(^id (id _s, id _a, id _b, id _c) { return nil; }); break;
            case 4: imp = imp_implementationWithBlock(^id (id _s, id _a, id _b, id _c, id _d) { return nil; }); break;
            default: break;
        }
    }
    if (!imp) return NO;

    method_setImplementation(m, imp);
    return YES;
}

// 清掉一个类上所有 amI* 方法（类方法 + 实例方法）
static int adlab_clean_class(Class cls)
{
    if (!cls) return 0;
    int n = 0;

    // 类方法挂在 metaclass 上
    Class meta = object_getClass(cls);
    if (meta) {
        unsigned int cnt = 0;
        Method *list = class_copyMethodList(meta, &cnt);
        if (list) {
            for (unsigned int i = 0; i < cnt; i++) {
                NSString *nm = NSStringFromSelector(method_getName(list[i]));
                if ([nm hasPrefix:@"amI"]) {
                    if (adlab_neutralize_method(cls, method_getName(list[i]), YES)) n++;
                }
            }
            free(list);
        }
    }

    // 实例方法
    unsigned int cnt = 0;
    Method *list = class_copyMethodList(cls, &cnt);
    if (list) {
        for (unsigned int i = 0; i < cnt; i++) {
            NSString *nm = NSStringFromSelector(method_getName(list[i]));
            if ([nm hasPrefix:@"amI"]) {
                if (adlab_neutralize_method(cls, method_getName(list[i]), NO)) n++;
            }
        }
        free(list);
    }

    return n;
}

static BOOL adlab_class_name_interesting(const char *name)
{
    if (!name) return NO;
    static const char *frags[] = {
        "IOSSecuritySuite", "SecurityChecker", "Jailbreak",
        "Tamper", "FridaDetector", "ReverseEngineer", "AntiDebug",
        NULL
    };
    for (int i = 0; frags[i]; i++) {
        if (strstr(name, frags[i]) != NULL) return YES;
    }
    return NO;
}

static void adlab_install_stealth(void)
{
    @try {
        int total = objc_getClassList(NULL, 0);
        if (total <= 0) { ALOG(@"objc_getClassList 返回 0"); return; }

        Class *classes = (Class *)malloc(sizeof(Class) * (size_t)total);
        if (!classes) return;
        int real = objc_getClassList(classes, total);
        if (real <= 0) { free(classes); return; }

        int matched = 0;
        for (int i = 0; i < real; i++) {
            Class c = classes[i];
            const char *nm = class_getName(c);
            if (!adlab_class_name_interesting(nm)) continue;
            matched++;
            int n = adlab_clean_class(c);
            if (n > 0) {
                gStealthHits += n;
                ALOG(@"清掉 %s 上的 %d 个检测方法", nm, n);
            }
        }
        free(classes);

        ALOG(@"stealth 扫描完毕：类总数=%d 命中类=%d 清理方法=%d",
             real, matched, gStealthHits);

        if (matched == 0) {
            ALOG(@"没找到任何检测类 —— 可能已内联进主二进制，或本版本没带 IOSSecuritySuite");
        }
    } @catch (NSException *e) {
        ALOG(@"stealth 异常 %@", e.reason);
    }
}

#pragma mark - 原生侧观察（只记日志，不改行为）

static void (*g_o_showInspireAd_cls)(id, SEL, id) = NULL;
static void (*g_o_showInspireAd_inst)(id, SEL, id) = NULL;

static void adlab_showInspireAd_cls(id self, SEL _cmd, id json)
{
    NSString *s = [json isKindOfClass:[NSString class]] ? (NSString *)json : nil;
    ALOG(@"native +showInspireAd: %@",
         s ? (s.length > 120 ? [[s substringToIndex:120] stringByAppendingString:@"..."] : s)
           : @"(nil)");
    if (g_o_showInspireAd_cls) g_o_showInspireAd_cls(self, _cmd, json);
}

static void adlab_showInspireAd_inst(id self, SEL _cmd, id json)
{
    NSString *s = [json isKindOfClass:[NSString class]] ? (NSString *)json : nil;
    ALOG(@"native -showInspireAd: %@",
         s ? (s.length > 120 ? [[s substringToIndex:120] stringByAppendingString:@"..."] : s)
           : @"(nil)");
    if (g_o_showInspireAd_inst) g_o_showInspireAd_inst(self, _cmd, json);
}

static void adlab_install_native_observer(void)
{
    @try {
        Class cls = NSClassFromString(@"ViewController");
        if (!cls) { ALOG(@"ViewController 未找到"); return; }

        SEL sel = NSSelectorFromString(@"showInspireAd:");
        g_o_showInspireAd_cls =
            (void (*)(id, SEL, id))adlab_swizzle(cls, sel, (IMP)adlab_showInspireAd_cls, YES);
        if (g_o_showInspireAd_cls) ALOG(@"+[ViewController showInspireAd:] 已挂观察");

        g_o_showInspireAd_inst =
            (void (*)(id, SEL, id))adlab_swizzle(cls, sel, (IMP)adlab_showInspireAd_inst, NO);
        if (g_o_showInspireAd_inst) ALOG(@"-[ViewController showInspireAd:] 已挂观察");

        if (!g_o_showInspireAd_cls && !g_o_showInspireAd_inst) {
            ALOG(@"ViewController 上没有 showInspireAd:（类方法/实例方法都没有）");
        }
    } @catch (NSException *e) {
        ALOG(@"原生观察异常 %@", e.reason);
    }
}

#pragma mark - 悬浮 UI

// 关键：自定义 UIWindow，命中空白处返回 nil，
// 让触摸事件穿透到下面游戏的窗口。否则整个屏幕都点不动。
@interface AdlabWindow : UIWindow
@end

// 找一个可用的 UIWindowScene（iOS 13+）。取不到返回 nil，
// 调用方负责延时重试 —— 因为 constructor 跑在 main() 之前，
// 那时 UIApplication 的 connectedScenes 往往是空的。
static UIWindowScene *adlab_find_window_scene(void)
{
    if (@available(iOS 13.0, *)) {
        UIApplication *app = [UIApplication sharedApplication];
        if (!app) return nil;

        UIWindowScene *fallback = nil;
        for (UIScene *s in app.connectedScenes) {
            if (![s isKindOfClass:[UIWindowScene class]]) continue;
            UIWindowScene *ws = (UIWindowScene *)s;
            if (ws.activationState == UISceneActivationStateForegroundActive)
                return ws;                       // 首选：前台活跃
            if (!fallback) fallback = ws;        // 次选：任何 windowScene
        }
        return fallback;
    }
    return nil;                                  // iOS 12 及以下没有 UIScene
}

@interface AdlabBall : UIButton
@end

@interface AdlabPanel : UIView
@property (nonatomic, strong) UITextView *logView;
@property (nonatomic, strong) UILabel *statLabel;
@property (nonatomic, strong) UISwitch *forceSwitch;
@end

@interface AdlabOverlay : NSObject
@property (nonatomic, strong) AdlabWindow *win;
@property (nonatomic, strong) AdlabBall *ball;
@property (nonatomic, strong) AdlabPanel *panel;
+ (instancetype)shared;
- (void)install;
- (void)refresh;
@end

@implementation AdlabWindow
- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event
{
    UIView *v = [super hitTest:point withEvent:event];
    // 只有落在球或面板上的点击才由本窗口处理
    if (v == self) return nil;
    if (self.rootViewController && v == self.rootViewController.view) return nil;
    return v;
}
@end

@implementation AdlabBall
- (instancetype)initWithFrame:(CGRect)frame
{
    self = [super initWithFrame:frame];
    if (!self) return nil;
    self.backgroundColor = [UIColor colorWithRed:0.10 green:0.45 blue:0.95 alpha:0.93];
    self.layer.cornerRadius = frame.size.width / 2.0;
    self.layer.borderWidth = 1.5;
    self.layer.borderColor = [UIColor whiteColor].CGColor;
    self.layer.shadowColor = [UIColor blackColor].CGColor;
    self.layer.shadowOpacity = 0.4;
    self.layer.shadowRadius = 6;
    self.layer.shadowOffset = CGSizeMake(0, 2);
    [self setTitle:@"A" forState:UIControlStateNormal];
    self.titleLabel.font = [UIFont boldSystemFontOfSize:21];
    [self setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    return self;
}
@end

@implementation AdlabPanel
- (instancetype)initWithFrame:(CGRect)frame
{
    self = [super initWithFrame:frame];
    if (!self) return nil;

    self.backgroundColor = [UIColor colorWithWhite:0.06 alpha:0.96];
    self.layer.cornerRadius = 14;
    self.layer.borderWidth = 1;
    self.layer.borderColor = [UIColor colorWithWhite:1 alpha:0.22].CGColor;
    self.clipsToBounds = YES;

    CGFloat w = frame.size.width;

    UILabel *title = [[UILabel alloc] initWithFrame:CGRectMake(14, 10, w - 60, 24)];
    title.text = @"adlab · 悬浮助手";
    title.textColor = [UIColor whiteColor];
    title.font = [UIFont boldSystemFontOfSize:16];
    [self addSubview:title];

    UIButton *close = [UIButton buttonWithType:UIButtonTypeSystem];
    close.frame = CGRectMake(w - 46, 6, 38, 30);
    [close setTitle:@"×" forState:UIControlStateNormal];
    close.titleLabel.font = [UIFont systemFontOfSize:25];
    [close setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    [close addTarget:self action:@selector(onClose)
    forControlEvents:UIControlEventTouchUpInside];
    [self addSubview:close];

    UILabel *swLab = [[UILabel alloc] initWithFrame:CGRectMake(14, 44, w - 96, 26)];
    swLab.text = @"强制奖励（改写 JS 锚点）";
    swLab.textColor = [UIColor colorWithWhite:0.92 alpha:1];
    swLab.font = [UIFont systemFontOfSize:14];
    [self addSubview:swLab];

    _forceSwitch = [[UISwitch alloc] initWithFrame:CGRectMake(w - 66, 41, 52, 30)];
    _forceSwitch.on = gForceReward;
    [_forceSwitch addTarget:self action:@selector(onToggle)
           forControlEvents:UIControlEventValueChanged];
    [self addSubview:_forceSwitch];

    _statLabel = [[UILabel alloc] initWithFrame:CGRectMake(14, 76, w - 28, 52)];
    _statLabel.numberOfLines = 4;
    _statLabel.textColor = [UIColor colorWithWhite:0.62 alpha:1];
    _statLabel.font = [UIFont fontWithName:@"Menlo" size:10];
    [self addSubview:_statLabel];

    _logView = [[UITextView alloc] initWithFrame:
                CGRectMake(10, 132, w - 20, frame.size.height - 142)];
    _logView.backgroundColor = [UIColor colorWithWhite:0 alpha:0.6];
    _logView.textColor = [UIColor colorWithRed:0.58 green:1.0 blue:0.70 alpha:1];
    _logView.font = [UIFont fontWithName:@"Menlo" size:9.5];
    _logView.editable = NO;
    _logView.layer.cornerRadius = 8;
    _logView.textContainerInset = UIEdgeInsetsMake(6, 6, 6, 6);
    [self addSubview:_logView];

    return self;
}

- (void)onClose { [AdlabOverlay shared].panel.hidden = YES; }

- (void)onToggle
{
    gForceReward = self.forceSwitch.on;
    ALOG(@"force-reward = %@（重进 app 生效）", gForceReward ? @"ON" : @"OFF");
    [[AdlabOverlay shared] refresh];
}
@end

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
    if (self.win) return;

    // UIWindow 必须在主线程创建
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{ [self install]; });
        return;
    }

    @try {
        adlab_install_native_observer();

        // iOS 13+ 起，UIWindow 不绑定到 UIScene 就完全不会被显示。
        // 这是「注入成功、不闪退、但看不到悬浮球」的第一嫌疑，必须先处理。
        UIWindowScene *scene = adlab_find_window_scene();
        if (!scene) {
            if (++gInstallRetry <= 50) {           // 50 * 200ms = 10s
                ALOG(@"windowScene 未就绪 → 200ms 后重试 (%d/50)", gInstallRetry);
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                                             (int64_t)(0.2 * NSEC_PER_SEC)),
                               dispatch_get_main_queue(), ^{ [self install]; });
            } else {
                ALOG(@"windowScene 始终未就绪，放弃安装 UI（dylib 已加载，补丁逻辑不受影响）");
            }
            return;
        }
        ALOG(@"windowScene 就位：%@", NSStringFromClass([scene class]));

        CGRect scr = [UIScreen mainScreen].bounds;

        self.win = [[AdlabWindow alloc] initWithFrame:scr];
        // ← 关键：不设 windowScene = 永不显示（iOS 13+ 强制要求绑场景）
        if (@available(iOS 13.0, *)) {
            self.win.windowScene = scene;
        }
        self.win.windowLevel = UIWindowLevelAlert + 100;
        self.win.backgroundColor = [UIColor clearColor];
        self.win.rootViewController = [UIViewController new];
        self.win.hidden = NO;

        CGFloat bs = 52;
        self.ball = [[AdlabBall alloc] initWithFrame:
                     CGRectMake(scr.size.width - bs - 12, 118, bs, bs)];
        [self.ball addTarget:self action:@selector(onBallTap)
            forControlEvents:UIControlEventTouchUpInside];
        UIPanGestureRecognizer *pan =
            [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(onPan:)];
        [self.ball addGestureRecognizer:pan];
        [self.win addSubview:self.ball];

        CGFloat pw = MIN(344.0, scr.size.width - 28);
        CGFloat ph = MIN(440.0, scr.size.height - 170);
        self.panel = [[AdlabPanel alloc] initWithFrame:
                      CGRectMake((scr.size.width - pw) / 2,
                                 (scr.size.height - ph) / 2, pw, ph)];
        self.panel.hidden = YES;
        [self.win addSubview:self.panel];

        [self refresh];
        ALOG(@"悬浮球已就位 · 点 A 打开面板");
    } @catch (NSException *e) {
        ALOG(@"UI 安装异常 %@", e.reason);
    }
}

- (void)onBallTap
{
    self.panel.hidden = !self.panel.hidden;
    if (!self.panel.hidden) [self refresh];
}

- (void)onPan:(UIPanGestureRecognizer *)g
{
    CGPoint d = [g translationInView:self.win];
    CGPoint c = self.ball.center;
    self.ball.center = CGPointMake(c.x + d.x, c.y + d.y);
    [g setTranslation:CGPointMake(0, 0) inView:self.win];
}

- (void)refresh
{
    self.panel.forceSwitch.on = gForceReward;
    self.panel.statLabel.text = [NSString stringWithFormat:
        @"disk=%d  hooks=%d\npatched=%d  reads=%d\nNSData=%d  NSString=%d  FM=%d\nstealth=%d",
        gDiskPatched ? 1 : 0, gHooksInstalled ? 1 : 0,
        gPatchHits, gReadHits,
        gViaNSData, gViaNSString, gViaFileMgr,
        gStealthHits];

    [gLogLock lock];
    NSMutableString *s = [NSMutableString string];
    for (NSString *l in [gLogLines reverseObjectEnumerator]) {
        [s appendString:l];
        [s appendString:@"\n"];
    }
    [gLogLock unlock];
    self.panel.logView.text = s;
}

@end

#pragma mark - 入口

__attribute__((constructor))
static void adlab_init(void)
{
    @autoreleasepool {
        adlab_log_init();
        ALOG(@"==== dylib loaded  pid=%d ====", getpid());

        // 1) 首选：磁盘直改。成功就不装任何 hook。
        gDiskPatched = adlab_patch_on_disk();

        // 2) 兜底：只在磁盘直改失败时装 swizzle
        if (!gDiskPatched) {
            ALOG(@"磁盘直改不可用 → 启用读通道 swizzle");
            adlab_install_read_hooks();
        }

        // 3) 反检测
        adlab_install_stealth();

        // 4) UI 延后 1.0s（也监听 didFinishLaunching 兜底，install 是幂等的）
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            [[AdlabOverlay shared] install];
        });

        [[NSNotificationCenter defaultCenter]
            addObserverForName:UIApplicationDidFinishLaunchingNotification
                        object:nil
                         queue:[NSOperationQueue mainQueue]
                    usingBlock:^(__unused NSNotification *n) {
            [[AdlabOverlay shared] install];
        }];

        ALOG(@"init 完成 disk=%d hooks=%d stealth=%d",
             gDiskPatched, gHooksInstalled, gStealthHits);
    }
}
