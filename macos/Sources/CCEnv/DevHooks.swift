// 开发用钩子，普通使用不会触发：
//   CCENV_APPEARANCE=dark|light   强制外观，便于截图对比
//   CCENV_SNAPSHOT=/path/out.png  检测完成后把窗口渲染成 PNG 并退出（不需要屏幕录制权限）
import AppKit

enum DevHooks {
    static let appearance = ProcessInfo.processInfo.environment["CCENV_APPEARANCE"]
    static let snapshotPath = ProcessInfo.processInfo.environment["CCENV_SNAPSHOT"]

    @MainActor static func applyAppearance() {
        switch appearance {
        case "dark": NSApp.appearance = NSAppearance(named: .darkAqua)
        case "light": NSApp.appearance = NSAppearance(named: .aqua)
        default: break
        }
    }

    static func log(_ s: String) {
        guard snapshotPath != nil else { return }
        FileHandle.standardError.write(("[ccenv] " + s + "\n").data(using: .utf8)!)
    }

    @MainActor static func snapshotIfRequested() {
        guard let path = snapshotPath else { return }
        log("snapshot requested → \(path)")
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 800_000_000)
            let desc = NSApp.windows.map { w -> String in "\(w.title) visible=\(w.isVisible) \(Int(w.frame.width))x\(Int(w.frame.height))" }
            log("windows: \(desc)")
            guard let window = NSApp.windows.first(where: { $0.isVisible }),
                  let frame = window.contentView?.superview else { log("no window"); NSApp.terminate(nil); return }
            if let h = ProcessInfo.processInfo.environment["CCENV_SNAPSHOT_HEIGHT"].flatMap(Double.init) {
                var f = window.frame
                f.origin.y -= (h - f.height)
                f.size.height = h
                window.setFrame(f, display: true)
                try? await Task.sleep(nanoseconds: 400_000_000)
            }
            let rep = frame.bitmapImageRepForCachingDisplay(in: frame.bounds)!
            frame.cacheDisplay(in: frame.bounds, to: rep)
            if let png = rep.representation(using: .png, properties: [:]) {
                do { try png.write(to: URL(fileURLWithPath: path)); log("written \(png.count) bytes") } catch { log("write failed \(error)") }
            }
            NSApp.terminate(nil)
        }
    }
}
