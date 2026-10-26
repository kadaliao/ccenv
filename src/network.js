// 出口层：真实公网 IP 采样 + 多源 IP/ASN 情报。
//
// 设计要点（和 check-cc 最大的区别）：
// 1. 一定落地真实的 IP 情报，不是写死 enabled:false 的空壳；
// 2. 用多个互相独立的回显服务交叉验证，能发现"同一时刻不同目的地走不同出口"这种分流；
// 3. 采样多次，能发现出口 IP 在抖动（这是 check-cc 完全没做的）。

import { classifyEgress } from "./classify.js";

const DEFAULT_TIMEOUT = 8000;

async function fetchWithTimeout(url, timeoutMs, { as = "text" } = {}) {
  const ctrl = new AbortController();
  const timer = setTimeout(() => ctrl.abort(), timeoutMs);
  try {
    const res = await fetch(url, {
      signal: ctrl.signal,
      headers: { "user-agent": "ccenv/0.1 (+local consistency check)" },
    });
    if (!res.ok) return null;
    return as === "json" ? await res.json() : (await res.text()).trim();
  } catch {
    return null;
  } finally {
    clearTimeout(timer);
  }
}

const isIp = (s) => typeof s === "string" && /^(\d{1,3}\.){3}\d{1,3}$/.test(s.trim()) || (typeof s === "string" && /^[0-9a-f:]+$/i.test(s.trim()) && s.includes(":"));

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

/** 独立回显服务。刻意分开 v4 / 通用，方便判断 IPv6 是否直连出去。 */
const ECHOES = [
  { id: "ipify", url: "https://api.ipify.org" },
  { id: "cf-trace", url: "https://www.cloudflare.com/cdn-cgi/trace", parse: "trace" },
  { id: "ipwho", url: "https://ipwho.is/", as: "json", parse: "ipwho" },
  { id: "ipinfo", url: "https://ipinfo.io/json", as: "json", parse: "ipinfo" },
];

function parseEcho(echo, raw) {
  if (!raw) return null;
  if (echo.parse === "trace") {
    if (typeof raw !== "string") return null;
    const map = Object.fromEntries(raw.split("\n").map((l) => l.split("=")).filter((p) => p.length === 2));
    return { ip: map.ip ?? null, country: map.loc ?? null, colo: map.colo ?? null };
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

  const [ipinfo, ipwho, ipapi] = await Promise.all([
    fetchWithTimeout(`https://ipinfo.io/${ip}/json`, timeoutMs, { as: "json" }),
    fetchWithTimeout(`https://ipwho.is/${ip}`, timeoutMs, { as: "json" }),
    fetchWithTimeout(`https://api.ipapi.is/?q=${ip}`, timeoutMs, { as: "json" }),
  ]);

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
      country: ipapi.country_code ?? null,
      region: ipapi.region ?? null,
      city: ipapi.city ?? null,
      timezone: ipapi.timezone ?? null,
      asn: ipapi.asn ? String(ipapi.asn).split(" ")[0] : null,
      org: ipapi.company ?? null,
      isp: ipapi.asn ? String(ipapi.asn).split(" ").slice(1).join(" ") : null,
      hostname: null,
    });
  }

  return sources;
}

function mergeIntel(sources, ip) {
  const first = (key) => sources.find((s) => s[key])?.[key] ?? null;
  const countries = [...new Set(sources.map((s) => s.country).filter(Boolean))];
  const asns = [...new Set(sources.map((s) => s.asn).filter(Boolean))];
  const timezones = [...new Set(sources.map((s) => s.timezone).filter(Boolean))];
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
  });
  return merged;
}

/**
 * @param {{samples?:number, intervalMs?:number, timeoutMs?:number}} opts
 */
export async function collectEgress({ samples = 6, intervalMs = 350, timeoutMs = DEFAULT_TIMEOUT } = {}) {
  const observations = [];

  // 1) 同一个回显服务重复采样，看出口是否漂移
  const repeated = [];
  for (let i = 0; i < samples; i += 1) {
    const raw = await fetchWithTimeout(ECHOES[0].url, timeoutMs);
    if (raw && isIp(raw)) repeated.push(raw.trim());
    if (i < samples - 1 && intervalMs > 0) await sleep(intervalMs);
  }

  // 2) 其它独立回显服务各打一次，看不同目的地是否走不同出口
  const crossed = await Promise.all(
    ECHOES.slice(1).map(async (echo) => {
      const raw = await fetchWithTimeout(echo.url, timeoutMs, { as: echo.as ?? "text" });
      return { echo: echo.id, ...(parseEcho(echo, raw) ?? { ip: null }) };
    }),
  );

  for (const ip of repeated) observations.push({ source: "ipify", ip });
  for (const c of crossed) if (c.ip) observations.push({ source: c.echo, ip: c.ip, country: c.country ?? null });

  const byIp = new Map();
  for (const o of observations) byIp.set(o.ip, (byIp.get(o.ip) ?? 0) + 1);
  const distinctIps = [...byIp.entries()].sort((a, b) => b[1] - a[1]).map(([ip, count]) => ({ ip, count }));
  const prefix24 = new Set(distinctIps.map((d) => d.ip.split(".").slice(0, 3).join(".")));
  const sampledDistinctCount = new Set(repeated).size;

  // 3) IPv6 是否独立直连出去（v6 泄漏最容易被忽略）
  const v6Raw = await fetchWithTimeout("https://v6.ipinfo.io/ip", timeoutMs);
  const v6 = v6Raw && v6Raw.includes(":") ? v6Raw.trim() : null;
  let v6Intel = null;
  if (v6) {
    const sources = await collectIntel(v6, timeoutMs);
    v6Intel = mergeIntel(sources, v6);
  }

  const primaryIp = distinctIps[0]?.ip ?? null;
  const sources = primaryIp ? await collectIntel(primaryIp, timeoutMs) : [];
  const primary = primaryIp ? mergeIntel(sources, primaryIp) : null;

  // 交叉回显看到的 IP 与主采样不同 -> 说明分流/负载
  const crossSeen = new Set(crossed.map((c) => c.ip).filter(Boolean));
  const crossDiffers = crossSeen.size > 0 && primaryIp ? [...crossSeen].some((ip) => ip !== primaryIp) : false;

  return {
    ok: Boolean(primaryIp),
    primary,
    distinctIps,
    distinctCount: distinctIps.length,
    sampledDistinctCount,
    samePrefix: prefix24.size <= 1,
    sampleCount: repeated.length,
    crossEchoes: crossed,
    crossDiffers,
    v6,
    v6Intel,
    error: primaryIp ? null : "所有回显服务均不可达（可能离线或代理挡掉了）",
  };
}
