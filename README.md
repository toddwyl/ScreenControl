<p align="center">
  <img src="assets/readme-icon.png" width="128" height="128" alt="KeepAgentAwake app icon" />
</p>

<h1 align="center">KeepAgentAwake</h1>

<p align="center">
  <strong>原生 Swift / SwiftUI 菜单栏工具</strong>：在需要时防止 Mac 因空闲进入睡眠，并支持可配置的空闲熄屏、键盘背光调节与合盖相关电源选项。
</p>

<p align="center">
  <a href="https://github.com/toddwyl/KeepAgentAwake/releases">Releases</a>
  ·
  <a href="#从源码构建">从源码构建</a>
</p>

---

## 概览

KeepAgentAwake 以**菜单栏图标**为主界面（`LSUIElement`，不占用 Dock），提供「**永不休眠**」开关与可选设置页。适合长时间下载、编译、演示或需要避免系统自动睡眠、又希望空闲时能关屏省电的场景。

> [!NOTE]
> 本应用通过 **IOKit 电源断言**、`caffeinate`、`pmset` 等系统能力工作；合盖相关选项若启用 `pmset disablesleep`，**仅在系统状态需要改变时**才会请求管理员密码（会先读取当前 `pmset` 状态再决定是否提权执行）。

---

## 功能

| 能力 | 说明 |
|------|------|
| **永不休眠** | 防止系统因**空闲**进入睡眠；可与「空闲后熄屏」组合，减轻长期强制亮屏带来的闪烁。 |
| **空闲熄屏** | 可设定空闲若干秒/分钟后关闭显示器（或设为「永不」）；有操作时保持亮屏。 |
| **键盘背光** | 在空闲触发熄屏时，可自动模拟多次「背光减小」键（效果因机型与系统策略而异）。 |
| **合盖电源** | 可选通过 `pmset -a disablesleep` 影响合盖行为（需管理员授权，详见应用内说明）。 |
| **快捷键** | **⌘⇧P** 切换永不休眠；**⌘⌃⎋** 在开启时紧急关闭永不休眠。 |
| **菜单栏** | 左键：若存在主窗口则在显示/隐藏主窗口间切换，否则切换永不休眠；右键打开菜单。 |

状态栏图标会随模式变化（例如「系统默认」与「永不休眠」等），并可选择在状态栏显示已运行时长。

---

## 系统要求

- **macOS 13** 或更高（与 `Info.plist` 中 `LSMinimumSystemVersion` 一致）
- **Xcode / Swift 命令行工具**（仅本地编译时需要）

---

## 从源码构建

需要已安装 Swift 与 `swiftc`（Xcode Command Line Tools）。

```bash
git clone https://github.com/toddwyl/KeepAgentAwake.git
cd KeepAgentAwake
chmod +x build.sh
./build.sh
```

构建成功后，应用位于 `build/KeepAgentAwake.app`：

```bash
open build/KeepAgentAwake.app
```

也可将 `KeepAgentAwake.app` 拷贝到 `/Applications/` 使用。

> [!TIP]
> `build.sh` 会调用 `tools/RenderAppIcon.swift` 生成图标并编译 `KeepAgentAwakeMain.swift`、`KeepAgentAwakeViews.swift`、`KeepAgentAwakeDelegate.swift`，无需 CocoaPods / SPM 依赖。

---

## 权限与隐私

- **自动化 / Apple Events**：调暗键盘背光等功能可能触发系统对「控制其他应用」或相关自动化权限的提示，请以系统实际对话框为准。
- **管理员密码**：仅在为使系统 `disablesleep` 等状态与选项一致而**必须**修改时，通过 AppleScript 请求提权；应用会尽量先读取当前电源设置再决定是否弹窗。
- 若曾使用旧版 **ScreenControl**，首次启动会从 `ScreenControl.*` 的 UserDefaults 键**迁移**到 `KeepAgentAwake.*`（新键不存在时复制），避免丢失偏好设置。

---

## 仓库结构

```
KeepAgentAwake/
├── KeepAgentAwakeMain.swift    # SwiftUI @main 入口
├── KeepAgentAwakeViews.swift   # 主窗口界面
├── KeepAgentAwakeDelegate.swift # AppDelegate、电源与菜单栏逻辑
├── Info.plist
├── build.sh
├── tools/
│   └── RenderAppIcon.swift     # 构建时生成 AppIcon
└── assets/
    └── readme-icon.png         # README 用图标
```

---

## 卸载

从「应用程序」中移除 `KeepAgentAwake.app` 即可。若曾在系统设置中为该应用授予过辅助功能、自动化等权限，可在 **系统设置 → 隐私与安全性** 中按需移除。
