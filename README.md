# ScreenControl

一个让 Mac 电脑一键熄屏但不休眠，同时关闭键盘背光的原生应用。支持两种模式：熄屏模式和永不熄屏模式。

## 功能特性

### ☕ 永不熄屏模式
- 保持屏幕常亮不熄灭
- 防止系统自动休眠
- 适合长时间阅读、监控、演示等场景

### 🌙 熄屏模式
- 关闭显示器 + 键盘背光
- 锁定键盘输入（防止误触唤醒）
- 系统保持运行（不休眠）
- 自动重新熄屏（屏幕意外亮起时）

### ⌨️ 快捷键
- **⌘⇧P** — 切换永不熄屏模式（全局有效）
- **⌘⇧L** — 切换熄屏/正常模式（全局有效）
- **⌘⌃⎋** — 紧急退出熄屏模式
- 左键点击状态栏 — 切换模式
- 右键点击状态栏 — 打开菜单

### 📊 状态栏图标
- **☀️** — 正常模式
- **☕** — 永不熄屏模式
- **🌙** — 熄屏模式

## 系统要求

- macOS 12.0 或更高版本
- 需要 Xcode 命令行工具（用于编译）

## 依赖项

本项目使用原生 Swift 开发，依赖以下 macOS 系统框架：

- **Cocoa** — macOS 应用 UI 框架
- **UserNotifications** — 系统通知
- **IOKit** — 电源管理（防止系统休眠）

无需安装第三方库。

## 安装方法

### 方式一：从源码编译（推荐）

```bash
# 1. 克隆仓库
git clone https://github.com/YOUR_USERNAME/ScreenControl.git
cd ScreenControl

# 2. 编译应用
chmod +x build.sh
./build.sh

# 3. 安装到应用程序文件夹
cp -r build/ScreenControl.app /Applications/

# 4. 运行应用
open /Applications/ScreenControl.app
```

### 方式二：手动编译

```bash
# 创建应用目录结构
mkdir -p build/ScreenControl.app/Contents/MacOS
mkdir -p build/ScreenControl.app/Contents/Resources

# 编译 Swift 代码
swiftc -O -o build/ScreenControl.app/Contents/MacOS/ScreenControl \
    -framework Cocoa \
    -framework UserNotifications \
    -framework IOKit \
    -parse-as-library \
    ScreenControlApp.swift

# 复制配置文件
cp Info.plist build/ScreenControl.app/Contents/
echo "APPL????" > build/ScreenControl.app/Contents/PkgInfo

# 运行
open build/ScreenControl.app
```

### 方式三：复制到 /Applications

编译完成后，直接复制到应用程序文件夹：

```bash
cp -r build/ScreenControl.app /Applications/
```

## 首次使用

### 1. 授予辅助功能权限

**键盘锁定功能需要辅助功能权限：**

1. 打开 **系统设置** → **隐私与安全** → **辅助功能**
2. 点击 **+** 按钮
3. 选择 **ScreenControl** 应用并启用

### 2. 添加到登录项（可选）

让 ScreenControl 随系统启动：

1. 打开 **系统设置** → **通用** → **登录项**
2. 点击 **+** 按钮
3. 选择 **ScreenControl.app**

## 使用场景

- **下载大文件时** — 熄屏模式，让 Mac 安静工作
- **编译、渲染等长时间任务** — 熄屏模式，节省电量
- **防止猫咪踩键盘捣乱** — 熄屏模式，锁定键盘
- **长时间阅读/监控/演示** — 永不熄屏模式

## 设置选项

右键点击状态栏图标打开菜单，可以调整：

- **🔒 锁定键盘输入** — 拦截所有键盘输入（需要辅助功能权限）
- **🔄 自动重新熄屏** — 屏幕意外唤醒后自动关闭
- **⏱ 显示计时器** — 状态栏显示运行时长

## 安全说明

- 键盘锁定仅在 ScreenControl 运行时有效
- 如果应用意外退出，键盘自动恢复正常
- 鼠标始终可用，可点击状态栏退出

## 文件说明

```
ScreenControl/
├── ScreenControlApp.swift    # 主程序源码
├── Info.plist                # 应用配置
├── build.sh                  # 编译脚本
└── README.md                 # 本文件
```

## 卸载

```bash
# 删除应用
rm -rf /Applications/ScreenControl.app

# 删除辅助功能权限（可选）
# 系统设置 → 隐私与安全 → 辅助功能 → 移除 ScreenControl
```

## License

MIT License

## 版本历史

- **v2.1** — 新增永不熄屏模式，优化键盘锁定
- **v2.0** — 原生 Swift 重写，支持键盘锁定
- **v1.0** — Python 原型版本

---

Made with ❤️ for Mac users
