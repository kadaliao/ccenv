// 入口：采集 → 规则 → 报告；以及 JSON / 纯文本导出。

import Foundation

public enum CCEnv {
    public static func check(options: CheckOptions = CheckOptions(), appVersion: String = coreVersion, progress: @escaping @Sendable (Stage) -> Void = { _ in }) async -> Report {
        progress(.local)
        let system = await Task.detached(priority: .userInitiated) { SystemCollector.collect(appVersion: appVersion) }.value
        let fonts = await Task.detached(priority: .utility) { FontCollector.collect() }.value

        let egress: EgressFacts = options.offline
            ? .offline("已选择离线模式，跳过网络层")
            : await EgressCollector.collect(options: options, progress: progress)

        progress(.rules)
        let ctx = Context(system: system, fonts: fonts, egress: egress)
        let outcome = RuleEngine.run(ctx)

        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return Report(
            tool: "ccenv",
            version: appVersion,
            schema: schemaVersion,
            generatedAt: iso.string(from: Date()),
            verdict: .init(value: outcome.verdict, worst: outcome.worst),
            facts: .init(egress: egress, system: system, fonts: fonts),
            rules: outcome.results
        )
    }

    public static func json(_ report: Report) -> String {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        guard let data = try? enc.encode(report) else { return "{}" }
        return String(decoding: data, as: UTF8.self)
    }

    /// 纯文本报告，和 CLI 的无色输出结构一致，用于「复制报告」。
    public static func text(_ report: Report, explain: Bool = true) -> String {
        var out: [String] = []
        let bar = String(repeating: "─", count: 52)
        func section(_ t: String) { out.append(""); out.append(t); out.append(bar) }
        func row(_ k: String, _ v: String) { out.append("  " + k.padded(18) + " " + v) }

        out.append("ccenv · 环境一致性检测  (\(report.version))")
        out.append(bar)
        out.append("结论  \(report.verdict.value.text)   最高等级 \(report.worst.rawValue)")

        let e = report.facts.egress
        let s = report.facts.system
        section("出口层（真实 IP / ASN）")
        if let p = e.primary, e.ok {
            row("出口 IP", e.distinctIps.map { $0.ip }.joined(separator: " / ") + (e.distinctCount > 1 ? "  (\(e.sampleCount) 次采样)" : ""))
            row("归属", "\(Classifier.regionName(p.country)) · \(p.region ?? "?") · \(p.city ?? "?")  (\(p.country ?? "?"))")
            row("ASN", "\(p.asn ?? "?") \(p.isp ?? p.org ?? "")")
            row("rDNS", p.hostname ?? "无")
            row("类型", "\(p.classification.kind.text)  置信 \(p.classification.confidence.rawValue)")
            row("出口时区", "\(p.timezone ?? "?") (\(TimeZoneMath.format(TimeZoneMath.offsetMinutes(for: p.timezone))))")
            row("IPv6", e.v6.map { "\($0) (\(Classifier.regionName(e.v6Intel?.country)))" } ?? "无 v6 出口")
            row("情报源", "\(p.sources.joined(separator: ", ")) · 耗时 \(String(format: "%.1f", Double(e.durationMs) / 1000))s")
        } else {
            row("无法取得出口 IP", e.error ?? "未知原因")
        }

        section("系统层")
        row("时区", "\(s.timezone.intl ?? "?") (\(s.timezone.offsetLabel))  localtime=\(s.timezone.localtimeLink ?? "?") TZ=\(s.timezone.env ?? "未设")")
        row("语言", "\(s.locale.appleLanguages.joined(separator: ", ").nilIfEmpty ?? s.locale.envRaw ?? "?")  AppleLocale=\(s.locale.appleLocale ?? "?")")
        row("Shell", "LANG=\(s.locale.envRaw ?? "未设置")")
        row("字体", "预装 CJK \(report.facts.fonts.stock.count)(不计分) · 三方 \(report.facts.fonts.thirdParty.count) · 厂商 \(report.facts.fonts.vendor.isEmpty ? "0" : report.facts.fonts.vendor.prefix(4).joined(separator: ", "))")
        let tun = s.proxy.tunnels.isEmpty ? "-" : s.proxy.tunnels.map { "\($0.name)(\($0.addrs.first ?? ""))" }.joined(separator: ",")
        row("链路", "\(s.proxy.active ? "经代理" : "直连") apps=[\(s.proxy.apps.joined(separator: ","))] tun=[\(tun)] sysProxy=\(s.proxy.system.https == true ? "on" : "off")")
        row("DNS", "\(s.dns.defaults.joined(separator: ", ").nilIfEmpty ?? "?") \(s.dns.allThroughProxy ? "(默认走代理)" : "(默认含公网)")" + (s.dns.scoped.isEmpty ? "" : " + \(s.dns.scoped.count) 个接口级限定"))
        row("设备", "\(s.hardware.os) · \(s.hardware.chip ?? "?") · \(s.hardware.machineArch)\(s.hardware.rosetta ? " (Rosetta)" : "")")
        row("运行时", "\(s.runtime.name) · \(s.runtime.shell ?? "?")")

        for group in [RuleGroup.consistency, .profile] {
            let items = report.conflicts.filter { $0.group == group }
            if items.isEmpty { continue }
            section("\(group.title)（\(items.count)）")
            for r in items {
                out.append("  [\(r.level.label.padded(6))] \(r.id) — \(r.summary)")
                for ev in r.evidence { out.append("      " + ev.label.padded(18) + " " + ev.value) }
                if explain {
                    out.append("      " + "影响".padded(18) + " " + r.impact)
                    for f in r.fix { out.append("      " + "处理".padded(18) + " " + f) }
                }
            }
        }
        section("通过项（\(report.passed.count)）")
        if report.passed.isEmpty { out.append("  无") }
        for r in report.passed { out.append("  [OK    ] \(r.id) — \(r.summary)") }
        if !report.skipped.isEmpty {
            section("跳过项（\(report.skipped.count)）")
            for r in report.skipped { out.append("  [SKIP  ] \(r.id) — \(r.summary)") }
        }
        out.append("")
        return out.joined(separator: "\n")
    }
}

public extension EgressKind {
    var text: String {
        switch self {
        case .hosting: return "机房/托管/代理段"
        case .isp: return "运营商/宽带段"
        case .unknown: return "无法归类"
        }
    }
}

extension String {
    /// 按显示宽度补空格（CJK 按 2 列算）。
    func padded(_ width: Int) -> String {
        var w = 0
        for ch in unicodeScalars { w += ch.value > 0x2E80 ? 2 : 1 }
        return self + String(repeating: " ", count: max(0, width - w))
    }
}
