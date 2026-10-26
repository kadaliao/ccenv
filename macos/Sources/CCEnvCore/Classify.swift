// 出口 IP / ASN 类型归类 + 地区名显示。对应 CLI 的 src/classify.js。
// 启发式判断，并始终把命中依据一起输出，让人能自己判断。

import Foundation

public enum Classifier {
    static let hostingASNs: Set<String> = [
        "AS36260", "AS16509", "AS14618", "AS396982", "AS15169", "AS8075", "AS14061",
        "AS20473", "AS63949", "AS48337", "AS24940", "AS213230", "AS16276", "AS51167",
        "AS45102", "AS37963", "AS132203", "AS31898", "AS9009", "AS60781", "AS200373",
        "AS209854", "AS62240", "AS41378", "AS6939", "AS13335", "AS54113", "AS19551",
        "AS202425", "AS210644", "AS49505", "AS9123", "AS174", "AS3356", "AS212238", "AS9370",
    ]

    static let hostingWords: [String] = [
        "hosting", "datacenter", "data center", "datacentre", "cloud", "vps",
        "server", "serverfarm", "colo", "colocation", "dedicated", "bare metal",
        "misaka", "digitalocean", "vultr", "linode", "hetzner", "ovh", "amazon",
        "aws", "google llc", "microsoft", "azure", "oracle", "contabo", "alibaba",
        "aliyun", "tencent", "zenlayer", "m247", "frantech", "buyvm", "upcloud",
        "scaleway", "equinix", "leaseweb", "choopa", "akamai", "fastly",
        "cloudflare", "kaopu", "cogent", "hurricane electric", "zayo", "gtt",
        "level3", "lumen", "transit", "backbone", "datacamp", "cdn77", "sakura internet",
    ]

    static let ispWords: [String] = [
        "broadband", "telecom", "telecommunication", "communications", "cable",
        "fiber", "fibre", "mobile", "wireless", "cellular", "internet service",
        "telco", "comcast", "verizon", "at&t", "deutsche telekom", "vodafone",
        "singtel", "starhub", "m1 limited", "softbank", "kddi", "docomo", "china mobile",
        "china unicom", "china telecom", "chunghwa", "hkt", "pccw", "hgc",
        "sk broadband", "kt corporation", "lg uplus", "jio", "airtel", "rogers", "bell canada",
        "telus", "telstra", "optus", "vocus", "spark new zealand",
        "proximus", "kpn", "ziggo", "telenet", "swisscom", "telefonica", "orange",
        "virgin media", "talktalk", "bt public", "sky uk", "elisa", "telenor", "telia",
        "hotwire", "sonic", "spectrum", "charter", "cox", "frontier", "centurylink",
    ]

    public static func classify(asn: String?, org: String?, isp: String?, hostname: String?, flags: IntelFlags?) -> Classification {
        let asnShort = (asn ?? "").uppercased().split(separator: " ").first.map(String.init) ?? ""
        let text = [org, isp].compactMap { $0 }.joined(separator: " ").lowercased()

        var basis: [String] = []
        var confidence: Confidence = .low
        var forced: EgressKind?

        if let f = flags {
            let on = [("datacenter", f.datacenter), ("vpn", f.vpn), ("proxy", f.proxy), ("tor", f.tor)].filter { $0.1 == true }.map { $0.0 }
            if !on.isEmpty {
                basis.append("情报源标记：\(on.joined(separator: ", "))")
                confidence = .high
                forced = .hosting
            } else if f.datacenter == false && f.vpn == false && f.proxy == false {
                basis.append("情报源标记：非机房 / 非 VPN / 非代理")
            }
        }

        if !asnShort.isEmpty, hostingASNs.contains(asnShort) {
            basis.append("\(asnShort) 在托管/云厂商 ASN 名单中")
            confidence = .high
            forced = .hosting
        }

        let h = hostingWords.filter { text.contains($0) }
        let i = ispWords.filter { text.contains($0) }
        if !h.isEmpty { basis.append("组织名命中托管关键字：\(h.prefix(4).joined(separator: ", "))") }
        if !i.isEmpty { basis.append("组织名命中运营商关键字：\(i.prefix(4).joined(separator: ", "))") }

        if let hostname, !hostname.isEmpty {
            let hst = hostname.lowercased()
            let looksDynamic = Rx.test("(dynamic|dyn|dsl|ppp|pppoe|dhcp|broadband|bb\\.|cust|client|pool|static|res\\.|resi|home|user)", hst)
            if !looksDynamic, hst.contains(".") {
                basis.append("rDNS 为业务域名 \(hst)（非运营商动态地址命名）")
                if confidence == .low { confidence = .medium }
            } else if looksDynamic {
                basis.append("rDNS 像运营商客户地址命名 \(hst)")
            }
        }

        var kind: EgressKind = .unknown
        if let forced { kind = forced }
        else if h.count > i.count { kind = .hosting }
        else if i.count > h.count { kind = .isp }

        if kind != .unknown, confidence == .low, h.count + i.count >= 2 { confidence = .medium }

        return Classification(kind: kind, basis: basis.isEmpty ? ["无任何托管/运营商特征，无法判定"] : basis, confidence: confidence)
    }

    static let regionOverrides: [String: String] = ["CN": "中国大陆", "HK": "香港", "MO": "澳门", "TW": "台湾"]
    static let zh = Locale(identifier: "zh_CN")

    public static func regionName(_ code: String?) -> String {
        guard let code, !code.isEmpty else { return "未知" }
        let cc = code.uppercased()
        if let o = regionOverrides[cc] { return o }
        return zh.localizedString(forRegionCode: cc) ?? cc
    }

    static let nameToCode: [String: String] = {
        let en = Locale(identifier: "en_US")
        var map: [String: String] = [:]
        for region in Locale.Region.isoRegions where region.identifier.count == 2 {
            if let name = en.localizedString(forRegionCode: region.identifier) {
                map[name.lowercased()] = region.identifier
            }
        }
        let aliases: [String: String] = [
            "united states of america": "US", "usa": "US", "uk": "GB", "russia": "RU",
            "south korea": "KR", "korea, republic of": "KR", "taiwan": "TW",
            "hong kong sar": "HK", "hong kong": "HK", "macau": "MO", "macao": "MO",
            "china": "CN", "mainland china": "CN", "vietnam": "VN", "czech republic": "CZ",
            "turkey": "TR", "netherlands": "NL", "the netherlands": "NL",
        ]
        for (k, v) in aliases { map[k] = v }
        return map
    }()

    /// 英文国家全名 -> ISO 代码（ipapi.is 免费层只给全名）。
    public static func countryCode(fromName name: String?) -> String? {
        guard let name else { return nil }
        let n = name.trimmingCharacters(in: .whitespaces)
        if Rx.test("^[A-Za-z]{2}$", n) { return n.uppercased() }
        return nameToCode[n.lowercased()]
    }

    /// 语言主标签 -> 常见使用地区。
    public static let langHome: [String: Set<String>] = [
        "zh": ["CN", "HK", "MO", "TW", "SG", "MY"],
        "en": ["US", "GB", "CA", "AU", "NZ", "IE", "SG", "IN", "PH", "ZA", "HK", "MY"],
        "ja": ["JP"], "ko": ["KR"], "ru": ["RU", "BY", "KZ"], "fa": ["IR"],
        "de": ["DE", "AT", "CH"], "fr": ["FR", "CA", "BE", "CH"],
        "es": ["ES", "MX", "AR", "CO", "CL", "PE"], "pt": ["PT", "BR"],
        "it": ["IT", "CH"], "nl": ["NL", "BE"], "ar": ["AE", "SA", "EG", "QA", "KW"],
        "th": ["TH"], "vi": ["VN"], "id": ["ID"], "ms": ["MY", "SG"], "tr": ["TR"],
    ]
}
