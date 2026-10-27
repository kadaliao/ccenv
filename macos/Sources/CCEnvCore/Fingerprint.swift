// Claude 在本机留下的标识（指纹）：采集、快照、对比、重新生成。src/fingerprint.js 的 Swift 移植，
// 条目 ID、文案、快照格式和 CLI 相同，两边存的快照可以互相对比（默认都放在 ~/.ccenv/fingerprints）。
//
// 只读固定位置里的标识字段，不读令牌、会话和项目数据。
// 「重新生成」只改首次运行时随机生成、缺失时会自动重建的标识，写前先备份：
//   Claude Code 的 userID / machineID / summonSidKey；桌面版的 ant-did 和 ccd-ids.json 的 salt（只在桌面版退出时改）。
// 设备登记（ant-device-registry.json）背后是钥匙串 / Secure Enclave 里的硬件密钥，属于安全凭据，不碰。

import Foundation
import Darwin

public struct FingerprintItem: Codable, Hashable, Identifiable, Sendable {
    public var id: String
    public var group: String
    public var label: String
    public var value: String?
    public var source: String
    public var note: String?
    public var resettable: Bool
    /// 标识类的值，展示时默认打码。
    public var masked: Bool
    /// 个人信息（邮箱），打码更狠。
    public var sensitive: Bool

    public init(id: String, group: String, label: String, value: String?, source: String, note: String? = nil, resettable: Bool = false, masked: Bool = false, sensitive: Bool = false) {
        self.id = id
        self.group = group
        self.label = label
        self.value = value
        self.source = source
        self.note = note
        self.resettable = resettable
        self.masked = masked || sensitive
        self.sensitive = sensitive
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        group = try c.decodeIfPresent(String.self, forKey: .group) ?? "其它"
        label = try c.decodeIfPresent(String.self, forKey: .label) ?? id
        value = try c.decodeIfPresent(String.self, forKey: .value)
        source = try c.decodeIfPresent(String.self, forKey: .source) ?? ""
        note = try c.decodeIfPresent(String.self, forKey: .note)
        resettable = try c.decodeIfPresent(Bool.self, forKey: .resettable) ?? false
        sensitive = try c.decodeIfPresent(Bool.self, forKey: .sensitive) ?? false
        masked = (try c.decodeIfPresent(Bool.self, forKey: .masked) ?? true) || sensitive
    }

    /// 展示值：reveal=false 时按 masked / sensitive 打码。
    public func display(reveal: Bool) -> String {
        reveal ? (value ?? "—") : Fingerprints.mask(value, masked: masked, sensitive: sensitive)
    }
}

public struct Fingerprint: Codable, Sendable {
    public var tool: String
    public var kind: String
    public var schema: Int
    public var version: String
    public var generatedAt: String
    public var host: String
    public var items: [FingerprintItem]

    public var groups: [String] {
        var seen: [String] = []
        for i in items where !seen.contains(i.group) { seen.append(i.group) }
        return seen
    }

    public var hasResettable: Bool { items.contains { $0.resettable } }
}

public enum DiffStatus: String, Codable, Sendable {
    case same, changed, added, removed
}

public struct FingerprintDiffRow: Codable, Hashable, Identifiable, Sendable {
    public var id: String
    public var status: DiffStatus
    public var before: String?
    public var after: String?
}

public struct RegenerateChange: Sendable, Hashable {
    public var key: String
    public var before: String
    public var after: String
}

public struct RegenerateResult: Sendable {
    public var file: String
    public var changes: [RegenerateChange]
    public var backup: String?
}

public enum FingerprintError: LocalizedError {
    case locked(String)
    case invalidJSON(String)
    case notSnapshot(String)

    public var errorDescription: String? {
        switch self {
        case .locked(let f): return "\(f) 正被 Claude Code 占用，稍后再试"
        case .invalidJSON(let f): return "\(f) 不是合法的 JSON"
        case .notSnapshot(let f): return "不是 ccenv 指纹快照：\(f)"
        }
    }
}

public enum Fingerprints {
    public static let schema = 1
    public static let resettableKeys = ["userID", "machineID", "summonSidKey"]

    static var home: String { NSHomeDirectory() }
    public static var snapshotDir: URL { URL(fileURLWithPath: home).appendingPathComponent(".ccenv/fingerprints") }
    static var backupDir: URL { URL(fileURLWithPath: home).appendingPathComponent(".ccenv/backups") }
    public static var desktopDir: String { (home as NSString).appendingPathComponent("Library/Application Support/Claude") }
    public static let desktopBundleID = "com.anthropic.claudefordesktop"
    public static let desktopGroup = "Claude 桌面版"

    /// ant-did 文件内容是 base64 编码的 UUID，解不出 UUID 返回 nil。
    public static func decodeAntDid(_ raw: String?) -> String? {
        guard let raw, let data = Data(base64Encoded: raw.trimmingCharacters(in: .whitespacesAndNewlines)),
              let s = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
              UUID(uuidString: s) != nil else { return nil }
        return s
    }

    public static func tildify(_ p: String) -> String {
        let h = home
        if p == h { return "~" }
        return p.hasPrefix(h + "/") ? "~" + p.dropFirst(h.count) : p
    }

    static func isHex64(_ s: String) -> Bool {
        s.count == 64 && s.allSatisfy { ("0"..."9").contains($0) || ("a"..."f").contains($0) }
    }

    static func readJSON(_ path: String) -> Any? {
        guard let data = FileManager.default.contents(atPath: path) else { return nil }
        return try? JSONSerialization.jsonObject(with: data)
    }

    static func stringValue(_ v: Any?) -> String? {
        switch v {
        case let s as String: return s
        case let n as NSNumber:
            return CFGetTypeID(n) == CFBooleanGetTypeID() ? (n.boolValue ? "true" : "false") : n.stringValue
        default: return nil
        }
    }

    static let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    // MARK: 采集

    /// Claude Code 可能使用的全局配置文件，去重后按优先级排列。
    public static func claudeCodeConfigPaths(env: [String: String] = ProcessInfo.processInfo.environment) -> [String] {
        var list: [String] = []
        if let dir = env["CLAUDE_CONFIG_DIR"], !dir.isEmpty { list.append((dir as NSString).appendingPathComponent(".claude.json")) }
        list.append((home as NSString).appendingPathComponent(".claude.json"))
        list.append((home as NSString).appendingPathComponent(".claude/.claude.json"))
        var seen = Set<String>()
        return list.map { ($0 as NSString).standardizingPath }
            .filter { seen.insert($0).inserted && FileManager.default.fileExists(atPath: $0) }
    }

    struct Field {
        let key: String
        let label: String
        var note: String? = nil
        var masked = false
        var sensitive = false
    }

    static let codeFields: [Field] = [
        Field(key: "userID", label: "设备 ID (userID)", note: "遥测里的 device_id，首次运行时随机生成", masked: true),
        Field(key: "machineID", label: "机器 ID (machineID)", note: "首次运行时随机生成", masked: true),
        Field(key: "summonSidKey", label: "summonSidKey", note: "首次使用相关功能时随机生成", masked: true),
        Field(key: "firstStartTime", label: "首次启动时间"),
        Field(key: "firstStartVersion", label: "首次启动版本"),
        Field(key: "installMethod", label: "安装方式"),
        Field(key: "oauthAccount.accountUuid", label: "账号 UUID", note: "服务端账号身份，本地改不了", masked: true),
        Field(key: "oauthAccount.organizationUuid", label: "组织 UUID", masked: true),
        Field(key: "oauthAccount.emailAddress", label: "账号邮箱", sensitive: true),
    ]

    /// 从一个已解析的 .claude.json 里取标识字段。
    public static func claudeCodeItems(_ config: [String: Any], file: String) -> [FingerprintItem] {
        let src = tildify(file)
        let group = "Claude Code · \(src)"
        return codeFields.compactMap { f in
            var cur: Any? = config
            for part in f.key.split(separator: ".") { cur = (cur as? [String: Any])?[String(part)] }
            guard let value = stringValue(cur) else { return nil }
            return FingerprintItem(id: "\(src)#\(f.key)", group: group, label: f.label, value: value, source: src, note: f.note,
                                   resettable: resettableKeys.contains(f.key) && isHex64(value), masked: f.masked, sensitive: f.sensitive)
        }
    }

    static func desktopItems() -> [FingerprintItem] {
        let dir = desktopDir
        guard FileManager.default.fileExists(atPath: dir) else { return [] }
        let group = desktopGroup
        func path(_ f: String) -> String { (dir as NSString).appendingPathComponent(f) }
        func src(_ f: String) -> String { tildify(path(f)) }
        var out: [FingerprintItem] = []
        if let raw = try? String(contentsOfFile: path("ant-did"), encoding: .utf8) {
            let did = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if !did.isEmpty {
                out.append(.init(id: src("ant-did"), group: group, label: "设备 ID (ant-did)", value: did, source: src("ant-did"),
                                 note: "桌面版首次启动时随机生成的 UUID（base64 存储）", resettable: decodeAntDid(did) != nil, masked: true))
            }
        }
        if let salt = (readJSON(path("ccd-ids.json")) as? [String: Any])?["salt"] as? String {
            out.append(.init(id: "\(src("ccd-ids.json"))#salt", group: group, label: "ID 盐 (ccd-ids)", value: salt, source: src("ccd-ids.json"),
                             note: "桌面版随机生成，用来给本地路径做哈希", resettable: !salt.isEmpty, masked: true))
        }
        if let registry = readJSON(path("ant-device-registry.json")) as? [String: Any] {
            // 值是设备登记凭据，只列出登记过的账号，不读值。
            let keys = registry.keys.sorted()
            out.append(.init(id: "\(src("ant-device-registry.json"))#keys", group: group, label: "设备登记", value: keys.isEmpty ? "无" : keys.joined(separator: ", "),
                             source: src("ant-device-registry.json"), note: "只列登记过的账号，不读登记凭据", masked: true))
        }
        // config.json 里有登录令牌，只取两个非敏感字段。
        if let cfg = readJSON(path("config.json")) as? [String: Any] {
            if let uuid = cfg["lastKnownAccountUuid"] as? String {
                out.append(.init(id: "\(src("config.json"))#lastKnownAccountUuid", group: group, label: "最近账号 UUID", value: uuid, source: src("config.json"), masked: true))
            }
            if let ms = cfg["first_launch_at"] as? NSNumber, CFGetTypeID(ms) != CFBooleanGetTypeID() {
                out.append(.init(id: "\(src("config.json"))#first_launch_at", group: group, label: "首次启动时间",
                                 value: iso.string(from: Date(timeIntervalSince1970: ms.doubleValue / 1000)), source: src("config.json")))
            }
        }
        return out
    }

    static var hostname: String {
        var buf = [CChar](repeating: 0, count: 256)
        return gethostname(&buf, buf.count) == 0 ? String(cString: buf) : ProcessInfo.processInfo.hostName
    }

    static func hardwareItems() -> [FingerprintItem] {
        let group = "本机硬件"
        var out: [FingerprintItem] = []
        if let io = Shell.run("/usr/sbin/ioreg", ["-rd1", "-c", "IOPlatformExpertDevice"]),
           let uuid = Rx.groups(#""IOPlatformUUID" = "([^"]+)""#, io)?.first ?? nil {
            out.append(.init(id: "hardware#IOPlatformUUID", group: group, label: "硬件 UUID", value: uuid, source: "ioreg",
                             note: "Claude Code 的 OpenTelemetry 用它作 host.id，只在开启 OTel 时上报", masked: true))
        }
        out.append(.init(id: "hardware#hostname", group: group, label: "主机名", value: hostname, source: "os.hostname()"))
        return out
    }

    public static func collect(version: String = coreVersion) -> Fingerprint {
        var items: [FingerprintItem] = []
        for file in claudeCodeConfigPaths() {
            if let cfg = readJSON(file) as? [String: Any] { items += claudeCodeItems(cfg, file: file) }
        }
        items += desktopItems()
        items += hardwareItems()
        return Fingerprint(tool: "ccenv", kind: "fingerprint", schema: schema, version: version,
                           generatedAt: iso.string(from: Date()), host: hostname, items: items)
    }

    // MARK: 进程

    public static func isClaudeCodeProcess(_ args: String) -> Bool {
        Rx.test(#"/claude/versions/[^/\s]+(\s|$)"#, args, caseInsensitive: false)
            || Rx.test(#"@anthropic-ai/claude-code/"#, args, caseInsensitive: false)
            || Rx.test(#"(^|/)claude(\s|$)"#, args, caseInsensitive: false)
    }

    public static func isClaudeDesktopProcess(_ args: String) -> Bool {
        Rx.test(#"/Claude\.app/Contents/MacOS/Claude(\s|$)"#, args, caseInsensitive: false)
    }

    /// 正在运行的 Claude Code 进程数。它们把标识缓存在内存里，重新生成后要重启才会用新值。
    public static func runningClaudeCode() -> Int {
        guard let out = Shell.run("/bin/ps", ["-axo", "pid=,args="]) else { return 0 }
        return out.split(separator: "\n").filter { line in
            let args = String(line).trimmingCharacters(in: .whitespaces).replacingOccurrences(of: #"^\d+\s+"#, with: "", options: .regularExpression)
            return isClaudeCodeProcess(args)
        }.count
    }

    // MARK: 对比 / 打码

    /// 逐条对比两份快照。
    public static func diff(_ before: Fingerprint, _ after: Fingerprint) -> [FingerprintDiffRow] {
        let prev = Dictionary(before.items.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let nextIds = Set(after.items.map { $0.id })
        var rows: [FingerprintDiffRow] = after.items.map { cur in
            guard let old = prev[cur.id] else { return .init(id: cur.id, status: .added, before: nil, after: cur.value) }
            return .init(id: cur.id, status: old.value == cur.value ? .same : .changed, before: old.value, after: cur.value)
        }
        rows += before.items.filter { !nextIds.contains($0.id) }.map { .init(id: $0.id, status: .removed, before: $0.value, after: nil) }
        return rows
    }

    /// 展示用打码：保留头 8 尾 4；邮箱只留首字母和域名。
    public static func mask(_ value: String?, masked: Bool = true, sensitive: Bool = false) -> String {
        guard let s = value else { return "—" }
        if !masked && !sensitive { return s }
        if sensitive, let at = s.firstIndex(of: "@") {
            return "\(s.prefix(1))***@\(s[s.index(after: at)...])"
        }
        return s.count > 16 ? "\(s.prefix(8))…\(s.suffix(4))" : s
    }

    // MARK: 快照

    static func stamp(_ d: Date = Date()) -> String {
        String(iso.string(from: d).replacingOccurrences(of: ":", with: "-").replacingOccurrences(of: ".", with: "-").prefix(19))
    }

    public static func encode(_ fp: Fingerprint) -> Data {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .withoutEscapingSlashes]
        return (try? enc.encode(fp)) ?? Data("{}".utf8)
    }

    @discardableResult
    public static func save(_ fp: Fingerprint, to url: URL? = nil) throws -> URL {
        let target = url ?? snapshotDir.appendingPathComponent("fingerprint-\(stamp()).json")
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        try encode(fp).write(to: target, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: target.path)
        return target
    }

    public static func load(_ url: URL) throws -> Fingerprint {
        let data = try Data(contentsOf: url)
        guard let fp = try? JSONDecoder().decode(Fingerprint.self, from: data), fp.kind == "fingerprint" else {
            throw FingerprintError.notSnapshot(url.lastPathComponent)
        }
        return fp
    }

    public static func listSnapshots() -> [URL] {
        let urls = (try? FileManager.default.contentsOfDirectory(at: snapshotDir, includingPropertiesForKeys: nil)) ?? []
        return urls.filter { $0.pathExtension == "json" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    // MARK: 重新生成

    public static func randomHex64() -> String {
        var rng = SystemRandomNumberGenerator()
        return (0..<32).map { _ in String(format: "%02x", UInt8.random(in: 0...255, using: &rng)) }.joined()
    }

    /// 在原文里把 "key": "<旧值>" 换成新值，其它字节保持原样（不重排键、不改缩进）。只换 64 位十六进制的值。
    public static func regenerate(in text: String, keys: [String] = resettableKeys, generate: () -> String = randomHex64) throws -> (text: String, changes: [RegenerateChange]) {
        guard let obj = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any] else { throw FingerprintError.invalidJSON("配置") }
        var out = text
        var changes: [RegenerateChange] = []
        for key in keys {
            guard let old = obj[key] as? String, isHex64(old) else { continue }
            let next = generate()
            guard let replaced = replaceValue(in: out, key: key, old: old, with: next) else { continue }
            out = replaced
            changes.append(.init(key: key, before: old, after: next))
        }
        // 防御：写回去之前确认仍是合法 JSON
        guard (try? JSONSerialization.jsonObject(with: Data(out.utf8))) != nil else { throw FingerprintError.invalidJSON("配置") }
        return (out, changes)
    }

    /// 把原文里 "key": "<old>" 的值换成 next，其它字节不变；没匹配到返回 nil。
    static func replaceValue(in text: String, key: String, old: String, with next: String) -> String? {
        let pattern = "\"\(NSRegularExpression.escapedPattern(for: key))\"\\s*:\\s*\"\(NSRegularExpression.escapedPattern(for: old))\""
        guard let re = try? NSRegularExpression(pattern: pattern) else { return nil }
        let ns = text as NSString
        let matches = re.matches(in: text, range: NSRange(location: 0, length: ns.length))
        if matches.isEmpty { return nil }
        // 从后往前替换每处匹配里的旧值，前面的偏移量不受影响。
        let mutable = NSMutableString(string: text)
        for m in matches.reversed() {
            // 值在匹配的末尾：跳过末尾引号往前取 old 的长度
            let inner = NSRange(location: m.range.location + m.range.length - 1 - (old as NSString).length, length: (old as NSString).length)
            mutable.replaceCharacters(in: inner, with: next)
        }
        return mutable as String
    }

    static func backupFile(_ file: String, to dir: URL) throws -> String {
        let fm = FileManager.default
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let name = tildify(file).replacingOccurrences(of: #"^~/"#, with: "", options: .regularExpression).replacingOccurrences(of: "/", with: "_")
        let backup = dir.appendingPathComponent("\(name)-\(stamp())")
        try? fm.removeItem(at: backup)
        try fm.copyItem(atPath: file, toPath: backup.path)
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: backup.path)
        return backup.path
    }

    /// 写临时文件再 rename，保留原文件权限。
    static func atomicWrite(_ text: String, to file: String) throws {
        let fm = FileManager.default
        let mode = ((try? fm.attributesOfItem(atPath: file))?[.posixPermissions] as? NSNumber)?.intValue ?? 0o600
        let tmp = file + ".ccenv-\(getpid()).tmp"
        try Data(text.utf8).write(to: URL(fileURLWithPath: tmp))
        try fm.setAttributes([.posixPermissions: mode], ofItemAtPath: tmp)
        guard rename(tmp, file) == 0 else {
            let err = POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            try? fm.removeItem(atPath: tmp)
            throw err
        }
    }

    /// 和 Claude Code（proper-lockfile）同一把锁：<file>.lock 目录。超过 10 秒视为陈旧锁。
    static func withConfigLock<T>(_ file: String, _ body: () throws -> T) throws -> T {
        let lock = file + ".lock"
        let fm = FileManager.default
        let deadline = Date().addingTimeInterval(5)
        while mkdir(lock, 0o755) != 0 {
            guard errno == EEXIST else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            if let m = (try? fm.attributesOfItem(atPath: lock))?[.modificationDate] as? Date, Date().timeIntervalSince(m) > 10 {
                rmdir(lock)
                continue
            }
            if Date() > deadline { throw FingerprintError.locked(tildify(file)) }
            usleep(100_000)
        }
        defer { rmdir(lock) }
        return try body()
    }

    /// 重新生成所有 Claude Code 配置里的随机标识。每个文件先备份到 ~/.ccenv/backups。
    public static func regenerateIds(files: [String] = claudeCodeConfigPaths(), keys: [String] = resettableKeys, backupTo: URL? = nil) throws -> [RegenerateResult] {
        let backupDir = backupTo ?? self.backupDir
        return try files.map { file in
            try withConfigLock(file) {
                guard let text = try? String(contentsOfFile: file, encoding: .utf8) else { throw FingerprintError.invalidJSON(tildify(file)) }
                let (next, changes) = try regenerate(in: text, keys: keys)
                guard !changes.isEmpty else { return RegenerateResult(file: file, changes: [], backup: nil) }
                let backup = try backupFile(file, to: backupDir)
                try atomicWrite(next, to: file)
                return RegenerateResult(file: file, changes: changes, backup: backup)
            }
        }
    }

    /// 重新生成桌面版的 ant-did 和 ccd-ids.json 的 salt。桌面版只在启动时读它们，
    /// 运行中改了会被忽略甚至写回，调用方要先确认桌面版已退出。
    public static func regenerateDesktopIds(dir: String = desktopDir, backupTo: URL? = nil, generate: () -> String = { UUID().uuidString.lowercased() }) throws -> [RegenerateResult] {
        let backupDir = backupTo ?? self.backupDir
        var results: [RegenerateResult] = []
        let did = (dir as NSString).appendingPathComponent("ant-did")
        if let raw = try? String(contentsOfFile: did, encoding: .utf8), decodeAntDid(raw) != nil {
            let backup = try backupFile(did, to: backupDir)
            let next = Data(generate().utf8).base64EncodedString()
            try atomicWrite(next, to: did)
            results.append(.init(file: did, changes: [.init(key: "ant-did", before: raw.trimmingCharacters(in: .whitespacesAndNewlines), after: next)], backup: backup))
        }
        let ids = (dir as NSString).appendingPathComponent("ccd-ids.json")
        if let text = try? String(contentsOfFile: ids, encoding: .utf8),
           let obj = (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any],
           let old = obj["salt"] as? String {
            let next = generate()
            if let replaced = replaceValue(in: text, key: "salt", old: old, with: next) {
                let backup = try backupFile(ids, to: backupDir)
                try atomicWrite(replaced, to: ids)
                results.append(.init(file: ids, changes: [.init(key: "salt", before: old, after: next)], backup: backup))
            }
        }
        return results
    }
}
