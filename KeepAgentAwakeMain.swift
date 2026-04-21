import SwiftUI

@main
struct KeepAgentAwakeApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        WindowGroup {
            MainWindowView()
                .environmentObject(appDelegate)
        }
        .defaultSize(width: 480, height: 620)
        .commands {
            CommandGroup(replacing: .appInfo) {}
            CommandGroup(after: .appInfo) {
                Button("关于 KeepAgentAwake…") {
                    appDelegate.showAboutWindow()
                }
            }
        }
    }
}
