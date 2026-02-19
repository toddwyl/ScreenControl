#!/bin/bash
# 构建 ScreenControl v2.1

set -e

echo "🔨 开始构建 ScreenControl v2.1..."

APP_NAME="ScreenControl"
BUILD_DIR="build"
APP_DIR="$BUILD_DIR/$APP_NAME.app"
CONTENTS_DIR="$APP_DIR/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
RESOURCES_DIR="$CONTENTS_DIR/Resources"

# 清理旧的构建
rm -rf "$BUILD_DIR"

# 创建应用目录结构
mkdir -p "$MACOS_DIR"
mkdir -p "$RESOURCES_DIR"

# 编译 Swift 代码
echo "📦 编译 Swift 代码..."
swiftc -O -o "$MACOS_DIR/$APP_NAME" \
    -framework Cocoa \
    -framework UserNotifications \
    -framework IOKit \
    -parse-as-library \
    ScreenControlApp.swift

# 复制 Info.plist
cp Info.plist "$CONTENTS_DIR/"

# 创建 PkgInfo
echo "APPL????" > "$CONTENTS_DIR/PkgInfo"

# 检查编译结果
if [ -f "$MACOS_DIR/$APP_NAME" ]; then
    SIZE=$(du -h "$MACOS_DIR/$APP_NAME" | awk '{print $1}')
    echo ""
    echo "✅ 构建完成！"
    echo "📍 应用位置: $APP_DIR"
    echo "📦 二进制大小: $SIZE"
    echo ""
    echo "🚀 运行方式:"
    echo "   open $APP_DIR"
    echo ""
    echo "📋 安装到 /Applications:"
    echo "   cp -r $APP_DIR /Applications/"
    echo "   open /Applications/$APP_NAME.app"
    echo ""
    echo "⌨️ 快捷键:"
    echo "   ⌘⇧P  — 切换永不熄屏模式"
    echo "   ⌘⇧L  — 切换熄屏/正常模式"
    echo "   ⌘⌃⎋  — 紧急退出熄屏模式"
else
    echo "❌ 构建失败！"
    exit 1
fi
