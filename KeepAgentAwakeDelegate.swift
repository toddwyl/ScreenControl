import Cocoa
import Combine
import CoreGraphics
import SwiftUI
import UserNotifications
import IOKit.pwr_mgt

// MARK: - User defaults

private enum KAKey {
    static let prefix = "KeepAgentAwake."
    static let showTimer = prefix + "showTimer"
    static let smartIdleDisplayOff = prefix + "smartIdleDisplayOff"
    /// 秒；旧版 `idleTimeoutMinutes` 在首次读取时迁移
    static let idleTimeoutSeconds = prefix + "idleTimeoutSeconds"
    static let legacyIdleTimeoutMinutes = prefix + "idleTimeoutMinutes"
    /// 空闲熄屏时是否自动降低键盘背光（内部固定触发 30 次减小）
    static let dimKeyboardOnIdleOff = prefix + "dimKeyboardOnIdleOff"
    /// 合盖时通过 `pmset -a disablesleep` 关闭系统睡眠（需管理员密码）
    static let keepAwakeOnLidClose = prefix + "keepAwakeOnLidClose"
}

// MARK: - AppDelegate

final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate, ObservableObject {

    // MARK: Published (UI + UserDefaults)

    @Published var showTimer: Bool = (UserDefaults.standard.object(forKey: KAKey.showTimer) as? Bool) ?? true {
        didSet {
            UserDefaults.standard.set(showTimer, forKey: KAKey.showTimer)
            scheduleStatusTimerForCurrentMode()
            updateIcon()
        }
    }
    /// 开启时：只阻止系统休眠，空闲后关闭显示器（可减轻与「强制显示器常亮」相关的闪烁）
    @Published var smartIdleDisplayOff: Bool = (UserDefaults.standard.object(forKey: KAKey.smartIdleDisplayOff) as? Bool) ?? true {
        didSet {
            UserDefaults.standard.set(smartIdleDisplayOff, forKey: KAKey.smartIdleDisplayOff)
            guard isProtectionOn else { return }
            applyProtectionPowerPolicy(startIdleMonitor: true)
            scheduleStatusTimerForCurrentMode()
            updateIcon()
        }
    }
    /// 空闲多久后关闭显示器（秒）。默认 600 = 10 分钟。
    @Published var idleTimeoutSeconds: Int = AppDelegate.loadIdleTimeoutSeconds() {
        didSet {
            UserDefaults.standard.set(idleTimeoutSeconds, forKey: KAKey.idleTimeoutSeconds)
            guard isProtectionOn, smartIdleDisplayOff else { return }
            restartIdleMonitoringTimerIfNeeded()
        }
    }
    /// 空闲熄屏时是否调暗键盘背光（模拟按下背光减小键，不保证「完全熄灭」）
    @Published var dimKeyboardOnIdleOff: Bool = (UserDefaults.standard.object(forKey: KAKey.dimKeyboardOnIdleOff) as? Bool) ?? true {
        didSet { UserDefaults.standard.set(dimKeyboardOnIdleOff, forKey: KAKey.dimKeyboardOnIdleOff) }
    }
    /// 合盖时执行 `sudo pmset -a disablesleep 1`（通过系统密码框授权）
    @Published var keepAwakeOnLidClose: Bool = (UserDefaults.standard.object(forKey: KAKey.keepAwakeOnLidClose) as? Bool) ?? true {
        didSet {
            UserDefaults.standard.set(keepAwakeOnLidClose, forKey: KAKey.keepAwakeOnLidClose)
            guard isProtectionOn else { return }
            applyProtectionPowerPolicy(startIdleMonitor: true)
            syncPmsetDisablesleep()
        }
    }

    @Published private(set) var isProtectionOn = false
    @Published private(set) var displayOffDueToIdle = false

    // MARK: UI

    private var statusItem: NSStatusItem!

    private var startTime: Date?

    // MARK: Sleep prevention (single "protection" mode)

    private var preventDisplayAssertionID: IOPMAssertionID = 0
    private var hasPreventDisplayAssertion = false
    private var preventDisplayCaffeinateProcess: Process?

    /// `PreventUserIdleSystemSleep`：防止因空闲进入睡眠
    private var idleSystemSleepAssertionID: IOPMAssertionID = 0
    private var hasIdleSystemSleepAssertion = false

    /// 是否已成功执行 `pmset -a disablesleep 1`（退出时需恢复为 0）
    private var hasPmsetDisablesleepOn = false

    /// SwiftUI 主窗口（用于可靠地前置/收起，避免仅依赖 `canBecomeKey`）
    private weak var mainContentWindow: NSWindow?

    private var caffeinateProcess: Process?

    // MARK: Timers

    private var uiTimer: Timer?
    private var idleCheckTimer: Timer?

    // MARK: Global hotkey + activity

    private var globalMonitor: Any?
    private var localMonitor: Any?
    private var activityMonitors: [Any] = []

    private var lastUserActivity = Date()
    private var lastActivityThrottle = Date.distantPast

    // MARK: Lifecycle

    func applicationDidFinishLaunching(_ notification: Notification) {
        migrateUserDefaultsFromScreenControlIfNeeded()
        applyUserDefaultsToPublishedSettingsFromDisk()
        // 仅菜单栏展示，不占用 Dock（与 Info.plist 中 LSUIElement 一致）
        NSApp.setActivationPolicy(.accessory)
        refreshPmsetStateFromSystem()
        setupNotifications()
        setupStatusBar()
        setupGlobalHotkey()
        setupActivityMonitoring()
        DispatchQueue.main.async {
            NSApp.activate(ignoringOtherApps: true)
        }
        print("🚀 KeepAgentAwake 已启动")
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag {
            for w in sender.windows where w.canBecomeKey {
                w.makeKeyAndOrderFront(nil)
                break
            }
        }
        NSApp.activate(ignoringOtherApps: true)
        return true
    }

    func applicationWillTerminate(_ notification: Notification) {
        cleanup()
    }

    /// 自旧名 ScreenControl 重命名后，从 `ScreenControl.*` 迁移到 `KeepAgentAwake.*`（仅新键不存在时复制）
    private func migrateUserDefaultsFromScreenControlIfNeeded() {
        let d = UserDefaults.standard
        let oldP = "ScreenControl."
        let newP = KAKey.prefix
        let suffixes = [
            "showTimer", "smartIdleDisplayOff", "idleTimeoutSeconds",
            "idleTimeoutMinutes", "dimKeyboardOnIdleOff", "keepAwakeOnLidClose",
        ]
        for s in suffixes {
            let ok = oldP + s
            let nk = newP + s
            if d.object(forKey: nk) == nil, d.object(forKey: ok) != nil {
                d.set(d.object(forKey: ok), forKey: nk)
            }
        }
    }

    /// 在迁移之后与磁盘上的 UserDefaults 对齐（因属性初始化早于 `applicationDidFinishLaunching`）
    private func applyUserDefaultsToPublishedSettingsFromDisk() {
        let d = UserDefaults.standard
        if let v = d.object(forKey: KAKey.showTimer) as? Bool { showTimer = v }
        if let v = d.object(forKey: KAKey.smartIdleDisplayOff) as? Bool { smartIdleDisplayOff = v }
        idleTimeoutSeconds = Self.loadIdleTimeoutSeconds()
        if let v = d.object(forKey: KAKey.dimKeyboardOnIdleOff) as? Bool { dimKeyboardOnIdleOff = v }
        if let v = d.object(forKey: KAKey.keepAwakeOnLidClose) as? Bool { keepAwakeOnLidClose = v }
    }

    private static func loadIdleTimeoutSeconds() -> Int {
        let d = UserDefaults.standard
        if d.object(forKey: KAKey.legacyIdleTimeoutMinutes) != nil {
            let minutes = d.integer(forKey: KAKey.legacyIdleTimeoutMinutes)
            d.removeObject(forKey: KAKey.legacyIdleTimeoutMinutes)
            if d.object(forKey: KAKey.idleTimeoutSeconds) == nil {
                d.set(max(1, minutes * 60), forKey: KAKey.idleTimeoutSeconds)
            }
        }
        if let v = d.object(forKey: KAKey.idleTimeoutSeconds) as? Int {
            return max(0, v)
        }
        return 600
    }

    // MARK: - UI helpers (SwiftUI)

    var modeStartTime: Date? {
        isProtectionOn ? startTime : nil
    }

    var statusDetailText: String {
        guard isProtectionOn else {
            return "系统默认：未启用永不休眠。点击「永不休眠」可防止系统因空闲睡眠；「恢复正常」后恢复默认电源策略。"
        }
        if displayOffDueToIdle {
            return "因空闲已关闭显示器；移动鼠标或按键即可唤醒。系统不会进入睡眠。"
        }
        if smartIdleDisplayOff {
            if idleTimeoutSeconds == 0 {
                if dimKeyboardOnIdleOff {
                    return "永不休眠：不因空闲自动熄屏；仅防止系统睡眠。空闲熄屏关闭时不会调键盘背光。"
                }
                return "永不休眠：不因空闲自动熄屏；仅防止系统睡眠。"
            }
            let desc = Self.describeDuration(seconds: idleTimeoutSeconds)
            if dimKeyboardOnIdleOff {
                return "永不休眠：有操作时保持亮屏。熄屏空闲 \(desc) 后关闭所有显示器；若开启调暗键盘背光，将自动触发约 30 次背光减小。"
            }
            return "永不休眠：有操作时保持亮屏。熄屏空闲 \(desc) 后关闭所有显示器（未调键盘背光）。"
        }
        return "保持显示器常亮并防止系统睡眠（经典强制亮屏模式）。"
    }

    private static func describeDuration(seconds: Int) -> String {
        if seconds == 0 { return "永不" }
        if seconds < 60 { return "\(seconds) 秒" }
        if seconds % 3600 == 0 { return "\(seconds / 3600) 小时" }
        if seconds % 60 == 0 { return "\(seconds / 60) 分钟" }
        return "\(seconds) 秒"
    }

    var statusBadge: (String, Color) {
        guard isProtectionOn else { return ("系统默认", Color.green) }
        return displayOffDueToIdle ? ("永不休眠 · 显示器已关", Color.orange) : ("永不休眠", Color.brown)
    }

    func formattedDuration(since start: Date) -> String {
        let secs = Int(Date().timeIntervalSince(start))
        let h = secs / 3600
        let m = (secs % 3600) / 60
        let s = secs % 60
        if h > 0 { return String(format: "%d:%02d:%02d", h, m, s) }
        return String(format: "%d:%02d", m, s)
    }

    func toggleProtectionFromUI() {
        toggleProtectionMode()
    }

    func focusStatusItem() {
        statusItem?.button?.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func showAboutWindow() {
        let a = NSAlert()
        a.messageText = "KeepAgentAwake"
        let ver = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? ""
        a.informativeText = "版本 \(ver) (\(build))\n\n仅菜单栏 · 永不休眠 · 键盘背光为模拟按键\n⌘⇧P 永不休眠 / 恢复正常"
        a.alertStyle = .informational
        a.addButton(withTitle: "好的")
        a.runModal()
    }

    // MARK: - Setup

    private func setupNotifications() {
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        center.requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    private func setupStatusBar() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        guard let button = statusItem.button else { return }
        button.target = self
        button.action = #selector(onStatusBarClick(_:))
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        updateIcon()
    }

    private func setupGlobalHotkey() {
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            self?.handleHotkeyEvent(event)
        }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if self?.handleHotkeyEvent(event) == true { return nil }
            return event
        }
    }

    private func setupActivityMonitoring() {
        let mask: NSEvent.EventTypeMask = [
            .mouseMoved, .keyDown, .leftMouseDown, .rightMouseDown, .otherMouseDown, .scrollWheel,
        ]
        if let g = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: { [weak self] _ in
            self?.noteUserActivity()
        }) {
            activityMonitors.append(g)
        }
        if let l = NSEvent.addLocalMonitorForEvents(matching: mask, handler: { [weak self] event in
            self?.noteUserActivity()
            return event
        }) {
            activityMonitors.append(l)
        }
    }

    private func noteUserActivity() {
        let n = Date()
        if n.timeIntervalSince(lastActivityThrottle) < 0.12 { return }
        lastActivityThrottle = n
        lastUserActivity = n

        if displayOffDueToIdle {
            wakeDisplay()
            displayOffDueToIdle = false
        }
    }

    @discardableResult
    private func handleHotkeyEvent(_ event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        // ⌘⇧P — 开关永不休眠
        if flags.contains([.command, .shift]) && event.keyCode == 35 {
            DispatchQueue.main.async { self.toggleProtectionMode() }
            return true
        }
        // ⌘⌃⎋ — 紧急关闭永不休眠
        if flags.contains([.command, .control]) && event.keyCode == 53 {
            DispatchQueue.main.async {
                if self.isProtectionOn { self.stopProtection() }
            }
            return true
        }
        return false
    }

    // MARK: - Status Bar UI

    private func statusSymbolName() -> String {
        guard isProtectionOn else { return "sun.max.fill" }
        return displayOffDueToIdle ? "moon.zzz.fill" : "cup.and.saucer.fill"
    }

    private func updateIcon() {
        guard let button = statusItem.button else { return }

        let config = NSImage.SymbolConfiguration(pointSize: 13, weight: .medium)
        let name = statusSymbolName()
        if let img = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(config) {
            let t = img.copy() as! NSImage
            t.isTemplate = true
            button.image = t
        } else {
            button.image = nil
        }
        button.imagePosition = .imageLeading

        if isProtectionOn, showTimer, let start = startTime {
            button.title = formattedDuration(since: start)
        } else {
            button.title = ""
        }
    }

    @objc private func onStatusBarClick(_ sender: NSStatusBarButton) {
        guard let event = NSApp.currentEvent else { return }
        if event.type == .rightMouseUp {
            showContextMenu()
            return
        }
        // 左键：若存在主窗口，则在「隐藏 ↔ 再次显示」之间切换；否则才切换永不休眠（避免每次点图标都走 start/stop 触发 pmset）
        if let w = resolvedMainWindow() {
            if w.isVisible && !w.isMiniaturized {
                w.orderOut(nil)
            } else {
                NSApp.activate(ignoringOtherApps: true)
                w.makeKeyAndOrderFront(nil)
            }
            return
        }
        isProtectionOn ? stopProtection() : startProtection()
    }

    private func showContextMenu() {
        let menu = NSMenu()

        let statusText: String
        if isProtectionOn {
            statusText = displayOffDueToIdle ? "☕ 永不休眠（显示器已关）" : "☕ 永不休眠"
        } else {
            statusText = "☀️ 系统默认"
        }
        let statusMenuItem = NSMenuItem(title: statusText, action: nil, keyEquivalent: "")
        statusMenuItem.isEnabled = false
        menu.addItem(statusMenuItem)

        if isProtectionOn, let start = startTime {
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

        menu.addItem(appMenuItem("打开主窗口", action: #selector(openMainWindow)))

        let toggleTitle = isProtectionOn ? "恢复正常" : "永不休眠"
        let toggleItem = appMenuItem(toggleTitle, action: #selector(toggleProtectionMode), keyEquivalent: "p", modifiers: [.command, .shift])
        menu.addItem(toggleItem)

        menu.addItem(.separator())

        let settingsMenu = NSMenu()

        let tmItem = appMenuItem("⏱ 显示计时器", action: #selector(toggleShowTimer))
        tmItem.state = showTimer ? .on : .off
        settingsMenu.addItem(tmItem)

        let smartItem = appMenuItem("🧠 空闲后自动熄屏（减轻闪烁）", action: #selector(toggleSmartIdle))
        smartItem.state = smartIdleDisplayOff ? .on : .off
        settingsMenu.addItem(smartItem)

        let settingsItem = NSMenuItem(title: "⚙️ 菜单内设置", action: nil, keyEquivalent: "")
        settingsItem.submenu = settingsMenu
        menu.addItem(settingsItem)

        menu.addItem(.separator())

        let sc2 = NSMenuItem(title: "⌘⇧P  永不休眠 / 恢复正常", action: nil, keyEquivalent: "")
        sc2.isEnabled = false
        menu.addItem(sc2)
        let sc3 = NSMenuItem(title: "⌘⌃⎋  紧急关闭", action: nil, keyEquivalent: "")
        sc3.isEnabled = false
        menu.addItem(sc3)

        menu.addItem(.separator())

        menu.addItem(appMenuItem("💡 使用说明", action: #selector(showHelp)))
        menu.addItem(.separator())
        let quitItem = appMenuItem("退出 KeepAgentAwake", action: #selector(quitApp), keyEquivalent: "q", modifiers: [.command])
        menu.addItem(quitItem)

        statusItem.menu = menu
        statusItem.button?.performClick(nil)
        DispatchQueue.main.async { self.statusItem.menu = nil }
    }

    /// 无 target 时，菜单动作不会派发到 `AppDelegate`，导致「打开主窗口」等无响应
    private func appMenuItem(
        _ title: String,
        action: Selector?,
        keyEquivalent: String = "",
        modifiers: NSEvent.ModifierFlags = []
    ) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: keyEquivalent)
        item.target = self
        if !modifiers.isEmpty {
            item.keyEquivalentModifierMask = modifiers
        }
        return item
    }

    /// 由主界面 `MainWindowAccessor` 注册，便于前置/收起
    func registerMainContentWindow(_ window: NSWindow) {
        mainContentWindow = window
        window.isReleasedWhenClosed = false
        window.hidesOnDeactivate = true
    }

    /// 主窗口（弱引用失效时按标题再查找 SwiftUI 窗口）
    private func resolvedMainWindow() -> NSWindow? {
        if let w = mainContentWindow { return w }
        let candidates = NSApp.windows.filter { w in
            guard w !== self.statusItem.button?.window else { return false }
            guard w.level == .normal || w.level == .floating else { return false }
            let cls = NSStringFromClass(type(of: w))
            if cls.contains("StatusBar") { return false }
            return true
        }
        for w in candidates where w.title == "KeepAgentAwake" {
            registerMainContentWindow(w)
            return w
        }
        // 标题可能尚未就绪：本 App 通常只有一个文档式窗口
        if candidates.count == 1, let w = candidates.first {
            registerMainContentWindow(w)
            return w
        }
        return nil
    }

    @objc private func openMainWindow() {
        NSApp.activate(ignoringOtherApps: true)
        if let w = resolvedMainWindow() {
            w.makeKeyAndOrderFront(nil)
            return
        }
        for w in NSApp.windows {
            guard w !== statusItem.button?.window else { continue }
            guard w.level == .normal || w.level == .floating else { continue }
            let cls = NSStringFromClass(type(of: w))
            if cls.contains("StatusBar") { continue }
            registerMainContentWindow(w)
            w.makeKeyAndOrderFront(nil)
            return
        }
        openMainWindowProgrammatically()
    }

    private func openMainWindowProgrammatically() {
        let root = MainWindowView().environmentObject(self)
        let host = NSHostingController(rootView: root)
        let w = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 620),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        w.title = "KeepAgentAwake"
        w.contentViewController = host
        w.center()
        w.setFrameAutosaveName("KeepAgentAwakeMain")
        registerMainContentWindow(w)
        w.makeKeyAndOrderFront(nil)
    }

    // MARK: - Protection mode (single mode)

    @objc func toggleProtectionMode() {
        isProtectionOn ? stopProtection() : startProtection()
    }

    private func startProtection() {
        guard !isProtectionOn else { return }
        isProtectionOn = true
        displayOffDueToIdle = false
        startTime = Date()
        lastUserActivity = Date()

        applyProtectionPowerPolicy(startIdleMonitor: true)
        syncPmsetDisablesleep()

        scheduleStatusTimerForCurrentMode()

        updateIcon()
        notify(
            title: "永不休眠已开启",
            body: notificationBodyForStart()
        )
        print("☕ 永不休眠已开启  smartIdle=\(smartIdleDisplayOff)  idle=\(idleTimeoutSeconds)s")
    }

    private func stopProtection() {
        guard isProtectionOn else { return }
        isProtectionOn = false
        displayOffDueToIdle = false

        wakeDisplay()

        teardownProtectionPowerPolicy()
        syncPmsetDisablesleep()

        uiTimer?.invalidate()
        uiTimer = nil

        idleCheckTimer?.invalidate()
        idleCheckTimer = nil

        startTime = nil
        updateIcon()
        notify(title: "永不休眠已关闭", body: "已恢复电源断言；若曾勾选合盖选项，将尝试 pmset disablesleep 0（可能再次请求管理员密码）。")
        print("☀️ 永不休眠已停止")
    }

    private func notificationBodyForStart() -> String {
        var parts: [String] = []
        if smartIdleDisplayOff {
            if idleTimeoutSeconds == 0 {
                parts.append("已防止系统睡眠；熄屏空闲为「永不」，不会因空闲自动关显示器")
            } else {
                var s = "已防止系统睡眠；熄屏空闲 \(Self.describeDuration(seconds: idleTimeoutSeconds)) 后将关闭显示器"
                if dimKeyboardOnIdleOff {
                    s += "，并自动降低键盘背光"
                }
                parts.append(s)
            }
        } else {
            parts.append("屏幕将保持常亮，并防止空闲睡眠（经典强制亮屏）")
        }
        if keepAwakeOnLidClose {
            parts.append("若系统尚未处于 disablesleep，将请求管理员密码执行 pmset -a disablesleep 1（关闭系统睡眠）")
        } else {
            parts.append("未启用 pmset disablesleep；合盖后系统仍可能睡眠")
        }
        return parts.joined(separator: "。") + "。"
    }

    private func applyProtectionPowerPolicy(startIdleMonitor: Bool) {
        teardownProtectionPowerPolicy()

        if smartIdleDisplayOff {
            applyIdleSystemSleepAssertion()
            if startIdleMonitor { restartIdleMonitoringTimerIfNeeded() }
            if !hasIdleSystemSleepAssertion {
                print("⚠️ PreventUserIdleSystemSleep 失败，回退 caffeinate -i")
                startCaffeinate(arguments: ["-i"])
            }
        } else {
            preventDisplayAndSystemSleepClassic()
        }
    }

    private func teardownProtectionPowerPolicy() {
        releaseIdleSystemSleepAssertion()
        allowDisplayAndSystemSleepClassic()
        idleCheckTimer?.invalidate()
        idleCheckTimer = nil
    }

    /// 与「永不休眠 + 合盖」对齐 `pmset -a disablesleep`。
    /// 逻辑位置：本方法 + `runPmsetDisablesleep`。密码弹窗来自 AppleScript `with administrator privileges`；
    /// **每次执行**都会向系统要管理员授权，因此必须先读当前值（`refreshPmsetStateFromSystem`），仅在实际需要 0↔1 时才调用 `runPmsetDisablesleep`。
    private func syncPmsetDisablesleep() {
        refreshPmsetStateFromSystem()

        let wantOn = isProtectionOn && keepAwakeOnLidClose
        if wantOn == hasPmsetDisablesleepOn { return }
        if wantOn {
            if runPmsetDisablesleep(enable: true) {
                hasPmsetDisablesleepOn = true
                print("✅ pmset -a disablesleep 1")
            } else {
                refreshPmsetStateFromSystem()
                notify(
                    title: "未应用 pmset disablesleep",
                    body: "已取消输入密码或执行失败。合盖仍可能睡眠；可稍后在设置中重新开启「合盖时关闭系统睡眠」。"
                )
            }
        } else {
            guard hasPmsetDisablesleepOn else { return }
            if runPmsetDisablesleep(enable: false) {
                print("✅ pmset -a disablesleep 0")
            } else {
                notify(
                    title: "未能恢复系统睡眠",
                    body: "请手动在终端执行：sudo /usr/bin/pmset -a disablesleep 0"
                )
            }
            refreshPmsetStateFromSystem()
        }
    }

    /// 无 sudo 读取当前 disablesleep 相关开关，用于与内存状态对齐，避免重复弹管理员密码
    private func refreshPmsetStateFromSystem() {
        if let v = readDisablesleepFromPmset() {
            hasPmsetDisablesleepOn = (v != 0)
        }
    }

    /// 解析 `pmset -g` / `pmset -g custom` 中的 `disablesleep` 或 `SleepDisabled`（系统展示名因版本可能不同）
    private func readDisablesleepFromPmset() -> Int? {
        if let v = readDisablesleepFromPmsetOutput(arguments: ["-g"]) { return v }
        return readDisablesleepFromPmsetOutput(arguments: ["-g", "custom"])
    }

    private func readDisablesleepFromPmsetOutput(arguments: [String]) -> Int? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
        p.arguments = arguments
        let out = Pipe()
        p.standardOutput = out
        p.standardError = Pipe()
        do {
            try p.run()
        } catch {
            return nil
        }
        p.waitUntilExit()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        guard let text = String(data: data, encoding: .utf8) else { return nil }
        var fromDisablesleep: Int?
        var fromSleepDisabled: Int?
        for line in text.split(separator: "\n") {
            let s = String(line)
            let lower = s.lowercased()
            if lower.contains("disablesleep"), !lower.contains("displaysleep"), !lower.contains("disksleep") {
                if let n = extractIntFromPmsetLine(s) { fromDisablesleep = n }
            } else if s.contains("SleepDisabled") {
                if let n = extractIntFromPmsetLine(s) { fromSleepDisabled = n }
            }
        }
        if let v = fromDisablesleep { return v }
        if let v = fromSleepDisabled { return v }
        return nil
    }

    private func extractIntFromPmsetLine(_ line: String) -> Int? {
        let parts = line.split { $0.isWhitespace || $0 == "\t" }.map(String.init)
        for part in parts.reversed() {
            if let n = Int(part) { return n }
        }
        return nil
    }

    /// 通过 AppleScript 请求管理员权限执行 `pmset -a disablesleep`
    @discardableResult
    private func runPmsetDisablesleep(enable: Bool) -> Bool {
        let run: () -> Bool = {
            let v = enable ? "1" : "0"
            let shell = "/usr/bin/pmset -a disablesleep \(v)"
            let source = "do shell script \"\(shell)\" with administrator privileges"
            var err: NSDictionary?
            guard let script = NSAppleScript(source: source) else { return false }
            _ = script.executeAndReturnError(&err)
            if let e = err {
                print("⚠️ pmset AppleScript: \(e)")
                return false
            }
            return true
        }
        if Thread.isMainThread {
            return run()
        }
        var ok = false
        DispatchQueue.main.sync { ok = run() }
        return ok
    }

    /// 防止因**空闲**进入系统睡眠（不能单独阻止合盖睡眠）
    private func applyIdleSystemSleepAssertion() {
        let reason = "KeepAgentAwake: PreventUserIdleSystemSleep" as CFString
        let type = "PreventUserIdleSystemSleep" as CFString
        let ret = IOPMAssertionCreateWithName(
            type,
            IOPMAssertionLevel(kIOPMAssertionLevelOn),
            reason,
            &idleSystemSleepAssertionID
        )
        hasIdleSystemSleepAssertion = (ret == kIOReturnSuccess)
        if hasIdleSystemSleepAssertion {
            print("✅ PreventUserIdleSystemSleep 断言已创建")
        } else {
            print("⚠️ PreventUserIdleSystemSleep 创建失败")
        }
    }

    private func releaseIdleSystemSleepAssertion() {
        if hasIdleSystemSleepAssertion {
            IOPMAssertionRelease(idleSystemSleepAssertionID)
            hasIdleSystemSleepAssertion = false
        }
        stopCaffeinate()
    }

    private func preventDisplayAndSystemSleepClassic() {
        let reason = "KeepAgentAwake: 防睡眠（经典）" as CFString
        let type = "PreventUserIdleDisplaySleep" as CFString
        let ret = IOPMAssertionCreateWithName(
            type,
            IOPMAssertionLevel(kIOPMAssertionLevelOn),
            reason,
            &preventDisplayAssertionID
        )
        hasPreventDisplayAssertion = (ret == kIOReturnSuccess)
        if hasPreventDisplayAssertion {
            print("✅ PreventUserIdleDisplaySleep 断言已创建")
        } else {
            print("⚠️ PreventUserIdleDisplaySleep 失败，回退 caffeinate -d -i")
            startPreventDisplayCaffeinate()
        }
    }

    private func allowDisplayAndSystemSleepClassic() {
        if hasPreventDisplayAssertion {
            IOPMAssertionRelease(preventDisplayAssertionID)
            hasPreventDisplayAssertion = false
        }
        stopPreventDisplayCaffeinate()
    }

    private func startPreventDisplayCaffeinate() {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/caffeinate")
        p.arguments = ["-d", "-i"]
        try? p.run()
        preventDisplayCaffeinateProcess = p
    }

    private func stopPreventDisplayCaffeinate() {
        preventDisplayCaffeinateProcess?.terminate()
        preventDisplayCaffeinateProcess = nil
    }

    private func startCaffeinate(arguments: [String]) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/caffeinate")
        p.arguments = arguments
        try? p.run()
        caffeinateProcess = p
    }

    private func stopCaffeinate() {
        caffeinateProcess?.terminate()
        caffeinateProcess = nil
    }

    // MARK: - Display control

    private func sleepDisplay() {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
        p.arguments = ["displaysleepnow"]
        try? p.run()
    }

    private func wakeDisplay() {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/caffeinate")
        p.arguments = ["-u", "-t", "1"]
        try? p.run()
    }

    // MARK: - Idle display off

    private func idleCheckIntervalSeconds() -> TimeInterval {
        let t = TimeInterval(idleTimeoutSeconds)
        if t <= 0 { return 5.0 }
        if t <= 2 { return 0.2 }
        if t <= 30 { return 0.5 }
        if t <= 120 { return 1.0 }
        return 5.0
    }

    private func restartIdleMonitoringTimerIfNeeded() {
        idleCheckTimer?.invalidate()
        idleCheckTimer = nil
        guard isProtectionOn, smartIdleDisplayOff else { return }
        guard idleTimeoutSeconds > 0 else { return }

        let iv = idleCheckIntervalSeconds()
        idleCheckTimer = Timer.scheduledTimer(withTimeInterval: iv, repeats: true) { [weak self] _ in
            self?.tickIdleDisplayOff()
        }
        RunLoop.main.add(idleCheckTimer!, forMode: .common)
    }

    private func tickIdleDisplayOff() {
        guard isProtectionOn, smartIdleDisplayOff else { return }
        guard idleTimeoutSeconds > 0 else { return }
        guard !displayOffDueToIdle else { return }

        let timeout = TimeInterval(idleTimeoutSeconds)
        if Date().timeIntervalSince(lastUserActivity) >= timeout {
            sleepDisplayForIdle()
        }
    }

    private func sleepDisplayForIdle() {
        displayOffDueToIdle = true
        if dimKeyboardOnIdleOff {
            dimKeyboardBacklight()
        }
        sleepDisplay()
        updateIcon()
        notify(
            title: "显示器已因空闲关闭",
            body: "系统仍保持唤醒。移动鼠标即可点亮屏幕。"
        )
    }

    // MARK: - Keyboard backlight
    /// 固定触发 30 次「背光减小」（key code 107），由系统决定最终亮度。

    private let keyboardBacklightDimIterations = 30

    private func dimKeyboardBacklight() {
        let n = keyboardBacklightDimIterations
        DispatchQueue.global(qos: .utility).async {
            for _ in 0..<n {
                var err: NSDictionary?
                NSAppleScript(source: "tell application \"System Events\" to key code 107")?
                    .executeAndReturnError(&err)
                Thread.sleep(forTimeInterval: 0.05)
            }
        }
    }

    // MARK: - Status timer

    private func scheduleStatusTimerForCurrentMode() {
        uiTimer?.invalidate()
        uiTimer = nil

        guard showTimer, isProtectionOn else {
            updateIcon()
            return
        }

        let interval: TimeInterval = 5.0
        uiTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            self?.updateIcon()
        }
        RunLoop.main.add(uiTimer!, forMode: .common)
    }

    // MARK: - Menu toggles

    @objc private func toggleShowTimer() {
        showTimer.toggle()
    }

    @objc private func toggleSmartIdle() {
        smartIdleDisplayOff.toggle()
    }

    // MARK: - Notifications

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

    // MARK: - Help & Quit

    @objc private func showHelp() {
        let a = NSAlert()
        a.messageText = "KeepAgentAwake 使用说明"
        a.informativeText = """
        • 永不休眠：使用 IOPM 断言防止空闲睡眠；熄屏空闲可选「永不」或定时关显示器。
        • 键盘背光：空闲熄屏时自动连续触发背光减小（内部固定次数），由系统决定最终亮度。
        • 合盖：勾选后通过管理员密码执行 pmset -a disablesleep 1；恢复正常时执行 disablesleep 0。

        快捷键：⌘⇧P 永不休眠 / 恢复正常 · ⌘⌃⎋ 紧急关闭
        """
        a.alertStyle = .informational
        a.addButton(withTitle: "知道了")
        a.runModal()
    }

    @objc private func quitApp() {
        if isProtectionOn { stopProtection() }
        NSApplication.shared.terminate(self)
    }

    func quitApplication() {
        quitApp()
    }

    private func cleanup() {
        teardownProtectionPowerPolicy()
        refreshPmsetStateFromSystem()
        if hasPmsetDisablesleepOn {
            _ = runPmsetDisablesleep(enable: false)
            refreshPmsetStateFromSystem()
        }
        if let m = globalMonitor { NSEvent.removeMonitor(m) }
        if let m = localMonitor { NSEvent.removeMonitor(m) }
        for m in activityMonitors {
            NSEvent.removeMonitor(m)
        }
        activityMonitors.removeAll()
    }
}
