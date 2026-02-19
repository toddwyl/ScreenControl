import Cocoa
import UserNotifications
import IOKit.pwr_mgt

// ─────────────────────────────────────────────
// MARK: - CGEventTap C Callback
// ─────────────────────────────────────────────
func keyboardTapCallback(
    proxy: CGEventTapProxy,
    type: CGEventType,
    event: CGEvent,
    refcon: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    guard let refcon = refcon else { return Unmanaged.passRetained(event) }
    let app = Unmanaged<AppDelegate>.fromOpaque(refcon).takeUnretainedValue()
    return app.processKeyboardEvent(proxy: proxy, type: type, event: event)
}

// ─────────────────────────────────────────────
// MARK: - AppDelegate
// ─────────────────────────────────────────────
@main
class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {

    // MARK: - Static main (AppKit entry)
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.run()
    }

    // ── UI ──
    private var statusItem: NSStatusItem!

    // ── State ──
    private(set) var isScreenOff = false
    private(set) var isPreventSleep = false  // 永不熄屏模式
    private var startTime: Date?

    // ── Preferences ──
    private var blockKeyboard = true
    private var autoReSleep  = true
    private var showTimer    = true

    // ── Sleep prevention ──
    private var assertionID: IOPMAssertionID = 0
    private var hasAssertion = false
    private var caffeinateProcess: Process?

    // ── Prevent display sleep (永不熄屏) ──
    private var preventDisplayAssertionID: IOPMAssertionID = 0
    private var hasPreventDisplayAssertion = false
    private var preventDisplayCaffeinateProcess: Process?

    // ── Keyboard blocking ──
    private var eventTap: CFMachPort?
    private var tapRunLoopSource: CFRunLoopSource?

    // ── Timers ──
    private var uiTimer: Timer?
    private var reSleepTimer: Timer?

    // ── Global hotkey ──
    private var globalMonitor: Any?
    private var localMonitor: Any?

    // ═══════════════════════════════════════════
    // MARK: - App Lifecycle
    // ═══════════════════════════════════════════

    func applicationDidFinishLaunching(_ notification: Notification) {
        setupNotifications()
        setupStatusBar()
        setupGlobalHotkey()
        print("🚀 ScreenControl v2.1 已启动")
    }

    func applicationWillTerminate(_ notification: Notification) {
        cleanup()
    }

    // ═══════════════════════════════════════════
    // MARK: - Setup
    // ═══════════════════════════════════════════

    private func setupNotifications() {
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        center.requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    private func setupStatusBar() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        guard let button = statusItem.button else { return }
        updateIcon()
        button.action = #selector(onStatusBarClick(_:))
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])
    }

    private func setupGlobalHotkey() {
        // ⌘⇧L  — toggle screen-off mode (when NOT intercepted by event tap)
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            self?.handleHotkeyEvent(event)
        }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if self?.handleHotkeyEvent(event) == true { return nil }
            return event
        }
    }

    @discardableResult
    private func handleHotkeyEvent(_ event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        // ⌘⇧L  (keyCode 37 = L)
        if flags.contains([.command, .shift]) && event.keyCode == 37 {
            DispatchQueue.main.async { self.toggleMode() }
            return true
        }
        // ⌘⇧P  (keyCode 35 = P) - 永不熄屏
        if flags.contains([.command, .shift]) && event.keyCode == 35 {
            DispatchQueue.main.async { self.togglePreventSleepMode() }
            return true
        }
        return false
    }

    // ═══════════════════════════════════════════
    // MARK: - Status Bar UI
    // ═══════════════════════════════════════════

    private func updateIcon() {
        guard let button = statusItem.button else { return }
        if isScreenOff {
            if showTimer, let start = startTime {
                let secs = Int(Date().timeIntervalSince(start))
                let h = secs / 3600
                let m = (secs % 3600) / 60
                let s = secs % 60
                button.title = h > 0
                    ? String(format: "🌙 %d:%02d:%02d", h, m, s)
                    : String(format: "🌙 %d:%02d", m, s)
            } else {
                button.title = "🌙"
            }
        } else if isPreventSleep {
            // 永不熄屏模式 - 显示咖啡杯图标
            if showTimer, let start = startTime {
                let secs = Int(Date().timeIntervalSince(start))
                let h = secs / 3600
                let m = (secs % 3600) / 60
                let s = secs % 60
                button.title = h > 0
                    ? String(format: "☕ %d:%02d:%02d", h, m, s)
                    : String(format: "☕ %d:%02d", m, s)
            } else {
                button.title = "☕"
            }
        } else {
            button.title = "☀️"
        }
    }

    @objc private func onStatusBarClick(_ sender: NSStatusBarButton) {
        guard let event = NSApp.currentEvent else { return }
        if event.type == .rightMouseUp {
            showContextMenu()
        } else {
            // 左键点击: 在三种模式间切换
            // 正常 → 永不熄屏 → 正常
            // (熄屏模式通过快捷键或菜单进入)
            if isScreenOff {
                exitScreenOffMode()
            } else if isPreventSleep {
                stopPreventSleep()
            } else {
                startPreventSleep()
            }
        }
    }

    private func showContextMenu() {
        let menu = NSMenu()

        // ── 状态 ──
        let statusText: String
        if isScreenOff {
            statusText = "🌙 熄屏模式"
        } else if isPreventSleep {
            statusText = "☕ 永不熄屏"
        } else {
            statusText = "☀️ 正常模式"
        }
        let statusMenuItem = NSMenuItem(title: statusText, action: nil, keyEquivalent: "")
        statusMenuItem.isEnabled = false
        menu.addItem(statusMenuItem)

        if (isScreenOff || isPreventSleep), let start = startTime {
            let secs = Int(Date().timeIntervalSince(start))
            let h = secs / 3600, m = (secs % 3600) / 60
            var durStr = "⏱ 已运行 "
            if h > 0 { durStr += "\(h) 小时 " }
            durStr += "\(m) 分钟"
            let durItem = NSMenuItem(title: durStr, action: nil, keyEquivalent: "")
            durItem.isEnabled = false
            menu.addItem(durItem)
        }

        menu.addItem(.separator())

        // ── 永不熄屏开关 ──
        let preventSleepTitle = isPreventSleep ? "☕ 关闭永不熄屏" : "☕ 开启永不熄屏"
        let preventSleepItem = NSMenuItem(title: preventSleepTitle, action: #selector(togglePreventSleepMode), keyEquivalent: "p")
        preventSleepItem.keyEquivalentModifierMask = [.command, .shift]
        menu.addItem(preventSleepItem)

        // ── 熄屏模式切换 ──
        let toggleTitle = isScreenOff ? "🔆 恢复正常模式" : "🌙 进入熄屏模式"
        let toggleItem = NSMenuItem(title: toggleTitle, action: #selector(toggleMode), keyEquivalent: "l")
        toggleItem.keyEquivalentModifierMask = [.command, .shift]
        menu.addItem(toggleItem)

        menu.addItem(.separator())

        // ── 设置 ──
        let settingsMenu = NSMenu()

        let kbItem = NSMenuItem(title: "🔒 锁定键盘输入", action: #selector(toggleBlockKeyboard), keyEquivalent: "")
        kbItem.state = blockKeyboard ? .on : .off
        settingsMenu.addItem(kbItem)

        let rsItem = NSMenuItem(title: "🔄 自动重新熄屏", action: #selector(toggleAutoReSleep), keyEquivalent: "")
        rsItem.state = autoReSleep ? .on : .off
        settingsMenu.addItem(rsItem)

        let tmItem = NSMenuItem(title: "⏱ 显示计时器", action: #selector(toggleShowTimer), keyEquivalent: "")
        tmItem.state = showTimer ? .on : .off
        settingsMenu.addItem(tmItem)

        let settingsItem = NSMenuItem(title: "⚙️ 设置", action: nil, keyEquivalent: "")
        settingsItem.submenu = settingsMenu
        menu.addItem(settingsItem)

        menu.addItem(.separator())

        // ── 快捷键提示 ──
        let sc1 = NSMenuItem(title: "⌘⇧L  切换熄屏模式", action: nil, keyEquivalent: "")
        sc1.isEnabled = false
        menu.addItem(sc1)
        let sc2 = NSMenuItem(title: "⌘⇧P  永不熄屏", action: nil, keyEquivalent: "")
        sc2.isEnabled = false
        menu.addItem(sc2)
        let sc3 = NSMenuItem(title: "⌘⌃⎋  紧急退出", action: nil, keyEquivalent: "")
        sc3.isEnabled = false
        menu.addItem(sc3)

        menu.addItem(.separator())

        menu.addItem(NSMenuItem(title: "💡 使用说明", action: #selector(showHelp), keyEquivalent: ""))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "退出 ScreenControl", action: #selector(quitApp), keyEquivalent: "q"))

        statusItem.menu = menu
        statusItem.button?.performClick(nil)
        DispatchQueue.main.async { self.statusItem.menu = nil }
    }

    // ═══════════════════════════════════════════
    // MARK: - Core: Toggle Mode
    // ═══════════════════════════════════════════

    @objc private func toggleMode() {
        // 如果永不熄屏模式开启，先关闭它
        if isPreventSleep { stopPreventSleep() }
        isScreenOff ? exitScreenOffMode() : enterScreenOffMode()
    }

    private func enterScreenOffMode() {
        guard !isScreenOff else { return }
        isScreenOff = true
        startTime = Date()

        // 1) 防止系统休眠
        preventSleep()

        // 2) 锁定键盘
        if blockKeyboard { startEventTap() }

        // 3) 调暗键盘背光
        dimKeyboardBacklight()

        // 4) 状态栏计时器
        uiTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            self?.updateIcon()
        }

        // 5) 关闭显示器（稍延迟，等背光调暗）
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
            self?.sleepDisplay()
        }

        // 6) 自动重新熄屏
        if autoReSleep { startReSleepMonitor() }

        updateIcon()
        notify(
            title: "🌙 熄屏模式已启动",
            body: blockKeyboard
                ? "屏幕关闭 · 键盘锁定 · 系统保持运行\n⌘⇧L 切换  |  ⌘⌃⎋ 紧急退出"
                : "屏幕关闭 · 系统保持运行\n⌘⇧L 或点击状态栏退出"
        )
        print("🌙 进入熄屏模式  keyboard=\(blockKeyboard)  reSleep=\(autoReSleep)")
    }

    private func exitScreenOffMode() {
        guard isScreenOff else { return }
        isScreenOff = false

        // 1) 恢复休眠策略
        allowSleep()

        // 2) 解锁键盘
        stopEventTap()

        // 3) 停止计时器
        uiTimer?.invalidate();    uiTimer = nil
        reSleepTimer?.invalidate(); reSleepTimer = nil

        // 4) 唤醒显示器
        wakeDisplay()

        startTime = nil
        updateIcon()
        notify(title: "☀️ 正常模式已恢复", body: "屏幕和键盘已恢复正常")
        print("☀️ 退出熄屏模式")
    }

    // ═══════════════════════════════════════════
    // MARK: - Prevent Sleep Mode (永不熄屏)
    // ═══════════════════════════════════════════

    @objc func togglePreventSleepMode() {
        isPreventSleep ? stopPreventSleep() : startPreventSleep()
    }

    private func startPreventSleep() {
        // 如果在熄屏模式，先退出
        if isScreenOff { exitScreenOffMode() }

        guard !isPreventSleep else { return }
        isPreventSleep = true
        startTime = Date()

        // 防止显示器休眠和系统休眠
        preventDisplayAndSystemSleep()

        // 状态栏计时器
        uiTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            self?.updateIcon()
        }

        updateIcon()
        notify(
            title: "☕ 永不熄屏已启动",
            body: "屏幕将保持常亮，系统不会休眠\n⌘⇧P 或点击状态栏退出"
        )
        print("☕ 永不熄屏模式已启动")
    }

    private func stopPreventSleep() {
        guard isPreventSleep else { return }
        isPreventSleep = false

        // 恢复正常休眠策略
        allowDisplayAndSystemSleep()

        // 停止计时器
        uiTimer?.invalidate(); uiTimer = nil

        startTime = nil
        updateIcon()
        notify(title: "☀️ 正常模式已恢复", body: "系统休眠策略已恢复正常")
        print("☀️ 永不熄屏模式已停止")
    }

    // ═══════════════════════════════════════════
    // MARK: - Prevent Display Sleep (IOPMAssertion)
    // ═══════════════════════════════════════════

    private func preventDisplayAndSystemSleep() {
        let reason = "ScreenControl: 永不熄屏模式" as CFString
        // PreventUserIdleDisplaySleep: 防止显示器空闲休眠
        let type = "PreventUserIdleDisplaySleep" as CFString
        let ret = IOPMAssertionCreateWithName(
            type,
            IOPMAssertionLevel(kIOPMAssertionLevelOn),
            reason,
            &preventDisplayAssertionID
        )
        hasPreventDisplayAssertion = (ret == kIOReturnSuccess)
        if hasPreventDisplayAssertion {
            print("✅ PreventDisplaySleep IOPMAssertion 创建成功 (ID: \(preventDisplayAssertionID))")
        } else {
            print("⚠️ PreventDisplaySleep IOPMAssertion 失败，回退到 caffeinate")
            startPreventDisplayCaffeinate()
        }
    }

    private func allowDisplayAndSystemSleep() {
        if hasPreventDisplayAssertion {
            IOPMAssertionRelease(preventDisplayAssertionID)
            hasPreventDisplayAssertion = false
            print("✅ PreventDisplaySleep IOPMAssertion 已释放")
        }
        stopPreventDisplayCaffeinate()
    }

    private func startPreventDisplayCaffeinate() {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/caffeinate")
        p.arguments = ["-d", "-i"]  // -d 防止显示器休眠, -i 防止系统空闲休眠
        try? p.run()
        preventDisplayCaffeinateProcess = p
    }

    private func stopPreventDisplayCaffeinate() {
        preventDisplayCaffeinateProcess?.terminate()
        preventDisplayCaffeinateProcess = nil
    }

    // ═══════════════════════════════════════════
    // MARK: - Sleep Prevention  (IOPMAssertion)
    // ═══════════════════════════════════════════

    private func preventSleep() {
        let reason = "ScreenControl: 熄屏模式运行中" as CFString
        // PreventUserIdleSystemSleep: 防止系统空闲休眠，但允许显示器休眠
        let type = "PreventUserIdleSystemSleep" as CFString
        let ret = IOPMAssertionCreateWithName(
            type,
            IOPMAssertionLevel(kIOPMAssertionLevelOn),
            reason,
            &assertionID
        )
        hasAssertion = (ret == kIOReturnSuccess)
        if hasAssertion {
            print("✅ IOPMAssertion 创建成功 (ID: \(assertionID))")
        } else {
            print("⚠️ IOPMAssertion 失败，回退到 caffeinate")
            startCaffeinate()
        }
    }

    private func allowSleep() {
        if hasAssertion {
            IOPMAssertionRelease(assertionID)
            hasAssertion = false
            print("✅ IOPMAssertion 已释放")
        }
        stopCaffeinate()
    }

    private func startCaffeinate() {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/caffeinate")
        p.arguments = ["-i"]   // -i 防止空闲休眠
        try? p.run()
        caffeinateProcess = p
    }

    private func stopCaffeinate() {
        caffeinateProcess?.terminate()
        caffeinateProcess = nil
    }

    // ═══════════════════════════════════════════
    // MARK: - Display Control
    // ═══════════════════════════════════════════

    private func sleepDisplay() {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
        p.arguments = ["displaysleepnow"]
        try? p.run()
    }

    private func wakeDisplay() {
        // caffeinate -u 模拟用户活动来唤醒显示器（不会产生按键输入）
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/caffeinate")
        p.arguments = ["-u", "-t", "1"]
        try? p.run()
    }

    private func startReSleepMonitor() {
        // 每 5 秒检查，如果显示器意外亮起则重新关闭
        reSleepTimer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) { [weak self] _ in
            guard let self = self, self.isScreenOff, self.autoReSleep else { return }
            self.sleepDisplay()
        }
    }

    // ═══════════════════════════════════════════
    // MARK: - Keyboard Blocking  (CGEventTap)
    // ═══════════════════════════════════════════

    private func startEventTap() {
        // 检查辅助功能权限
        let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary
        guard AXIsProcessTrustedWithOptions(opts) else {
            print("⚠️ 需要辅助功能权限")
            notify(
                title: "⚠️ 需要辅助功能权限",
                body: "请前往 系统设置 → 隐私与安全 → 辅助功能\n授权 ScreenControl 后重试"
            )
            blockKeyboard = false
            return
        }

        // 拦截 keyDown + keyUp（不拦截 flagsChanged，允许 modifier 键传递）
        let mask: CGEventMask =
            (1 << CGEventType.keyDown.rawValue) |
            (1 << CGEventType.keyUp.rawValue)

        let refcon = UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque())
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: keyboardTapCallback,
            userInfo: refcon
        ) else {
            print("❌ CGEventTap 创建失败")
            blockKeyboard = false
            return
        }

        eventTap = tap
        tapRunLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), tapRunLoopSource, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        print("✅ 键盘事件拦截已启动")
    }

    private func stopEventTap() {
        guard let tap = eventTap else { return }
        CGEvent.tapEnable(tap: tap, enable: false)
        if let src = tapRunLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), src, .commonModes)
        }
        eventTap = nil
        tapRunLoopSource = nil
        print("✅ 键盘事件拦截已停止")
    }

    /// 由 C 回调函数调用
    func processKeyboardEvent(
        proxy: CGEventTapProxy,
        type: CGEventType,
        event: CGEvent
    ) -> Unmanaged<CGEvent>? {

        // 系统可能因超时禁用 tap，需要重新启用
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap = eventTap { CGEvent.tapEnable(tap: tap, enable: true) }
            return Unmanaged.passRetained(event)
        }

        // 只在激活状态下拦截
        guard isScreenOff, blockKeyboard else {
            return Unmanaged.passRetained(event)
        }

        let flags   = event.flags
        let keyCode = event.getIntegerValueField(.keyboardEventKeycode)

        // ── 白名单: ⌘⌃⎋  (Cmd+Ctrl+Escape)  → 紧急退出 ──
        if flags.contains([.maskCommand, .maskControl]) && keyCode == 53 {
            DispatchQueue.main.async { self.exitScreenOffMode() }
            return nil   // 消费事件，不传递
        }

        // ── 白名单: ⌘⇧L  (Cmd+Shift+L)  → 切换模式 ──
        if flags.contains([.maskCommand, .maskShift]) && keyCode == 37 {
            DispatchQueue.main.async { self.toggleMode() }
            return nil
        }

        // ── 拦截所有其他键盘事件 ──
        return nil
    }

    // ═══════════════════════════════════════════
    // MARK: - Keyboard Backlight
    // ═══════════════════════════════════════════

    private func dimKeyboardBacklight() {
        DispatchQueue.global(qos: .utility).async {
            for _ in 0..<16 {
                var err: NSDictionary?
                NSAppleScript(source: "tell application \"System Events\" to key code 107")?
                    .executeAndReturnError(&err)
                Thread.sleep(forTimeInterval: 0.05)
            }
        }
    }

    // ═══════════════════════════════════════════
    // MARK: - Settings Toggles
    // ═══════════════════════════════════════════

    @objc private func toggleBlockKeyboard() {
        blockKeyboard.toggle()
        if isScreenOff {
            blockKeyboard ? startEventTap() : stopEventTap()
        }
    }

    @objc private func toggleAutoReSleep() {
        autoReSleep.toggle()
        if isScreenOff {
            if autoReSleep {
                startReSleepMonitor()
            } else {
                reSleepTimer?.invalidate()
                reSleepTimer = nil
            }
        }
    }

    @objc private func toggleShowTimer() {
        showTimer.toggle()
        updateIcon()
    }

    // ═══════════════════════════════════════════
    // MARK: - Notifications
    // ═══════════════════════════════════════════

    private func notify(title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = nil
        let req = UNNotificationRequest(
            identifier: UUID().uuidString,
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(req, withCompletionHandler: nil)
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler handler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        handler([.banner])
    }

    // ═══════════════════════════════════════════
    // MARK: - Help & Quit
    // ═══════════════════════════════════════════

    @objc private func showHelp() {
        let a = NSAlert()
        a.messageText = "ScreenControl v2.1 使用说明"
        a.informativeText = """
        ☕ 永不熄屏模式 (新功能):
        • 保持屏幕常亮不熄灭
        • 防止系统自动休眠
        • 适合长时间阅读、监控、演示

        🌙 熄屏模式:
        • 关闭显示器 + 键盘背光
        • 锁定键盘输入（防止误触唤醒）
        • 系统保持运行（不休眠）
        • 自动重新熄屏（屏幕意外亮起时）

        ⌨️ 快捷键:
        • ⌘⇧P — 切换永不熄屏模式（全局有效）
        • ⌘⇧L — 切换熄屏/正常模式（全局有效）
        • ⌘⌃⎋ — 紧急退出熄屏模式
        • 左键点击状态栏 — 切换模式
        • 右键点击状态栏 — 打开菜单

        📊 状态栏图标:
        • ☀️ — 正常模式
        • ☕ — 永不熄屏模式
        • 🌙 — 熄屏模式

        ⚙️ 设置选项:
        • 锁定键盘 — 拦截所有键盘输入（需要辅助功能权限）
        • 自动重新熄屏 — 屏幕意外唤醒后自动关闭
        • 显示计时器 — 状态栏显示运行时长

        🐱 适用场景:
        • 下载大文件时不想屏幕一直亮（熄屏模式）
        • 编译、渲染等长时间任务（熄屏模式）
        • 晚上让 Mac 安静工作（熄屏模式）
        • 防止猫咪踩键盘捣乱（熄屏模式）
        • 长时间阅读/监控/演示（永不熄屏模式）

        🔐 安全说明:
        • 键盘锁定仅在 ScreenControl 运行时有效
        • 如果应用意外退出，键盘自动恢复正常
        • 鼠标始终可用，可点击状态栏退出
        """
        a.alertStyle = .informational
        a.addButton(withTitle: "知道了 👌")
        a.runModal()
    }

    @objc private func quitApp() {
        if isScreenOff { exitScreenOffMode() }
        if isPreventSleep { stopPreventSleep() }
        NSApplication.shared.terminate(self)
    }

    private func cleanup() {
        allowSleep()
        allowDisplayAndSystemSleep()
        stopEventTap()
        if let m = globalMonitor { NSEvent.removeMonitor(m) }
        if let m = localMonitor  { NSEvent.removeMonitor(m) }
    }
}
