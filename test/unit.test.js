import { test } from "node:test";
import assert from "node:assert/strict";

import { parseLocaleTag, isPrivateAddr, offsetMinutesFor, formatOffset, parseScutilDns, parseIfconfig, activeTunnels, matchProxyApps, parseScutilProxy } from "../src/system.js";
import { classifyEgress, regionName, countryCodeFromName, LANG_HOME } from "../src/classify.js";
import { parseEcho, mergeIntel, isV4, isV6 } from "../src/network.js";
import { parseArgs } from "../src/cli.js";

test("parseLocaleTag 处理 POSIX / BCP47 / 带编码的标签", () => {
  assert.deepEqual(parseLocaleTag("zh_SG"), { language: "zh", script: null, region: "SG", raw: "zh_SG" });
  assert.deepEqual(parseLocaleTag("en_US.UTF-8"), { language: "en", script: null, region: "US", raw: "en_US.UTF-8" });
  assert.deepEqual(parseLocaleTag("zh-Hans-SG"), { language: "zh", script: "hans", region: "SG", raw: "zh-Hans-SG" });
  assert.equal(parseLocaleTag("de_DE@euro").region, "DE");
  assert.equal(parseLocaleTag(null), null);
});

test("isPrivateAddr：CGNAT 只覆盖 100.64/10，fake-ip 的 198.18 算保留", () => {
  for (const ip of ["10.0.0.1", "127.0.0.1", "192.168.1.1", "172.16.0.1", "172.31.255.255", "100.64.0.1", "100.118.2.114", "198.18.0.1", "169.254.1.1", "::1", "fe80::1", "fd7a:115c::1"]) {
    assert.equal(isPrivateAddr(ip), true, ip);
  }
  for (const ip of ["8.8.8.8", "100.0.0.1", "100.128.0.1", "172.32.0.1", "198.20.0.1", "2001:4860::8888", "not-an-ip", ""]) {
    assert.equal(isPrivateAddr(ip), false, ip);
  }
});

test("offsetMinutesFor 用 Intl 计算偏移并处理夏令时", () => {
  assert.equal(offsetMinutesFor("Asia/Singapore"), 480);
  assert.equal(offsetMinutesFor("UTC"), 0);
  assert.equal(offsetMinutesFor("America/Los_Angeles", new Date("2026-01-15T12:00:00Z")), -480);
  assert.equal(offsetMinutesFor("America/Los_Angeles", new Date("2026-07-15T12:00:00Z")), -420);
  assert.equal(offsetMinutesFor("Asia/Kolkata"), 330);
  assert.equal(offsetMinutesFor("Not/AZone"), null);
  assert.equal(formatOffset(-420), "UTC-07:00");
  assert.equal(formatOffset(330), "UTC+05:30");
});

const SCUTIL_DNS = `
DNS configuration

resolver #1
  nameserver[0] : 127.0.0.1
  if_index : 24 (utun5)
  flags    : Request A records, Request AAAA records
  reach    : 0x00030002 (Reachable,Local Address,Directly Reachable Address)

resolver #2
  domain   : youtu.be
  nameserver[0] : 127.0.0.1
  flags    : Supplemental, Request A records

resolver #3
  domain   : local
  options  : mdns
  timeout  : 5
  flags    : Request A records
  order    : 300000

DNS configuration (for scoped queries)

resolver #1
  search domain[0] : corp.example
  nameserver[0] : 202.106.0.20
  nameserver[1] : 202.106.196.115
  if_index : 12 (en0)
  flags    : Scoped, Request A records, Request AAAA records
`;

test("parseScutilDns 区分默认路径 / 按域名 / 接口限定", () => {
  const dns = parseScutilDns(SCUTIL_DNS);
  assert.deepEqual(dns.defaults, ["127.0.0.1"]);
  assert.deepEqual(dns.perDomain, [{ domain: "youtu.be", nameservers: ["127.0.0.1"] }]);
  assert.equal(dns.scoped.length, 1);
  assert.equal(dns.scoped[0].ifName, "en0");
  assert.deepEqual(dns.scoped[0].nameservers, ["202.106.0.20", "202.106.196.115"]);
  assert.deepEqual(parseScutilDns(null), { all: [], defaults: [], perDomain: [], scoped: [] });
});

const IFCONFIG = `
lo0: flags=8049<UP,LOOPBACK,RUNNING,MULTICAST> mtu 16384
	inet 127.0.0.1 netmask 0xff000000
	inet6 ::1 prefixlen 128
utun0: flags=8051<UP,POINTOPOINT,RUNNING,MULTICAST> mtu 1500
	inet6 fe80::66f1:a857:b874:493c%utun0 prefixlen 64 scopeid 0x12
utun1: flags=8051<UP,POINTOPOINT,RUNNING,MULTICAST> mtu 1380
	inet6 fe80::e584:95df:2899:f322%utun1 prefixlen 64 scopeid 0x13
utun5: flags=8051<UP,POINTOPOINT,RUNNING,MULTICAST> mtu 9000
	inet 198.18.0.1 --> 198.18.0.1 netmask 0xfffffffc
utun9: flags=8051<UP,POINTOPOINT,RUNNING,MULTICAST> mtu 1280
	inet6 fe80::6e1f:f7ff:fe19:9919%utun9 prefixlen 64 scopeid 0x23
	inet 100.118.2.114 --> 100.118.2.114 netmask 0xffffffff
	inet6 fd7a:115c:a1e0::2401:2a9 prefixlen 48
en0: flags=8863<UP,BROADCAST,SMART,RUNNING,SIMPLEX,MULTICAST> mtu 1500
	inet 192.168.1.10 netmask 0xffffff00 broadcast 192.168.1.255
`;

test("activeTunnels 只认有实际地址的 utun，忽略系统自带的 fe80-only 接口", () => {
  const tunnels = activeTunnels(parseIfconfig(IFCONFIG));
  assert.deepEqual(tunnels.map((t) => t.name), ["utun5", "utun9"]);
  assert.deepEqual(tunnels[1].addrs, ["100.118.2.114", "fd7a:115c:a1e0::2401:2a9"]);
});

test("matchProxyApps 命中已知进程名且不误伤", () => {
  const ps = ["/usr/libexec/trustd", "mihomo", "/Applications/ClashX Meta.app/Contents/MacOS/ClashX Meta", "tailscaled", "surgeon", "node"].join("\n");
  const found = matchProxyApps(ps);
  assert.ok(found.includes("mihomo"));
  assert.ok(found.includes("clashx meta"));
  assert.ok(found.includes("tailscaled"));
  assert.ok(!found.includes("surgeon"));
  assert.ok(!found.includes("node"));
});

test("parseScutilProxy 读取开关", () => {
  const p = parseScutilProxy("<dictionary> {\n  HTTPEnable : 1\n  HTTPPort : 7890\n  HTTPSEnable : 0\n  SOCKSEnable : 1\n}");
  assert.deepEqual(p, { available: true, http: true, https: false, socks: true, pac: false });
  assert.deepEqual(parseScutilProxy(null), { available: false });
});

test("classifyEgress：ASN 名单 / 关键字 / rDNS / 情报标记", () => {
  const misaka = classifyEgress({ asn: "AS36260", org: "Misaka Network, Inc.", hostname: "mail4.example.com" });
  assert.equal(misaka.kind, "hosting");
  assert.equal(misaka.confidence, "high");

  const isp = classifyEgress({ asn: "AS7922", org: "Comcast Cable Communications, LLC", hostname: "c-1-2-3-4.hsd1.wa.comcast.net" });
  assert.equal(isp.kind, "isp");

  const googleFiber = classifyEgress({ asn: "AS16591", org: "Google Fiber Inc." });
  assert.equal(googleFiber.kind, "isp");

  const tie = classifyEgress({ asn: "AS99998", org: "Cloud Fiber Ltd" });
  assert.equal(tie.kind, "unknown");

  const flagged = classifyEgress({ asn: "AS99999", org: "Nobody", flags: { datacenter: true, vpn: false, proxy: false, tor: false } });
  assert.equal(flagged.kind, "hosting");
  assert.equal(flagged.confidence, "high");

  const none = classifyEgress({ asn: null, org: null });
  assert.equal(none.kind, "unknown");
  assert.equal(none.basis[0], "无任何托管/运营商特征，无法判定");
});

test("regionName / countryCodeFromName 走 Intl 并保留口语化覆盖", () => {
  assert.equal(regionName("US"), "美国");
  assert.equal(regionName("CN"), "中国大陆");
  assert.equal(regionName("HK"), "香港");
  assert.equal(regionName(null), "未知");
  assert.equal(countryCodeFromName("United States"), "US");
  assert.equal(countryCodeFromName("Hong Kong"), "HK");
  assert.equal(countryCodeFromName("sg"), "SG");
  assert.equal(countryCodeFromName("Atlantis"), null);
  assert.ok(LANG_HOME.en.has("SG"));
});

test("parseEcho / isV4 / isV6", () => {
  assert.equal(isV4("1.2.3.4"), true);
  assert.equal(isV6("2001:db8::1"), true);
  assert.equal(isV4("2001:db8::1"), false);
  const trace = parseEcho({ parse: "trace" }, "fl=1\nip=65.97.55.214\nts=1792990187.000\nloc=US\n");
  assert.equal(trace.ip, "65.97.55.214");
  assert.equal(trace.country, "US");
  assert.equal(trace.serverTs, 1792990187000);
  assert.equal(parseEcho({}, "garbage").ip, null);
  assert.equal(parseEcho({}, "9.9.9.9").ip, "9.9.9.9");
});

test("mergeIntel 汇总多源并判一致性", () => {
  const merged = mergeIntel(
    [
      { source: "a", country: "US", asn: "AS1", timezone: "America/Los_Angeles", org: "Example Hosting" },
      { source: "b", country: "US", asn: "AS1", timezone: "America/Los_Angeles" },
      { source: "c", country: "CA", asn: "AS2" },
    ],
    "1.2.3.4",
  );
  assert.equal(merged.country, "US");
  assert.deepEqual(merged.countries, ["US", "CA"]);
  assert.equal(merged.countryConsistent, false);
  assert.equal(merged.asnConsistent, false);
  assert.equal(merged.classification.kind, "hosting");
});

test("parseArgs 校验数字参数", () => {
  assert.equal(parseArgs(["--samples", "12"]).samples, 12);
  assert.equal(parseArgs(["--timeout", "10"]).timeoutMs, 1000);
  assert.equal(parseArgs(["--offline", "--json"]).offline, true);
  assert.throws(() => parseArgs(["--samples", "abc"]), /需要一个数字/);
  assert.throws(() => parseArgs(["--samples"]), /缺少取值/);
  assert.throws(() => parseArgs(["--bogus"]), /未知参数/);
});
