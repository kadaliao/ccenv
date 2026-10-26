// 规则层：跨层找矛盾，而不是把「像哪个国家」的分数相加。
//
// 两条设计纪律：
// 1. 一个规则只对应一个底层事实。出口 IP 抖动这件事只由 ip-stability 一条规则报告，
//    不拆成「采样抖动」+「多源分歧」两条各自加分——那就是重复计权。
// 2. 规则只输出离散等级（high/medium/low/ok/info），不做任意权重累加。
//    结论取最高等级，而不是求和后拿一个拍出来的阈值去切。

import { offsetMinutesFor, formatOffset, isPrivateAddr } from "./system.js";
import { regionName, LANG_HOME } from "./classify.js";

export const LEVELS = ["high", "medium", "low", "info", "ok"];
export const LEVEL_RANK = { high: 0, medium: 1, low: 2, info: 3, ok: 4 };

const ok = (summary, extra = {}) => ({ level: "ok", summary, ...extra });
const info = (summary, extra = {}) => ({ level: "info", summary, ...extra });
const skip = (summary) => ({ level: "info", skipped: true, summary });

const circularMinutes = (a, b) => {
  const d = Math.abs(a - b) % 1440;
  return d > 720 ? 1440 - d : d;
};

export const RULES = [
  {
    id: "egress-timezone",
    group: "consistency",
    title: "出口时区 ↔ 系统时区",
    evaluate(ctx) {
      const geo = ctx.egress?.primary;
      const sys = ctx.system.timezone;
      if (!geo?.timezone) return skip("未取得出口 IP 的归属时区（离线或情报源全失败）");
      const geoOffset = offsetMinutesFor(geo.timezone);
      if (geoOffset == null) return skip(`无法解析出口时区 ${geo.timezone}`);
      const delta = circularMinutes(geoOffset, sys.offsetMinutes);
      const evidence = [
        ["出口时区", `${geo.timezone} (${formatOffset(geoOffset)})`],
        ["系统时区", `${sys.intl ?? "未知"} (${sys.offsetLabel})`],
        ["相差", `${Math.floor(delta / 60)} 小时 ${delta % 60} 分`],
      ];
      if (delta === 0) return ok("出口与系统时区一致", { evidence });
      if (delta <= 60) return { level: "low", summary: "出口与系统时区相差 1 小时以内（夏令时/邻国边界常见）", evidence };
      if (delta <= 300) return { level: "medium", summary: "出口与系统时区相差 1~5 小时", evidence };
      return { level: "high", summary: "出口与系统时区相差超过 5 小时，是最典型的「IP 画像 ≠ 设备画像」", evidence };
    },
    impact:
      "这是风控里最廉价、被判得最广的一组信号：同一个会话里 IP 在一个时区、设备时钟在另一个时区。" +
      "它本身不能证明任何事（跨国办公、公司共享出口都很常见），但和 IP 类型、IP 稳定性叠加时权重很高。",
    fix: [
      "让出口和系统时区对齐：要么把系统时区改成出口所在地（macOS: 系统设置 › 通用 › 日期与时间，或 sudo systemsetup -settimezone <Area/City>）",
      "要么把出口固定到系统时区所在的地区，并长期不再变",
    ],
  },

  {
    id: "egress-locale",
    group: "consistency",
    title: "出口国家 ↔ 系统区域/语言",
    evaluate(ctx) {
      const geo = ctx.egress?.primary;
      if (!geo?.country) return skip("未取得出口国家（离线或情报源全失败）");
      const loc = ctx.system.locale;
      const lang = loc.primary?.language ?? null;
      const localeRegion = loc.apple?.region ?? loc.primary?.region ?? null;
      const home = lang ? LANG_HOME[lang] : null;
      const evidence = [
        ["出口国家", `${regionName(geo.country)} (${geo.country})`],
        ["系统首选语言", loc.primary?.raw ?? "未知"],
        ["系统区域", loc.apple?.raw ?? localeRegion ?? "未知"],
      ];
      if (localeRegion === geo.country) return ok("系统区域与出口国家一致", { evidence });
      if (home?.has(geo.country)) {
        evidence.push(["说明", `${lang} 在 ${regionName(geo.country)} 也是常用语言，仅区域子标签不同`]);
        return { level: "low", summary: "语言与出口国家相容，仅区域设置不同", evidence };
      }
      return {
        level: "medium",
        summary: `系统区域是 ${localeRegion ? regionName(localeRegion) : "未知"}，出口在 ${regionName(geo.country)}`,
        evidence,
      };
    },
    impact:
      "第二层交叉校验。单独看几乎没有证明力（很多人系统语言和居住国并不一致），" +
      "它的作用是和 egress-timezone 一起构成「多条独立线索同时偏向另一个地区」的累积证据。",
    fix: ["如果希望画像统一，把系统区域设置为出口所在国家；不想改就把它当作已知的弱偏差，不必当成问题"],
  },

  {
    id: "ip-kind",
    group: "profile",
    title: "出口 IP 类型（住宅/运营商 vs 机房/托管）",
    evaluate(ctx) {
      const geo = ctx.egress?.primary;
      if (!geo?.asn) return skip("未取得 ASN 情报");
      const c = geo.classification;
      const evidence = [
        ["ASN", `${geo.asn} ${geo.isp ?? geo.org ?? ""}`.trim()],
        ["主机名", geo.hostname ?? "无 rDNS"],
        ["判定依据", c.basis.join("；")],
        ["情报源", geo.sources.join(", ")],
      ];
      if (c.kind === "isp") return ok("出口属于运营商/宽带段", { evidence });
      if (c.kind === "unknown") {
        return { level: "low", summary: "无法归类出口类型，按可疑处理前请人工确认", evidence };
      }
      return {
        level: "high",
        summary: `出口属于机房/托管/代理段（${c.confidence === "high" ? "高" : "中"}置信）`,
        evidence,
      };
    },
    impact:
      "比语言、字体重要一个量级。账号注册/订阅/风控建模里，机房段和「一个 IP 关联多少账号」是最强的两个特征，" +
      "共享机房出口意味着同 IP 上的其他人会影响你的 IP 声誉。",
    fix: [
      "尽量使用住宅/运营商出口，或至少是专属的、不与他人共享的固定出口",
      "无法更换时：避免在同一个出口上并发多账号操作，并确保出口不再漂移",
    ],
  },

  {
    id: "ip-stability",
    group: "consistency",
    title: "出口 IP 稳定性（重复采样 + 多源交叉）",
    evaluate(ctx) {
      const e = ctx.egress;
      if (!e?.ok) return skip("未取得出口 IP");
      const echoCount = e.crossEchoes.filter((c) => c.ip).length;
      if (e.distinctCount <= 1) {
        return ok(`出口稳定（${e.sampleCount} 次采样、${echoCount} 个独立回显均同一 IP）`, {
          evidence: [["出口 IP", e.primary.ip]],
        });
      }
      const evidence = [
        ["观测到的 IP", e.distinctIps.map((d) => `${d.ip}（${d.count} 次）`).join(" / ")],
        ["重复采样", `${e.sampleCount} 次，其中 ${e.sampledDistinctCount} 个不同 IP`],
        ["多源交叉", e.crossEchoes.filter((c) => c.ip).map((c) => `${c.echo}=${c.ip}`).join(" / ") || "无"],
        ["是否同 /24", e.samePrefix ? "是（同一出口池轮询）" : "否（跨网段/跨地区）"],
      ];
      if (!e.samePrefix) {
        return { level: "high", summary: "出口 IP 跨网段漂移，等价于同一会话里换出口", evidence };
      }
      return {
        level: "medium",
        summary: `同一出口池在 ${e.distinctCount} 个 IP 之间轮询，会话中出口会变`,
        evidence,
      };
    },
    impact:
      "「同一账号短时间内在多个 IP 上出现」本身就是独立的风控特征，和 IP 国家是不是目标国无关。" +
      "轮询池还有个副作用：多源情报对同一个会话可能给出不同归属，进一步降低画像确定性。",
    fix: [
      "给需要稳定身份的目的域名绑定单一固定出口，禁用负载均衡/故障转移策略",
      "至少不要在一个会话进行中途切换节点",
    ],
  },

  {
    id: "ip-intel-consistency",
    group: "consistency",
    title: "多源 IP 情报是否自相矛盾",
    evaluate(ctx) {
      const geo = ctx.egress?.primary;
      if (!geo || geo.sources.length < 2) return skip("有效情报源不足 2 个，无法交叉验证");
      const evidence = [
        ["国家", `${geo.countries.map(regionName).join(" / ") || "无"}`],
        ["ASN", `${geo.asns.join(" / ") || "无"}`],
        ["情报源", geo.sources.join(", ")],
      ];
      if (geo.countryConsistent && geo.asnConsistent) return ok("各情报源对同一 IP 的国家与 ASN 结论一致", { evidence });
      return { level: "medium", summary: "不同情报源对同一 IP 的归属结论不一致", evidence };
    },
    impact:
      "如果不同 GeoIP 库对同一个出口给出不同国家，说明这个 IP 段归属模糊（anycast、刚过户、或分级转售）。" +
      "这类出口在对方风控里同样呈现为「画像不确定」。",
    fix: ["换一个归属清晰的出口；至少记录下来，出问题时可作为申诉背景"],
  },

  {
    id: "clock-skew",
    group: "consistency",
    title: "本机时钟 ↔ 服务器时间",
    evaluate(ctx) {
      const clock = ctx.egress?.clock;
      if (!clock) return skip("未取得服务端时间戳（离线或回显未带时间）");
      if (clock.rttMs > 4000) return skip(`回显往返 ${clock.rttMs} ms 过长，时钟对比不可靠`);
      const skew = Math.round(clock.skewMs);
      const abs = Math.abs(skew);
      const human = abs < 1000 ? `${abs} ms` : abs < 60000 ? `${(abs / 1000).toFixed(1)} 秒` : `${(abs / 60000).toFixed(1)} 分钟`;
      const evidence = [
        ["偏差", `${skew >= 0 ? "本机快" : "本机慢"} ${human}`],
        ["对比来源", clock.source + (clock.coarse ? "（秒级精度）" : "")],
        ["往返时延", `${clock.rttMs} ms`],
      ];
      const tolerance = clock.coarse ? 3000 : 1500;
      if (abs <= tolerance) return ok("本机时钟与服务器时间一致", { evidence });
      if (abs <= 30000) return { level: "low", summary: `本机时钟偏差 ${human}`, evidence };
      if (abs <= 300000) return { level: "medium", summary: `本机时钟偏差 ${human}，超过常见容忍范围`, evidence };
      return { level: "high", summary: `本机时钟偏差 ${human}，TLS/签名类请求可能直接失败`, evidence };
    },
    impact:
      "客户端上报的时间戳和服务器时间差得多，会被当作「设备时钟被改过」或虚拟机快照恢复；超过几分钟还会让 TOTP、签名请求失效。",
    fix: ["打开 系统设置 › 通用 › 日期与时间 的自动设置；虚拟机里确认宿主时间同步"],
  },

  {
    id: "tz-layer",
    group: "consistency",
    title: "系统时区三层自洽（TZ 环境变量 / /etc/localtime / Intl）",
    evaluate(ctx) {
      const tz = ctx.system.timezone;
      const evidence = [
        ["TZ 环境变量", tz.env ?? "未设置"],
        ["/etc/localtime", tz.localtimeLink ?? "未读取"],
        ["Intl 解析", tz.intl ?? "未知"],
      ];
      if (tz.consistent) return ok("三层一致", { evidence });
      return { level: "medium", summary: "系统内不同来源给出的时区不一致", evidence };
    },
    impact:
      "命令行工具、浏览器、系统 UI 会各自读不同来源。三层不一致时，同一个账号在不同客户端上会呈现不同时区，属于自伤式矛盾。",
    fix: ["清理多余的 TZ 环境变量（检查 ~/.zshrc、~/.zshenv、/etc/profile），只保留系统时区一个来源"],
  },

  {
    id: "locale-layer",
    group: "consistency",
    title: "语言/区域三层自洽（系统首选语言 / AppleLocale / Shell LANG）",
    evaluate(ctx) {
      const l = ctx.system.locale;
      const langs = [l.primary?.language, l.apple?.language, l.env?.language].filter(Boolean);
      const evidence = [
        ["系统首选语言", l.appleLanguages.join(", ") || "未读取"],
        ["AppleLocale", l.appleLocale ?? "未读取"],
        ["Shell LANG", l.envRaw ?? "未设置"],
      ];
      const uniq = [...new Set(langs)];
      if (uniq.length <= 1) return ok("语言三层一致", { evidence });
      return {
        level: "low",
        summary: `语言标签不一致：${uniq.join(" / ")}`,
        evidence,
      };
    },
    impact:
      "很常见（系统中文 + 终端英文），证明力弱，但确实会让不同客户端上报不同语言，属于轻度画像噪声。",
    fix: ["如果在意一致性，把 Shell 的 LANG 调成和系统首选语言一致（如 zh_SG.UTF-8），或反过来统一成英文"],
  },

  {
    id: "ipv6",
    group: "consistency",
    title: "IPv6 出口",
    evaluate(ctx) {
      const e = ctx.egress;
      if (!e?.ok) return skip("未取得出口 IP");
      if (!e.v6) {
        return info("当前没有可用的 IPv6 出口（不会被 v6 直连泄漏真实位置）", {
          evidence: [["IPv4 出口", e.primary.ip]],
        });
      }
      const v6 = e.v6Intel;
      const evidence = [
        ["IPv6 出口", e.v6],
        ["v6 归属", `${regionName(v6?.country)} (${v6?.country ?? "?"}) ${v6?.asn ?? ""}`.trim()],
        ["IPv4 归属", `${regionName(e.primary.country)} (${e.primary.country}) ${e.primary.asn ?? ""}`.trim()],
      ];
      if (e.v6ViaDualStackEcho) evidence.push(["说明", "双栈回显服务优先走了 v6，说明系统对双栈目标会优先用 v6 直连"]);
      if (!v6?.country) return info("存在 IPv6 出口，但归属未知", { evidence });
      if (v6.country === e.primary.country) return ok("IPv6 与 IPv4 出口国家一致", { evidence });
      return { level: "high", summary: "IPv6 出口与 IPv4 出口不在同一国家，等于同时暴露两个地点", evidence };
    },
    impact:
      "开了 IPv6 但代理只接管 IPv4 是最经典的泄漏：对方看到两个不同国家的来源。当前没开就不构成风险。",
    fix: ["若启用 IPv6，确保代理同时接管 v6（TUN 栈双栈），或直接在系统里关闭 IPv6"],
  },

  {
    id: "dns-path",
    group: "consistency",
    title: "DNS 解析路径",
    evaluate(ctx) {
      const { dns, proxy } = ctx.system;
      if (!dns.resolvers.length) return skip("未读取到 DNS 解析器");

      const scopedText = dns.scoped.length
        ? dns.scoped.map((s) => `${s.ifName ?? `if#${s.ifIndex ?? "?"}`} → ${s.nameservers.join(",")}`).join("；")
        : "无";
      const perDomainText = dns.perDomain.length
        ? `${dns.perDomain.length} 条按域名路由（如 ${dns.perDomain[0].domain} → ${dns.perDomain[0].nameservers.join(",")}）`
        : "无";
      const evidence = [
        ["默认解析器", dns.defaults.join(", ") || "无"],
        ["按域名路由", perDomainText],
        ["接口级限定", scopedText],
        ["系统代理", proxy.system.available ? `http=${proxy.system.http} https=${proxy.system.https} socks=${proxy.system.socks}` : "未读取"],
      ];

      const externalDefaults = dns.defaults.filter((r) => !isPrivateAddr(r));
      if (!dns.defaults.length) {
        return info("未读到默认解析器（已全部按域名/接口限定）", { evidence });
      }
      if (!externalDefaults.length) {
        return ok("默认 DNS 走本机/代理，公共域名解析不直接暴露解析位置", { evidence });
      }

      evidence.push(["直连默认解析器", externalDefaults.join(", ")]);
      if (proxy.active) {
        return { level: "low", summary: "出口已走代理，但默认 DNS 仍直连公网解析器", evidence };
      }
      return info("默认 DNS 为公网解析器（当前未发现代理链路）", { evidence });
    },
    impact:
      "代理商不接管 DNS 时，解析请求会从本地运营商出去，泄漏 ISP/城市层面的位置，和出口国家形成第二组矛盾。",
    fix: ["让代理接管 DNS（TUN/fake-ip 模式通常已经接管），或把系统 DNS 指到代理内置解析"],
  },

  {
    id: "vendor-fonts",
    group: "profile",
    title: "设备厂商定制字体（强地区线索）",
    evaluate(ctx) {
      const f = ctx.fonts;
      const geo = ctx.egress?.primary;
      const evidence = [
        ["厂商字体", f.vendor.length ? f.vendor.slice(0, 6).join(", ") : "无"],
        ["系统预装 CJK", f.stock.length ? `${f.stock.length} 个（不计入判定）` : "无"],
        ["Office/Windows 系", f.thirdParty.length ? f.thirdParty.slice(0, 4).join(", ") : "无"],
      ];
      if (!f.vendor.length) return ok("未发现整机厂商定制字体", { evidence });
      if (!geo?.country) return info("存在整机厂商定制字体（未取得出口国家，无法比对）", { evidence });
      if (geo.country === "CN") return ok("厂商字体与出口国家一致", { evidence });
      return {
        level: "low",
        summary: `存在整机厂商定制字体，但出口在 ${regionName(geo.country)}`,
        evidence,
      };
    },
    impact:
      "MiSans/HarmonyOS Sans/OPPO Sans 这类字体只会随国产定制系统出现，是真实的设备地区证据；" +
      "而 macOS 预装的 Hiragino/STHeiti/Songti 全世界每台 Mac 都有，零信息量——把两者混在一起算分会直接给所有 Mac 送分。",
    fix: ["无需处理，仅作为画像说明；如确实要消除，卸载第三方厂商字体即可"],
  },

  {
    id: "runtime-arch",
    group: "consistency",
    title: "运行时与机器架构",
    evaluate(ctx) {
      const hw = ctx.system.hardware;
      const rt = ctx.system.runtime;
      const evidence = [
        ["运行时", `${rt.node} (${process.platform}/${hw.arch})`],
        ["机器", `${hw.chip ?? "未知"} / ${hw.machineArch}`],
        ["Rosetta", hw.rosetta ? "是" : "否"],
        ["终端", `${rt.term ?? "未知"} · ${rt.shell ?? "未知"}`],
      ];
      if (hw.rosetta || hw.arch !== hw.machineArch) {
        return { level: "low", summary: "客户端运行在转译/异构架构下，UA 与硬件线索会不一致", evidence };
      }
      return ok("运行时与硬件架构一致", { evidence });
    },
    impact: "转译运行会让客户端上报的架构与设备真实架构矛盾，是一类弱但免费的矛盾信号。",
    fix: ["使用与机器架构匹配的 Node/CLI 版本"],
  },
];

const VERDICTS = { high: "severe", medium: "notable", low: "minor", info: "consistent", ok: "consistent" };

export function runRules(ctx) {
  const results = RULES.map((rule) => {
    let outcome;
    try {
      outcome = rule.evaluate(ctx);
    } catch (err) {
      outcome = { level: "info", skipped: true, summary: `规则执行失败：${err.message}` };
    }
    return {
      id: rule.id,
      group: rule.group,
      title: rule.title,
      impact: rule.impact,
      fix: rule.fix,
      ...outcome,
    };
  });

  const ranked = [...results].sort(
    (a, b) => LEVEL_RANK[a.level] - LEVEL_RANK[b.level] || a.id.localeCompare(b.id),
  );
  const worst = ranked.find((r) => !r.skipped)?.level ?? "ok";
  const verdict = VERDICTS[worst] ?? "consistent";

  return { results: ranked, worst, verdict };
}
