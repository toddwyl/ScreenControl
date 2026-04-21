import AppKit
import SwiftUI

/// 熄屏空闲时间预设（秒）。`0` = 永不因空闲自动熄屏（仍保持「永不休眠」防睡眠）
private let idlePresets: [Int] = [0, 1, 5, 10, 30, 60, 120, 300, 600, 900, 1800, 3600]

private func idleChoices(current: Int) -> [Int] {
    var s = Set(idlePresets)
    s.insert(max(0, current))
    return s.sorted()
}

/// 将 SwiftUI 窗口绑定到 `AppDelegate`，供菜单栏「打开主窗口」可靠前置，并启用 `hidesOnDeactivate`
private struct MainWindowAccessor: NSViewRepresentable {
    @EnvironmentObject var app: AppDelegate

    func makeNSView(context: Context) -> NSView {
        NSView()
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async {
            guard let window = nsView.window else { return }
            app.registerMainContentWindow(window)
        }
    }
}

struct MainWindowView: View {
    @EnvironmentObject var app: AppDelegate

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                header
                modeCard
                Divider()
                quickActions
                Divider()
                settingsSummary
                Spacer(minLength: 8)
            }
            .padding(24)
        }
        .frame(minWidth: 440, minHeight: 520)
        .background(MainWindowAccessor())
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 14) {
            Group {
                if let icon = NSApp.applicationIconImage {
                    Image(nsImage: icon)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                } else {
                    Image(systemName: "display.and.arrow.down")
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                }
            }
            .frame(width: 56, height: 56)
            .cornerRadius(12)
            VStack(alignment: .leading, spacing: 4) {
                Text("KeepAgentAwake")
                    .font(.title2.weight(.semibold))
                Text("菜单栏 · 永不休眠 · 可定时空闲熄屏")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
    }

    private var modeCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("当前状态")
                .font(.headline)
            HStack {
                statusBadge
                Spacer()
                if let start = app.modeStartTime {
                    Text("已运行 \(app.formattedDuration(since: start))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }
            Text(app.statusDetailText)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
        .background(.quaternary.opacity(0.35))
        .cornerRadius(12)
    }

    private var statusBadge: some View {
        let (text, color) = app.statusBadge
        return Text(text)
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(color.opacity(0.15))
            .foregroundStyle(color)
            .cornerRadius(8)
    }

    private var quickActions: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("快捷操作")
                .font(.headline)
            Button(app.isProtectionOn ? "恢复正常" : "永不休眠") {
                app.toggleProtectionFromUI()
            }
            .keyboardShortcut("p", modifiers: [.command, .shift])
            Text("开启后为「永不休眠」；再点此按钮为「恢复正常」（系统默认电源行为）。⌘⇧P 切换 · ⌘⌃⎋ 紧急恢复")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var settingsSummary: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("设置")
                .font(.headline)
            Toggle("状态栏显示计时器", isOn: $app.showTimer)
            Divider().padding(.vertical, 4)
            Toggle("空闲后自动熄屏（推荐，可减轻屏幕闪烁）", isOn: $app.smartIdleDisplayOff)
                .help("关闭时使用经典「强制显示器常亮」。开启时可设熄屏空闲时间，含「永不」。")
            HStack {
                Text("熄屏空闲时间")
                Spacer()
                Picker("", selection: $app.idleTimeoutSeconds) {
                    ForEach(idleChoices(current: app.idleTimeoutSeconds), id: \.self) { sec in
                        Text(Self.labelForIdleSeconds(sec)).tag(sec)
                    }
                }
                .frame(maxWidth: 240)
            }
            .disabled(!app.smartIdleDisplayOff)
            Toggle("空闲熄屏时自动降低键盘背光", isOn: $app.dimKeyboardOnIdleOff)
                .disabled(!app.smartIdleDisplayOff || app.idleTimeoutSeconds == 0)
            Toggle("合盖时关闭系统睡眠（pmset disablesleep）", isOn: $app.keepAwakeOnLidClose)
                .help("开启永不休眠后，将请求管理员密码执行 pmset -a disablesleep 1；恢复正常时尝试执行 disablesleep 0。")
            Text("熄屏空闲为「永不」时不会自动关显示器。键盘背光在需要时会自动触发若干次减小。合盖选项依赖系统密码授权。")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Button("在菜单栏聚焦图标") {
                app.focusStatusItem()
            }
            Divider().padding(.vertical, 8)
            Button("退出 KeepAgentAwake") {
                app.quitApplication()
            }
            .keyboardShortcut("q", modifiers: [.command])
        }
    }

    private static func labelForIdleSeconds(_ sec: Int) -> String {
        if sec == 0 { return "永不（不因空闲熄屏）" }
        if sec < 60 { return "\(sec) 秒" }
        if sec % 3600 == 0 { return "\(sec / 3600) 小时" }
        if sec % 60 == 0 { return "\(sec / 60) 分钟" }
        return "\(sec) 秒"
    }
}
