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

    // 偏好：手动落到 UserDefaults（@Observable 和 @AppStorage 不能直接混用）
    var offline: Bool { didSet { UserDefaults.standard.set(offline, forKey: "offline") } }
    var samples: Int { didSet { UserDefaults.standard.set(samples, forKey: "samples") } }
    var timeoutMs: Int { didSet { UserDefaults.standard.set(timeoutMs, forKey: "timeoutMs") } }

    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var toastTask: Task<Void, Never>?

    init() {
        let d = UserDefaults.standard
        offline = d.bool(forKey: "offline")
        samples = d.object(forKey: "samples") as? Int ?? 6
        timeoutMs = d.object(forKey: "timeoutMs") as? Int ?? 8000
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
