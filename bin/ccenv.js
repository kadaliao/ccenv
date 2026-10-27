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
//   node bin/ccenv.js update          # 检查并安装新版本

import { createInterface } from "node:readline/promises";
import { check, readVersion, renderReport, renderJson } from "../src/index.js";
import { HELP, parseArgs } from "../src/cli.js";
import { renderFingerprint, renderRegenerate } from "../src/report.js";
import { collectFingerprint, diffFingerprints, loadSnapshot, regenerateIds, runningClaudeCode, saveSnapshot, tildify } from "../src/fingerprint.js";
import { compareVersions, detectInstall, fetchLatestVersion, installLatest, PACKAGE_NAME } from "../src/update.js";

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
  if (opts.command === "update") return update(opts);

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
      console.error("ccenv: 没找到 Claude Code 生成的随机 ID，无需重新生成。");
      process.exit(1);
    }
    const running = runningClaudeCode();
    if (!opts.yes) {
      const warn = running ? `（有 ${running} 个 Claude Code 进程在运行，建议先退出）` : "";
      const ok = await confirm(`将重新生成 Claude Code 的 userID / machineID，原文件会先备份${warn}。继续？[y/N] `);
      if (!ok) {
        console.error("已取消。非交互环境请加 --yes。");
        process.exit(1);
      }
    }
    const snap = saveSnapshot(before);
    const results = regenerateIds();
    console.log(renderRegenerate(results.map((r) => ({ ...r, file: tildify(r.file), backup: r.backup && tildify(r.backup) })), { reveal: opts.reveal, running }));
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

async function update(opts) {
  const latest = await fetchLatestVersion({ timeoutMs: opts.timeoutMs });
  const cmp = compareVersions(latest, VERSION);
  if (cmp <= 0) {
    console.log(`ccenv ${VERSION} 已是最新版本。`);
    return;
  }
  console.log(`发现新版本 ${latest}（当前 ${VERSION}）。`);
  if (opts.checkOnly) {
    console.log(`运行 ccenv update 安装，或 npm install -g ${PACKAGE_NAME}@latest。`);
    return;
  }
  const install = detectInstall();
  if (install.kind === "source") {
    console.log(`这份 ccenv 是从源码运行的（${install.root}），请在仓库里 git pull。`);
    return;
  }
  if (install.kind === "npx") {
    console.log(`这是 npx 临时运行的副本，改用 npx ${PACKAGE_NAME}@latest 即可拿到新版本。`);
    return;
  }
  const code = installLatest();
  if (code !== 0) {
    console.error(`ccenv: 安装失败（npm 退出码 ${code}）。权限不足时可以试试 sudo，或检查 npm prefix。`);
    process.exit(code);
  }
  console.log(`已更新到 ${latest}。`);
}

main().catch((err) => {
  console.error(`ccenv: 执行失败 — ${err?.stack ?? err}`);
  process.exit(2);
});
