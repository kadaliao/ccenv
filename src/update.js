// 检查并安装 CLI 新版本。版本号来自 npm registry，安装走 npm install -g。

import { spawnSync } from "node:child_process";
import { existsSync, realpathSync } from "node:fs";
import { fileURLToPath } from "node:url";
import path from "node:path";

export const PACKAGE_NAME = "@kadaliao/ccenv";
const REGISTRY_URL = `https://registry.npmjs.org/${PACKAGE_NAME.replace("/", "%2f")}/latest`;

/** 比较 x.y.z 版本号，忽略预发布后缀。返回 -1 / 0 / 1。 */
export function compareVersions(a, b) {
  const parse = (v) => String(v ?? "").replace(/^v/, "").split(/[-+]/)[0].split(".").map((n) => Number.parseInt(n, 10) || 0);
  const pa = parse(a);
  const pb = parse(b);
  for (let i = 0; i < Math.max(pa.length, pb.length); i += 1) {
    const d = (pa[i] ?? 0) - (pb[i] ?? 0);
    if (d !== 0) return d > 0 ? 1 : -1;
  }
  return 0;
}

export async function fetchLatestVersion({ timeoutMs = 8000 } = {}) {
  const res = await fetch(REGISTRY_URL, { signal: AbortSignal.timeout(timeoutMs), headers: { accept: "application/json" } });
  if (!res.ok) throw new Error(`npm registry 返回 HTTP ${res.status}`);
  const body = await res.json();
  if (typeof body.version !== "string") throw new Error("npm registry 没有返回版本号");
  return body.version;
}

/**
 * 当前这份 ccenv 是怎么装的，决定能不能原地升级：
 *   source      git 仓库里 npm link / 直接运行，应该 git pull
 *   npx         npx 临时缓存，下次 npx 自动拿最新
 *   npm-global  npm install -g，可以直接升级
 */
export function detectInstall(root = path.dirname(path.dirname(fileURLToPath(import.meta.url)))) {
  let real = root;
  try {
    real = realpathSync(root);
  } catch {}
  if (existsSync(path.join(real, ".git"))) return { kind: "source", root: real };
  if (/[\\/]_npx[\\/]/.test(real)) return { kind: "npx", root: real };
  return { kind: "npm-global", root: real };
}

export function installLatest() {
  const npm = process.platform === "win32" ? "npm.cmd" : "npm";
  const res = spawnSync(npm, ["install", "-g", `${PACKAGE_NAME}@latest`], { stdio: "inherit" });
  if (res.error) throw res.error;
  return res.status ?? 1;
}
