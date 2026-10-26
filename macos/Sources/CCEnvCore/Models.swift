// 数据模型。字段名与 CLI 的 --json 输出保持一致（schema 2），便于两边对拍。

import Foundation

public let schemaVersion = 2
public let coreVersion = "0.3.0"

public enum Level: String, Codable, CaseIterable, Comparable, Sendable {
    case high, medium, low, info, ok

    public var rank: Int {
        switch self {
        case .high: return 0
        case .medium: return 1
        case .low: return 2
        case .info: return 3
        case .ok: return 4
        }
    }

    public static func < (a: Level, b: Level) -> Bool { a.rank < b.rank }

    public var label: String {
        switch self {
        case .high: return "HIGH"
        case .medium: return "MEDIUM"
        case .low: return "LOW"
        case .info: return "INFO"
        case .ok: return "OK"
        }
    }
}

public enum Verdict: String, Codable, Sendable {
    case severe, notable, minor, consistent

    public var text: String {
        switch self {
        case .severe: return "严重冲突"
        case .notable: return "明显冲突"
        case .minor: return "轻度冲突"
        case .consistent: return "未发现冲突"
        }
    }

    public static func from(worst: Level) -> Verdict {
        switch worst {
        case .high: return .severe
        case .medium: return .notable
        case .low: return .minor
        case .info, .ok: return .consistent
        }
    }
}

public enum RuleGroup: String, Codable, Sendable {
    case consistency, profile

    public var title: String {
        switch self {
        case .consistency: return "一致性冲突"
        case .profile: return "画像风险"
        }
    }
}

/// 证据行。JSON 里编码成 `[label, value]` 二元数组，和 CLI 一致。
public struct Evidence: Hashable, Sendable {
    public let label: String
    public let value: String
    public init(_ label: String, _ value: String) {
        self.label = label
        self.value = value
    }
}

extension Evidence: Codable {
    public init(from decoder: Decoder) throws {
        var c = try decoder.unkeyedContainer()
        label = try c.decode(String.self)
        value = try c.decode(String.self)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.unkeyedContainer()
        try c.encode(label)
        try c.encode(value)
    }
}

public struct RuleOutcome: Sendable {
    public var level: Level
    public var skipped: Bool
    public var summary: String
    public var evidence: [Evidence]

    public init(level: Level, summary: String, evidence: [Evidence] = [], skipped: Bool = false) {
        self.level = level
        self.summary = summary
        self.evidence = evidence
        self.skipped = skipped
    }

    public static func ok(_ summary: String, _ evidence: [Evidence] = []) -> RuleOutcome { .init(level: .ok, summary: summary, evidence: evidence) }
    public static func info(_ summary: String, _ evidence: [Evidence] = []) -> RuleOutcome { .init(level: .info, summary: summary, evidence: evidence) }
    public static func skip(_ summary: String) -> RuleOutcome { .init(level: .info, summary: summary, skipped: true) }
}

public struct RuleResult: Codable, Identifiable, Hashable, Sendable {
    public let id: String
    public let group: RuleGroup
    public let title: String
    public let level: Level
    public let skipped: Bool
    public let summary: String
    public let evidence: [Evidence]
    public let impact: String
    public let fix: [String]
}

// MARK: - 系统层

public struct LocaleTag: Codable, Equatable, Sendable {
    public let language: String?
    public let script: String?
    public let region: String?
    public let raw: String
}

public struct TimezoneFacts: Codable, Sendable {
    public var intl: String?
    public var localtimeLink: String?
    public var env: String?
    public var offsetMinutes: Int
    public var offsetLabel: String
    public var consistent: Bool
}

public struct LocaleFacts: Codable, Sendable {
    public var appleLocale: String?
    public var appleLanguages: [String]
    public var envRaw: String?
    public var env: LocaleTag?
    public var primary: LocaleTag?
    public var apple: LocaleTag?
}

public struct HardwareFacts: Codable, Sendable {
    public var os: String
    public var model: String?
    public var chip: String?
    public var arch: String
    public var machineArch: String
    public var rosetta: Bool
}

public struct RuntimeFacts: Codable, Sendable {
    /// 运行时标识。CLI 里是 node 版本，这里是 app 版本；JSON 键名沿用 `node` 以保持 schema 不变。
    public var name: String
    public var term: String?
    public var shell: String?

    enum CodingKeys: String, CodingKey {
        case name = "node"
        case term, shell
    }
}

public struct SystemProxyFacts: Codable, Sendable {
    public var available: Bool
    public var http: Bool?
    public var https: Bool?
    public var socks: Bool?
    public var pac: Bool?
}

public struct Tunnel: Codable, Hashable, Sendable {
    public var name: String
    public var addrs: [String]
}

public struct ProxyFacts: Codable, Sendable {
    public var system: SystemProxyFacts
    public var env: [String]
    public var apps: [String]
    public var tun: [String]
    public var tunnels: [Tunnel]
    public var active: Bool
}

public struct PerDomainResolver: Codable, Hashable, Sendable {
    public var domain: String
    public var nameservers: [String]
}

public struct ScopedResolver: Codable, Hashable, Sendable {
    public var ifIndex: Int?
    public var ifName: String?
    public var domains: [String]
    public var nameservers: [String]
}

public struct DNSFacts: Codable, Sendable {
    public var resolvers: [String]
    public var defaults: [String]
    public var perDomain: [PerDomainResolver]
    public var scoped: [ScopedResolver]
    public var allThroughProxy: Bool
}

public struct SystemFacts: Codable, Sendable {
    public var collectedAt: String
    public var timezone: TimezoneFacts
    public var locale: LocaleFacts
    public var hardware: HardwareFacts
    public var runtime: RuntimeFacts
    public var proxy: ProxyFacts
    public var dns: DNSFacts
}

public struct FontFacts: Codable, Sendable {
    public var scannedFiles: Int
    public var stock: [String]
    public var thirdParty: [String]
    public var vendor: [String]
    public var hasEmoji: Bool
}

// MARK: - 出口层

public struct IntelFlags: Codable, Hashable, Sendable {
    public var datacenter: Bool?
    public var vpn: Bool?
    public var proxy: Bool?
    public var tor: Bool?
}

public struct IntelSource: Sendable {
    public var source: String
    public var country: String?
    public var region: String?
    public var city: String?
    public var timezone: String?
    public var asn: String?
    public var org: String?
    public var isp: String?
    public var hostname: String?
    public var flags: IntelFlags?

    public init(source: String, country: String? = nil, region: String? = nil, city: String? = nil, timezone: String? = nil, asn: String? = nil, org: String? = nil, isp: String? = nil, hostname: String? = nil, flags: IntelFlags? = nil) {
        self.source = source
        self.country = country
        self.region = region
        self.city = city
        self.timezone = timezone
        self.asn = asn
        self.org = org
        self.isp = isp
        self.hostname = hostname
        self.flags = flags
    }
}

public enum EgressKind: String, Codable, Sendable { case hosting, isp, unknown }
public enum Confidence: String, Codable, Sendable { case high, medium, low }

public struct Classification: Codable, Hashable, Sendable {
    public var kind: EgressKind
    public var basis: [String]
    public var confidence: Confidence
}

public struct IPIntel: Codable, Hashable, Sendable {
    public var ip: String
    public var country: String?
    public var region: String?
    public var city: String?
    public var timezone: String?
    public var asn: String?
    public var org: String?
    public var isp: String?
    public var hostname: String?
    public var countries: [String]
    public var asns: [String]
    public var timezones: [String]
    public var flags: IntelFlags?
    public var sources: [String]
    public var countryConsistent: Bool
    public var asnConsistent: Bool
    public var classification: Classification
}

public struct IPCount: Codable, Hashable, Sendable {
    public var ip: String
    public var count: Int
}

public struct CrossEcho: Codable, Hashable, Sendable {
    public var echo: String
    public var ip: String?
    public var country: String?
}

public struct ClockSample: Codable, Hashable, Sendable {
    public var source: String
    public var skewMs: Double
    public var rttMs: Double
    public var coarse: Bool
}

public struct EgressFacts: Codable, Sendable {
    public var ok: Bool
    public var primary: IPIntel?
    public var distinctIps: [IPCount]
    public var distinctCount: Int
    public var sampledDistinctCount: Int
    public var samePrefix: Bool
    public var sampleCount: Int
    public var crossEchoes: [CrossEcho]
    public var crossDiffers: Bool
    public var v6: String?
    public var v6Intel: IPIntel?
    public var v6ViaDualStackEcho: Bool
    public var clock: ClockSample?
    public var durationMs: Int
    public var error: String?

    public static func offline(_ reason: String) -> EgressFacts {
        EgressFacts(ok: false, primary: nil, distinctIps: [], distinctCount: 0, sampledDistinctCount: 0, samePrefix: true, sampleCount: 0, crossEchoes: [], crossDiffers: false, v6: nil, v6Intel: nil, v6ViaDualStackEcho: false, clock: nil, durationMs: 0, error: reason)
    }
}

// MARK: - 汇总

public struct Context: Sendable {
    public var system: SystemFacts
    public var fonts: FontFacts
    public var egress: EgressFacts

    public init(system: SystemFacts, fonts: FontFacts, egress: EgressFacts) {
        self.system = system
        self.fonts = fonts
        self.egress = egress
    }
}

public struct Report: Codable, Sendable {
    public struct VerdictBlock: Codable, Sendable {
        public var value: Verdict
        public var worst: Level
    }

    public struct Facts: Codable, Sendable {
        public var egress: EgressFacts
        public var system: SystemFacts
        public var fonts: FontFacts
    }

    public var tool: String
    public var version: String
    public var schema: Int
    public var generatedAt: String
    public var verdict: VerdictBlock
    public var facts: Facts
    public var rules: [RuleResult]

    public var worst: Level { verdict.worst }
    public var conflicts: [RuleResult] { rules.filter { !$0.skipped && $0.level != .ok } }
    public var passed: [RuleResult] { rules.filter { $0.level == .ok } }
    public var skipped: [RuleResult] { rules.filter { $0.skipped } }
    public func count(of level: Level) -> Int { rules.filter { !$0.skipped && $0.level == level }.count }
}

public enum Stage: String, Sendable {
    case local, sampling, intel, rules

    public var text: String {
        switch self {
        case .local: return "读取本地层（时区 / 语言 / 字体 / DNS）"
        case .sampling: return "采样出口 IP（多源回显）"
        case .intel: return "查询 IP / ASN 情报"
        case .rules: return "比对规则"
        }
    }
}

public struct CheckOptions: Sendable, Equatable {
    public var offline: Bool
    public var samples: Int
    public var intervalMs: Int
    public var timeoutMs: Int

    public init(offline: Bool = false, samples: Int = 6, intervalMs: Int = 350, timeoutMs: Int = 8000) {
        self.offline = offline
        self.samples = max(1, samples)
        self.intervalMs = max(0, intervalMs)
        self.timeoutMs = max(1000, timeoutMs)
    }
}
