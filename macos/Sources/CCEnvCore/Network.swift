// 出口层：真实公网 IP 采样 + 多源 IP/ASN 情报。对应 CLI 的 src/network.js。
// v4 / v6 观测严格分开统计；顺带用服务端时间戳检测本机时钟偏差。

import Foundation

struct FetchResult {
    var body: Data
    var text: String { String(data: body, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "" }
    var json: [String: Any]? { (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] }
    var dateHeader: String?
    var rttMs: Double
    var receivedAt: Date
}

enum HTTP {
    static let userAgent = "ccenv/\(coreVersion) (+local consistency check; macOS app)"

    static func session(timeoutMs: Int) -> URLSession {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = Double(timeoutMs) / 1000
        cfg.timeoutIntervalForResource = Double(timeoutMs) / 1000
        cfg.httpAdditionalHeaders = ["User-Agent": userAgent, "Accept": "application/json, text/plain, */*"]
        cfg.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        cfg.urlCache = nil
        return URLSession(configuration: cfg)
    }

    static func fetch(_ url: String, session: URLSession) async -> FetchResult? {
        guard let u = URL(string: url) else { return nil }
        let started = Date()
        do {
            let (data, resp) = try await session.data(from: u)
            guard let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode) else { return nil }
            let now = Date()
            return FetchResult(body: data, dateHeader: http.value(forHTTPHeaderField: "Date"), rttMs: now.timeIntervalSince(started) * 1000, receivedAt: now)
        } catch {
            return nil
        }
    }
}

struct Echo {
    enum Parse { case plain, trace, ipwho, ipinfo }
    var id: String
    var url: String
    var parse: Parse
}

struct EchoObservation {
    var echo: String
    var ip: String?
    var country: String?
    var serverTs: Date?
    var rttMs: Double?
    var receivedAt: Date?
    var dateHeader: String?
}

public enum EgressCollector {
    static let echoes: [Echo] = [
        Echo(id: "ipify", url: "https://api.ipify.org", parse: .plain),
        Echo(id: "cf-trace", url: "https://www.cloudflare.com/cdn-cgi/trace", parse: .trace),
        Echo(id: "ipwho", url: "https://ipwho.is/", parse: .ipwho),
        Echo(id: "ipinfo", url: "https://ipinfo.io/json", parse: .ipinfo),
    ]
    static let v6Probes = ["https://v6.ipinfo.io/ip", "https://api6.ipify.org"]

    static func parseEcho(_ echo: Echo, _ r: FetchResult?) -> EchoObservation {
        var obs = EchoObservation(echo: echo.id, rttMs: r?.rttMs, receivedAt: r?.receivedAt, dateHeader: r?.dateHeader)
        guard let r else { return obs }
        switch echo.parse {
        case .plain:
            let t = r.text
            obs.ip = Net.isV4(t) || Net.isV6(t) ? t : nil
        case .trace:
            var map: [String: String] = [:]
            for line in r.text.split(separator: "\n") {
                let kv = line.split(separator: "=", maxSplits: 1)
                if kv.count == 2 { map[String(kv[0])] = String(kv[1]) }
            }
            obs.ip = map["ip"]
            obs.country = map["loc"]
            if let ts = map["ts"].flatMap(Double.init) { obs.serverTs = Date(timeIntervalSince1970: ts) }
        case .ipwho:
            let j = r.json
            obs.ip = j?["ip"] as? String
            obs.country = j?["country_code"] as? String
        case .ipinfo:
            let j = r.json
            obs.ip = j?["ip"] as? String
            obs.country = j?["country"] as? String
        }
        return obs
    }

    static func str(_ v: Any?) -> String? {
        if let s = v as? String { return s.isEmpty ? nil : s }
        if let n = v as? NSNumber { return n.stringValue }
        return nil
    }

    static func collectIntel(_ ip: String, session: URLSession) async -> [IntelSource] {
        async let a = HTTP.fetch("https://ipinfo.io/\(ip)/json", session: session)
        async let b = HTTP.fetch("https://ipwho.is/\(ip)", session: session)
        async let c = HTTP.fetch("https://api.ipapi.is/?q=\(ip)", session: session)
        let (ipinfo, ipwho, ipapi) = await (a?.json, b?.json, c?.json)

        var sources: [IntelSource] = []
        if let j = ipinfo, (j["bogon"] as? Bool) != true {
            let org = str(j["org"])
            let parts = org?.split(separator: " ", maxSplits: 1).map(String.init)
            sources.append(IntelSource(
                source: "ipinfo.io",
                country: str(j["country"]), region: str(j["region"]), city: str(j["city"]), timezone: str(j["timezone"]),
                asn: parts?.first, org: parts?.count == 2 ? parts?[1] : nil, hostname: str(j["hostname"])
            ))
        }
        if let j = ipwho, (j["success"] as? Bool) != false {
            let conn = j["connection"] as? [String: Any]
            let tz = j["timezone"] as? [String: Any]
            let asn = (conn?["asn"] as? NSNumber).map { "AS\($0.intValue)" }
            sources.append(IntelSource(
                source: "ipwho.is",
                country: str(j["country_code"]), region: str(j["region"]), city: str(j["city"]), timezone: str(tz?["id"]),
                asn: asn, org: str(conn?["org"]), isp: str(conn?["isp"])
            ))
        }
        if let j = ipapi, j["error"] == nil, j["ip"] != nil {
            let loc = j["location"] as? [String: Any]
            var asn: String?, isp: String?
            if let asnObj = j["asn"] as? [String: Any] {
                asn = (asnObj["asn"] as? NSNumber).map { "AS\($0.intValue)" }
                isp = str(asnObj["org"])
            } else if let asnStr = str(j["asn"]) {
                let parts = asnStr.split(separator: " ", maxSplits: 1).map(String.init)
                asn = parts.first
                isp = parts.count == 2 ? parts[1] : nil
            }
            var org: String?
            if let comp = j["company"] as? [String: Any] { org = str(comp["name"]) } else { org = str(j["company"]) }
            let country = str(loc?["country_code"]) ?? str(j["country_code"]) ?? Classifier.countryCode(fromName: str(j["country"]))
            let flags = IntelFlags(datacenter: j["is_datacenter"] as? Bool, vpn: j["is_vpn"] as? Bool, proxy: j["is_proxy"] as? Bool, tor: j["is_tor"] as? Bool)
            let hasFlags = flags.datacenter != nil || flags.vpn != nil || flags.proxy != nil || flags.tor != nil
            sources.append(IntelSource(
                source: "ipapi.is",
                country: country, region: str(loc?["state"]) ?? str(j["region"]), city: str(loc?["city"]) ?? str(j["city"]),
                timezone: str(loc?["timezone"]) ?? str(j["timezone"]),
                asn: asn, org: org, isp: isp, flags: hasFlags ? flags : nil
            ))
        }
        return sources
    }

    public static func merge(_ sources: [IntelSource], ip: String) -> IPIntel {
        func first(_ f: (IntelSource) -> String?) -> String? { sources.lazy.compactMap(f).first }
        func uniq(_ xs: [String?]) -> [String] {
            var seen = Set<String>()
            return xs.compactMap { $0 }.filter { seen.insert($0).inserted }
        }
        let countries = uniq(sources.map { $0.country })
        let asns = uniq(sources.map { $0.asn })
        let timezones = uniq(sources.map { $0.timezone })
        let flags = sources.lazy.compactMap { $0.flags }.first
        let org = first { $0.org }
        let isp = first { $0.isp }
        let asn = first { $0.asn }
        let hostname = first { $0.hostname }
        return IPIntel(
            ip: ip,
            country: first { $0.country }, region: first { $0.region }, city: first { $0.city }, timezone: first { $0.timezone },
            asn: asn, org: org, isp: isp, hostname: hostname,
            countries: countries, asns: asns, timezones: timezones, flags: flags,
            sources: sources.map { $0.source },
            countryConsistent: countries.count <= 1,
            asnConsistent: asns.count <= 1,
            classification: Classifier.classify(asn: asn, org: org, isp: isp, hostname: hostname, flags: flags)
        )
    }

    public static func collect(options: CheckOptions, progress: @escaping @Sendable (Stage) -> Void) async -> EgressFacts {
        let started = Date()
        let session = HTTP.session(timeoutMs: options.timeoutMs)
        progress(.sampling)

        // 1) 重复采样、2) 交叉回显、3) v6 探针 三路并行。
        async let repeatedTask: [String] = {
            var out: [String] = []
            for i in 0..<options.samples {
                if let r = await HTTP.fetch(echoes[0].url, session: session), Net.isV4(r.text) { out.append(r.text) }
                if i < options.samples - 1, options.intervalMs > 0 {
                    try? await Task.sleep(nanoseconds: UInt64(options.intervalMs) * 1_000_000)
                }
            }
            return out
        }()

        async let crossedTask: [EchoObservation] = withTaskGroup(of: (Int, EchoObservation).self) { group in
            for (i, echo) in echoes.dropFirst().enumerated() {
                group.addTask { (i, parseEcho(echo, await HTTP.fetch(echo.url, session: session))) }
            }
            var out: [(Int, EchoObservation)] = []
            for await x in group { out.append(x) }
            return out.sorted { $0.0 < $1.0 }.map { $0.1 }
        }

        async let v6Task: String? = withTaskGroup(of: String?.self) { group in
            for u in v6Probes {
                group.addTask {
                    let r = await HTTP.fetch(u, session: session)
                    return (r.map { Net.isV6($0.text) } ?? false) ? r?.text : nil
                }
            }
            var hit: String?
            for await x in group where hit == nil { hit = x }
            return hit
        }

        let (repeated, crossed, v6Probe) = await (repeatedTask, crossedTask, v6Task)

        var v4Obs: [String] = repeated
        var v6Seen: [String] = []
        for c in crossed {
            guard let ip = c.ip else { continue }
            if Net.isV4(ip) { v4Obs.append(ip) }
            else if Net.isV6(ip), !v6Seen.contains(ip) { v6Seen.append(ip) }
        }
        if let v6Probe, !v6Seen.contains(v6Probe) { v6Seen.insert(v6Probe, at: 0) }

        var counts: [String: Int] = [:]
        var order: [String] = []
        for ip in v4Obs {
            if counts[ip] == nil { order.append(ip) }
            counts[ip, default: 0] += 1
        }
        let distinct = order.map { IPCount(ip: $0, count: counts[$0]!) }.sorted { $0.count != $1.count ? $0.count > $1.count : $0.ip < $1.ip }
        let prefixes = Set(distinct.map { $0.ip.split(separator: ".").prefix(3).joined(separator: ".") })
        let primaryIp = distinct.first?.ip
        let v6 = v6Probe ?? v6Seen.first

        // 时钟偏差：优先 cf-trace 的 ts（毫秒级），退而用 Date 头（秒级）。
        var clock: ClockSample?
        if let cf = crossed.first(where: { $0.echo == "cf-trace" && $0.serverTs != nil && $0.receivedAt != nil }), let rtt = cf.rttMs {
            let skew = (cf.receivedAt!.timeIntervalSince1970 - rtt / 2000 - cf.serverTs!.timeIntervalSince1970) * 1000
            clock = ClockSample(source: "cf-trace ts", skewMs: skew, rttMs: rtt, coarse: false)
        } else if let any = crossed.first(where: { $0.dateHeader != nil && $0.receivedAt != nil }), let rtt = any.rttMs {
            let fmt = DateFormatter()
            fmt.locale = Locale(identifier: "en_US_POSIX")
            fmt.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
            if let t = fmt.date(from: any.dateHeader!) {
                let skew = (any.receivedAt!.timeIntervalSince1970 - rtt / 2000 - t.timeIntervalSince1970) * 1000
                clock = ClockSample(source: "\(any.echo) Date 头", skewMs: skew, rttMs: rtt, coarse: true)
            }
        }

        progress(.intel)
        async let primarySources: [IntelSource] = {
            guard let ip = primaryIp else { return [] }
            return await collectIntel(ip, session: session)
        }()
        async let v6Sources: [IntelSource] = {
            guard let ip = v6 else { return [] }
            return await collectIntel(ip, session: session)
        }()
        let (ps, vs) = await (primarySources, v6Sources)
        let primary = primaryIp.map { merge(ps, ip: $0) }
        let v6Intel = v6.map { merge(vs, ip: $0) }

        let crossSeen = Set(crossed.compactMap { $0.ip }.filter { Net.isV4($0) })
        let crossDiffers = primaryIp != nil && !crossSeen.isEmpty && crossSeen.contains { $0 != primaryIp }

        return EgressFacts(
            ok: primaryIp != nil,
            primary: primary,
            distinctIps: distinct,
            distinctCount: distinct.count,
            sampledDistinctCount: Set(repeated).count,
            samePrefix: prefixes.count <= 1,
            sampleCount: repeated.count,
            crossEchoes: crossed.map { CrossEcho(echo: $0.echo, ip: $0.ip, country: $0.country) },
            crossDiffers: crossDiffers,
            v6: v6,
            v6Intel: v6Intel,
            v6ViaDualStackEcho: !v6Seen.isEmpty && v6Probe == nil,
            clock: clock,
            durationMs: Int(Date().timeIntervalSince(started) * 1000),
            error: primaryIp == nil ? "所有回显服务均不可达（可能离线或代理挡掉了）" : nil
        )
    }
}
