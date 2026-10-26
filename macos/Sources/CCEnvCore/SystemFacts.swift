// 系统层事实采集：时区、区域/语言、硬件、代理链路、DNS。对应 CLI 的 src/system.js。

import Foundation
import CFNetwork
import Darwin

public enum TimeZoneMath {
    /// 任意 IANA 时区在当前时刻的 UTC 偏移（分钟，东正）。
    public static func offsetMinutes(for identifier: String?, at date: Date = Date()) -> Int? {
        guard let identifier, let tz = TimeZone(identifier: identifier) else { return nil }
        return tz.secondsFromGMT(for: date) / 60
    }

    public static func format(_ minutes: Int?) -> String {
        guard let minutes else { return "未知" }
        let sign = minutes < 0 ? "-" : "+"
        let abs = Swift.abs(minutes)
        return String(format: "UTC%@%02d:%02d", sign, abs / 60, abs % 60)
    }

    /// 两个偏移在 24 小时环上的最短距离。
    public static func circularMinutes(_ a: Int, _ b: Int) -> Int {
        let d = Swift.abs(a - b) % 1440
        return d > 720 ? 1440 - d : d
    }
}

public enum LocaleParsing {
    /// zh_SG / en_US.UTF-8 / zh-Hans-SG / de_DE@euro -> LocaleTag
    public static func parse(_ raw: String?) -> LocaleTag? {
        guard let raw, !raw.isEmpty else { return nil }
        var cleaned = raw
        if let dot = cleaned.firstIndex(of: ".") { cleaned = String(cleaned[..<dot]) }
        if let at = cleaned.firstIndex(of: "@") { cleaned = String(cleaned[..<at]) }
        cleaned = cleaned.replacingOccurrences(of: "_", with: "-")
        let parts = cleaned.split(separator: "-").map(String.init).filter { !$0.isEmpty }
        let language = parts.first?.lowercased()
        var script: String?
        var region: String?
        for p in parts.dropFirst() {
            if Rx.test("^[A-Za-z]{4}$", p) { script = p.lowercased() }
            else if Rx.test("^[A-Za-z]{2}$|^\\d{3}$", p) { region = p.uppercased() }
        }
        return LocaleTag(language: (language?.isEmpty ?? true) ? nil : language, script: script, region: region, raw: raw)
    }
}

public enum Net {
    /// 私有 / 保留 / 本机地址。100.x 只有 100.64/10 是 CGNAT；198.18/15 是 fake-ip 常用的基准测试段。
    public static func isPrivate(_ ip: String) -> Bool {
        let s = ip.trimmingCharacters(in: .whitespaces)
        if s.isEmpty { return false }
        if s.contains(":") {
            return Rx.test("^(::1$|::$|fe80:|f[cd][0-9a-f]{2}:)", s)
        }
        let p = s.split(separator: ".").map { Int($0) }
        guard p.count == 4, p.allSatisfy({ $0 != nil && $0! >= 0 && $0! <= 255 }) else { return false }
        let a = p[0]!, b = p[1]!
        return a == 0 || a == 10 || a == 127
            || (a == 100 && b >= 64 && b <= 127)
            || (a == 169 && b == 254)
            || (a == 172 && b >= 16 && b <= 31)
            || (a == 192 && b == 168)
            || (a == 198 && (b == 18 || b == 19))
    }

    public static func isV4(_ s: String?) -> Bool {
        guard let s else { return false }
        return Rx.test("^(\\d{1,3}\\.){3}\\d{1,3}$", s.trimmingCharacters(in: .whitespaces))
    }

    public static func isV6(_ s: String?) -> Bool {
        guard let s, s.contains(":") else { return false }
        return Rx.test("^[0-9a-f:.]+$", s.trimmingCharacters(in: .whitespaces))
    }
}

public enum SystemCollector {
    static let proxyApps = [
        "mihomo", "clash", "clashx", "clash-verge", "verge-mihomo", "sing-box",
        "v2ray", "xray", "v2rayu", "surge", "shadowrocket", "tun2socks",
        "wireguard-go", "openvpn", "tailscaled", "warp-svc", "trojan", "hysteria",
        "naive", "brook", "leaf", "stash", "loon", "quantumult",
    ]

    /// 从 `ps -axo comm=` 的输出里挑出已知代理/隧道进程名。
    public static func matchProxyApps(_ ps: String?) -> [String] {
        guard let ps else { return [] }
        var found: [String] = []
        for line in ps.split(separator: "\n") {
            let base = line.trimmingCharacters(in: .whitespaces).split(separator: "/").last.map { String($0).lowercased() } ?? ""
            if base.isEmpty { continue }
            for app in proxyApps {
                let suffix = base.hasPrefix(app) ? String(base.dropFirst(app.count)) : nil
                let ok = base == app || base == app + "d" || (suffix.map { !$0.isEmpty && !($0.first!.isLetter) } ?? false)
                if ok, !found.contains(base) { found.append(base) }
            }
        }
        return found
    }

    /// 解析 `scutil --proxy`。
    public static func parseScutilProxy(_ out: String?) -> SystemProxyFacts {
        guard let out else { return SystemProxyFacts(available: false) }
        var entries: [String: String] = [:]
        for line in out.split(separator: "\n") {
            if let g = Rx.groups("^\\s*([A-Za-z][\\w]*)\\s*:\\s*(\\S+)\\s*$", String(line)), let k = g[0], let v = g[1] {
                entries[k] = v
            }
        }
        let on = { (k: String) in entries[k] == "1" }
        return SystemProxyFacts(available: true, http: on("HTTPEnable"), https: on("HTTPSEnable"), socks: on("SOCKSEnable"), pac: on("ProxyAutoConfigEnable"))
    }

    /// 走 CFNetwork 读系统代理，不起子进程。
    static func systemProxy() -> SystemProxyFacts {
        guard let dict = CFNetworkCopySystemProxySettings()?.takeRetainedValue() as? [String: Any] else {
            return parseScutilProxy(Shell.run("/usr/sbin/scutil", ["--proxy"]))
        }
        let on = { (k: String) -> Bool in (dict[k] as? NSNumber)?.intValue == 1 }
        return SystemProxyFacts(available: true, http: on("HTTPEnable"), https: on("HTTPSEnable"), socks: on("SOCKSEnable"), pac: on("ProxyAutoConfigEnable"))
    }

    public struct Interface: Equatable {
        public var name: String
        public var inet: [String]
        public var inet6: [String]
    }

    /// 解析 `ifconfig` 全量输出（测试用；运行时走 getifaddrs）。
    public static func parseIfconfig(_ out: String?) -> [Interface] {
        var ifaces: [Interface] = []
        for raw in (out ?? "").split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(raw)
            if let g = Rx.groups("^([a-z][\\w.-]*\\d*):\\s+flags=", line), let name = g[0] {
                ifaces.append(Interface(name: name, inet: [], inet6: []))
                continue
            }
            guard !ifaces.isEmpty else { continue }
            let t = line.trimmingCharacters(in: .whitespaces)
            if let g = Rx.groups("^inet\\s+(\\d+\\.\\d+\\.\\d+\\.\\d+)", t), let ip = g[0] {
                ifaces[ifaces.count - 1].inet.append(ip)
            } else if let g = Rx.groups("^inet6\\s+([0-9a-f:]+)", t), let ip = g[0], !ip.lowercased().hasPrefix("fe80:") {
                ifaces[ifaces.count - 1].inet6.append(ip)
            }
        }
        return ifaces
    }

    /// 用 getifaddrs 列出接口地址。
    static func interfaces() -> [Interface] {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return [] }
        defer { freeifaddrs(head) }
        var order: [String] = []
        var map: [String: Interface] = [:]
        var p: UnsafeMutablePointer<ifaddrs>? = first
        while let cur = p {
            defer { p = cur.pointee.ifa_next }
            let name = String(cString: cur.pointee.ifa_name)
            if map[name] == nil {
                map[name] = Interface(name: name, inet: [], inet6: [])
                order.append(name)
            }
            guard let addr = cur.pointee.ifa_addr else { continue }
            let family = Int32(addr.pointee.sa_family)
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            if family == AF_INET {
                if getnameinfo(addr, socklen_t(addr.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 {
                    map[name]?.inet.append(String(cString: host))
                }
            } else if family == AF_INET6 {
                if getnameinfo(addr, socklen_t(addr.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 {
                    var ip = String(cString: host)
                    if let pct = ip.firstIndex(of: "%") { ip = String(ip[..<pct]) }
                    if !ip.lowercased().hasPrefix("fe80:") { map[name]?.inet6.append(ip) }
                }
            }
        }
        return order.compactMap { map[$0] }
    }

    /// 有实际地址的隧道接口。macOS 自带的 utun0~3 只有 fe80 地址，不算。
    public static func activeTunnels(_ ifaces: [Interface]) -> [Tunnel] {
        ifaces
            .filter { Rx.test("^(utun|tun|tap|wg|ppp|ipsec)\\d*$", $0.name, caseInsensitive: false) }
            .filter { !$0.inet.isEmpty || !$0.inet6.isEmpty }
            .map { Tunnel(name: $0.name, addrs: $0.inet + $0.inet6) }
    }

    /// 解析 `scutil --dns`。第一段是默认解析路径，第二段「for scoped queries」是接口限定的。
    public static func parseScutilDns(_ out: String?) -> DNSFacts {
        guard let out else { return DNSFacts(resolvers: [], defaults: [], perDomain: [], scoped: [], allThroughProxy: false) }

        struct Block {
            var section: String
            var nameservers: [String] = []
            var domains: [String] = []
            var searchDomains: [String] = []
            var ifIndex: Int?
            var ifName: String?
        }
        var blocks: [Block] = []
        var section = "default"
        var inBlock = false

        for raw in out.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("DNS configuration") {
                section = line.lowercased().contains("scoped queries") ? "scoped" : "default"
                inBlock = false
                continue
            }
            if Rx.test("^resolver #(\\d+)", line) {
                blocks.append(Block(section: section))
                inBlock = true
                continue
            }
            guard inBlock, !blocks.isEmpty else { continue }
            let i = blocks.count - 1
            if let g = Rx.groups("^nameserver\\[\\d+\\]\\s*:\\s*(\\S+)", line), let v = g[0] { blocks[i].nameservers.append(v); continue }
            if let g = Rx.groups("^domain\\s*:\\s*(\\S+)", line), let v = g[0] { blocks[i].domains.append(v); continue }
            if let g = Rx.groups("^search domain\\[\\d+\\]\\s*:\\s*(\\S+)", line), let v = g[0] { blocks[i].searchDomains.append(v); continue }
            if let g = Rx.groups("^if_index\\s*:\\s*(\\d+)\\s*(?:\\(([\\w.]+)\\))?", line), let v = g[0] {
                blocks[i].ifIndex = Int(v)
                blocks[i].ifName = g.count > 1 ? g[1] : nil
            }
        }

        func uniq(_ xs: [String]) -> [String] {
            var seen = Set<String>()
            return xs.filter { seen.insert($0).inserted }
        }

        let all = uniq(blocks.flatMap { $0.nameservers })
        let defaults = uniq(blocks.filter { $0.section == "default" && $0.domains.isEmpty && !$0.nameservers.isEmpty }.flatMap { $0.nameservers })
        let perDomain = blocks
            .filter { $0.section == "default" && !$0.domains.isEmpty && !$0.nameservers.isEmpty }
            .map { PerDomainResolver(domain: $0.domains[0], nameservers: $0.nameservers) }

        var scopedOrder: [String] = []
        var scopedMap: [String: ScopedResolver] = [:]
        for b in blocks where b.section == "scoped" && !b.nameservers.isEmpty {
            let key = b.ifIndex.map(String.init) ?? "未知接口"
            if scopedMap[key] == nil {
                scopedMap[key] = ScopedResolver(ifIndex: b.ifIndex, ifName: b.ifName, domains: [], nameservers: [])
                scopedOrder.append(key)
            }
            for d in b.domains + b.searchDomains where !(scopedMap[key]!.domains.contains(d)) { scopedMap[key]!.domains.append(d) }
            for ns in b.nameservers where !(scopedMap[key]!.nameservers.contains(ns)) { scopedMap[key]!.nameservers.append(ns) }
        }
        let scoped = scopedOrder.compactMap { scopedMap[$0] }

        return DNSFacts(
            resolvers: all,
            defaults: defaults,
            perDomain: perDomain,
            scoped: scoped,
            allThroughProxy: !defaults.isEmpty && defaults.allSatisfy(Net.isPrivate)
        )
    }

    static func localtimeLink() -> String? {
        guard let target = try? FileManager.default.destinationOfSymbolicLink(atPath: "/etc/localtime") else { return nil }
        guard let r = target.range(of: "zoneinfo/") else { return nil }
        return String(target[r.upperBound...])
    }

    /// 采集全部系统层事实。`shellEnv` 可注入（测试用）。
    public static func collect(appVersion: String = coreVersion, shellEnv: [String: String]? = nil) -> SystemFacts {
        let env = shellEnv ?? Shell.loginShellEnvironment()

        let tzIntl = TimeZone.current.identifier
        let tzLink = localtimeLink()
        let tzEnv = env["TZ"].flatMap { $0.isEmpty ? nil : $0 }
        let offset = TimeZone.current.secondsFromGMT() / 60
        let tzSet = Set([tzIntl, tzLink, tzEnv].compactMap { $0 })

        let defaults = UserDefaults.standard
        let appleLocale = defaults.string(forKey: "AppleLocale")
        let appleLanguages = (defaults.array(forKey: "AppleLanguages") as? [String]) ?? []
        let langEnv = [env["LC_ALL"], env["LC_MESSAGES"], env["LANG"]].compactMap { $0 }.first { !$0.isEmpty }

        let isArm64Machine = Shell.sysctlInt("hw.optional.arm64") == 1
        #if arch(arm64)
        let procArch = "arm64"
        #else
        let procArch = "x64"
        #endif
        let osv = ProcessInfo.processInfo.operatingSystemVersion
        let hardware = HardwareFacts(
            os: "macOS \(osv.majorVersion).\(osv.minorVersion)" + (osv.patchVersion > 0 ? ".\(osv.patchVersion)" : ""),
            model: Shell.sysctlString("hw.model"),
            chip: Shell.sysctlString("machdep.cpu.brand_string"),
            arch: procArch,
            machineArch: isArm64Machine ? "arm64" : "x64",
            rosetta: Shell.sysctlInt("sysctl.proc_translated") == 1
        )

        let runtime = RuntimeFacts(
            name: "ccenv.app \(appVersion)",
            term: env["TERM_PROGRAM"] ?? env["TERM"],
            shell: Shell.loginShell.split(separator: "/").last.map(String.init)
        )

        let sysProxy = systemProxy()
        let envProxy = ["HTTPS_PROXY", "https_proxy", "HTTP_PROXY", "http_proxy", "ALL_PROXY", "all_proxy"]
            .compactMap { k in env[k].flatMap { $0.isEmpty ? nil : "\(k)=\($0)" } }
        let apps = matchProxyApps(Shell.run("/bin/ps", ["-axo", "comm="], timeout: 6))
        let tunnels = activeTunnels(interfaces())
        let dns = parseScutilDns(Shell.run("/usr/sbin/scutil", ["--dns"]))

        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

        return SystemFacts(
            collectedAt: iso.string(from: Date()),
            timezone: TimezoneFacts(intl: tzIntl, localtimeLink: tzLink, env: tzEnv, offsetMinutes: offset, offsetLabel: TimeZoneMath.format(offset), consistent: tzSet.count <= 1),
            locale: LocaleFacts(
                appleLocale: appleLocale,
                appleLanguages: appleLanguages,
                envRaw: langEnv,
                env: LocaleParsing.parse(langEnv),
                primary: LocaleParsing.parse(appleLanguages.first ?? langEnv),
                apple: LocaleParsing.parse(appleLocale)
            ),
            hardware: hardware,
            runtime: runtime,
            proxy: ProxyFacts(
                system: sysProxy,
                env: envProxy,
                apps: apps,
                tun: tunnels.map { $0.name },
                tunnels: tunnels,
                active: !apps.isEmpty || !tunnels.isEmpty || sysProxy.https == true || sysProxy.http == true || sysProxy.socks == true || !envProxy.isEmpty
            ),
            dns: dns
        )
    }
}
