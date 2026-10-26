// 子进程与 C API 的薄封装。只读，不改任何设置。

import Foundation
import Darwin

enum Shell {
    /// 运行一个外部命令，超时或失败返回 nil。stdout 用后台线程读完，避免管道写满死锁。
    static func run(_ path: String, _ args: [String] = [], timeout: TimeInterval = 5) -> String? {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: path)
        proc.arguments = args
        let out = Pipe()
        proc.standardOutput = out
        proc.standardError = FileHandle.nullDevice
        proc.standardInput = FileHandle.nullDevice

        var data = Data()
        let reader = DispatchGroup()
        reader.enter()
        DispatchQueue.global(qos: .utility).async {
            data = out.fileHandleForReading.readDataToEndOfFile()
            reader.leave()
        }
        // terminationHandler 必须在 run() 之前装好，否则命令跑得太快会错过回调、白等到超时。
        let done = DispatchGroup()
        done.enter()
        proc.terminationHandler = { _ in done.leave() }
        do {
            try proc.run()
        } catch {
            done.leave()
            return nil
        }
        if done.wait(timeout: .now() + timeout) == .timedOut {
            proc.terminate()
            _ = done.wait(timeout: .now() + 1)
            return nil
        }
        _ = reader.wait(timeout: .now() + 1)
        guard proc.terminationStatus == 0 else { return nil }
        return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func sysctlString(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buf = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buf, &size, nil, 0) == 0 else { return nil }
        return String(cString: buf)
    }

    static func sysctlInt(_ name: String) -> Int? {
        var value: Int32 = 0
        var size = MemoryLayout<Int32>.size
        guard sysctlbyname(name, &value, &size, nil, 0) == 0 else { return nil }
        return Int(value)
    }

    /// 当前用户的登录 shell（GUI 进程拿不到终端里的 SHELL，要查 passwd）。
    static var loginShell: String {
        if let pw = getpwuid(getuid()), let shell = pw.pointee.pw_shell {
            return String(cString: shell)
        }
        return ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
    }

    /// 以登录 shell 启动一次拿到用户的环境变量（LANG / TZ / 代理变量等）。
    /// Finder 启动的 app 没有这些变量，要模拟终端的视角就得问 shell。
    static func loginShellEnvironment(timeout: TimeInterval = 4) -> [String: String] {
        let shell = loginShell
        guard let out = run(shell, ["-l", "-c", "/usr/bin/env"], timeout: timeout) else {
            return ProcessInfo.processInfo.environment
        }
        var env: [String: String] = [:]
        for line in out.split(separator: "\n") {
            guard let eq = line.firstIndex(of: "=") else { continue }
            let key = String(line[line.startIndex..<eq])
            let value = String(line[line.index(after: eq)...])
            if !key.isEmpty, key.range(of: "^[A-Za-z_][A-Za-z0-9_]*$", options: .regularExpression) != nil {
                env[key] = value
            }
        }
        return env.isEmpty ? ProcessInfo.processInfo.environment : env
    }
}

/// 带缓存的正则辅助，字体名单和各类解析都用它。
enum Rx {
    private static var cache: [String: NSRegularExpression] = [:]
    private static let lock = NSLock()

    static func regex(_ pattern: String, caseInsensitive: Bool = true) -> NSRegularExpression? {
        let key = (caseInsensitive ? "i:" : "c:") + pattern
        lock.lock(); defer { lock.unlock() }
        if let r = cache[key] { return r }
        let r = try? NSRegularExpression(pattern: pattern, options: caseInsensitive ? [.caseInsensitive] : [])
        if let r { cache[key] = r }
        return r
    }

    static func test(_ pattern: String, _ s: String, caseInsensitive: Bool = true) -> Bool {
        guard let r = regex(pattern, caseInsensitive: caseInsensitive) else { return false }
        return r.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) != nil
    }

    /// 第一处匹配的捕获组（1-based）。
    static func groups(_ pattern: String, _ s: String, caseInsensitive: Bool = true) -> [String?]? {
        guard let r = regex(pattern, caseInsensitive: caseInsensitive),
              let m = r.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) else { return nil }
        return (1..<m.numberOfRanges).map { i in
            let range = m.range(at: i)
            guard range.location != NSNotFound, let rr = Range(range, in: s) else { return nil }
            return String(s[rr])
        }
    }

    static func allGroups(_ pattern: String, _ s: String) -> [[String?]] {
        guard let r = regex(pattern) else { return [] }
        return r.matches(in: s, range: NSRange(s.startIndex..., in: s)).map { m in
            (1..<m.numberOfRanges).map { i in
                let range = m.range(at: i)
                guard range.location != NSNotFound, let rr = Range(range, in: s) else { return nil }
                return String(s[rr])
            }
        }
    }
}
