// 程序化入口：采集 → 规则 → 结果。bin/ccenv.js 和测试都走这里。

import { readFileSync } from "node:fs";
import { collectSystem } from "./system.js";
import { collectFonts } from "./fonts.js";
import { collectEgress } from "./network.js";
import { runRules } from "./rules.js";
import { renderReport, renderJson, toJson } from "./report.js";

export function readVersion() {
  try {
    const pkg = JSON.parse(readFileSync(new URL("../package.json", import.meta.url), "utf8"));
    return typeof pkg.version === "string" ? pkg.version : "0.0.0";
  } catch {
    return "0.0.0";
  }
}

/**
 * @param {{offline?:boolean, samples?:number, intervalMs?:number, timeoutMs?:number, onProgress?:(stage:string)=>void}} opts
 */
export async function check({ offline = false, samples = 6, intervalMs = 350, timeoutMs = 8000, onProgress = () => {} } = {}) {
  onProgress("local");
  const system = collectSystem();
  const fonts = collectFonts();

  const egress = offline
    ? { ok: false, error: "已指定 --offline，跳过网络层" }
    : await collectEgress({ samples, intervalMs, timeoutMs, onProgress });

  onProgress("rules");
  const ctx = { system: { ...system, fontsStockCount: fonts.stock.length }, fonts, egress };
  const verdict = runRules(ctx);
  return { ctx, verdict };
}

export { collectSystem, collectFonts, collectEgress, runRules, renderReport, renderJson, toJson };
