import AppKit
import Observation
import SwiftUI
import CCEnvCore

@MainActor
@Observable
final class AppModel {
    enum Phase: Equatable {
        case idle
        case running(Stage)
        case done
        case failed(String)
    }

    var phase: Phase = .idle
    var report: Report?
    var lastRun: Date?
    var expanded: Set<String> = []
    var toast: String?
    /// 非空时弹出分享图片预览。
    var shareImage: ShareImage?

    // 偏好：手动落到 UserDefaults（@Observable 和 @AppStorage 不能直接混用）
    var offline: Bool { didSet { UserDefaults.standard.set(offline, forKey: "offline") } }
    var samples: Int { didSet { UserDefaults.standard.set(samples, forKey: "samples") } }
    var timeoutMs: Int { didSet { UserDefaults.standard.set(timeoutMs, forKey: "timeoutMs") } }

    enum Tab: String, CaseIterable {
        case check, fingerprint
        var title: String { self == .check ? "环境检测" : "Claude 指纹" }
    }

    var tab: Tab = .check
    let updater = Updater(currentVersion: AppModel.appVersion)

    // 指纹
    struct Baseline {
        var name: String
        var fp: Fingerprint
    }

    var fingerprint: Fingerprint?
    var baseline: Baseline?
    var reveal = false
    var fingerprintBusy = false
    var recentSnapshots: [URL] = []
    /// 点「重新生成」时的现场情况，非空时弹出确认框。
    struct RegenerateContext {
        var codeRunning: Int
        var hasCode: Bool
        var hasDesktop: Bool
        var desktopRunning: Bool
    }

    var regenerateConfirm: RegenerateContext?

    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var toastTask: Task<Void, Never>?

    init() {
        let d = UserDefaults.standard
        offline = d.bool(forKey: "offline")
        samples = d.object(forKey: "samples") as? Int ?? 6
        timeoutMs = d.object(forKey: "timeoutMs") as? Int ?? 8000
        if ProcessInfo.processInfo.environment["CCENV_TAB"] == "fingerprint" { tab = .fingerprint }
    }

    var isRunning: Bool {
        if case .running = phase { return true }
        return false
    }

    var options: CheckOptions { CheckOptions(offline: offline, samples: samples, timeoutMs: timeoutMs) }

    static let appVersion: String = {
        let b = Bundle.main
        return (b.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) ?? coreVersion
    }()

    func run() {
        DevHooks.log("run() called")
        task?.cancel()
        phase = .running(.local)
        let opts = options
        task = Task { [weak self] in
            let report = await CCEnv.check(options: opts, appVersion: Self.appVersion) { stage in
                DevHooks.log("stage \(stage)")
                Task { @MainActor in
                    guard let self, self.isRunning else { return }
                    self.phase = .running(stage)
                }
            }
            DevHooks.log("check finished: \(report.verdict.value) cancelled=\(Task.isCancelled)")
            guard !Task.isCancelled, let self else { return }
            withAnimation(.snappy) {
                self.report = report
                self.lastRun = Date()
                self.phase = .done
                self.expanded = ProcessInfo.processInfo.environment["CCENV_SNAPSHOT_COLLAPSE"] != nil
                    ? [] : Set(report.conflicts.filter { $0.level <= .medium }.map { $0.id })
            }
            DevHooks.snapshotIfRequested()
        }
    }

    func toggle(_ id: String) {
        withAnimation(.snappy(duration: 0.2)) {
            if expanded.contains(id) { expanded.remove(id) } else { expanded.insert(id) }
        }
    }

    func copyText() {
        guard let report else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(CCEnv.text(report), forType: .string)
        flash("已复制文本报告")
    }

    func copyJSON() {
        guard let report else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(CCEnv.json(report), forType: .string)
        flash("已复制 JSON")
    }

    func exportJSON() {
        guard let report else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.canCreateDirectories = true
        let stamp = report.generatedAt.replacingOccurrences(of: ":", with: "-").prefix(19)
        panel.nameFieldStringValue = "ccenv-\(stamp).json"
        panel.begin { [weak self] resp in
            guard resp == .OK, let url = panel.url else { return }
            do {
                try CCEnv.json(report).write(to: url, atomically: true, encoding: .utf8)
                self?.flash("已导出到 \(url.lastPathComponent)")
            } catch {
                self?.flash("导出失败：\(error.localizedDescription)")
            }
        }
    }

    // MARK: 分享图片

    private func renderShareImage() -> ShareImage? {
        guard let report else { return nil }
        if let img = ShareImage.render(report) { return img }
        flash("生成图片失败")
        return nil
    }

    func presentShareImage() {
        shareImage = renderShareImage()
    }

    func copyImage() {
        guard let img = renderShareImage() else { return }
        copyShareImage(img)
    }

    func copyShareImage(_ img: ShareImage) {
        let item = NSPasteboardItem()
        item.setData(img.png, forType: .png)
        if let tiff = img.image.tiffRepresentation { item.setData(tiff, forType: .tiff) } // 有些应用只认 TIFF
        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects([item])
        flash("已复制图片，可直接粘贴")
    }

    func saveShareImage(_ img: ShareImage) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = img.fileName
        panel.begin { [weak self] resp in
            guard resp == .OK, let url = panel.url else { return }
            do {
                try img.png.write(to: url, options: .atomic)
                self?.flash("已存储到 \(url.lastPathComponent)")
            } catch {
                self?.flash("存储失败：\(error.localizedDescription)")
            }
        }
    }

    // MARK: 更新

    func checkForUpdates() {
        Task {
            if let msg = await updater.check(userInitiated: true) { flash(msg) }
        }
    }

    // MARK: 指纹

    var diffRows: [String: FingerprintDiffRow] {
        guard let baseline, let fingerprint else { return [:] }
        return Dictionary(Fingerprints.diff(baseline.fp, fingerprint).map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
    }

    /// 基准快照里有、现在没有的条目。
    var removedItems: [FingerprintItem] {
        guard let baseline, let fingerprint else { return [] }
        let ids = Set(fingerprint.items.map { $0.id })
        return baseline.fp.items.filter { !ids.contains($0.id) }
    }

    func refreshFingerprint() {
        fingerprintBusy = true
        let version = Self.appVersion
        Task {
            let fp = await Task.detached(priority: .userInitiated) { Fingerprints.collect(version: version) }.value
            withAnimation(.snappy) {
                fingerprint = fp
                fingerprintBusy = false
                recentSnapshots = Array(Fingerprints.listSnapshots().suffix(8).reversed())
            }
        }
    }

    func saveSnapshot() {
        guard let fingerprint else { return }
        do {
            let url = try Fingerprints.save(fingerprint)
            recentSnapshots = Array(Fingerprints.listSnapshots().suffix(8).reversed())
            flash("快照已存到 ~/.ccenv/fingerprints/\(url.lastPathComponent)")
        } catch {
            flash("存储失败：\(error.localizedDescription)")
        }
    }

    func exportFingerprint() {
        guard let fingerprint else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = "ccenv-fingerprint-\(fingerprint.generatedAt.replacingOccurrences(of: ":", with: "-").prefix(19)).json"
        panel.begin { [weak self] resp in
            guard resp == .OK, let url = panel.url else { return }
            do {
                try Fingerprints.save(fingerprint, to: url)
                self?.flash("已导出到 \(url.lastPathComponent)")
            } catch {
                self?.flash("导出失败：\(error.localizedDescription)")
            }
        }
    }

    func compare(with url: URL) {
        do {
            let fp = try Fingerprints.load(url)
            withAnimation(.snappy) { baseline = Baseline(name: url.lastPathComponent, fp: fp) }
        } catch {
            flash(error.localizedDescription)
        }
    }

    func pickSnapshotToCompare() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.directoryURL = Fingerprints.snapshotDir
        panel.begin { [weak self] resp in
            guard resp == .OK, let url = panel.url else { return }
            self?.compare(with: url)
        }
    }

    func clearBaseline() {
        withAnimation(.snappy) { baseline = nil }
    }

    func copyValue(_ item: FingerprintItem) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(item.value ?? "", forType: .string)
        flash("已复制\(item.label)")
    }

    func askRegenerate() {
        let items = fingerprint?.items ?? []
        let hasDesktop = items.contains { $0.resettable && $0.group == Fingerprints.desktopGroup }
        let hasCode = items.contains { $0.resettable && $0.group != Fingerprints.desktopGroup }
        let desktopRunning = !NSRunningApplication.runningApplications(withBundleIdentifier: Fingerprints.desktopBundleID).isEmpty
        Task {
            let running = await Task.detached { Fingerprints.runningClaudeCode() }.value
            regenerateConfirm = RegenerateContext(codeRunning: running, hasCode: hasCode, hasDesktop: hasDesktop, desktopRunning: desktopRunning)
        }
    }

    /// 正常退出桌面版（相当于 ⌘Q），最多等 15 秒。返回退出前的 bundle 位置，用于之后重新打开；没退出返回 nil。
    private func quitDesktop() async -> URL? {
        let apps = NSRunningApplication.runningApplications(withBundleIdentifier: Fingerprints.desktopBundleID)
        guard let url = apps.first?.bundleURL else { return nil }
        apps.forEach { $0.terminate() }
        for _ in 0..<75 {
            if apps.allSatisfy(\.isTerminated) { return url }
            try? await Task.sleep(nanoseconds: 200_000_000)
        }
        return nil
    }

    /// 重新生成前自动存一份快照并设为对比基准，做完直接能看到哪些值变了。
    /// includeDesktop：连同桌面版的 ant-did / salt；quitDesktop：桌面版在运行时先退出，改完再打开。
    func regenerateIds(includeDesktop: Bool, quitDesktop shouldQuit: Bool = false) {
        let version = Self.appVersion
        fingerprintBusy = true
        Task {
            var desktop = includeDesktop
            var relaunch: URL?
            var note = ""
            if desktop && shouldQuit {
                relaunch = await quitDesktop()
                if relaunch == nil {
                    desktop = false
                    note = "；桌面版没有退出，跳过了它的 ID"
                }
            }
            if desktop && !NSRunningApplication.runningApplications(withBundleIdentifier: Fingerprints.desktopBundleID).isEmpty {
                desktop = false
                note = "；桌面版仍在运行，跳过了它的 ID"
            }
            let doDesktop = desktop
            let outcome = await Task.detached(priority: .userInitiated) { () -> Result<(URL, [RegenerateResult]), Error> in
                do {
                    let before = Fingerprints.collect(version: version)
                    let snap = try Fingerprints.save(before)
                    var results = try Fingerprints.regenerateIds()
                    if doDesktop { results += try Fingerprints.regenerateDesktopIds() }
                    return .success((snap, results))
                } catch {
                    return .failure(error)
                }
            }.value
            if let relaunch {
                NSWorkspace.shared.openApplication(at: relaunch, configuration: NSWorkspace.OpenConfiguration()) { _, _ in }
            }
            fingerprintBusy = false
            switch outcome {
            case .success(let (snap, results)):
                compare(with: snap)
                let n = results.reduce(0) { $0 + $1.changes.count }
                flash(n > 0 ? "已重新生成 \(n) 个 ID，旧文件备份在 ~/.ccenv/backups\(note)" : "没有可重新生成的 ID\(note)")
            case .failure(let error):
                flash("重新生成失败：\(error.localizedDescription)")
            }
            refreshFingerprint()
        }
    }

    private func flash(_ text: String) {
        toastTask?.cancel()
        withAnimation(.snappy) { toast = text }
        toastTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 2_200_000_000)
            guard !Task.isCancelled else { return }
            withAnimation(.snappy) { self?.toast = nil }
        }
    }
}
