// Claude 在本机留下的标识（指纹）：采集、快照、对比、重新生成。
//
// 只读这些固定位置里的标识字段，不读令牌、会话和项目数据：
//   ~/.claude.json、~/.claude/.claude.json（以及 $CLAUDE_CONFIG_DIR/.claude.json）  Claude Code
//   ~/Library/Application Support/Claude/{ant-did,ccd-ids.json,ant-device-registry.json,config.json}  桌面版
//   ioreg IOPlatformUUID                                                                Claude Code 的 OTel host.id
//
// 「重新生成」只改首次运行时随机生成、缺失时会自动重建的标识，写之前先备份：
//   Claude Code 的 userID / machineID / summonSidKey（持有和 Claude Code 相同的配置锁 <file>.lock）
//   桌面版的 ant-did（base64 编码的随机 UUID）和 ccd-ids.json 的 salt（随机 UUID），只在桌面版退出时改
// 设备登记（ant-device-registry.json）背后是钥匙串 / Secure Enclave 里的硬件密钥，属于安全凭据，不碰。

import { execFileSync } from "node:child_process";
import { randomBytes, randomUUID } from "node:crypto";
import { chmodSync, copyFileSync, existsSync, mkdirSync, readFileSync, readdirSync, renameSync, rmdirSync, statSync, writeFileSync } from "node:fs";
import os from "node:os";
import path from "node:path";

export const FINGERPRINT_SCHEMA = 1;

/** Claude Code 自己生成的随机标识：64 位十六进制。 */
export const RESETTABLE_KEYS = ["userID", "machineID", "summonSidKey"];
const HEX64 = /^[0-9a-f]{64}$/;
const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

/** ant-did 文件内容是 base64 编码的 UUID，解不出 UUID 返回 null。 */
export function decodeAntDid(raw) {
  if (typeof raw !== "string") return null;
  const s = Buffer.from(raw.trim(), "base64").toString("utf8").trim();
  return UUID_RE.test(s) ? s : null;
}

const home = () => os.homedir();
export const snapshotDir = () => path.join(home(), ".ccenv", "fingerprints");
const backupDir = () => path.join(home(), ".ccenv", "backups");
export const desktopDir = () => path.join(home(), "Library", "Application Support", "Claude");

/** 把绝对路径里的家目录换成 ~，用于展示和条目 ID。 */
export function tildify(p) {
  const h = home();
  return p === h ? "~" : p.startsWith(h + path.sep) ? "~" + p.slice(h.length) : p;
}

function readJson(file) {
  try {
    return JSON.parse(readFileSync(file, "utf8"));
  } catch {
    return null;
  }
}

function readText(file) {
  try {
    return readFileSync(file, "utf8").trim();
  } catch {
    return null;
  }
}

/** Claude Code 可能使用的全局配置文件，去重后按优先级排列。 */
export function claudeCodeConfigPaths(env = process.env) {
  const list = [];
  if (env.CLAUDE_CONFIG_DIR) list.push(path.join(env.CLAUDE_CONFIG_DIR, ".claude.json"));
  list.push(path.join(home(), ".claude.json"));
  list.push(path.join(home(), ".claude", ".claude.json"));
  return [...new Set(list.map((p) => path.resolve(p)))].filter((p) => existsSync(p));
}

const CODE_FIELDS = [
  { key: "userID", label: "设备 ID (userID)", note: "遥测里的 device_id，首次运行时随机生成", masked: true },
  { key: "machineID", label: "机器 ID (machineID)", note: "首次运行时随机生成", masked: true },
  { key: "summonSidKey", label: "summonSidKey", note: "首次使用相关功能时随机生成", masked: true },
  { key: "firstStartTime", label: "首次启动时间" },
  { key: "firstStartVersion", label: "首次启动版本" },
  { key: "installMethod", label: "安装方式" },
  { key: "oauthAccount.accountUuid", label: "账号 UUID", note: "服务端账号身份，本地改不了", masked: true },
  { key: "oauthAccount.organizationUuid", label: "组织 UUID", masked: true },
  { key: "oauthAccount.emailAddress", label: "账号邮箱", sensitive: true },
];

const pick = (obj, dotted) => dotted.split(".").reduce((v, k) => (v && typeof v === "object" ? v[k] : undefined), obj);

/** masked：标识类的值，展示时默认打码；sensitive：个人信息（邮箱），打码更狠。 */
function item({ id, group, label, value, source, note = null, resettable = false, masked = false, sensitive = false }) {
  return { id, group, label, value: value == null ? null : String(value), source, note, resettable, masked: masked || sensitive, sensitive };
}

/** 从一个已解析的 .claude.json 里取标识字段。拆出来方便测试。 */
export function claudeCodeItems(config, file) {
  const src = tildify(file);
  const group = `Claude Code · ${src}`;
  const out = [];
  for (const f of CODE_FIELDS) {
    const value = pick(config, f.key);
    if (value == null || typeof value === "object") continue;
    out.push(item({
      id: `${src}#${f.key}`,
      group,
      label: f.label,
      value,
      source: src,
      note: f.note ?? null,
      resettable: RESETTABLE_KEYS.includes(f.key) && HEX64.test(String(value)),
      masked: f.masked ?? false,
      sensitive: f.sensitive ?? false,
    }));
  }
  return out;
}

function desktopItems() {
  const dir = desktopDir();
  if (!existsSync(dir)) return [];
  const group = "Claude 桌面版";
  const src = (f) => tildify(path.join(dir, f));
  const out = [];
  const did = readText(path.join(dir, "ant-did"));
  if (did) out.push(item({ id: `${src("ant-did")}`, group, label: "设备 ID (ant-did)", value: did, source: src("ant-did"), note: "桌面版首次启动时随机生成的 UUID（base64 存储）", resettable: decodeAntDid(did) != null, masked: true }));
  const salt = readJson(path.join(dir, "ccd-ids.json"))?.salt;
  if (typeof salt === "string") out.push(item({ id: `${src("ccd-ids.json")}#salt`, group, label: "ID 盐 (ccd-ids)", value: salt, source: src("ccd-ids.json"), note: "桌面版随机生成，用来给本地路径做哈希", resettable: salt.length > 0, masked: true }));
  const registry = readJson(path.join(dir, "ant-device-registry.json"));
  if (registry && typeof registry === "object") {
    // 值是设备登记凭据，只列出登记过的账号，不读值。
    const keys = Object.keys(registry).sort();
    out.push(item({ id: `${src("ant-device-registry.json")}#keys`, group, label: "设备登记", value: keys.join(", ") || "无", source: src("ant-device-registry.json"), note: "只列登记过的账号，不读登记凭据", masked: true }));
  }
  // config.json 里有登录令牌，只取两个非敏感字段。
  const cfg = readJson(path.join(dir, "config.json"));
  if (cfg) {
    if (typeof cfg.lastKnownAccountUuid === "string") out.push(item({ id: `${src("config.json")}#lastKnownAccountUuid`, group, label: "最近账号 UUID", value: cfg.lastKnownAccountUuid, source: src("config.json"), masked: true }));
    if (typeof cfg.first_launch_at === "number") out.push(item({ id: `${src("config.json")}#first_launch_at`, group, label: "首次启动时间", value: new Date(cfg.first_launch_at).toISOString(), source: src("config.json") }));
  }
  return out;
}

function run(cmd, args) {
  try {
    return execFileSync(cmd, args, { encoding: "utf8", timeout: 5000, stdio: ["ignore", "pipe", "ignore"] }).trim();
  } catch {
    return null;
  }
}

function hardwareItems() {
  const group = "本机硬件";
  const out = [];
  if (process.platform === "darwin") {
    const io = run("/usr/sbin/ioreg", ["-rd1", "-c", "IOPlatformExpertDevice"]);
    const uuid = io && /"IOPlatformUUID" = "([^"]+)"/.exec(io)?.[1];
    if (uuid) out.push(item({ id: "hardware#IOPlatformUUID", group, label: "硬件 UUID", value: uuid, source: "ioreg", note: "Claude Code 的 OpenTelemetry 用它作 host.id，只在开启 OTel 时上报", masked: true }));
  } else {
    const mid = readText("/etc/machine-id") ?? readText("/var/lib/dbus/machine-id");
    if (mid) out.push(item({ id: "hardware#machine-id", group, label: "machine-id", value: mid, source: "/etc/machine-id", note: "Claude Code 的 OpenTelemetry 用它作 host.id", masked: true }));
  }
  out.push(item({ id: "hardware#hostname", group, label: "主机名", value: os.hostname(), source: "os.hostname()" }));
  return out;
}

/** 正在运行的 Claude Code 进程数。它们把标识缓存在内存里，重新生成后要重启才会用新值。 */
export function runningClaudeCode() {
  const out = run("/bin/ps", ["-axo", "pid=,args="]);
  if (!out) return 0;
  return out.split("\n").filter((line) => isClaudeCodeProcess(line.trim().replace(/^\d+\s+/, ""))).length;
}

export function isClaudeCodeProcess(args) {
  return /\/claude\/versions\/[^/\s]+(\s|$)/.test(args)
    || /@anthropic-ai\/claude-code\//.test(args)
    || /(^|\/)claude(\s|$)/.test(args);
}

/** 正在运行的 Claude 桌面版主进程数（不含 Helper）。 */
export function runningClaudeDesktop() {
  const out = run("/bin/ps", ["-axo", "pid=,args="]);
  if (!out) return 0;
  return out.split("\n").filter((line) => isClaudeDesktopProcess(line.trim().replace(/^\d+\s+/, ""))).length;
}

export function isClaudeDesktopProcess(args) {
  return /\/Claude\.app\/Contents\/MacOS\/Claude(\s|$)/.test(args);
}

export function collectFingerprint({ version = "0.0.0" } = {}) {
  const items = [];
  for (const file of claudeCodeConfigPaths()) {
    const cfg = readJson(file);
    if (cfg && typeof cfg === "object") items.push(...claudeCodeItems(cfg, file));
  }
  items.push(...desktopItems(), ...hardwareItems());
  return {
    tool: "ccenv",
    kind: "fingerprint",
    schema: FINGERPRINT_SCHEMA,
    version,
    generatedAt: new Date().toISOString(),
    host: os.hostname(),
    items,
  };
}

/** 逐条对比两份快照。status: same / changed / added / removed。 */
export function diffFingerprints(before, after) {
  const prev = new Map((before?.items ?? []).map((i) => [i.id, i]));
  const next = new Map((after?.items ?? []).map((i) => [i.id, i]));
  const rows = [];
  for (const [id, cur] of next) {
    const old = prev.get(id);
    const status = !old ? "added" : old.value === cur.value ? "same" : "changed";
    rows.push({ id, group: cur.group, label: cur.label, status, before: old?.value ?? null, after: cur.value, masked: cur.masked ?? true, sensitive: cur.sensitive ?? false });
  }
  for (const [id, old] of prev) {
    if (!next.has(id)) rows.push({ id, group: old.group, label: old.label, status: "removed", before: old.value, after: null, masked: old.masked ?? true, sensitive: old.sensitive ?? false });
  }
  return rows;
}

/** 展示用打码：保留头 8 尾 4；邮箱只留首字母和域名。masked=false 的条目原样返回。 */
export function maskValue(value, { masked = true, sensitive = false } = {}) {
  if (value == null) return "—";
  const s = String(value);
  if (!masked && !sensitive) return s;
  if (sensitive && s.includes("@")) {
    const [user, domain] = s.split("@");
    return `${user.slice(0, 1)}***@${domain}`;
  }
  return s.length > 16 ? `${s.slice(0, 8)}…${s.slice(-4)}` : s;
}

// ── 快照 ────────────────────────────────────────────────

const stamp = (d = new Date()) => d.toISOString().replace(/[:.]/g, "-").slice(0, 19);

export function saveSnapshot(fp, file) {
  const target = file ?? path.join(snapshotDir(), `fingerprint-${stamp()}.json`);
  mkdirSync(path.dirname(target), { recursive: true });
  writeFileSync(target, JSON.stringify(fp, null, 2) + "\n", { mode: 0o600 });
  return target;
}

export function listSnapshots() {
  try {
    return readdirSync(snapshotDir())
      .filter((f) => f.endsWith(".json"))
      .sort()
      .map((f) => path.join(snapshotDir(), f));
  } catch {
    return [];
  }
}

export function loadSnapshot(file) {
  const target = file === "latest" ? listSnapshots().at(-1) : file;
  if (!target) throw new Error(`没有已保存的快照（${tildify(snapshotDir())}）`);
  const fp = readJson(target);
  if (!fp || fp.kind !== "fingerprint" || !Array.isArray(fp.items)) throw new Error(`不是 ccenv 指纹快照：${target}`);
  return { file: target, fp };
}

// ── 重新生成 ────────────────────────────────────────────

/**
 * 在原文里把 "key": "<旧值>" 换成新值，其它字节保持原样（不重排键、不改缩进）。
 * 只换值是 64 位十六进制的键；返回 { text, changes }。
 */
export function regenerateInText(text, keys = RESETTABLE_KEYS, gen = () => randomBytes(32).toString("hex")) {
  const parsed = JSON.parse(text);
  const changes = [];
  let out = text;
  for (const key of keys) {
    const old = parsed[key];
    if (typeof old !== "string" || !HEX64.test(old)) continue;
    const next = gen();
    const re = new RegExp(`("${key}"\\s*:\\s*")${old}(")`, "g");
    const replaced = out.replace(re, (_, head, tail) => `${head}${next}${tail}`);
    if (replaced === out) continue;
    out = replaced;
    changes.push({ key, before: old, after: next });
  }
  JSON.parse(out); // 防御：写回去之前确认仍是合法 JSON
  return { text: out, changes };
}

function withConfigLock(file, fn) {
  // 和 Claude Code（proper-lockfile）同一把锁：<file>.lock 目录。拿不到就等，超过 10 秒视为陈旧锁。
  const lock = `${file}.lock`;
  const deadline = Date.now() + 5000;
  for (;;) {
    try {
      mkdirSync(lock);
      break;
    } catch (err) {
      if (err.code !== "EEXIST") throw err;
      let stale = false;
      try {
        stale = Date.now() - statSync(lock).mtimeMs > 10_000;
      } catch {}
      if (stale) {
        try { rmdirSync(lock); } catch {}
        continue;
      }
      if (Date.now() > deadline) throw new Error(`${tildify(file)} 正被 Claude Code 占用，稍后再试`);
      Atomics.wait(new Int32Array(new SharedArrayBuffer(4)), 0, 0, 100);
    }
  }
  try {
    return fn();
  } finally {
    try { rmdirSync(lock); } catch {}
  }
}

function backupFile(file, backupTo) {
  mkdirSync(backupTo, { recursive: true });
  const backup = path.join(backupTo, `${tildify(file).replace(/^~\//, "").replace(/\//g, "_")}-${stamp()}`);
  copyFileSync(file, backup);
  chmodSync(backup, 0o600);
  return backup;
}

function atomicWrite(file, text) {
  const mode = statSync(file).mode & 0o777;
  const tmp = `${file}.ccenv-${process.pid}.tmp`;
  writeFileSync(tmp, text, { mode });
  renameSync(tmp, file);
}

/**
 * 重新生成桌面版的 ant-did 和 ccd-ids.json 的 salt。桌面版只在启动时读它们，
 * 运行中改了会被忽略甚至被写回，所以调用方要先确认桌面版已退出。
 */
export function regenerateDesktopIds({ dir = desktopDir(), backupTo = backupDir(), gen = randomUUID } = {}) {
  const results = [];
  const did = path.join(dir, "ant-did");
  if (existsSync(did)) {
    const raw = readFileSync(did, "utf8");
    if (decodeAntDid(raw) != null) {
      const backup = backupFile(did, backupTo);
      const next = Buffer.from(gen(), "utf8").toString("base64");
      atomicWrite(did, next);
      results.push({ file: did, changes: [{ key: "ant-did", before: raw.trim(), after: next }], backup });
    }
  }
  const ids = path.join(dir, "ccd-ids.json");
  const cfg = existsSync(ids) ? readJson(ids) : null;
  if (cfg && typeof cfg === "object" && typeof cfg.salt === "string") {
    const backup = backupFile(ids, backupTo);
    const next = gen();
    atomicWrite(ids, JSON.stringify({ ...cfg, salt: next })); // 和桌面版自己的写法一致
    results.push({ file: ids, changes: [{ key: "salt", before: cfg.salt, after: next }], backup });
  }
  return results;
}

/** 重新生成所有 Claude Code 配置里的随机标识。每个文件先备份到 ~/.ccenv/backups。 */
export function regenerateIds({ files = claudeCodeConfigPaths(), keys = RESETTABLE_KEYS, backupTo = backupDir() } = {}) {
  const results = [];
  for (const file of files) {
    const res = withConfigLock(file, () => {
      const text = readFileSync(file, "utf8");
      const { text: next, changes } = regenerateInText(text, keys);
      if (!changes.length) return { file, changes, backup: null };
      const backup = backupFile(file, backupTo);
      atomicWrite(file, next);
      return { file, changes, backup };
    });
    results.push(res);
  }
  return results;
}
