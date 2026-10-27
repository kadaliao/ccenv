import SwiftUI
import CCEnvCore

final class AppDelegate: NSObject, NSApplicationDelegate {
    @MainActor static weak var updater: Updater?

    func applicationWillTerminate(_ notification: Notification) {
        MainActor.assumeIsolated { Self.updater?.installOnQuitIfReady() }
    }
}

@main
struct CCEnvApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var model = AppModel()

    var body: some Scene {
        Window("ccenv", id: "main") {
            ContentView()
                .environment(model)
                .frame(minWidth: 680, minHeight: 520)
                .task {
                    DevHooks.applyAppearance()
                    AppDelegate.updater = model.updater
                    if model.report == nil { model.run() }
                    model.updater.checkOnLaunch()
                }
        }
        .defaultSize(width: 940, height: 820)
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandGroup(after: .appInfo) {
                Button("检查更新…") { model.checkForUpdates() }
                    .disabled(model.updater.isBusy)
            }
            CommandGroup(before: .sidebar) {
                Button("环境检测") { model.tab = .check }
                    .keyboardShortcut("1", modifiers: .command)
                Button("Claude 指纹") { model.tab = .fingerprint }
                    .keyboardShortcut("2", modifiers: .command)
                Divider()
            }
            CommandMenu("检测") {
                Button("重新检测") { model.run() }
                    .keyboardShortcut("r", modifiers: .command)
                    .disabled(model.isRunning)
                Divider()
                Button("分享图片…") { model.presentShareImage() }
                    .disabled(model.report == nil)
                Button("复制文本报告") { model.copyText() }
                    .keyboardShortcut("c", modifiers: [.command, .shift])
                    .disabled(model.report == nil)
                Button("导出 JSON…") { model.exportJSON() }
                    .keyboardShortcut("e", modifiers: .command)
                    .disabled(model.report == nil)
                Divider()
                Toggle("离线模式（只查本地层）", isOn: Binding(get: { model.offline }, set: { model.offline = $0 }))
            }
        }
    }
}
