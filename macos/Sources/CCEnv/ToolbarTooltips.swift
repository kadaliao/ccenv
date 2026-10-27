// 工具栏按钮的悬停提示。
//
// SwiftUI 会把工具栏里的普通 Button 转成原生 NSToolbarItem，这时 .help() 不生效（菜单、开关、
// 分段控件外面有一层托管视图，不受影响）。这里直接给原生 NSToolbarItem 设 toolTip：
// 窗口出现时扫一遍，之后切页面重建工具栏时靠 willAddItem 通知补上。

import AppKit
import SwiftUI

enum ToolbarTips {
    /// 工具栏项标题 → 提示文案。标题要和 Label 的文字一致。
    static let byLabel: [String: String] = [
        "重新检测": "重新检测网络出口和本机环境 (⌘R)",
        "刷新": "重新读取 Claude 的本机标识",
        "重新生成 ID": "重新生成随机 ID：Claude Code 的 userID / machineID，以及桌面版的设备 ID 和 ID 盐",
    ]

    static func apply(to item: NSToolbarItem) {
        if let tip = byLabel[item.label], item.toolTip != tip { item.toolTip = tip }
    }
}

/// 放在窗口内容里任意位置即可，不占空间。
struct ToolbarTooltipInstaller: NSViewRepresentable {
    final class Coordinator {
        var observer: NSObjectProtocol?
        weak var toolbar: NSToolbar?
        deinit { observer.map(NotificationCenter.default.removeObserver) }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSView { NSView(frame: .zero) }

    func updateNSView(_ view: NSView, context: Context) {
        // 工具栏在视图挂上窗口之后才建好，放到下一轮 runloop 再处理
        DispatchQueue.main.async { install(view, context.coordinator) }
    }

    private func install(_ view: NSView, _ c: Coordinator) {
        guard let toolbar = view.window?.toolbar else { return }
        toolbar.items.forEach(ToolbarTips.apply)
        guard c.toolbar !== toolbar else { return }
        c.observer.map(NotificationCenter.default.removeObserver)
        c.toolbar = toolbar
        c.observer = NotificationCenter.default.addObserver(forName: NSToolbar.willAddItemNotification, object: toolbar, queue: .main) { note in
            guard let item = note.userInfo?["item"] as? NSToolbarItem else { return }
            // SwiftUI 可能在加入后才填标题，下一轮再设一次
            MainActor.assumeIsolated { ToolbarTips.apply(to: item) }
            DispatchQueue.main.async { ToolbarTips.apply(to: item) }
        }
    }
}
