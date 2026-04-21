#!/bin/bash
# 构建 KeepAgentAwake（SwiftUI 窗口 + 菜单栏 + App 图标）

set -e

echo "🔨 开始构建 KeepAgentAwake…"

APP_NAME="KeepAgentAwake"
BUILD_DIR="build"
APP_DIR="$BUILD_DIR/$APP_NAME.app"
CONTENTS_DIR="$APP_DIR/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
RESOURCES_DIR="$CONTENTS_DIR/Resources"
ICON_SRC="$BUILD_DIR/AppIcon_1024.png"
ICONSET="$BUILD_DIR/AppIcon.iconset"

rm -rf "$BUILD_DIR"
mkdir -p "$MACOS_DIR"
mkdir -p "$RESOURCES_DIR"

echo "🎨 生成应用图标…"
swift tools/RenderAppIcon.swift "$ICON_SRC"

mkdir -p "$ICONSET"
sips -z 16 16 "$ICON_SRC" --out "$ICONSET/icon_16x16.png" >/dev/null
sips -z 32 32 "$ICON_SRC" --out "$ICONSET/icon_16x16@2x.png" >/dev/null
sips -z 32 32 "$ICON_SRC" --out "$ICONSET/icon_32x32.png" >/dev/null
sips -z 64 64 "$ICON_SRC" --out "$ICONSET/icon_32x32@2x.png" >/dev/null
sips -z 128 128 "$ICON_SRC" --out "$ICONSET/icon_128x128.png" >/dev/null
sips -z 256 256 "$ICON_SRC" --out "$ICONSET/icon_128x128@2x.png" >/dev/null
sips -z 256 256 "$ICON_SRC" --out "$ICONSET/icon_256x256.png" >/dev/null
sips -z 512 512 "$ICON_SRC" --out "$ICONSET/icon_256x256@2x.png" >/dev/null
sips -z 512 512 "$ICON_SRC" --out "$ICONSET/icon_512x512.png" >/dev/null
sips -z 1024 1024 "$ICON_SRC" --out "$ICONSET/icon_512x512@2x.png" >/dev/null

iconutil -c icns "$ICONSET" -o "$RESOURCES_DIR/AppIcon.icns"

echo "📦 编译 Swift…"
swiftc -O -o "$MACOS_DIR/$APP_NAME" \
    -framework Cocoa \
    -framework SwiftUI \
    -framework Combine \
    -framework UserNotifications \
    -framework IOKit \
    -parse-as-library \
    KeepAgentAwakeMain.swift \
    KeepAgentAwakeViews.swift \
    KeepAgentAwakeDelegate.swift

cp Info.plist "$CONTENTS_DIR/"
echo "APPL????" > "$CONTENTS_DIR/PkgInfo"

if [ -f "$MACOS_DIR/$APP_NAME" ]; then
    SIZE=$(du -h "$MACOS_DIR/$APP_NAME" | awk '{print $1}')
    echo ""
    echo "✅ 构建完成！"
    echo "📍 应用位置: $APP_DIR"
    echo "📦 二进制大小: $SIZE"
    echo ""
    echo "🚀 运行: open \"$APP_DIR\""
else
    echo "❌ 构建失败！"
    exit 1
fi
