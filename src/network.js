// 出口层：真实公网 IP 采样 + 多源 IP/ASN 情报。
//
// 设计要点：
// 1. 多个互相独立的回显服务交叉验证，能发现「同一时刻不同目的地走不同出口」这种分流；
// 2. 同一服务重复采样，能发现出口 IP 在抖动；
// 3. v4 / v6 观测严格分开统计——双栈机器上 cf-trace / ipinfo 会回 v6，混进 v4 池会被误判成「跨网段漂移」。
// 4. 顺带记录服务端时间戳，用来检测本机时钟偏差。

import { classifyEgress, countryCodeFromName } from "./classify.js";

const DEFAULT_TIMEOUT = 8000;
const USER_AGENT = "ccenv/0.2 (+local consistency check)";

async function fetchWithTimeout(url, timeoutMs, { as = "text" } = {}) {
  const ctrl = new AbortController();
  const timer = setTimeout(() => ctrl.abort(), timeoutMs);
  const started = Date.now();
  try {
    const res = await fetch(url, { signal: ctrl.signal, headers: { "user-agent": USER_AGENT } });
    if (!res.ok) return null;
    const body = as === "json" ? await res.json() : (await res.text()).trim();
    return { body, dateHeader: res.headers.get("date"), rttMs: Date.now() - started, receivedAt: Date.now() };
  } catch {
    return null;
  } finally {
    clearTimeout(timer);
  }
}

export const isV4 = (s) => typeof s === "string" && /^(\d{1,3}\.){3}\d{1,3}$/.test(s.trim());
export const isV6 = (s) => typeof s === "string" && s.includes(":") && /^[0-9a-f:.]+$/i.test(s.trim());
export const isIp = (s) => isV4(s) || isV6(s);

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

/** 独立回显服务。ipify 的 api.ipify.org 只回 v4，其余是双栈。 */
const ECHOES = [
  { id: "ipify", url: "https://api.ipify.org" },
  { id: "cf-trace", url: "https://www.cloudflare.com/cdn-cgi/trace", parse: "trace" },
  { id: "ipwho", url: "https://ipwho.is/", as: "json", parse: "ipwho" },
  { id: "ipinfo", url: "https://ipinfo.io/json", as: "json", parse: "ipinfo" },
];

/** 只回 v6 的探针，任一成功即可。 */
const V6_PROBES = ["https://v6.ipinfo.io/ip", "https://api6.ipify.org"];

export function parseEcho(echo, raw) {
  if (raw == null) return null;
  if (echo.parse === "trace") {
    if (typeof raw !== "string") return null;
    const map = Object.fromEntries(raw.split("\n").map((l) => l.split("=")).filter((p) => p.length === 2));
    const ts = Number(map.ts);
    return { ip: map.ip ?? null, country: map.loc ?? null, colo: map.colo ?? null, serverTs: Number.isFinite(ts) ? ts * 1000 : null };
  }
  if (echo.parse === "ipwho") {
    return { ip: raw.ip ?? null, country: raw.country_code ?? null, city: raw.city ?? null };
  }
  if (echo.parse === "ipinfo") {
    return { ip: raw.ip ?? null, country: raw.country ?? null, city: raw.city ?? null };
  }
  return { ip: isIp(raw) ? raw.trim() : null };
}

/** 多源情报：国家 / 城市 / 时区 / ASN。任一源失败不影响其它源。 */
async function collectIntel(ip, timeoutMs) {
  const sources = [];
  const push = (source, data) => {
    if (data) sources.push({ source, ...data });
  };

  const [ipinfo, ipwho, ipapi] = (
    await Promise.all([
      fetchWithTimeout(`https://ipinfo.io/${ip}/json`, timeoutMs, { as: "json" }),
      fetchWithTimeout(`https://ipwho.is/${ip}`, timeoutMs, { as: "json" }),
      fetchWithTimeout(`https://api.ipapi.is/?q=${ip}`, timeoutMs, { as: "json" }),
    ])
  ).map((r) => r?.body ?? null);

  if (ipinfo && !ipinfo.bogon) {
    push("ipinfo.io", {
      country: ipinfo.country ?? null,
      region: ipinfo.region ?? null,
      city: ipinfo.city ?? null,
      timezone: ipinfo.timezone ?? null,
      asn: ipinfo.org ? String(ipinfo.org).split(" ")[0] : null,
      org: ipinfo.org ? String(ipinfo.org).split(" ").slice(1).join(" ") : null,
      hostname: ipinfo.hostname ?? null,
    });
  }
  if (ipwho && ipwho.success !== false) {
    push("ipwho.is", {
      country: ipwho.country_code ?? null,
      region: ipwho.region ?? null,
      city: ipwho.city ?? null,
      timezone: ipwho.timezone?.id ?? null,
      asn: ipwho.connection?.asn ? `AS${ipwho.connection.asn}` : null,
      org: ipwho.connection?.org ?? null,
      isp: ipwho.connection?.isp ?? null,
      hostname: null,
    });
  }
  if (ipapi && !ipapi.error && ipapi.ip) {
    push("ipapi.is", {
      country: ipapi.location?.country_code ?? ipapi.country_code ?? countryCodeFromName(ipapi.country) ?? null,
      region: ipapi.location?.state ?? ipapi.region ?? null,
      city: ipapi.location?.city ?? ipapi.city ?? null,
      timezone: ipapi.location?.timezone ?? ipapi.timezone ?? null,
      asn: ipapi.asn?.asn ? `AS${ipapi.asn.asn}` : ipapi.asn ? String(ipapi.asn).split(" ")[0] : null,
      org: ipapi.company?.name ?? (typeof ipapi.company === "string" ? ipapi.company : null),
      isp: ipapi.asn?.org ?? null,
      hostname: null,
      // ipapi.is 免费层偶尔会带这些布尔标记，有就用
      flags: {
        datacenter: ipapi.is_datacenter ?? null,
        vpn: ipapi.is_vpn ?? null,
        proxy: ipapi.is_proxy ?? null,
        tor: ipapi.is_tor ?? null,
      },
    });
  }

  return sources;
}

export function mergeIntel(sources, ip) {
  const first = (key) => sources.find((s) => s[key])?.[key] ?? null;
  const countries = [...new Set(sources.map((s) => s.country).filter(Boolean))];
  const asns = [...new Set(sources.map((s) => s.asn).filter(Boolean))];
  const timezones = [...new Set(sources.map((s) => s.timezone).filter(Boolean))];
  const flags = sources.find((s) => s.flags)?.flags ?? null;
  const merged = {
    ip,
    country: first("country"),
    region: first("region"),
    city: first("city"),
    timezone: first("timezone"),
    asn: first("asn"),
    org: first("org"),
    isp: first("isp"),
    hostname: first("hostname"),
    countries,
    asns,
    timezones,
    flags,
    sources: sources.map((s) => s.source),
  };
  merged.countryConsistent = countries.length <= 1;
  merged.asnConsistent = asns.length <= 1;
  merged.classification = classifyEgress({
    asn: merged.asn,
    name: merged.org,
    org: merged.org,
    isp: merged.isp,
    company: merged.org,
    hostname: merged.hostname,
    flags,
  });
  return merged;
}

/**
 * @param {{samples?:number, intervalMs?:number, timeoutMs?:number, onProgress?:(stage:string)=>void}} opts
 */
export async function collectEgress({ samples = 6, intervalMs = 350, timeoutMs = DEFAULT_TIMEOUT, onProgress = () => {} } = {}) {
  const started = Date.now();
  onProgress("sampling");

  // 1) 重复采样、2) 交叉回显、3) v6 探针 三路并行，互不依赖。
  const repeatedTask = (async () => {
    const out = [];
    for (let i = 0; i < samples; i += 1) {
      const r = await fetchWithTimeout(ECHOES[0].url, timeoutMs);
      if (r && isV4(r.body)) out.push(r.body.trim());
      if (i < samples - 1 && intervalMs > 0) await sleep(intervalMs);
    }
    return out;
  })();

  const crossedTask = Promise.all(
    ECHOES.slice(1).map(async (echo) => {
      const r = await fetchWithTimeout(echo.url, timeoutMs, { as: echo.as ?? "text" });
      const parsed = parseEcho(echo, r?.body) ?? { ip: null };
      return { echo: echo.id, ...parsed, rttMs: r?.rttMs ?? null, receivedAt: r?.receivedAt ?? null, dateHeader: r?.dateHeader ?? null };
    }),
  );

  const v6Task = (async () => {
    const results = await Promise.all(V6_PROBES.map((u) => fetchWithTimeout(u, timeoutMs)));
    const hit = results.find((r) => r && isV6(r.body));
    return hit ? hit.body.trim() : null;
  })();

  const [repeated, crossed, v6Probe] = await Promise.all([repeatedTask, crossedTask, v6Task]);

  // v4 / v6 分桶
  const v4Obs = [];
  const v6Seen = new Set();
  for (const ip of repeated) v4Obs.push({ source: "ipify", ip });
  for (const c of crossed) {
    if (!c.ip) continue;
    if (isV4(c.ip)) v4Obs.push({ source: c.echo, ip: c.ip, country: c.country ?? null });
    else if (isV6(c.ip)) v6Seen.add(c.ip);
  }
  if (v6Probe) v6Seen.add(v6Probe);

  const byIp = new Map();
  for (const o of v4Obs) byIp.set(o.ip, (byIp.get(o.ip) ?? 0) + 1);
  const distinctIps = [...byIp.entries()].sort((a, b) => b[1] - a[1]).map(([ip, count]) => ({ ip, count }));
  const prefix24 = new Set(distinctIps.map((d) => d.ip.split(".").slice(0, 3).join(".")));
  const sampledDistinctCount = new Set(repeated).size;
  const primaryIp = distinctIps[0]?.ip ?? null;
  const v6 = v6Probe ?? [...v6Seen][0] ?? null;

  // 时钟偏差：以 cf-trace 的 ts 为准（毫秒级），退而用 Date 头（秒级）。
  const clock = (() => {
    const cf = crossed.find((c) => c.echo === "cf-trace" && c.serverTs && c.receivedAt);
    if (cf) return { source: "cf-trace ts", skewMs: cf.receivedAt - cf.rttMs / 2 - cf.serverTs, rttMs: cf.rttMs };
    const any = crossed.find((c) => c.dateHeader && c.receivedAt);
    if (any) {
      const t = Date.parse(any.dateHeader);
      if (Number.isFinite(t)) return { source: `${any.echo} Date 头`, skewMs: any.receivedAt - any.rttMs / 2 - t, rttMs: any.rttMs, coarse: true };
    }
    return null;
  })();

  onProgress("intel");
  const [sources, v6Sources] = await Promise.all([
    primaryIp ? collectIntel(primaryIp, timeoutMs) : [],
    v6 ? collectIntel(v6, timeoutMs) : [],
  ]);
  const primary = primaryIp ? mergeIntel(sources, primaryIp) : null;
  const v6Intel = v6 ? mergeIntel(v6Sources, v6) : null;

  // 交叉回显看到的 v4 与主采样不同 -> 说明分流/负载
  const crossSeen = new Set(crossed.map((c) => c.ip).filter(isV4));
  const crossDiffers = crossSeen.size > 0 && primaryIp ? [...crossSeen].some((ip) => ip !== primaryIp) : false;

  return {
    ok: Boolean(primaryIp),
    primary,
    distinctIps,
    distinctCount: distinctIps.length,
    sampledDistinctCount,
    samePrefix: prefix24.size <= 1,
    sampleCount: repeated.length,
    crossEchoes: crossed.map(({ echo, ip, country }) => ({ echo, ip, country: country ?? null })),
    crossDiffers,
    v6,
    v6Intel,
    v6ViaDualStackEcho: v6Seen.size > 0 && !v6Probe,
    clock,
    durationMs: Date.now() - started,
    error: primaryIp ? null : "所有回显服务均不可达（可能离线或代理挡掉了）",
  };
}
