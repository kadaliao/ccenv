import XCTest
@testable import CCEnvCore

final class CoreTests: XCTestCase {
    func testLocaleParsing() {
        XCTAssertEqual(LocaleParsing.parse("zh_SG"), LocaleTag(language: "zh", script: nil, region: "SG", raw: "zh_SG"))
        XCTAssertEqual(LocaleParsing.parse("en_US.UTF-8")?.region, "US")
        XCTAssertEqual(LocaleParsing.parse("zh-Hans-SG")?.script, "hans")
        XCTAssertEqual(LocaleParsing.parse("de_DE@euro")?.region, "DE")
        XCTAssertNil(LocaleParsing.parse(nil))
    }

    func testPrivateAddresses() {
        for ip in ["10.0.0.1", "127.0.0.1", "192.168.1.1", "172.16.0.1", "100.64.0.1", "100.118.2.114", "198.18.0.1", "169.254.1.1", "::1", "fe80::1", "fd7a:115c::1"] {
            XCTAssertTrue(Net.isPrivate(ip), ip)
        }
        for ip in ["8.8.8.8", "100.0.0.1", "100.128.0.1", "172.32.0.1", "198.20.0.1", "2001:4860::8888", "nope", ""] {
            XCTAssertFalse(Net.isPrivate(ip), ip)
        }
    }

    func testTimeZoneMath() {
        XCTAssertEqual(TimeZoneMath.offsetMinutes(for: "Asia/Singapore"), 480)
        XCTAssertEqual(TimeZoneMath.offsetMinutes(for: "America/Los_Angeles", at: Date(timeIntervalSince1970: 1_768_478_400)), -480) // 2026-01-15
        XCTAssertEqual(TimeZoneMath.offsetMinutes(for: "America/Los_Angeles", at: Date(timeIntervalSince1970: 1_784_116_800)), -420) // 2026-07-15
        XCTAssertNil(TimeZoneMath.offsetMinutes(for: "Not/AZone"))
        XCTAssertEqual(TimeZoneMath.format(-420), "UTC-07:00")
        XCTAssertEqual(TimeZoneMath.format(330), "UTC+05:30")
        XCTAssertEqual(TimeZoneMath.circularMinutes(-420, 480), 540)
        XCTAssertEqual(TimeZoneMath.circularMinutes(-720, 720), 0)
    }

    func testScutilDns() {
        let out = """
        DNS configuration

        resolver #1
          nameserver[0] : 127.0.0.1
          if_index : 24 (utun5)

        resolver #2
          domain   : youtu.be
          nameserver[0] : 127.0.0.1

        DNS configuration (for scoped queries)

        resolver #1
          search domain[0] : corp.example
          nameserver[0] : 202.106.0.20
          nameserver[1] : 202.106.196.115
          if_index : 12 (en0)
        """
        let dns = SystemCollector.parseScutilDns(out)
        XCTAssertEqual(dns.defaults, ["127.0.0.1"])
        XCTAssertEqual(dns.perDomain, [PerDomainResolver(domain: "youtu.be", nameservers: ["127.0.0.1"])])
        XCTAssertEqual(dns.scoped.count, 1)
        XCTAssertEqual(dns.scoped.first?.ifName, "en0")
        XCTAssertEqual(dns.scoped.first?.nameservers, ["202.106.0.20", "202.106.196.115"])
        XCTAssertTrue(dns.allThroughProxy)
    }

    func testTunnels() {
        let out = """
        utun0: flags=8051<UP,POINTOPOINT,RUNNING,MULTICAST> mtu 1500
        \tinet6 fe80::66f1:a857:b874:493c%utun0 prefixlen 64 scopeid 0x12
        utun5: flags=8051<UP,POINTOPOINT,RUNNING,MULTICAST> mtu 9000
        \tinet 198.18.0.1 --> 198.18.0.1 netmask 0xfffffffc
        utun9: flags=8051<UP,POINTOPOINT,RUNNING,MULTICAST> mtu 1280
        \tinet6 fe80::6e1f:f7ff:fe19:9919%utun9 prefixlen 64 scopeid 0x23
        \tinet 100.118.2.114 --> 100.118.2.114 netmask 0xffffffff
        \tinet6 fd7a:115c:a1e0::2401:2a9 prefixlen 48
        en0: flags=8863<UP,BROADCAST,SMART,RUNNING,SIMPLEX,MULTICAST> mtu 1500
        \tinet 192.168.1.10 netmask 0xffffff00 broadcast 192.168.1.255
        """
        let tunnels = SystemCollector.activeTunnels(SystemCollector.parseIfconfig(out))
        XCTAssertEqual(tunnels.map { $0.name }, ["utun5", "utun9"])
        XCTAssertEqual(tunnels[1].addrs, ["100.118.2.114", "fd7a:115c:a1e0::2401:2a9"])
    }

    func testProxyApps() {
        let ps = ["/usr/libexec/trustd", "mihomo", "/Applications/ClashX Meta.app/Contents/MacOS/ClashX Meta", "tailscaled", "surgeon", "node"].joined(separator: "\n")
        let found = SystemCollector.matchProxyApps(ps)
        XCTAssertTrue(found.contains("mihomo"))
        XCTAssertTrue(found.contains("clashx meta"))
        XCTAssertTrue(found.contains("tailscaled"))
        XCTAssertFalse(found.contains("surgeon"))
        XCTAssertFalse(found.contains("node"))
    }

    func testClassify() {
        let misaka = Classifier.classify(asn: "AS36260", org: "Misaka Network, Inc.", isp: nil, hostname: "mail4.example.com", flags: nil)
        XCTAssertEqual(misaka.kind, .hosting)
        XCTAssertEqual(misaka.confidence, .high)
        let comcast = Classifier.classify(asn: "AS7922", org: "Comcast Cable Communications, LLC", isp: nil, hostname: "c-1-2-3-4.hsd1.wa.comcast.net", flags: nil)
        XCTAssertEqual(comcast.kind, .isp)
        XCTAssertEqual(Classifier.classify(asn: "AS99998", org: "Cloud Fiber Ltd", isp: nil, hostname: nil, flags: nil).kind, .unknown)
        let flagged = Classifier.classify(asn: "AS99999", org: "Nobody", isp: nil, hostname: nil, flags: IntelFlags(datacenter: true, vpn: false, proxy: false, tor: false))
        XCTAssertEqual(flagged.kind, .hosting)
        XCTAssertEqual(Classifier.classify(asn: nil, org: nil, isp: nil, hostname: nil, flags: nil).basis, ["无任何托管/运营商特征，无法判定"])
    }

    func testRegionNames() {
        XCTAssertEqual(Classifier.regionName("US"), "美国")
        XCTAssertEqual(Classifier.regionName("CN"), "中国大陆")
        XCTAssertEqual(Classifier.regionName(nil), "未知")
        XCTAssertEqual(Classifier.countryCode(fromName: "United States"), "US")
        XCTAssertEqual(Classifier.countryCode(fromName: "Hong Kong"), "HK")
        XCTAssertEqual(Classifier.countryCode(fromName: "sg"), "SG")
        XCTAssertNil(Classifier.countryCode(fromName: "Atlantis"))
    }

    // MARK: 规则

    func fixture(_ mutate: (inout Context) -> Void = { _ in }) -> Context {
        let primary = EgressCollector.merge([
            IntelSource(source: "ipinfo.io", country: "US", region: "Washington", city: "Seattle", timezone: "America/Los_Angeles", asn: "AS36260", org: "Misaka Network, Inc.", hostname: "mail4.example.com"),
            IntelSource(source: "ipwho.is", country: "US", timezone: "America/Los_Angeles", asn: "AS36260", org: "Misaka Network, Inc."),
        ], ip: "65.97.55.214")
        var ctx = Context(
            system: SystemFacts(
                collectedAt: "now",
                timezone: TimezoneFacts(intl: "Asia/Singapore", localtimeLink: "Asia/Singapore", env: nil, offsetMinutes: 480, offsetLabel: "UTC+08:00", consistent: true),
                locale: LocaleFacts(appleLocale: "zh_SG", appleLanguages: ["zh-Hans-SG", "en-SG"], envRaw: "en_US.UTF-8",
                                    env: LocaleParsing.parse("en_US.UTF-8"), primary: LocaleParsing.parse("zh-Hans-SG"), apple: LocaleParsing.parse("zh_SG")),
                hardware: HardwareFacts(os: "macOS 26.7", model: "Mac", chip: "Apple M1 Max", arch: "arm64", machineArch: "arm64", rosetta: false),
                runtime: RuntimeFacts(name: "ccenv.app test", term: nil, shell: "zsh"),
                proxy: ProxyFacts(system: SystemProxyFacts(available: true, http: false, https: false, socks: false, pac: false), env: [], apps: ["mihomo"], tun: ["utun5"], tunnels: [Tunnel(name: "utun5", addrs: ["198.18.0.1"])], active: true),
                dns: DNSFacts(resolvers: ["127.0.0.1"], defaults: ["127.0.0.1"], perDomain: [], scoped: [], allThroughProxy: true)
            ),
            fonts: FontFacts(scannedFiles: 10, stock: ["PingFang.ttc"], thirdParty: [], vendor: [], hasEmoji: true),
            egress: EgressFacts(ok: true, primary: primary, distinctIps: [IPCount(ip: "65.97.55.214", count: 8)], distinctCount: 1, sampledDistinctCount: 1, samePrefix: true, sampleCount: 6,
                                crossEchoes: [CrossEcho(echo: "cf-trace", ip: "65.97.55.214", country: "US")], crossDiffers: false, v6: nil, v6Intel: nil, v6ViaDualStackEcho: false,
                                clock: ClockSample(source: "cf-trace ts", skewMs: 120, rttMs: 300, coarse: false), durationMs: 2000, error: nil)
        )
        mutate(&ctx)
        return ctx
    }

    func level(_ o: RuleEngine.Outcome, _ id: String) -> Level { o.results.first { $0.id == id }!.level }
    func skipped(_ o: RuleEngine.Outcome, _ id: String) -> Bool { o.results.first { $0.id == id }!.skipped }

    func testRuleIdsUnique() {
        let ids = RuleEngine.rules.map { $0.id }
        XCTAssertEqual(Set(ids).count, ids.count)
        XCTAssertEqual(ids.count, 12)
    }

    func testTypicalScenario() {
        let o = RuleEngine.run(fixture())
        XCTAssertEqual(level(o, "egress-timezone"), .high)
        XCTAssertEqual(level(o, "ip-kind"), .high)
        XCTAssertEqual(level(o, "egress-locale"), .medium)
        XCTAssertEqual(level(o, "locale-layer"), .low)
        XCTAssertEqual(level(o, "ip-stability"), .ok)
        XCTAssertEqual(level(o, "clock-skew"), .ok)
        XCTAssertEqual(level(o, "ipv6"), .info)
        XCTAssertEqual(o.worst, .high)
        XCTAssertEqual(o.verdict, .severe)
        XCTAssertEqual(o.results.first?.level, .high)
    }

    func testLocaleRule() {
        let en = RuleEngine.run(fixture { $0.system.locale.primary = LocaleParsing.parse("en-SG") })
        XCTAssertEqual(level(en, "egress-locale"), .low)
        let us = RuleEngine.run(fixture { $0.system.locale.apple = LocaleParsing.parse("en_US") })
        XCTAssertEqual(level(us, "egress-locale"), .ok)
    }

    func testStabilityRule() {
        let roll = RuleEngine.run(fixture {
            $0.egress.distinctIps = [IPCount(ip: "65.97.55.214", count: 5), IPCount(ip: "65.97.55.215", count: 2)]
            $0.egress.distinctCount = 2
        })
        XCTAssertEqual(level(roll, "ip-stability"), .medium)
        let jump = RuleEngine.run(fixture {
            $0.egress.distinctIps = [IPCount(ip: "65.97.55.214", count: 5), IPCount(ip: "1.2.3.4", count: 2)]
            $0.egress.distinctCount = 2
            $0.egress.samePrefix = false
        })
        XCTAssertEqual(level(jump, "ip-stability"), .high)
    }

    func testClockSkew() {
        XCTAssertEqual(level(RuleEngine.run(fixture { $0.egress.clock = ClockSample(source: "x", skewMs: 10_000, rttMs: 200, coarse: false) }), "clock-skew"), .low)
        XCTAssertEqual(level(RuleEngine.run(fixture { $0.egress.clock = ClockSample(source: "x", skewMs: -120_000, rttMs: 200, coarse: false) }), "clock-skew"), .medium)
        XCTAssertEqual(level(RuleEngine.run(fixture { $0.egress.clock = ClockSample(source: "x", skewMs: 900_000, rttMs: 200, coarse: false) }), "clock-skew"), .high)
        XCTAssertTrue(skipped(RuleEngine.run(fixture { $0.egress.clock = ClockSample(source: "x", skewMs: 900_000, rttMs: 9000, coarse: false) }), "clock-skew"))
    }

    func testIPv6Rule() {
        let leak = RuleEngine.run(fixture {
            $0.egress.v6 = "2001:db8::1"
            $0.egress.v6Intel = EgressCollector.merge([IntelSource(source: "ipinfo.io", country: "SG", asn: "AS7473")], ip: "2001:db8::1")
        })
        XCTAssertEqual(level(leak, "ipv6"), .high)
    }

    func testDnsRule() {
        let low = RuleEngine.run(fixture { $0.system.dns.defaults = ["8.8.8.8", "127.0.0.1"]; $0.system.dns.allThroughProxy = false })
        XCTAssertEqual(level(low, "dns-path"), .low)
        let direct = RuleEngine.run(fixture {
            $0.system.dns.defaults = ["8.8.8.8"]; $0.system.dns.allThroughProxy = false
            $0.system.proxy.active = false; $0.system.proxy.apps = []; $0.system.proxy.tunnels = []
        })
        XCTAssertEqual(level(direct, "dns-path"), .info)
    }

    func testOffline() {
        let o = RuleEngine.run(fixture { $0.egress = .offline("offline") })
        for id in ["egress-timezone", "egress-locale", "ip-kind", "ip-stability", "ip-intel-consistency", "clock-skew", "ipv6"] {
            XCTAssertTrue(skipped(o, id), id)
        }
        XCTAssertEqual(o.worst, .low)
        XCTAssertEqual(o.verdict, .minor)
    }

    func testJsonSchemaShape() throws {
        let ctx = fixture()
        let o = RuleEngine.run(ctx)
        let report = Report(tool: "ccenv", version: "test", schema: schemaVersion, generatedAt: "now", verdict: .init(value: o.verdict, worst: o.worst), facts: .init(egress: ctx.egress, system: ctx.system, fonts: ctx.fonts), rules: o.results)
        let data = CCEnv.json(report).data(using: .utf8)!
        let obj = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        XCTAssertEqual(obj["schema"] as? Int, 2)
        let rules = obj["rules"] as! [[String: Any]]
        XCTAssertEqual(rules.count, 12)
        let ev = rules.first { $0["id"] as? String == "egress-timezone" }!["evidence"] as! [[String]]
        XCTAssertEqual(ev.first?.count, 2)
        let runtime = ((obj["facts"] as! [String: Any])["system"] as! [String: Any])["runtime"] as! [String: Any]
        XCTAssertNotNil(runtime["node"])
        // 往返
        let decoded = try JSONDecoder().decode(Report.self, from: data)
        XCTAssertEqual(decoded.rules.count, 12)
        XCTAssertFalse(CCEnv.text(report).isEmpty)
    }
}
