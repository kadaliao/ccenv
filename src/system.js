// 系统层事实采集：时区、区域/语言、运行时、代理链路、DNS。
// 只读，不改任何设置。

import { execFileSync } from "node:child_process";
import { readlinkSync } from "node:fs";
import os from "node:os";

function run(cmd, args, timeout = 5000) {
  try {
    return execFileSync(cmd, args, {
      encoding: "utf8",
      timeout,
      stdio: ["ignore", "pipe", "ignore"],
      maxBuffer: 1 << 20,
    }).trim();
  } catch {
    return null;
  }
}

/** 任意 IANA 时区在当前时刻的 UTC 偏移（分钟，东正）。用 Intl 计算，天然处理夏令时。 */
export function offsetMinutesFor(tz, at = new Date()) {
  if (!tz) return null;
  try {
    const parts = new Intl.DateTimeFormat("en-US", {
      timeZone: tz,
      timeZoneName: "longOffset",
    }).formatToParts(at);
    const raw = parts.find((p) => p.type === "timeZoneName")?.value ?? "";
    const m = /^GMT([+-])(\d{2}):?(\d{2})?$/.exec(raw);
    if (!m) return raw === "GMT" ? 0 : null;
    const sign = m[1] === "-" ? -1 : 1;
    return sign * (Number(m[2]) * 60 + Number(m[3] ?? 0));
  } catch {
    return null;
  }
}

export function formatOffset(minutes) {
  if (minutes == null) return "未知";
  const sign = minutes < 0 ? "-" : "+";
  const abs = Math.abs(minutes);
  return `UTC${sign}${String(Math.floor(abs / 60)).padStart(2, "0")}:${String(abs % 60).padStart(2, "0")}`;
}

/** /etc/localtime -> /var/db/timezone/zoneinfo/Asia/Singapore */
function tzFromLocaltime() {
  try {
    const target = readlinkSync("/etc/localtime");
    const idx = target.indexOf("zoneinfo/");
    return idx >= 0 ? target.slice(idx + "zoneinfo/".length) : null;
  } catch {
    return null;
  }
}

/** zh_SG / en_US.UTF-8 / zh-Hans-SG -> { language, script, region, raw } */
export function parseLocaleTag(raw) {
  if (!raw) return null;
  const cleaned = String(raw)
    .replace(/\.(UTF-8|utf8|UTF8|ISO8859-\d+)$/i, "")
    .replace(/@.*$/, "")
    .replace(/_/g, "-");
  const parts = cleaned.split("-").filter(Boolean);
  const language = (parts[0] ?? "").toLowerCase() || null;
  let script = null;
  let region = null;
  for (const p of parts.slice(1)) {
    if (/^[A-Za-z]{4}$/.test(p)) script = p.toLowerCase();
    else if (/^[A-Za-z]{2}$|^\d{3}$/.test(p)) region = p.toUpperCase();
  }
  return { language, script, region, raw: String(raw) };
}

/**
 * 私有 / 保留 / 本机地址。用于判断「DNS 解析器是不是本机或代理内置」。
 * 注意 100.x 只有 100.64.0.0/10（CGNAT，Tailscale 也用它）是保留段，100.0.0.0/8 其余是公网。
 * 198.18.0.0/15 是基准测试保留段，代理 fake-ip 模式几乎都用它。
 */
export function isPrivateAddr(ip) {
  const s = String(ip ?? "").trim();
  if (!s) return false;
  if (s.includes(":")) return /^(::1$|::$|fe80:|f[cd][0-9a-f]{2}:)/i.test(s);
  const p = s.split(".").map(Number);
  if (p.length !== 4 || p.some((n) => !Number.isInteger(n) || n < 0 || n > 255)) return false;
  return (
    p[0] === 0 ||
    p[0] === 10 ||
    p[0] === 127 ||
    (p[0] === 100 && p[1] >= 64 && p[1] <= 127) ||
    (p[0] === 169 && p[1] === 254) ||
    (p[0] === 172 && p[1] >= 16 && p[1] <= 31) ||
    (p[0] === 192 && p[1] === 168) ||
    (p[0] === 198 && (p[1] === 18 || p[1] === 19))
  );
}

/** 解析 `scutil --proxy` 的字典输出。 */
export function parseScutilProxy(out) {
  if (!out) return { available: false };
  // 每行 "Key : Value"；嵌套数组成员形如 "0 : 127.0.0.1"。按行取键值对即可。
  const entries = new Map();
  for (const line of out.split("\n")) {
    const m = /^\s*([A-Za-z][\w]*)\s*:\s*(\S+)\s*$/.exec(line);
    if (m) entries.set(m[1], m[2]);
  }
  const enabled = (key) => entries.get(key) === "1";
  return {
    available: true,
    http: enabled("HTTPEnable"),
    https: enabled("HTTPSEnable"),
    socks: enabled("SOCKSEnable"),
    pac: enabled("ProxyAutoConfigEnable"),
  };
}

const PROXY_APPS = [
  "mihomo", "clash", "clashx", "clash-verge", "verge-mihomo", "sing-box",
  "v2ray", "xray", "v2rayu", "surge", "shadowrocket", "tun2socks",
  "wireguard-go", "openvpn", "tailscaled", "warp-svc", "trojan", "hysteria",
  "naive", "brook", "leaf", "stash", "loon", "quantumult",
];

/** 从 `ps -axo comm=` 的输出里挑出已知代理/隧道进程名。 */
export function matchProxyApps(psOutput) {
  if (!psOutput) return [];
  const found = new Set();
  for (const line of psOutput.split("\n")) {
    const base = line.trim().split("/").pop()?.toLowerCase();
    if (!base) continue;
    for (const app of PROXY_APPS) {
      // 精确匹配，或「名字 + 非字母后缀」（mihomo-core / clashx meta / sing-box.1），避免 surge 误伤 surgeon
      if (base === app || base === `${app}d` || (base.startsWith(app) && /^[^a-z]/.test(base.slice(app.length)))) {
        found.add(base);
      }
    }
  }
  return [...found];
}

/**
 * 解析 `ifconfig` 全量输出，返回每个接口的地址。
 * 关键点：macOS 自带 utun0~utun3（iCloud 私密中继等），它们只有 fe80 链路本地地址，
 * 不能当成代理/VPN 隧道；只有拿到了 inet 或全局 inet6 地址的 tun 才算真在用。
 */
export function parseIfconfig(out) {
  const ifaces = [];
  let current = null;
  for (const raw of (out ?? "").split("\n")) {
    const head = /^([a-z][\w.-]*\d*):\s+flags=/.exec(raw);
    if (head) {
      current = { name: head[1], inet: [], inet6: [] };
      ifaces.push(current);
      continue;
    }
    if (!current) continue;
    const line = raw.trim();
    const v4 = /^inet\s+(\d+\.\d+\.\d+\.\d+)/.exec(line);
    if (v4) {
      current.inet.push(v4[1]);
      continue;
    }
    const v6 = /^inet6\s+([0-9a-f:]+)(%\w+)?/i.exec(line);
    if (v6 && !/^fe80:/i.test(v6[1])) current.inet6.push(v6[1]);
  }
  return ifaces;
}

/** 有实际地址的隧道接口。 */
export function activeTunnels(ifaces) {
  return ifaces
    .filter((i) => /^(utun|tun|tap|wg|ppp|ipsec)\d*$/.test(i.name))
    .filter((i) => i.inet.length || i.inet6.length)
    .map((i) => ({ name: i.name, addrs: [...i.inet, ...i.inet6] }));
}

/**
 * 解析 `scutil --dns`。
 * 输出有两段：第一段「DNS configuration」是默认解析路径，第二段「(for scoped queries)」是按接口限定的。
 * 区分这两段很关键：公司内网按域名/接口指定 DNS 是正常配置，当成泄漏就是误报。
 */
export function parseScutilDns(out) {
  const empty = { all: [], defaults: [], perDomain: [], scoped: [] };
  if (!out) return empty;

  const blocks = [];
  let current = null;
  let section = "default";
  for (const raw of out.split("\n")) {
    const line = raw.trim();
    if (/^DNS configuration/.test(line)) {
      section = /scoped queries/i.test(line) ? "scoped" : "default";
      current = null;
      continue;
    }
    const header = /^resolver #(\d+)/.exec(line);
    if (header) {
      current = { index: Number(header[1]), section, nameservers: [], domains: [], searchDomains: [], ifIndex: null, ifName: null };
      blocks.push(current);
      continue;
    }
    if (!current) continue;

    const ns = /^nameserver\[\d+\]\s*:\s*(\S+)/.exec(line);
    if (ns) {
      current.nameservers.push(ns[1]);
      continue;
    }
    const domain = /^domain\s*:\s*(\S+)/.exec(line);
    if (domain) {
      current.domains.push(domain[1]);
      continue;
    }
    const search = /^search domain\[\d+\]\s*:\s*(\S+)/.exec(line);
    if (search) {
      current.searchDomains.push(search[1]);
      continue;
    }
    const ifIndex = /^if_index\s*:\s*(\d+)\s*(?:\(([\w.]+)\))?/.exec(line);
    if (ifIndex) {
      current.ifIndex = Number(ifIndex[1]);
      current.ifName = ifIndex[2] ?? null;
    }
  }

  const all = [...new Set(blocks.flatMap((b) => b.nameservers))];

  // 默认路径 = 第一段里没有 domain 限定的块（search domain 只管短名补全，不限制路由）
  const defaultBlocks = blocks.filter((b) => b.section === "default" && b.domains.length === 0 && b.nameservers.length);
  const defaults = [...new Set(defaultBlocks.flatMap((b) => b.nameservers))];

  // 第一段里按域名指定具体解析器的（如 youtu.be -> 127.0.0.1）
  const perDomain = blocks
    .filter((b) => b.section === "default" && b.domains.length && b.nameservers.length)
    .map((b) => ({ domain: b.domains[0], nameservers: b.nameservers }));

  // 第二段：接口级限定解析器
  const scopedMap = new Map();
  for (const b of blocks.filter((x) => x.section === "scoped" && x.nameservers.length)) {
    const key = b.ifIndex ?? "未知接口";
    if (!scopedMap.has(key)) scopedMap.set(key, { ifIndex: b.ifIndex, ifName: b.ifName, domains: [], nameservers: new Set() });
    const entry = scopedMap.get(key);
    for (const d of [...b.domains, ...b.searchDomains]) if (!entry.domains.includes(d)) entry.domains.push(d);
    for (const ns of b.nameservers) entry.nameservers.add(ns);
  }
  const scoped = [...scopedMap.values()].map((v) => ({ ...v, nameservers: [...v.nameservers] }));

  return { all, defaults, perDomain, scoped };
}

export function collectSystem() {
  const isMac = process.platform === "darwin";

  const tzIntl = (() => {
    try {
      return Intl.DateTimeFormat().resolvedOptions().timeZone ?? null;
    } catch {
      return null;
    }
  })();
  const tzLink = tzFromLocaltime();
  const tzEnv = process.env.TZ ?? null;
  const localOffset = -new Date().getTimezoneOffset();

  const appleLocaleRaw = isMac ? run("defaults", ["read", "-g", "AppleLocale"]) : null;
  const appleLanguagesRaw = isMac ? run("defaults", ["read", "-g", "AppleLanguages"]) : null;
  const appleLanguages = appleLanguagesRaw
    ? [...appleLanguagesRaw.matchAll(/"([^"]+)"/g)].map((m) => m[1])
    : [];

  const langEnv = process.env.LC_ALL || process.env.LC_MESSAGES || process.env.LANG || null;

  // os.arch() 在 Rosetta 下和 process.arch 一样返回 x64，拿不到真实机器架构，得问内核。
  const machineArch = isMac
    ? run("sysctl", ["-n", "hw.optional.arm64"]) === "1" ? "arm64" : "x64"
    : os.arch();

  const hardware = {
    os: isMac ? `${run("sw_vers", ["-productName"]) ?? "macOS"} ${run("sw_vers", ["-productVersion"]) ?? ""}`.trim() : `${os.type()} ${os.release()}`,
    model: isMac ? run("sysctl", ["-n", "hw.model"]) : null,
    chip: isMac ? run("sysctl", ["-n", "machdep.cpu.brand_string"]) : os.cpus()?.[0]?.model ?? null,
    arch: process.arch,
    machineArch,
    rosetta: isMac ? run("sysctl", ["-n", "sysctl.proc_translated"]) === "1" : false,
  };

  const runtime = {
    node: process.version,
    term: process.env.TERM_PROGRAM || process.env.TERM || null,
    shell: process.env.SHELL ? process.env.SHELL.split("/").pop() : null,
  };

  const proxy = parseScutilProxy(isMac ? run("scutil", ["--proxy"]) : null);
  const envProxy = ["HTTPS_PROXY", "https_proxy", "HTTP_PROXY", "http_proxy", "ALL_PROXY", "all_proxy"]
    .filter((k) => process.env[k])
    .map((k) => `${k}=${process.env[k]}`);
  const apps = matchProxyApps(run("ps", ["-axo", "comm="], 6000));
  const tunnels = activeTunnels(parseIfconfig(run("ifconfig", [])));
  const dns = parseScutilDns(isMac ? run("scutil", ["--dns"]) : null);

  return {
    collectedAt: new Date().toISOString(),
    timezone: {
      intl: tzIntl,
      localtimeLink: tzLink,
      env: tzEnv,
      offsetMinutes: localOffset,
      offsetLabel: formatOffset(localOffset),
      consistent: new Set([tzIntl, tzLink, tzEnv].filter(Boolean)).size <= 1,
    },
    locale: {
      appleLocale: appleLocaleRaw,
      appleLanguages,
      envRaw: langEnv,
      env: parseLocaleTag(langEnv),
      // 系统首选语言优先取 AppleLanguages[0]，其次 shell 的 LANG
      primary: parseLocaleTag(appleLanguages[0] ?? langEnv),
      apple: parseLocaleTag(appleLocaleRaw),
    },
    hardware,
    runtime,
    proxy: {
      system: proxy,
      env: envProxy,
      apps,
      tun: tunnels.map((t) => t.name),
      tunnels,
      active: apps.length > 0 || tunnels.length > 0 || proxy.https === true || proxy.http === true || proxy.socks === true || envProxy.length > 0,
    },
    dns: {
      resolvers: dns.all,
      defaults: dns.defaults,
      perDomain: dns.perDomain,
      scoped: dns.scoped,
      allThroughProxy: dns.defaults.length > 0 && dns.defaults.every(isPrivateAddr),
    },
  };
}
