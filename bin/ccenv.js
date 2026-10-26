#!/usr/bin/env node
// ccenv —— 环境一致性检测 CLI
//
// 用法:
//   node bin/ccenv.js                 # 完整检测（默认采样 6 次）
//   node bin/ccenv.js --explain       # 附带每项的影响与处理建议
//   node bin/ccenv.js --json          # 结构化输出，便于脚本/CI 使用
//   node bin/ccenv.js --offline       # 跳过网络层，只查本地
//   node bin/ccenv.js --samples 12    # 采样次数（越多越容易发现出口漂移）
//   node bin/ccenv.js --exit-code     # 有 high 级冲突时退出码 1

import { readFileSync } from "node:fs";
import { collectSystem } from "../src/system.js";
import { collectFonts } from "../src/fonts.js";
import { collectEgress } from "../src/network.js";
import { runRules } from "../src/rules.js";
import { renderReport, renderJson } from "../src/report.js";

function readVersion() {
  try {
    const pkg = JSON.parse(readFileSync(new URL("../package.json", import.meta.url), "utf8"));
    return typeof pkg.version === "string" ? pkg.version : "0.0.0";
  } catch {
    return "0.0.0";
  }
}

const VERSION = readVersion();

const HELP = `ccenv — 环境一致性检测（一致性冲突 + 真实 IP/ASN 查询）

它不回答「你像哪个国家」，而是回答「你的各层画像之间有没有互相矛盾」。

选项:
  --json               输出结构化 JSON
  --explain            对每个冲突项输出影响说明与处理建议
  --offline            跳过网络层（只检测时区/语言/字体/代理/DNS）
  --samples <n>        出口 IP 采样次数，默认 6
  --interval <ms>      采样间隔，默认 350
  --timeout <ms>       单次网络超时，默认 8000
  --no-color           关闭颜色
  --exit-code          存在 high 级冲突时以退出码 1 结束
  -v, --version        显示版本
  -h, --help           显示帮助

规则（每条只对应一个底层事实，不做加权求和）:
  一致性  出口时区↔系统时区 · 出口国家↔区域语言 · 出口 IP 稳定性 ·
          多源情报自洽 · 时区三层 · 语言三层 · IPv6 出口 · DNS 路径 · 运行时架构
  画像    出口 IP 类型（住宅/机房） · 设备厂商定制字体
`;

function parseArgs(argv) {
  const opts = { samples: 6, intervalMs: 350, timeoutMs: 8000, json: false, explain: false, offline: false, exitCode: false };
  for (let i = 0; i < argv.length; i += 1) {
    const arg = argv[i];
    const next = () => {
      const v = argv[i + 1];
      if (v == null || v.startsWith("--")) throw new Error(`${arg} 缺少取值`);
      i += 1;
      return v;
    };
    switch (arg) {
      case "--json":
        opts.json = true;
        break;
      case "--explain":
        opts.explain = true;
        break;
      case "--offline":
        opts.offline = true;
        break;
      case "--no-color":
        process.env.NO_COLOR = "1";
        break;
      case "--exit-code":
        opts.exitCode = true;
        break;
      case "--samples":
        opts.samples = Math.max(1, Number(next()));
        break;
      case "--interval":
        opts.intervalMs = Math.max(0, Number(next()));
        break;
      case "--timeout":
        opts.timeoutMs = Math.max(1000, Number(next()));
        break;
      case "-v":
      case "--version":
        opts.version = true;
        break;
      case "-h":
      case "--help":
        opts.help = true;
        break;
      default:
        throw new Error(`未知参数: ${arg}`);
    }
  }
  return opts;
}

async function main() {
  let opts;
  try {
    opts = parseArgs(process.argv.slice(2));
  } catch (err) {
    console.error(`ccenv: ${err.message}\n`);
    console.error(HELP);
    process.exit(2);
  }
  if (opts.help) {
    console.log(HELP);
    return;
  }
  if (opts.version) {
    console.log(`ccenv ${VERSION}`);
    return;
  }
  const system = collectSystem();
  const fonts = collectFonts();

  if (!opts.json) console.error("ccenv: 采集中…（本地层就绪，正在查询出口 IP / ASN）");

  const egress = opts.offline
    ? { ok: false, error: "已指定 --offline，跳过网络层" }
    : await collectEgress({ samples: opts.samples, intervalMs: opts.intervalMs, timeoutMs: opts.timeoutMs });

  const ctx = {
    system: { ...system, fontsStockCount: fonts.stock.length },
    fonts,
    egress,
  };

  const verdict = runRules(ctx);

  if (opts.json) {
    console.log(renderJson(ctx, verdict));
  } else {
    process.stderr.write("\x1b[2K\r");
    console.log(renderReport(ctx, verdict, { explain: opts.explain }));
  }

  if (opts.exitCode && verdict.worst === "high") process.exit(1);
}

main().catch((err) => {
  console.error(`ccenv: 执行失败 — ${err?.stack ?? err}`);
  process.exit(2);
});
