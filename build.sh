#!/usr/bin/env bash
# AdlabKit 构建脚本 —— 通用 iOS 广告加速 dylib
# 用法: ./build.sh        （在 macOS 上，需 Xcode Command Line Tools）
#       SDK=/path ./build.sh
set -euo pipefail

SDK="${SDK:-$(xcrun --sdk iphoneos --show-sdk-path)}"
SRC="AdlabKit.m"
OUT="build"
DYLIB="$OUT/libadlab.dylib"

mkdir -p "$OUT"

echo "== 环境 =="
echo "SDK   $SDK"
echo "SRC   $SRC ($(wc -c < "$SRC" | tr -d ' ') B)"
echo "ARCH  arm64"
echo

# 依赖：UIKit/Foundation 基础，QuartzCore（CADisplayLink 的 layer）、
#      AVFoundation（AVPlayer setRate:）、CoreMedia（时间换算）、
#      CoreGraphics（CGPointZero 已被 CGPointMake 取代，但仍需链接）
FRAMEWORKS="-framework UIKit -framework Foundation -framework QuartzCore \
-framework AVFoundation -framework CoreMedia -framework CoreGraphics"

echo "== 编译 =="
xcrun --sdk iphoneos clang \
    -arch arm64 \
    -miphoneos-version-min=12.0 \
    -isysroot "$SDK" \
    -dynamiclib \
    -O2 \
    -fobjc-arc \
    -fmodules \
    -Wall -Wextra \
    -Wno-unused-parameter \
    -Wno-deprecated-declarations \
    -install_name "@executable_path/Frameworks/libadlab.dylib" \
    $FRAMEWORKS \
    -o "$DYLIB" \
    "$SRC"

echo
echo "== 产物 =="
ls -l "$DYLIB"
file "$DYLIB"
echo
echo "== LC_ID_DYLIB（必须是 @executable_path/Frameworks/，否则 TrollFools 当 @rpath 处理会静默失败）=="
otool -l "$DYLIB" | grep -A2 LC_ID_DYLIB | tail -2 || true
echo
echo "== LC_RPATH（应为空；有 @rpath 说明 install_name 配错了）=="
otool -l "$DYLIB" | grep -c LC_RPATH || echo "0"
echo
echo "== 符号 =="
nm -a "$DYLIB" 2>/dev/null | grep -i 'adlab\|kswizzle\|hook_Double' | head -40 || true
echo
echo "== 必备 selector 必须在 strings 里 =="
for sel in \
    "scheduledTimerWithTimeInterval:target:selector:userInfo:repeats:" \
    "displayLinkWithTarget:selector:" \
    "setRate:" \
    "sendEvent:" \
    "timeIntervalSinceReferenceDate"
do
    n=$(strings -a "$DYLIB" | grep -c -- "$sel" || true)
    if [ "$n" -gt 0 ]; then
        echo "  OK   $sel"
    else
        echo "  FAIL $sel 缺失"
        exit 1
    fi
done
echo
echo "== 连接信息 =="
otool -L "$DYLIB"
echo
echo "构建完成: $DYLIB"
