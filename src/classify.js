// 出口 IP / ASN 的类型归类。
//
// 免费情报源大多不给 is_datacenter 这类标记，所以这里用「已知 ASN 名单 + 组织名关键字 + rDNS 形态」
// 做启发式判断，并始终把命中依据一起输出，让人能自己判断结论是不是拍脑袋。宁可能见，不求准确率。

const HOSTING_ASNS = new Set([
  "AS36260", // Misaka Network
  "AS16509", "AS14618", // AWS
  "AS396982", "AS15169", // GCP / Google
  "AS8075", // Azure
  "AS14061", // DigitalOcean
  "AS20473", // Vultr / Choopa
  "AS63949", "AS48337", // Akamai / Linode
  "AS24940", "AS213230", // Hetzner
  "AS16276", // OVH
  "AS51167", // Contabo
  "AS45102", "AS37963", // Alibaba Cloud
  "AS132203", // Tencent Cloud
  "AS31898", // Oracle Cloud
  "AS9009", // M247
  "AS60781", // Leaseweb
  "AS200373", // Zenlayer
  "AS209854", // Kaopu
  "AS62240", // Clouvider
  "AS41378", // Kirino
  "AS6939", // Hurricane Electric
  "AS13335", // Cloudflare
  "AS54113", // Fastly
  "AS19551", // Incapsula
  "AS202425", // IP Volume
  "AS210644", // AEZA
  "AS49505", // Selectel
  "AS9123", // Timeweb
  "AS174", // Cogent
  "AS3356", // Lumen / Level3
  "AS212238", // Datacamp / CDN77
  "AS9370", // Sakura Internet
]);

const HOSTING_WORDS = [
  "hosting", "datacenter", "data center", "datacentre", "cloud", "vps",
  "server", "serverfarm", "colo", "colocation", "dedicated", "bare metal",
  "misaka", "digitalocean", "vultr", "linode", "hetzner", "ovh", "amazon",
  "aws", "google llc", "microsoft", "azure", "oracle", "contabo", "alibaba",
  "aliyun", "tencent", "zenlayer", "m247", "frantech", "buyvm", "upcloud",
  "scaleway", "equinix", "leaseweb", "choopa", "akamai", "fastly",
  "cloudflare", "kaopu", "cogent", "hurricane electric", "zayo", "gtt",
  "level3", "lumen", "transit", "backbone", "datacamp", "cdn77", "sakura internet",
];

const ISP_WORDS = [
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
];

function hits(haystack, words) {
  const found = [];
  for (const w of words) if (haystack.includes(w)) found.push(w);
  return { count: found.length, found };
}

/**
 * @param {{asn?:string|null, name?:string|null, org?:string|null, isp?:string|null, company?:string|null, hostname?:string|null, flags?:object|null}} input
 * @returns {{kind:'hosting'|'isp'|'unknown', basis:string[], confidence:'high'|'medium'|'low'}}
 */
export function classifyEgress(input) {
  const asn = (input.asn ?? "").toUpperCase();
  const asnShort = asn.split(" ")[0];
  const text = [input.name, input.org, input.isp, input.company]
    .filter(Boolean)
    .join(" ")
    .toLowerCase();

  const basis = [];
  let confidence = "low";
  let forced = null;

  const flags = input.flags ?? null;
  if (flags && (flags.datacenter === true || flags.vpn === true || flags.proxy === true || flags.tor === true)) {
    const on = Object.entries(flags).filter(([, v]) => v === true).map(([k]) => k);
    basis.push(`情报源标记：${on.join(", ")}`);
    confidence = "high";
    forced = "hosting";
  } else if (flags && flags.datacenter === false && flags.vpn === false && flags.proxy === false) {
    basis.push("情报源标记：非机房 / 非 VPN / 非代理");
  }

  if (asnShort && HOSTING_ASNS.has(asnShort)) {
    basis.push(`${asnShort} 在托管/云厂商 ASN 名单中`);
    confidence = "high";
    forced = "hosting";
  }

  const h = hits(text, HOSTING_WORDS);
  const i = hits(text, ISP_WORDS);
  if (h.count) basis.push(`组织名命中托管关键字：${h.found.slice(0, 4).join(", ")}`);
  if (i.count) basis.push(`组织名命中运营商关键字：${i.found.slice(0, 4).join(", ")}`);

  if (input.hostname) {
    // 反查域名若不是运营商的「客户段」命名（如 1-2-3-4.dynamic.isp.net）而是一个业务域名，
    // 通常意味着这是自建/共享中转而不是终端用户的拨号地址。
    const hst = String(input.hostname).toLowerCase();
    const looksDynamic = /(dynamic|dyn|dsl|ppp|pppoe|dhcp|broadband|bb\.|cust|client|pool|static|res\.|resi|home|user)/.test(hst);
    if (!looksDynamic && hst.includes(".")) {
      basis.push(`rDNS 为业务域名 ${hst}（非运营商动态地址命名）`);
      if (confidence === "low") confidence = "medium";
    } else if (looksDynamic) {
      basis.push(`rDNS 像运营商客户地址命名 ${hst}`);
    }
  }

  let kind = "unknown";
  if (forced) kind = forced;
  else if (h.count > i.count) kind = "hosting";
  else if (i.count > h.count) kind = "isp";
  // 托管词和运营商词打平（如 "Google Fiber"）：不硬判，交给人看依据。

  if (kind !== "unknown" && confidence === "low" && (h.count + i.count) >= 2) confidence = "medium";

  return { kind, basis: basis.length ? basis : ["无任何托管/运营商特征，无法判定"], confidence };
}

/** 把地区码转成展示用的名字。优先用 Intl，少数几个用更口语的叫法覆盖。 */
const REGION_OVERRIDES = { CN: "中国大陆", HK: "香港", MO: "澳门", TW: "台湾" };
let displayNames = null;
try {
  displayNames = new Intl.DisplayNames(["zh-CN"], { type: "region", fallback: "none" });
} catch {
  displayNames = null;
}
export function regionName(code) {
  const cc = String(code ?? "").toUpperCase();
  if (!cc) return "未知";
  if (REGION_OVERRIDES[cc]) return REGION_OVERRIDES[cc];
  try {
    return displayNames?.of(cc) ?? cc;
  } catch {
    return cc;
  }
}

/** 语言主标签 -> 常见使用地区，用于「语言地区 vs 出口国家」的弱校验。 */
export const LANG_HOME = {
  zh: new Set(["CN", "HK", "MO", "TW", "SG", "MY"]),
  en: new Set(["US", "GB", "CA", "AU", "NZ", "IE", "SG", "IN", "PH", "ZA", "HK", "MY"]),
  ja: new Set(["JP"]),
  ko: new Set(["KR"]),
  ru: new Set(["RU", "BY", "KZ"]),
  fa: new Set(["IR"]),
  de: new Set(["DE", "AT", "CH"]),
  fr: new Set(["FR", "CA", "BE", "CH"]),
  es: new Set(["ES", "MX", "AR", "CO", "CL", "PE"]),
  pt: new Set(["PT", "BR"]),
  it: new Set(["IT", "CH"]),
  nl: new Set(["NL", "BE"]),
  ar: new Set(["AE", "SA", "EG", "QA", "KW"]),
  th: new Set(["TH"]),
  vi: new Set(["VN"]),
  id: new Set(["ID"]),
  ms: new Set(["MY", "SG"]),
  tr: new Set(["TR"]),
};

/** 英文国家全名 -> ISO 代码（ipapi.is 免费层只给全名）。用 Intl 反查，避免手写名单。 */
let nameToCode = null;
export function countryCodeFromName(name) {
  if (!name) return null;
  const n = String(name).trim();
  if (/^[A-Za-z]{2}$/.test(n)) return n.toUpperCase();
  if (!nameToCode) {
    nameToCode = new Map();
    try {
      const dn = new Intl.DisplayNames(["en"], { type: "region", fallback: "none" });
      for (let a = 65; a <= 90; a += 1) {
        for (let b = 65; b <= 90; b += 1) {
          const code = String.fromCharCode(a, b);
          const label = dn.of(code);
          if (label) nameToCode.set(label.toLowerCase(), code);
        }
      }
      // 常见别名
      nameToCode.set("united states of america", "US");
      nameToCode.set("usa", "US");
      nameToCode.set("uk", "GB");
      nameToCode.set("russia", "RU");
      nameToCode.set("south korea", "KR");
      nameToCode.set("korea, republic of", "KR");
      nameToCode.set("taiwan", "TW");
      nameToCode.set("hong kong sar", "HK");
      nameToCode.set("hong kong", "HK");
      nameToCode.set("macau", "MO");
      nameToCode.set("macao", "MO");
      nameToCode.set("china", "CN");
      nameToCode.set("mainland china", "CN");
      nameToCode.set("vietnam", "VN");
      nameToCode.set("czech republic", "CZ");
      nameToCode.set("turkey", "TR");
      nameToCode.set("netherlands", "NL");
      nameToCode.set("the netherlands", "NL");
    } catch {
      /* 没有 Intl.DisplayNames 就只能放弃 */
    }
  }
  return nameToCode.get(n.toLowerCase()) ?? null;
}
