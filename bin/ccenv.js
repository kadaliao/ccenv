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

import { check, readVersion, renderReport, renderJson } from "../src/index.js";
import { HELP, parseArgs } from "../src/cli.js";

const VERSION = readVersion();

const STAGE_TEXT = {
  local: "读取本地层（时区 / 语言 / 字体 / DNS）…",
  sampling: "采样出口 IP（多源回显）…",
  intel: "查询 IP / ASN 情报…",
  rules: "比对规则…",
};

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

  // 进度只在交互式终端上原地刷新；管道/重定向时完全静默，避免控制符混进输出。
  const interactive = process.stderr.isTTY && !opts.json;
  const onProgress = (stage) => {
    if (!interactive) return;
    process.stderr.write(`\x1b[2K\rccenv: ${STAGE_TEXT[stage] ?? stage}`);
  };

  const { ctx, verdict } = await check({ ...opts, onProgress });
  if (interactive) process.stderr.write("\x1b[2K\r");

  if (opts.json) {
    console.log(renderJson(ctx, verdict, { version: VERSION }));
  } else {
    console.log(renderReport(ctx, verdict, { explain: opts.explain }));
  }

  if (opts.exitCode && verdict.worst === "high") process.exit(1);
}

main().catch((err) => {
  console.error(`ccenv: 执行失败 — ${err?.stack ?? err}`);
  process.exit(2);
});
