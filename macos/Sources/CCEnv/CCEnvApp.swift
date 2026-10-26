import SwiftUI
import CCEnvCore

@main
struct CCEnvApp: App {
    @State private var model = AppModel()

    var body: some Scene {
        Window("ccenv", id: "main") {
            ContentView()
                .environment(model)
                .frame(minWidth: 680, minHeight: 520)
                .task {
                    DevHooks.applyAppearance()
                    if model.report == nil { model.run() }
                }
        }
        .defaultSize(width: 940, height: 820)
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(replacing: .newItem) {}
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
