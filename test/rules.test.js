import { test } from "node:test";
import assert from "node:assert/strict";
import { runRules, RULES } from "../src/rules.js";
import { mergeIntel } from "../src/network.js";

/** 一台「新加坡中文 Mac 走美国机房出口」的典型上下文。 */
function fixture(overrides = {}) {
  const primary = mergeIntel(
    [
      { source: "ipinfo.io", country: "US", region: "Washington", city: "Seattle", timezone: "America/Los_Angeles", asn: "AS36260", org: "Misaka Network, Inc.", hostname: "mail4.example.com" },
      { source: "ipwho.is", country: "US", timezone: "America/Los_Angeles", asn: "AS36260", org: "Misaka Network, Inc." },
    ],
    "65.97.55.214",
  );
  const ctx = {
    system: {
      timezone: { intl: "Asia/Singapore", localtimeLink: "Asia/Singapore", env: null, offsetMinutes: 480, offsetLabel: "UTC+08:00", consistent: true },
      locale: {
        appleLocale: "zh_SG",
        appleLanguages: ["zh-Hans-SG", "en-SG"],
        envRaw: "en_US.UTF-8",
        env: { language: "en", script: null, region: "US", raw: "en_US.UTF-8" },
        primary: { language: "zh", script: "hans", region: "SG", raw: "zh-Hans-SG" },
        apple: { language: "zh", script: null, region: "SG", raw: "zh_SG" },
      },
      hardware: { os: "macOS 26.7", chip: "Apple M1 Max", arch: "arm64", machineArch: "arm64", rosetta: false },
      runtime: { node: "v24.0.0", term: "iTerm", shell: "zsh" },
      proxy: { system: { available: true, http: false, https: false, socks: false }, env: [], apps: ["mihomo"], tun: ["utun5"], tunnels: [{ name: "utun5", addrs: ["198.18.0.1"] }], active: true },
      dns: { resolvers: ["127.0.0.1"], defaults: ["127.0.0.1"], perDomain: [], scoped: [], allThroughProxy: true },
    },
    fonts: { stock: ["PingFang.ttc"], thirdParty: [], vendor: [] },
    egress: {
      ok: true,
      primary,
      distinctIps: [{ ip: "65.97.55.214", count: 8 }],
      distinctCount: 1,
      sampledDistinctCount: 1,
      samePrefix: true,
      sampleCount: 6,
      crossEchoes: [{ echo: "cf-trace", ip: "65.97.55.214", country: "US" }],
      crossDiffers: false,
      v6: null,
      v6Intel: null,
      clock: { source: "cf-trace ts", skewMs: 120, rttMs: 300 },
      durationMs: 2000,
    },
  };
  return deepMerge(ctx, overrides);
}

function deepMerge(base, patch) {
  if (Array.isArray(patch) || patch === null || typeof patch !== "object") return patch;
  const out = { ...base };
  for (const [k, v] of Object.entries(patch)) out[k] = deepMerge(base?.[k], v);
  return out;
}

const byId = (verdict, id) => verdict.results.find((r) => r.id === id);

test("规则 ID 唯一且每条都有 impact/fix", () => {
  const ids = RULES.map((r) => r.id);
  assert.equal(new Set(ids).size, ids.length);
  for (const r of RULES) {
    assert.ok(r.impact, r.id);
    assert.ok(Array.isArray(r.fix) && r.fix.length, r.id);
  }
});

test("典型场景：时区差 9 小时 → high，结论 severe", () => {
  const v = runRules(fixture());
  assert.equal(byId(v, "egress-timezone").level, "high");
  assert.equal(byId(v, "ip-kind").level, "high");
  assert.equal(v.verdict, "severe");
});

test("egress-locale：语言与出口国相容只给 low，不相容给 medium", () => {
  // 系统区域 SG、出口 US、主语言 zh：zh 的常用地区不含 US → medium
  const v1 = runRules(fixture());
  assert.equal(byId(v1, "egress-locale").level, "medium");
  // 主语言 en 时，US 是 en 的常用地区 → low
  const v2 = runRules(fixture({ system: { locale: { primary: { language: "en", region: "SG", raw: "en-SG" } } } }));
  assert.equal(byId(v2, "egress-locale").level, "low");
  // 区域就是出口国 → ok
  const v3 = runRules(fixture({ system: { locale: { apple: { language: "en", region: "US", raw: "en_US" } } } }));
  assert.equal(byId(v3, "egress-locale").level, "ok");
});

test("ip-stability：同 /24 轮询 medium，跨网段 high，稳定 ok", () => {
  assert.equal(byId(runRules(fixture()), "ip-stability").level, "ok");
  const roll = fixture({ egress: { distinctIps: [{ ip: "65.97.55.214", count: 5 }, { ip: "65.97.55.215", count: 2 }], distinctCount: 2, sampledDistinctCount: 2, samePrefix: true } });
  assert.equal(byId(runRules(roll), "ip-stability").level, "medium");
  const jump = fixture({ egress: { distinctIps: [{ ip: "65.97.55.214", count: 5 }, { ip: "1.2.3.4", count: 2 }], distinctCount: 2, sampledDistinctCount: 2, samePrefix: false } });
  assert.equal(byId(runRules(jump), "ip-stability").level, "high");
});

test("clock-skew 分级", () => {
  assert.equal(byId(runRules(fixture()), "clock-skew").level, "ok");
  assert.equal(byId(runRules(fixture({ egress: { clock: { skewMs: 10_000, rttMs: 200, source: "x" } } })), "clock-skew").level, "low");
  assert.equal(byId(runRules(fixture({ egress: { clock: { skewMs: -120_000, rttMs: 200, source: "x" } } })), "clock-skew").level, "medium");
  assert.equal(byId(runRules(fixture({ egress: { clock: { skewMs: 900_000, rttMs: 200, source: "x" } } })), "clock-skew").level, "high");
  assert.equal(byId(runRules(fixture({ egress: { clock: { skewMs: 900_000, rttMs: 9000, source: "x" } } })), "clock-skew").skipped, true);
});

test("ipv6：无 v6 是 info，不同国家是 high", () => {
  assert.equal(byId(runRules(fixture()), "ipv6").level, "info");
  const leak = fixture({ egress: { v6: "2001:db8::1", v6Intel: { country: "SG", asn: "AS7473" } } });
  assert.equal(byId(runRules(leak), "ipv6").level, "high");
  const same = fixture({ egress: { v6: "2001:db8::1", v6Intel: { country: "US", asn: "AS36260" } } });
  assert.equal(byId(runRules(same), "ipv6").level, "ok");
});

test("dns-path：代理激活但默认解析器直连公网 → low", () => {
  const v = runRules(fixture({ system: { dns: { defaults: ["8.8.8.8", "127.0.0.1"], allThroughProxy: false } } }));
  assert.equal(byId(v, "dns-path").level, "low");
  const direct = runRules(fixture({ system: { proxy: { active: false, apps: [], tunnels: [], tun: [] }, dns: { defaults: ["8.8.8.8"], allThroughProxy: false } } }));
  assert.equal(byId(direct, "dns-path").level, "info");
});

test("离线：网络规则全部标为跳过，不算通过；结论只看本地层", () => {
  const v = runRules(fixture({ egress: { ok: false, primary: null, error: "offline", clock: null } }));
  for (const id of ["egress-timezone", "egress-locale", "ip-kind", "ip-stability", "ip-intel-consistency", "clock-skew", "ipv6"]) {
    assert.equal(byId(v, id).skipped, true, id);
  }
  assert.equal(byId(v, "vendor-fonts").level, "ok");
  assert.equal(v.worst, "low"); // 只剩 locale-layer zh/en 的 low
  assert.equal(v.verdict, "minor");
});

test("runtime-arch：Rosetta → low", () => {
  const v = runRules(fixture({ system: { hardware: { rosetta: true, arch: "x64" } } }));
  assert.equal(byId(v, "runtime-arch").level, "low");
});

test("结果按等级排序，worst/verdict 取最高非跳过项", () => {
  const v = runRules(fixture());
  assert.equal(v.results[0].level, "high");
  assert.equal(v.worst, "high");
  assert.equal(v.verdict, "severe");
});
