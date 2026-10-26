// 规则层：跨层找矛盾。对应 CLI 的 src/rules.js，规则 ID、等级阈值、文案一一对应。
// 一个规则只对应一个底层事实；只输出离散等级，结论取最高等级，不做加权求和。

import Foundation

public struct Rule: Sendable {
    public let id: String
    public let group: RuleGroup
    public let title: String
    public let impact: String
    public let fix: [String]
    public let evaluate: @Sendable (Context) -> RuleOutcome
}

public enum RuleEngine {
    static func rn(_ code: String?) -> String { Classifier.regionName(code) }

    public static let rules: [Rule] = [
        Rule(
            id: "egress-timezone", group: .consistency, title: "出口时区 ↔ 系统时区",
            impact: "这是风控里最廉价、被判得最广的一组信号：同一个会话里 IP 在一个时区、设备时钟在另一个时区。它本身不能证明任何事（跨国办公、公司共享出口都很常见），但和 IP 类型、IP 稳定性叠加时权重很高。",
            fix: [
                "让出口和系统时区对齐：要么把系统时区改成出口所在地（macOS: 系统设置 › 通用 › 日期与时间，或 sudo systemsetup -settimezone <Area/City>）",
                "要么把出口固定到系统时区所在的地区，并长期不再变",
            ]
        ) { ctx in
            guard let geo = ctx.egress.primary, let geoTz = geo.timezone else { return .skip("未取得出口 IP 的归属时区（离线或情报源全失败）") }
            guard let geoOffset = TimeZoneMath.offsetMinutes(for: geoTz) else { return .skip("无法解析出口时区 \(geoTz)") }
            let sys = ctx.system.timezone
            let delta = TimeZoneMath.circularMinutes(geoOffset, sys.offsetMinutes)
            let ev = [
                Evidence("出口时区", "\(geoTz) (\(TimeZoneMath.format(geoOffset)))"),
                Evidence("系统时区", "\(sys.intl ?? "未知") (\(sys.offsetLabel))"),
                Evidence("相差", "\(delta / 60) 小时 \(delta % 60) 分"),
            ]
            if delta == 0 { return .ok("出口与系统时区一致", ev) }
            if delta <= 60 { return RuleOutcome(level: .low, summary: "出口与系统时区相差 1 小时以内（夏令时/邻国边界常见）", evidence: ev) }
            if delta <= 300 { return RuleOutcome(level: .medium, summary: "出口与系统时区相差 1~5 小时", evidence: ev) }
            return RuleOutcome(level: .high, summary: "出口与系统时区相差超过 5 小时，是最典型的「IP 画像 ≠ 设备画像」", evidence: ev)
        },

        Rule(
            id: "egress-locale", group: .consistency, title: "出口国家 ↔ 系统区域/语言",
            impact: "第二层交叉校验。单独看几乎没有证明力（很多人系统语言和居住国并不一致），它的作用是和 egress-timezone 一起构成「多条独立线索同时偏向另一个地区」的累积证据。",
            fix: ["如果希望画像统一，把系统区域设置为出口所在国家；不想改就把它当作已知的弱偏差，不必当成问题"]
        ) { ctx in
            guard let geo = ctx.egress.primary, let country = geo.country else { return .skip("未取得出口国家（离线或情报源全失败）") }
            let loc = ctx.system.locale
            let lang = loc.primary?.language
            let localeRegion = loc.apple?.region ?? loc.primary?.region
            var ev = [
                Evidence("出口国家", "\(rn(country)) (\(country))"),
                Evidence("系统首选语言", loc.primary?.raw ?? "未知"),
                Evidence("系统区域", loc.apple?.raw ?? localeRegion ?? "未知"),
            ]
            if localeRegion == country { return .ok("系统区域与出口国家一致", ev) }
            if let lang, Classifier.langHome[lang]?.contains(country) == true {
                ev.append(Evidence("说明", "\(lang) 在 \(rn(country)) 也是常用语言，仅区域子标签不同"))
                return RuleOutcome(level: .low, summary: "语言与出口国家相容，仅区域设置不同", evidence: ev)
            }
            return RuleOutcome(level: .medium, summary: "系统区域是 \(localeRegion.map(rn) ?? "未知")，出口在 \(rn(country))", evidence: ev)
        },

        Rule(
            id: "ip-kind", group: .profile, title: "出口 IP 类型（住宅/运营商 vs 机房/托管）",
            impact: "比语言、字体重要一个量级。账号注册/订阅/风控建模里，机房段和「一个 IP 关联多少账号」是最强的两个特征，共享机房出口意味着同 IP 上的其他人会影响你的 IP 声誉。",
            fix: [
                "尽量使用住宅/运营商出口，或至少是专属的、不与他人共享的固定出口",
                "无法更换时：避免在同一个出口上并发多账号操作，并确保出口不再漂移",
            ]
        ) { ctx in
            guard let geo = ctx.egress.primary, let asn = geo.asn else { return .skip("未取得 ASN 情报") }
            let c = geo.classification
            let ev = [
                Evidence("ASN", "\(asn) \(geo.isp ?? geo.org ?? "")".trimmingCharacters(in: .whitespaces)),
                Evidence("主机名", geo.hostname ?? "无 rDNS"),
                Evidence("判定依据", c.basis.joined(separator: "；")),
                Evidence("情报源", geo.sources.joined(separator: ", ")),
            ]
            switch c.kind {
            case .isp: return .ok("出口属于运营商/宽带段", ev)
            case .unknown: return RuleOutcome(level: .low, summary: "无法归类出口类型，按可疑处理前请人工确认", evidence: ev)
            case .hosting: return RuleOutcome(level: .high, summary: "出口属于机房/托管/代理段（\(c.confidence == .high ? "高" : "中")置信）", evidence: ev)
            }
        },

        Rule(
            id: "ip-stability", group: .consistency, title: "出口 IP 稳定性（重复采样 + 多源交叉）",
            impact: "「同一账号短时间内在多个 IP 上出现」本身就是独立的风控特征，和 IP 国家是不是目标国无关。轮询池还有个副作用：多源情报对同一个会话可能给出不同归属，进一步降低画像确定性。",
            fix: [
                "给需要稳定身份的目的域名绑定单一固定出口，禁用负载均衡/故障转移策略",
                "至少不要在一个会话进行中途切换节点",
            ]
        ) { ctx in
            let e = ctx.egress
            guard e.ok, let primary = e.primary else { return .skip("未取得出口 IP") }
            let echoCount = e.crossEchoes.filter { $0.ip != nil }.count
            if e.distinctCount <= 1 {
                return .ok("出口稳定（\(e.sampleCount) 次采样、\(echoCount) 个独立回显均同一 IP）", [Evidence("出口 IP", primary.ip)])
            }
            let ev = [
                Evidence("观测到的 IP", e.distinctIps.map { "\($0.ip)（\($0.count) 次）" }.joined(separator: " / ")),
                Evidence("重复采样", "\(e.sampleCount) 次，其中 \(e.sampledDistinctCount) 个不同 IP"),
                Evidence("多源交叉", e.crossEchoes.compactMap { c in c.ip.map { "\(c.echo)=\($0)" } }.joined(separator: " / ").nilIfEmpty ?? "无"),
                Evidence("是否同 /24", e.samePrefix ? "是（同一出口池轮询）" : "否（跨网段/跨地区）"),
            ]
            if !e.samePrefix { return RuleOutcome(level: .high, summary: "出口 IP 跨网段漂移，等价于同一会话里换出口", evidence: ev) }
            return RuleOutcome(level: .medium, summary: "同一出口池在 \(e.distinctCount) 个 IP 之间轮询，会话中出口会变", evidence: ev)
        },

        Rule(
            id: "ip-intel-consistency", group: .consistency, title: "多源 IP 情报是否自相矛盾",
            impact: "如果不同 GeoIP 库对同一个出口给出不同国家，说明这个 IP 段归属模糊（anycast、刚过户、或分级转售）。这类出口在对方风控里同样呈现为「画像不确定」。",
            fix: ["换一个归属清晰的出口；至少记录下来，出问题时可作为申诉背景"]
        ) { ctx in
            guard let geo = ctx.egress.primary, geo.sources.count >= 2 else { return .skip("有效情报源不足 2 个，无法交叉验证") }
            let ev = [
                Evidence("国家", geo.countries.map(rn).joined(separator: " / ").nilIfEmpty ?? "无"),
                Evidence("ASN", geo.asns.joined(separator: " / ").nilIfEmpty ?? "无"),
                Evidence("情报源", geo.sources.joined(separator: ", ")),
            ]
            if geo.countryConsistent && geo.asnConsistent { return .ok("各情报源对同一 IP 的国家与 ASN 结论一致", ev) }
            return RuleOutcome(level: .medium, summary: "不同情报源对同一 IP 的归属结论不一致", evidence: ev)
        },

        Rule(
            id: "clock-skew", group: .consistency, title: "本机时钟 ↔ 服务器时间",
            impact: "客户端上报的时间戳和服务器时间差得多，会被当作「设备时钟被改过」或虚拟机快照恢复；超过几分钟还会让 TOTP、签名请求失效。",
            fix: ["打开 系统设置 › 通用 › 日期与时间 的自动设置；虚拟机里确认宿主时间同步"]
        ) { ctx in
            guard let clock = ctx.egress.clock else { return .skip("未取得服务端时间戳（离线或回显未带时间）") }
            if clock.rttMs > 4000 { return .skip("回显往返 \(Int(clock.rttMs)) ms 过长，时钟对比不可靠") }
            let skew = clock.skewMs.rounded()
            let abs = Swift.abs(skew)
            let human = abs < 1000 ? "\(Int(abs)) ms" : abs < 60000 ? String(format: "%.1f 秒", abs / 1000) : String(format: "%.1f 分钟", abs / 60000)
            let ev = [
                Evidence("偏差", "\(skew >= 0 ? "本机快" : "本机慢") \(human)"),
                Evidence("对比来源", clock.source + (clock.coarse ? "（秒级精度）" : "")),
                Evidence("往返时延", "\(Int(clock.rttMs)) ms"),
            ]
            let tolerance: Double = clock.coarse ? 3000 : 1500
            if abs <= tolerance { return .ok("本机时钟与服务器时间一致", ev) }
            if abs <= 30000 { return RuleOutcome(level: .low, summary: "本机时钟偏差 \(human)", evidence: ev) }
            if abs <= 300000 { return RuleOutcome(level: .medium, summary: "本机时钟偏差 \(human)，超过常见容忍范围", evidence: ev) }
            return RuleOutcome(level: .high, summary: "本机时钟偏差 \(human)，TLS/签名类请求可能直接失败", evidence: ev)
        },

        Rule(
            id: "tz-layer", group: .consistency, title: "系统时区三层自洽（TZ 环境变量 / /etc/localtime / 系统）",
            impact: "命令行工具、浏览器、系统 UI 会各自读不同来源。三层不一致时，同一个账号在不同客户端上会呈现不同时区，属于自伤式矛盾。",
            fix: ["清理多余的 TZ 环境变量（检查 ~/.zshrc、~/.zshenv、/etc/profile），只保留系统时区一个来源"]
        ) { ctx in
            let tz = ctx.system.timezone
            let ev = [
                Evidence("TZ 环境变量", tz.env ?? "未设置"),
                Evidence("/etc/localtime", tz.localtimeLink ?? "未读取"),
                Evidence("系统解析", tz.intl ?? "未知"),
            ]
            if tz.consistent { return .ok("三层一致", ev) }
            return RuleOutcome(level: .medium, summary: "系统内不同来源给出的时区不一致", evidence: ev)
        },

        Rule(
            id: "locale-layer", group: .consistency, title: "语言/区域三层自洽（系统首选语言 / AppleLocale / Shell LANG）",
            impact: "很常见（系统中文 + 终端英文），证明力弱，但确实会让不同客户端上报不同语言，属于轻度画像噪声。",
            fix: ["如果在意一致性，把 Shell 的 LANG 调成和系统首选语言一致（如 zh_SG.UTF-8），或反过来统一成英文"]
        ) { ctx in
            let l = ctx.system.locale
            let langs = [l.primary?.language, l.apple?.language, l.env?.language].compactMap { $0 }
            var uniq: [String] = []
            for x in langs where !uniq.contains(x) { uniq.append(x) }
            let ev = [
                Evidence("系统首选语言", l.appleLanguages.joined(separator: ", ").nilIfEmpty ?? "未读取"),
                Evidence("AppleLocale", l.appleLocale ?? "未读取"),
                Evidence("Shell LANG", l.envRaw ?? "未设置"),
            ]
            if uniq.count <= 1 { return .ok("语言三层一致", ev) }
            return RuleOutcome(level: .low, summary: "语言标签不一致：\(uniq.joined(separator: " / "))", evidence: ev)
        },

        Rule(
            id: "ipv6", group: .consistency, title: "IPv6 出口",
            impact: "开了 IPv6 但代理只接管 IPv4 是最经典的泄漏：对方看到两个不同国家的来源。当前没开就不构成风险。",
            fix: ["若启用 IPv6，确保代理同时接管 v6（TUN 栈双栈），或直接在系统里关闭 IPv6"]
        ) { ctx in
            let e = ctx.egress
            guard e.ok, let primary = e.primary else { return .skip("未取得出口 IP") }
            guard let v6 = e.v6 else {
                return .info("当前没有可用的 IPv6 出口（不会被 v6 直连泄漏真实位置）", [Evidence("IPv4 出口", primary.ip)])
            }
            let vi = e.v6Intel
            var ev = [
                Evidence("IPv6 出口", v6),
                Evidence("v6 归属", "\(rn(vi?.country)) (\(vi?.country ?? "?")) \(vi?.asn ?? "")".trimmingCharacters(in: .whitespaces)),
                Evidence("IPv4 归属", "\(rn(primary.country)) (\(primary.country ?? "?")) \(primary.asn ?? "")".trimmingCharacters(in: .whitespaces)),
            ]
            if e.v6ViaDualStackEcho { ev.append(Evidence("说明", "双栈回显服务优先走了 v6，说明系统对双栈目标会优先用 v6 直连")) }
            guard let v6Country = vi?.country else { return .info("存在 IPv6 出口，但归属未知", ev) }
            if v6Country == primary.country { return .ok("IPv6 与 IPv4 出口国家一致", ev) }
            return RuleOutcome(level: .high, summary: "IPv6 出口与 IPv4 出口不在同一国家，等于同时暴露两个地点", evidence: ev)
        },

        Rule(
            id: "dns-path", group: .consistency, title: "DNS 解析路径",
            impact: "代理商不接管 DNS 时，解析请求会从本地运营商出去，泄漏 ISP/城市层面的位置，和出口国家形成第二组矛盾。",
            fix: ["让代理接管 DNS（TUN/fake-ip 模式通常已经接管），或把系统 DNS 指到代理内置解析"]
        ) { ctx in
            let dns = ctx.system.dns
            let proxy = ctx.system.proxy
            if dns.resolvers.isEmpty { return .skip("未读取到 DNS 解析器") }
            let scopedText = dns.scoped.isEmpty ? "无" : dns.scoped.map { "\($0.ifName ?? "if#\($0.ifIndex.map(String.init) ?? "?")") → \($0.nameservers.joined(separator: ","))" }.joined(separator: "；")
            let perDomainText = dns.perDomain.first.map { "\(dns.perDomain.count) 条按域名路由（如 \($0.domain) → \($0.nameservers.joined(separator: ","))）" } ?? "无"
            let sp = proxy.system
            var ev = [
                Evidence("默认解析器", dns.defaults.joined(separator: ", ").nilIfEmpty ?? "无"),
                Evidence("按域名路由", perDomainText),
                Evidence("接口级限定", scopedText),
                Evidence("系统代理", sp.available ? "http=\(sp.http ?? false) https=\(sp.https ?? false) socks=\(sp.socks ?? false)" : "未读取"),
            ]
            let external = dns.defaults.filter { !Net.isPrivate($0) }
            if dns.defaults.isEmpty { return .info("未读到默认解析器（已全部按域名/接口限定）", ev) }
            if external.isEmpty { return .ok("默认 DNS 走本机/代理，公共域名解析不直接暴露解析位置", ev) }
            ev.append(Evidence("直连默认解析器", external.joined(separator: ", ")))
            if proxy.active { return RuleOutcome(level: .low, summary: "出口已走代理，但默认 DNS 仍直连公网解析器", evidence: ev) }
            return .info("默认 DNS 为公网解析器（当前未发现代理链路）", ev)
        },

        Rule(
            id: "vendor-fonts", group: .profile, title: "设备厂商定制字体（强地区线索）",
            impact: "MiSans/HarmonyOS Sans/OPPO Sans 这类字体只会随国产定制系统出现，是真实的设备地区证据；而 macOS 预装的 Hiragino/STHeiti/Songti 全世界每台 Mac 都有，零信息量——把两者混在一起算分会直接给所有 Mac 送分。",
            fix: ["无需处理，仅作为画像说明；如确实要消除，卸载第三方厂商字体即可"]
        ) { ctx in
            let f = ctx.fonts
            let geo = ctx.egress.primary
            let ev = [
                Evidence("厂商字体", f.vendor.isEmpty ? "无" : f.vendor.prefix(6).joined(separator: ", ")),
                Evidence("系统预装 CJK", f.stock.isEmpty ? "无" : "\(f.stock.count) 个（不计入判定）"),
                Evidence("Office/Windows 系", f.thirdParty.isEmpty ? "无" : f.thirdParty.prefix(4).joined(separator: ", ")),
            ]
            if f.vendor.isEmpty { return .ok("未发现整机厂商定制字体", ev) }
            guard let country = geo?.country else { return .info("存在整机厂商定制字体（未取得出口国家，无法比对）", ev) }
            if country == "CN" { return .ok("厂商字体与出口国家一致", ev) }
            return RuleOutcome(level: .low, summary: "存在整机厂商定制字体，但出口在 \(rn(country))", evidence: ev)
        },

        Rule(
            id: "runtime-arch", group: .consistency, title: "运行时与机器架构",
            impact: "转译运行会让客户端上报的架构与设备真实架构矛盾，是一类弱但免费的矛盾信号。",
            fix: ["使用与机器架构匹配的应用版本"]
        ) { ctx in
            let hw = ctx.system.hardware
            let rt = ctx.system.runtime
            let ev = [
                Evidence("运行时", "\(rt.name) (darwin/\(hw.arch))"),
                Evidence("机器", "\(hw.chip ?? "未知") / \(hw.machineArch)"),
                Evidence("Rosetta", hw.rosetta ? "是" : "否"),
                Evidence("终端", "\(rt.term ?? "未知") · \(rt.shell ?? "未知")"),
            ]
            if hw.rosetta || hw.arch != hw.machineArch {
                return RuleOutcome(level: .low, summary: "客户端运行在转译/异构架构下，UA 与硬件线索会不一致", evidence: ev)
            }
            return .ok("运行时与硬件架构一致", ev)
        },
    ]

    public struct Outcome: Sendable {
        public var results: [RuleResult]
        public var worst: Level
        public var verdict: Verdict
    }

    public static func run(_ ctx: Context) -> Outcome {
        let results = rules.map { rule -> RuleResult in
            let o = rule.evaluate(ctx)
            return RuleResult(id: rule.id, group: rule.group, title: rule.title, level: o.level, skipped: o.skipped, summary: o.summary, evidence: o.evidence, impact: rule.impact, fix: rule.fix)
        }
        .sorted { a, b in a.level != b.level ? a.level < b.level : a.id < b.id }
        let worst = results.first { !$0.skipped }?.level ?? .ok
        return Outcome(results: results, worst: worst, verdict: Verdict.from(worst: worst))
    }
}

extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
