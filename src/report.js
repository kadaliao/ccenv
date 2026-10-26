// 输出层：事实面板 + 冲突清单。--json 时直接输出结构化结果给脚本用。

import { formatOffset, offsetMinutesFor } from "./system.js";
import { regionName } from "./classify.js";

export const SCHEMA_VERSION = 2;

const useColor = () => Boolean(process.stdout.isTTY) && !process.env.NO_COLOR;

const c = (code) => (s) => (useColor() ? `\x1b[${code}m${s}\x1b[0m` : String(s));
const dim = c("2");
const bold = c("1");
const red = c("31");
const yellow = c("33");
const green = c("32");
const blue = c("36");
const gray = c("90");

const LEVEL_STYLE = {
  high: { label: "HIGH  ", paint: red },
  medium: { label: "MEDIUM", paint: yellow },
  low: { label: "LOW   ", paint: blue },
  info: { label: "INFO  ", paint: gray },
  ok: { label: "OK    ", paint: green },
};

export const VERDICT_TEXT = {
  severe: { text: "严重冲突", paint: red },
  notable: { text: "明显冲突", paint: yellow },
  minor: { text: "轻度冲突", paint: blue },
  consistent: { text: "未发现冲突", paint: green },
};

const GROUP_TITLE = { consistency: "一致性冲突", profile: "画像风险" };

const stripAnsi = (s) => String(s).replace(/\x1b\[[0-9;]*m/g, "");

/** 终端显示宽度：CJK / 全角按 2 列算。 */
function visibleWidth(s) {
  let w = 0;
  for (const ch of stripAnsi(s)) w += ch.codePointAt(0) > 0x2e80 ? 2 : 1;
  return w;
}

const padTo = (s, width) => String(s) + " ".repeat(Math.max(0, width - visibleWidth(s)));

const LABEL_COL = 18;
const BODY_COL = 96;

/** 简单按显示宽度折行，续行加缩进。 */
function wrap(text, indent, width = BODY_COL) {
  const lines = [];
  let line = "";
  for (const ch of String(text)) {
    if (visibleWidth(line + ch) > width) {
      lines.push(line);
      line = ch;
    } else {
      line += ch;
    }
  }
  if (line) lines.push(line);
  return lines.map((l, i) => (i === 0 ? l : `${" ".repeat(indent)}${l}`)).join("\n");
}

const section = (title) => `\n${bold(title)}\n${dim("─".repeat(52))}`;

function kindLabel(kind) {
  if (kind === "hosting") return red("机房/托管/代理段");
  if (kind === "isp") return green("运营商/宽带段");
  return yellow("无法归类");
}

function renderFacts(ctx) {
  const lines = [];
  const e = ctx.egress;
  const s = ctx.system;

  lines.push(section("出口层（真实 IP / ASN）"));
  if (!e?.ok) {
    lines.push(`  ${red("无法取得出口 IP")}  ${dim(e?.error ?? "未知原因")}`);
  } else {
    const p = e.primary;
    const rows = [
      ["出口 IP", `${e.distinctIps.map((d) => d.ip).join(" / ")}${e.distinctCount > 1 ? dim(`  (${e.sampleCount} 次采样)`) : ""}`],
      ["归属", `${regionName(p.country)} · ${p.region ?? "?"} · ${p.city ?? "?"}  ${dim(`(${p.country ?? "?"})`)}`],
      ["ASN", `${p.asn ?? "?"} ${p.isp ?? p.org ?? ""}`],
      ["rDNS", p.hostname ?? dim("无")],
      ["类型", `${kindLabel(p.classification.kind)}  ${dim(`置信 ${p.classification.confidence}`)}`],
      ["出口时区", `${p.timezone ?? "?"} ${dim(`(${formatOffset(offsetMinutesFor(p.timezone))})`)}`],
      ["IPv6", e.v6 ? `${e.v6} ${dim(`(${regionName(e.v6Intel?.country)})`)}` : dim("无 v6 出口")],
      ["情报源", dim(`${p.sources.join(", ") || "无"} · 耗时 ${((e.durationMs ?? 0) / 1000).toFixed(1)}s`)],
    ];
    for (const [k, v] of rows) lines.push(`  ${dim(padTo(k, LABEL_COL))} ${v}`);
  }

  lines.push(section("系统层"));
  const geoOffset = e?.ok ? offsetMinutesFor(e.primary.timezone) : null;
  const tzDelta = geoOffset != null ? Math.abs(s.timezone.offsetMinutes - geoOffset) : null;
  const tzWarn = tzDelta != null && tzDelta >= 120 ? red(" ← 与出口不一致") : "";
  const vendorText = ctx.fonts.vendor.length ? yellow(ctx.fonts.vendor.slice(0, 4).join(", ")) : "0";
  const tunText = s.proxy.tunnels?.length ? s.proxy.tunnels.map((t) => `${t.name}(${t.addrs[0]})`).join(",") : "-";
  const sysRows = [
    ["时区", `${s.timezone.intl ?? "?"} (${s.timezone.offsetLabel})${tzWarn}  ${dim(`localtime=${s.timezone.localtimeLink ?? "?"} TZ=${s.timezone.env ?? "未设"}`)}`],
    ["语言", `${s.locale.appleLanguages.join(", ") || s.locale.envRaw || "?"}  ${dim(`AppleLocale=${s.locale.appleLocale ?? "?"}`)}`],
    ["Shell", `LANG=${s.locale.envRaw ?? "未设置"}`],
    ["字体", `预装 CJK ${ctx.fonts.stock.length}${dim("(不计分)")} · 三方 ${ctx.fonts.thirdParty.length} · 厂商 ${vendorText}`],
    ["链路", `${s.proxy.active ? green("经代理") : dim("直连")} ${dim(`apps=[${s.proxy.apps.join(",") || "-"}] tun=[${tunText}] sysProxy=${s.proxy.system.https === true ? "on" : "off"}`)}`],
    ["DNS", `${s.dns.defaults.join(", ") || "?"} ${s.dns.allThroughProxy ? green("(默认走代理)") : yellow("(默认含公网)")}${s.dns.scoped.length ? dim(` + ${s.dns.scoped.length} 个接口级限定`) : ""}`],
    ["设备", `${s.hardware.os} · ${s.hardware.chip ?? "?"} · ${s.hardware.machineArch}${s.hardware.rosetta ? yellow(" (Rosetta)") : ""}`],
    ["运行时", `node ${s.runtime.node} · ${s.runtime.term ?? "?"} · ${s.runtime.shell ?? "?"}`],
  ];
  for (const [k, v] of sysRows) lines.push(`  ${dim(padTo(k, LABEL_COL))} ${v}`);

  return lines.join("\n");
}

function renderRule(rule, explain) {
  const style = LEVEL_STYLE[rule.level] ?? LEVEL_STYLE.info;
  const out = [`  ${style.paint(`[${style.label}]`)} ${bold(rule.id)} ${dim("—")} ${rule.summary}`];
  const evidence = rule.evidence ?? [];
  const labels = [...evidence.map(([k]) => k), ...(explain ? ["影响", "处理"] : [])];
  const col = Math.max(LABEL_COL, ...labels.map((l) => visibleWidth(l) + 2));
  for (const [k, val] of evidence) out.push(`      ${dim(padTo(k, col))} ${val}`);
  if (explain) {
    out.push(`      ${dim(padTo("影响", col))} ${wrap(rule.impact, 6 + col + 1)}`);
    for (const f of rule.fix ?? []) out.push(`      ${dim(padTo("处理", col))} ${wrap(f, 6 + col + 1)}`);
  }
  return out;
}

export function renderReport(ctx, { results, worst, verdict }, { explain = false } = {}) {
  const out = [];
  const v = VERDICT_TEXT[verdict] ?? VERDICT_TEXT.consistent;

  out.push("");
  out.push(`${bold("ccenv")} ${dim("· 环境一致性检测")}`);
  out.push(dim("─".repeat(52)));
  out.push(`结论  ${v.paint(bold(v.text))}   ${dim(`最高等级 ${worst}`)}`);
  out.push(dim("  逐层取事实 → 跨层找矛盾 → 取最高等级；不做加权求和，不对「像哪个国家」打分。"));

  out.push(renderFacts(ctx));

  const byGroup = { consistency: [], profile: [] };
  for (const r of results) {
    if (r.skipped || r.level === "ok") continue;
    (byGroup[r.group] ??= []).push(r);
  }
  const passed = results.filter((r) => r.level === "ok");
  const skipped = results.filter((r) => r.skipped);

  for (const group of ["consistency", "profile"]) {
    const items = byGroup[group];
    if (!items?.length) continue;
    out.push(section(`${GROUP_TITLE[group]}（${items.length}）`));
    for (const r of items) out.push(...renderRule(r, explain));
  }

  out.push(section(`通过项（${passed.length}）`));
  if (!passed.length) out.push(`  ${dim("无")}`);
  for (const r of passed) out.push(`  ${green("[OK    ]")} ${r.id} ${dim("—")} ${dim(r.summary)}`);

  if (skipped.length) {
    out.push(section(`跳过项（${skipped.length}）`));
    for (const r of skipped) out.push(`  ${gray("[SKIP  ]")} ${r.id} ${dim("—")} ${dim(r.summary)}`);
  }

  out.push("");
  if (!explain) out.push(dim("加 --explain 查看每项的影响说明与处理建议；加 --json 输出结构化结果。"));
  out.push("");
  return out.join("\n");
}

/** 结构化结果。schema 字段变更时递增 SCHEMA_VERSION。 */
export function toJson(ctx, verdict, { version = "0.0.0" } = {}) {
  return {
    tool: "ccenv",
    version,
    schema: SCHEMA_VERSION,
    generatedAt: new Date().toISOString(),
    verdict: { value: verdict.verdict, worst: verdict.worst },
    facts: {
      egress: ctx.egress?.ok
        ? {
            ok: true,
            ips: ctx.egress.distinctIps,
            distinctCount: ctx.egress.distinctCount,
            sampledDistinctCount: ctx.egress.sampledDistinctCount,
            sampleCount: ctx.egress.sampleCount,
            samePrefix: ctx.egress.samePrefix,
            primary: ctx.egress.primary,
            v6: ctx.egress.v6,
            v6Country: ctx.egress.v6Intel?.country ?? null,
            crossEchoes: ctx.egress.crossEchoes,
            clock: ctx.egress.clock,
            durationMs: ctx.egress.durationMs,
          }
        : { ok: false, error: ctx.egress?.error ?? null },
      system: ctx.system,
      fonts: { stock: ctx.fonts.stock, thirdParty: ctx.fonts.thirdParty, vendor: ctx.fonts.vendor },
    },
    rules: verdict.results.map((r) => ({
      id: r.id,
      group: r.group,
      title: r.title,
      level: r.level,
      skipped: Boolean(r.skipped),
      summary: r.summary,
      evidence: r.evidence ?? [],
      impact: r.impact,
      fix: r.fix ?? [],
    })),
  };
}

export function renderJson(ctx, verdict, opts) {
  return JSON.stringify(toJson(ctx, verdict, opts), null, 2);
}
