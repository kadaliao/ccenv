// 自动更新：查 GitHub Releases → 下载 zip → 解压到和 app 同一卷的临时目录 → 校验 Developer ID 签名 →
// 退出后用一个小 shell 脚本把新 bundle 换到原位置（可选重新打开）。
//
// 只接受同一个 Team ID 签名、同一个 bundle id、版本号和 release 一致的包；任一项不符就放弃，不动现有 app。

import AppKit
import Observation
import CCEnvCore

@MainActor
@Observable
final class Updater {
    nonisolated static let teamID = "HMDAVG9B8J"
    nonisolated static let bundleID = "com.kadaliao.ccenv"
    /// 自动检查的最小间隔。
    static let checkInterval: TimeInterval = 20 * 3600

    enum State: Equatable {
        case idle
        case checking
        case upToDate
        case available(ReleaseInfo)
        case downloading(ReleaseInfo)
        /// 新版本已解压并通过校验，等待替换。
        case ready(ReleaseInfo, URL)
        case failed(String)
    }

    var state: State = .idle
    var lastChecked: Date? { didSet { UserDefaults.standard.set(lastChecked, forKey: "update.lastChecked") } }
    var autoCheck: Bool { didSet { UserDefaults.standard.set(autoCheck, forKey: "update.autoCheck") } }
    /// 发现新版本后自动下载，退出时安装。
    var autoInstall: Bool { didSet { UserDefaults.standard.set(autoInstall, forKey: "update.autoInstall") } }

    let currentVersion: String

    init(currentVersion: String) {
        self.currentVersion = currentVersion
        let d = UserDefaults.standard
        autoCheck = d.object(forKey: "update.autoCheck") as? Bool ?? true
        autoInstall = d.object(forKey: "update.autoInstall") as? Bool ?? true
        lastChecked = d.object(forKey: "update.lastChecked") as? Date
    }

    var isBusy: Bool {
        switch state {
        case .checking, .downloading: return true
        default: return false
        }
    }

    var pendingRelease: ReleaseInfo? {
        switch state {
        case .available(let r), .downloading(let r), .ready(let r, _): return r
        default: return nil
        }
    }

    // MARK: 检查

    /// 启动时调用：开了自动检查且距上次超过间隔才查，失败不打扰。
    func checkOnLaunch() {
        guard autoCheck, ProcessInfo.processInfo.environment["CCENV_SNAPSHOT"] == nil else { return }
        if !DevHooks.updateTest, let last = lastChecked, Date().timeIntervalSince(last) < Self.checkInterval { return }
        Task { await check(userInitiated: false) }
    }

    /// 返回给界面一句结果文案（手动检查时用）。
    @discardableResult
    func check(userInitiated: Bool) async -> String? {
        if case .ready = state { return "新版本已下载，退出时安装" }
        guard !isBusy else { return nil }
        state = .checking
        do {
            let release = try await UpdateCheck.fetchLatest()
            lastChecked = Date()
            guard UpdateCheck.compare(release.version, currentVersion) == .orderedDescending else {
                state = .upToDate
                return "ccenv \(currentVersion) 已是最新版本"
            }
            state = .available(release)
            if autoInstall && !userInitiated { await download(release) }
            return "发现新版本 \(release.version)"
        } catch {
            DevHooks.log("update check failed: \(error)")
            state = userInitiated ? .failed("检查更新失败：\(error.localizedDescription)") : .idle
            return userInitiated ? "检查更新失败：\(error.localizedDescription)" : nil
        }
    }

    // MARK: 下载与校验

    var installLocationProblem: String? {
        let path = Bundle.main.bundlePath
        if path.contains("/AppTranslocation/") || path.hasPrefix("/Volumes/") {
            return "ccenv 正从下载位置或磁盘映像里运行，先把它拖到「应用程序」文件夹再更新"
        }
        let parent = (path as NSString).deletingLastPathComponent
        if !FileManager.default.isWritableFile(atPath: parent) {
            return "没有写入 \(parent) 的权限，请到 Releases 页面手动下载"
        }
        return nil
    }

    func download(_ release: ReleaseInfo) async {
        if let problem = installLocationProblem { state = .failed(problem); return }
        guard let asset = release.macZip else { state = .failed("Release \(release.tagName) 里没有 macOS zip"); return }
        state = .downloading(release)
        do {
            let staged = try await Self.fetchAndVerify(asset: asset, version: release.version, near: Bundle.main.bundleURL)
            state = .ready(release, staged)
            DevHooks.log("update staged at \(staged.path)")
            if DevHooks.updateTest { NSApp.terminate(nil) }
        } catch {
            state = .failed("下载更新失败：\(error.localizedDescription)")
        }
    }

    nonisolated static func fetchAndVerify(asset: ReleaseInfo.Asset, version: String, near bundleURL: URL) async throws -> URL {
        let fm = FileManager.default
        // 和 app 同一个卷，最后一步 mv 是原子的
        let work = try fm.url(for: .itemReplacementDirectory, in: .userDomainMask, appropriateFor: bundleURL, create: true)
        var req = URLRequest(url: asset.browserDownloadURL, timeoutInterval: 60)
        req.setValue("ccenv/\(coreVersion) (macOS app; update)", forHTTPHeaderField: "User-Agent")
        let (tmp, resp) = try await URLSession.shared.download(for: req)
        if let http = resp as? HTTPURLResponse, http.statusCode != 200 {
            throw UpdateCheckError("下载返回 HTTP \(http.statusCode)")
        }
        let zip = work.appendingPathComponent(asset.name)
        try fm.moveItem(at: tmp, to: zip)
        let unzip = Process()
        unzip.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        unzip.arguments = ["-x", "-k", zip.path, work.path]
        try unzip.run()
        unzip.waitUntilExit()
        guard unzip.terminationStatus == 0 else { throw UpdateCheckError("解压失败") }
        try? fm.removeItem(at: zip)

        let app = work.appendingPathComponent("ccenv.app")
        guard fm.fileExists(atPath: app.path) else { throw UpdateCheckError("压缩包里没有 ccenv.app") }
        try verify(app: app, version: version)
        return app
    }

    nonisolated static func verify(app: URL, version: String) throws {
        try UpdateCheck.verify(app: app, version: version, bundleID: bundleID, teamID: teamID)
    }

    // MARK: 安装

    /// 起一个脱离本进程的 shell：等本进程退出 → 换 bundle → 可选重新打开。
    private func launchSwap(staged: URL, relaunch: Bool) {
        let script = """
        PID="$1"; NEW="$2"; DEST="$3"; RELAUNCH="$4"
        while kill -0 "$PID" 2>/dev/null; do sleep 0.2; done
        OLD="$DEST.ccenv-old-$$"
        if mv "$DEST" "$OLD"; then
          if mv "$NEW" "$DEST"; then rm -rf "$OLD"; else mv "$OLD" "$DEST"; fi
        fi
        rm -rf "$(dirname "$NEW")"
        [ "$RELAUNCH" = 1 ] && /usr/bin/open "$DEST"
        exit 0
        """
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", script, "ccenv-update", String(getpid()), staged.path, Bundle.main.bundlePath, relaunch ? "1" : "0"]
        p.standardInput = FileHandle.nullDevice
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try? p.run()
    }

    /// 立即安装并重新打开。
    func installNow() {
        guard case .ready(_, let staged) = state else { return }
        state = .idle // 防止 applicationWillTerminate 再换一次
        launchSwap(staged: staged, relaunch: true)
        NSApp.terminate(nil)
    }

    /// 退出时调用：有已就绪的更新就换掉，不重新打开。
    func installOnQuitIfReady() {
        guard case .ready(_, let staged) = state else { return }
        state = .idle
        launchSwap(staged: staged, relaunch: false)
    }

    /// 点「下载并安装」：下载完立刻重启到新版本。
    func downloadAndInstall() {
        guard case .available(let release) = state else { return }
        Task {
            await download(release)
            if case .ready = state { installNow() }
        }
    }

    func dismissFailure() {
        if case .failed = state { state = .idle }
    }
}
