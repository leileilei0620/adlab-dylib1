#!/usr/bin/env bash
# ============================================================================
#  编译 AdlabOverlay dylib （需要在 macOS 上跑）
#
#  两种平台都能出这个 dylib：
#    1) 越狱机 / Mac 上装了 theos   -> 用 theos 的 iphoneos toolchain
#    2) 只有 Xcode                -> 用 xcrun -sdk iphoneos clang（下面的默认路径）
#
#  TrollFools 吃的是「未签名 dylib」，所以不需要 ldid / codesign，
#  但 dylib 的 platform 必须是 iphoneos（不能是 iphonesimulator / macosx）。
# ============================================================================
set -euo pipefail

SDK="${SDK:-$(xcrun --sdk iphoneos --show-sdk-path)}"
MIN="${MIN:-12.0}"                 # 目标机 iOS 15.3.1，12.0 起兼容最广
ARCH="${ARCH:-arm64}"              # iPhone 11 (A13) = arm64
OUT="${OUT:-build/libadlab.dylib}"

SRC="AdlabOverlay.m"
# 必须显式链 CoreGraphics：CGPointZero / CGRectZero 这类是 extern const 变量，
# 不是内联函数，不链就会报 Undefined symbols "_CGPointZero"。
# UIKit 会传递链接 CoreGraphics 对 app 有效，但对 -dynamiclib 的未定义符号
# 解析不保证能借道，所以显式列出来。
FRAMEWORKS="-framework UIKit -framework Foundation -framework CoreGraphics"
# 不再单独写 -lobjc：Foundation 已经链入 libobjc，重复写会让 ld 报
# "ignoring duplicate libraries: '-lobjc'"（无害但干扰日志判读）。

mkdir -p "$(dirname "$OUT")"

echo "==> SDK       : $SDK"
echo "==> min iOS   : $MIN"
echo "==> arch      : $ARCH"
echo "==> output    : $OUT"

xcrun --sdk iphoneos clang \
    -arch "$ARCH" \
    -miphoneos-version-min="$MIN" \
    -isysroot "$SDK" \
    -dynamiclib \
    -fobjc-arc \
    -O2 \
    -fvisibility=hidden \
    -Wl,-install_name,@executable_path/Frameworks/libadlab.dylib \
    -Wl,-dead_strip \
    -Wno-deprecated-declarations \
    $FRAMEWORKS \
    -o "$OUT" \
    "$SRC"

echo
echo "==> 产出"
ls -l "$OUT"
file "$OUT" || true

echo
echo "==> 依赖"
otool -L "$OUT" || true

echo
echo "==> 架构"
lipo -info "$OUT" || true

echo
echo "==> 本地符号（-fvisibility=hidden 下业务符号是 local，用 nm -a 看）"
nm -a "$OUT" 2>/dev/null | grep -i adlab | head -40 || true

echo
echo "==> 加载命令"
otool -l "$OUT" | grep -E 'LC_ID_DYLIB|LC_RPATH|__interpose' || true

echo
echo "==> 锚点字符串（必须出现 82 字节的 OLD 原文）"
strings -a "$OUT" | grep -c 'showInspireAd:' || echo "0  <-- 异常：锚点缺失，补丁不可能命中"

echo
echo "完成。把 $OUT 拷到设备后用 TrollFools 注入 com.maobei.yydiary"
echo "注意：v2 已彻底删除 __interpose（v1 崩溃根因），上面若出现 __interpose 段说明编到了旧源码。"
