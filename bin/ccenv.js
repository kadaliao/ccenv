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
//   node bin/ccenv.js fingerprint     # Claude 在本机留下的标识，可存快照 / 对比 / 重新生成

import { createInterface } from "node:readline/promises";
import { check, readVersion, renderReport, renderJson } from "../src/index.js";
import { HELP, parseArgs } from "../src/cli.js";
import { renderFingerprint, renderRegenerate } from "../src/report.js";
import { collectFingerprint, diffFingerprints, loadSnapshot, regenerateDesktopIds, regenerateIds, runningClaudeCode, runningClaudeDesktop, saveSnapshot, tildify } from "../src/fingerprint.js";

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
  if (opts.command === "fingerprint") return fingerprint(opts);

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

async function confirm(question) {
  if (!process.stdin.isTTY) return false;
  const rl = createInterface({ input: process.stdin, output: process.stderr });
  try {
    return /^y(es)?$/i.test((await rl.question(question)).trim());
  } finally {
    rl.close();
  }
}

async function fingerprint(opts) {
  if (opts.reset) {
    const before = collectFingerprint({ version: VERSION });
    if (!before.items.some((i) => i.resettable)) {
      console.error("ccenv: 没找到可重新生成的随机 ID。");
      process.exit(1);
    }
    const running = runningClaudeCode();
    const hasDesktop = before.items.some((i) => i.resettable && i.group === "Claude 桌面版");
    const desktopRunning = hasDesktop && runningClaudeDesktop() > 0;
    if (!opts.yes) {
      const scope = hasDesktop && !desktopRunning ? "Claude Code 的 userID / machineID 和桌面版的 ant-did / salt" : "Claude Code 的 userID / machineID";
      const warn = running ? `（有 ${running} 个 Claude Code 进程在运行，建议先退出）` : "";
      const ok = await confirm(`将重新生成 ${scope}，原文件会先备份${warn}。继续？[y/N] `);
      if (!ok) {
        console.error("已取消。非交互环境请加 --yes。");
        process.exit(1);
      }
    }
    const snap = saveSnapshot(before);
    const results = [...regenerateIds(), ...(hasDesktop && !desktopRunning ? regenerateDesktopIds() : [])];
    console.log(renderRegenerate(results.map((r) => ({ ...r, file: tildify(r.file), backup: r.backup && tildify(r.backup) })), { reveal: opts.reveal, running, desktopRunning }));
    const after = collectFingerprint({ version: VERSION });
    console.log(renderFingerprint(after, { reveal: opts.reveal, diff: diffFingerprints(before, after), baseline: `${tildify(snap)}（重新生成前自动保存）` }));
    return;
  }

  const fp = collectFingerprint({ version: VERSION });
  let diff = null;
  let baseline = null;
  if (opts.diff) {
    const { file, fp: base } = loadSnapshot(opts.diff);
    diff = diffFingerprints(base, fp);
    baseline = `${tildify(file)}（${base.generatedAt}）`;
  }
  if (opts.save) {
    const file = saveSnapshot(fp, opts.save === true ? undefined : opts.save);
    console.error(`ccenv: 快照已保存到 ${tildify(file)}`);
  }
  if (opts.json) {
    console.log(JSON.stringify(diff ? { ...fp, diff } : fp, null, 2));
  } else {
    console.log(renderFingerprint(fp, { reveal: opts.reveal, diff, baseline }));
  }
}

main().catch((err) => {
  console.error(`ccenv: 执行失败 — ${err?.stack ?? err}`);
  process.exit(2);
});
