// 出口 IP / ASN 的类型归类。
//
// 说明：ipapi.is 免费层不返回 is_datacenter/is_vpn 字段，ipinfo 免费层也不返回 privacy 分类，
// 所以这里用「已知 ASN 名单 + 组织名关键字」做启发式判断，并始终把命中依据一起输出，
// 让人能自己判断结论是不是拍脑袋。宁可能见，不求准确率。

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
]);

const HOSTING_WORDS = [
  "hosting", "host", "datacenter", "data center", "datacentre", "cloud", "vps",
  "server", "serverfarm", "colo", "colocation", "dedicated", "bare metal",
  "misaka", "digitalocean", "vultr", "linode", "hetzner", "ovh", "amazon",
  "aws", "google", "microsoft", "azure", "oracle", "contabo", "alibaba",
  "aliyun", "tencent", "zenlayer", "m247", "frantech", "buyvm", "upcloud",
  "scaleway", "equinix", "leaseweb", "choopa", "akamai", "fastly",
  "cloudflare", "kaopu", "cogent", "hurricane electric", "zayo", "gtt",
  "level3", "lumen", "transit", "backbone",
];

const ISP_WORDS = [
  "broadband", "telecom", "telecommunication", "communications", "cable",
  "fiber", "fibre", "mobile", "wireless", "cellular", "internet service",
  "telco", "comcast", "verizon", "at&t", "deutsche telekom", "vodafone",
  "singtel", "starhub", "softbank", "kddi", "docomo", "china mobile",
  "china unicom", "china telecom", "chunghwa", "hkt", "pccw",
  "sk broadband", "jio", "airtel", "rogers", "telstra", "optus", "vocus",
  "proximus", "kpn", "ziggo", "telenet", "swisscom", "telefonica",
  "virgin media", "talktalk", "elisa", "telenor", "hotwire", "sonic",
];

function hits(haystack, words) {
  const found = [];
  for (const w of words) if (haystack.includes(w)) found.push(w);
  return { count: found.length, found };
}

/**
 * @param {{asn?:string|null, name?:string|null, org?:string|null, isp?:string|null, company?:string|null, hostname?:string|null}} input
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

  if (asnShort && HOSTING_ASNS.has(asnShort)) {
    basis.push(`${asnShort} 在托管/云厂商 ASN 名单中`);
    confidence = "high";
  }

  const h = hits(text, HOSTING_WORDS);
  const i = hits(text, ISP_WORDS);
  if (h.count) basis.push(`组织名命中托管关键字：${h.found.slice(0, 4).join(", ")}`);
  if (i.count) basis.push(`组织名命中运营商关键字：${i.found.slice(0, 4).join(", ")}`);

  if (input.hostname) {
    // 反查域名本身不是 ISP 的 "客户段" 命名（如 1-2-3-4.dynamic.isp.net）而是一个业务域名，
    // 通常意味着这是自建/共享中转而不是终端用户的拨号地址。
    const hst = String(input.hostname).toLowerCase();
    const looksDynamic = /(dynamic|dsl|ppp|dhcp|broadband|cust|client|pool|static)/.test(hst);
    if (!looksDynamic && hst.includes(".")) {
      basis.push(`rDNS 为业务域名 ${hst}（非运营商动态地址命名）`);
      if (confidence === "low") confidence = "medium";
    } else if (looksDynamic) {
      basis.push(`rDNS 像运营商动态地址命名 ${hst}`);
    }
  }

  let kind = "unknown";
  if (confidence === "high" || h.count > i.count) kind = "hosting";
  else if (i.count > h.count) kind = "isp";
  else if (h.count > 0 && i.count > 0) kind = "hosting";
  else if (h.count > 0) kind = "hosting";
  else if (i.count > 0) kind = "isp";

  return { kind, basis: basis.length ? basis : ["无任何托管/运营商特征，无法判定"], confidence };
}

/** 把地区码转成展示用的名字，避免输出里全是两位字母。 */
const REGION_NAMES = {
  CN: "中国大陆", HK: "香港", MO: "澳门", TW: "台湾", SG: "新加坡", MY: "马来西亚",
  JP: "日本", KR: "韩国", US: "美国", CA: "加拿大", GB: "英国", DE: "德国",
  FR: "法国", NL: "荷兰", RU: "俄罗斯", IR: "伊朗", AU: "澳大利亚", IN: "印度",
  BR: "巴西", TR: "土耳其", AE: "阿联酋", TH: "泰国", VN: "越南", PH: "菲律宾",
  ID: "印尼", NZ: "新西兰", CH: "瑞士", SE: "瑞典", ES: "西班牙", IT: "意大利",
};
export const regionName = (code) => REGION_NAMES[String(code ?? "").toUpperCase()] ?? (code || "未知");

/** 语言主标签 -> 常见使用地区，用于「语言地区 vs 出口国家」的弱校验。 */
export const LANG_HOME = {
  zh: new Set(["CN", "HK", "MO", "TW", "SG", "MY"]),
  ja: new Set(["JP"]),
  ko: new Set(["KR"]),
  ru: new Set(["RU", "BY", "KZ"]),
  fa: new Set(["IR"]),
  de: new Set(["DE", "AT", "CH"]),
  fr: new Set(["FR", "CA", "BE", "CH"]),
  es: new Set(["ES", "MX", "AR", "CO", "CL", "PE"]),
  pt: new Set(["PT", "BR"]),
};
