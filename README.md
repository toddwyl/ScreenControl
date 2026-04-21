<p align="center">
  <img src="assets/readme-icon.png" width="128" height="128" alt="KeepAgentAwake app icon" />
</p>

<h1 align="center">KeepAgentAwake</h1>

<p align="center">
  <a href="README_zh.md">简体中文</a>
</p>

<p align="center">
  <strong>Native Swift / SwiftUI menu bar app</strong> for macOS: prevent idle system sleep when you need it, with optional idle display sleep, keyboard backlight dimming, and lid-close power options.
</p>

<p align="center">
  <a href="https://github.com/toddwyl/KeepAgentAwake/releases">Releases</a>
  ·
  <a href="#building-from-source">Building from source</a>
</p>

---

## Overview

KeepAgentAwake lives in the **menu bar** (`LSUIElement`, no Dock icon) and offers a **“never sleep”** toggle plus an optional settings window. It fits long downloads, builds, demos, or any case where you want to avoid automatic sleep but still save power by turning the display off when idle.

> [!NOTE]
> The app uses **IOKit power assertions**, `caffeinate`, and `pmset`. If you enable lid-related options that use `pmset disablesleep`, an **administrator password is requested only when the system state must actually change**—the app reads the current `pmset` state first, then decides whether to elevate.

---

## Features

| Capability | Description |
|------------|-------------|
| **Never sleep** | Prevents **idle** system sleep; can be combined with “sleep display when idle” to reduce long-term full-brightness flicker. |
| **Idle display off** | After N seconds/minutes of no input, turn displays off (or set to “never”); input keeps the screen on. |
| **Keyboard backlight** | Optionally simulates repeated “brightness down” keys when idle triggers display sleep (effect varies by hardware and OS). |
| **Lid / power** | Optional `pmset -a disablesleep` path for lid-close behavior (requires admin approval; see in-app text). |
| **Shortcuts** | **⌘⇧P** toggles never-sleep; **⌘⌃⎋** emergency-off while active. |
| **Menu bar** | **Left click:** if a main window exists, show/hide it; otherwise toggle never-sleep. **Right click:** menu. |

The status item reflects the current mode (e.g. system default vs never-sleep) and can show elapsed time.

---

## Requirements

- **macOS 13** or later (matches `LSMinimumSystemVersion` in `Info.plist`)
- **Xcode / Swift command-line tools** (only for building locally)

---

## Building from source

You need Swift and `swiftc` (Xcode Command Line Tools).

```bash
git clone https://github.com/toddwyl/KeepAgentAwake.git
cd KeepAgentAwake
chmod +x build.sh
./build.sh
```

The app bundle is written to `build/KeepAgentAwake.app`:

```bash
open build/KeepAgentAwake.app
```

You can copy `KeepAgentAwake.app` to `/Applications/` if you like.

> [!TIP]
> `build.sh` runs `tools/RenderAppIcon.swift` for the icon and compiles `KeepAgentAwakeMain.swift`, `KeepAgentAwakeViews.swift`, and `KeepAgentAwakeDelegate.swift`. No CocoaPods or SPM packages are required.

---

## Permissions & privacy

- **Automation / Apple Events**: Dimming keyboard backlight may trigger system prompts for controlling other apps or automation—follow what macOS shows.
- **Administrator password**: AppleScript elevation runs **only when** changing `disablesleep` (or similar) is required to match your settings; the app prefers reading power settings first.
- If you used the older **ScreenControl** build, the first launch **migrates** `ScreenControl.*` UserDefaults keys to `KeepAgentAwake.*` when the new key is missing, so preferences are preserved.

---

## Repository layout

```
KeepAgentAwake/
├── KeepAgentAwakeMain.swift     # SwiftUI @main entry
├── KeepAgentAwakeViews.swift    # Main window UI
├── KeepAgentAwakeDelegate.swift # AppDelegate, power & menu bar
├── Info.plist
├── build.sh
├── tools/
│   └── RenderAppIcon.swift      # Generates AppIcon at build time
└── assets/
    └── readme-icon.png          # Icon used in README
```

---

## Uninstall

Remove `KeepAgentAwake.app` from Applications. If you granted Accessibility, Automation, or other permissions, revoke them under **System Settings → Privacy & Security** as needed.
