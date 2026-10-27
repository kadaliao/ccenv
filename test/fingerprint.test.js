import { test } from "node:test";
import assert from "node:assert/strict";
import { mkdtempSync, readFileSync, readdirSync, statSync, writeFileSync, existsSync } from "node:fs";
import os from "node:os";
import path from "node:path";

import { claudeCodeItems, diffFingerprints, isClaudeCodeProcess, maskValue, regenerateIds, regenerateInText } from "../src/fingerprint.js";
import { compareVersions } from "../src/update.js";
import { parseArgs } from "../src/cli.js";

const HEX = (c) => c.repeat(64);

test("claudeCodeItems 只取标识字段，随机 ID 标为可重新生成", () => {
  const cfg = {
    userID: HEX("a"),
    machineID: "not-hex",
    firstStartTime: "2026-01-01T00:00:00.000Z",
    oauthAccount: { accountUuid: "u-1", emailAddress: "me@example.com", accessToken: "secret" },
    projects: { "/x": {} },
  };
  const items = claudeCodeItems(cfg, path.join(os.homedir(), ".claude.json"));
  const byKey = Object.fromEntries(items.map((i) => [i.id.split("#")[1], i]));
  assert.equal(byKey.userID.resettable, true);
  assert.equal(byKey.machineID.resettable, false);
  assert.equal(byKey["oauthAccount.emailAddress"].sensitive, true);
  assert.equal(byKey.firstStartTime.masked, false);
  assert.equal(items[0].source, "~/.claude.json");
  assert.ok(!items.some((i) => String(i.value).includes("secret")));
});

test("diffFingerprints 区分未变 / 变化 / 新增 / 消失", () => {
  const a = { items: [{ id: "x", label: "X", group: "g", value: "1" }, { id: "y", label: "Y", group: "g", value: "2" }, { id: "z", label: "Z", group: "g", value: "3" }] };
  const b = { items: [{ id: "x", label: "X", group: "g", value: "1" }, { id: "y", label: "Y", group: "g", value: "9" }, { id: "w", label: "W", group: "g", value: "4" }] };
  const status = Object.fromEntries(diffFingerprints(a, b).map((r) => [r.id, r.status]));
  assert.deepEqual(status, { x: "same", y: "changed", w: "added", z: "removed" });
});

test("maskValue 只给标识打码，邮箱只留首字母和域名", () => {
  assert.equal(maskValue(HEX("b")), "bbbbbbbb…bbbb");
  assert.equal(maskValue("host.local", { masked: false }), "host.local");
  assert.equal(maskValue("me@example.com", { sensitive: true }), "m***@example.com");
  assert.equal(maskValue(null), "—");
});

test("regenerateInText 只换值，保留其它字节和格式", () => {
  const text = `{\n  "numStartups": 3,\n  "userID": "${HEX("a")}",\n  "machineID":"${HEX("b")}",\n  "summonSidKey": "short",\n  "projects": {}\n}\n`;
  let n = 0;
  const { text: out, changes } = regenerateInText(text, undefined, () => HEX(String(++n)));
  assert.deepEqual(changes.map((c) => c.key), ["userID", "machineID"]);
  assert.equal(out, text.replace(HEX("a"), HEX("1")).replace(HEX("b"), HEX("2")));
});

test("regenerateIds 先备份再原子写回，保留权限", () => {
  const dir = mkdtempSync(path.join(os.tmpdir(), "ccenv-fp-"));
  const file = path.join(dir, ".claude.json");
  writeFileSync(file, JSON.stringify({ userID: HEX("c"), machineID: HEX("d") }, null, 2), { mode: 0o600 });
  const [res] = regenerateIds({ files: [file], backupTo: path.join(dir, "bak") });
  const after = JSON.parse(readFileSync(file, "utf8"));
  assert.equal(res.changes.length, 2);
  assert.match(after.userID, /^[0-9a-f]{64}$/);
  assert.notEqual(after.userID, HEX("c"));
  assert.equal(JSON.parse(readFileSync(res.backup, "utf8")).userID, HEX("c"));
  assert.equal(statSync(file).mode & 0o777, 0o600);
  assert.equal(existsSync(`${file}.lock`), false);
  assert.deepEqual(readdirSync(dir).sort(), [".claude.json", "bak"]);
});

test("isClaudeCodeProcess 认得原生版、npm 版和 claude 命令", () => {
  assert.ok(isClaudeCodeProcess("/Users/a/.local/share/claude/versions/2.1.311 --session-id x"));
  assert.ok(isClaudeCodeProcess("node /usr/local/lib/node_modules/@anthropic-ai/claude-code/cli.js"));
  assert.ok(isClaudeCodeProcess("/Users/a/.local/bin/claude daemon run"));
  assert.ok(isClaudeCodeProcess("claude"));
  assert.ok(!isClaudeCodeProcess("/Applications/Claude.app/Contents/MacOS/Claude"));
  assert.ok(!isClaudeCodeProcess("vim claude.md"));
});

test("compareVersions 按数字比较", () => {
  assert.equal(compareVersions("0.10.0", "0.9.9"), 1);
  assert.equal(compareVersions("v1.2.3", "1.2.3"), 0);
  assert.equal(compareVersions("1.2", "1.2.1"), -1);
  assert.equal(compareVersions("1.3.0-beta.1", "1.2.9"), 1);
});

test("parseArgs 支持子命令，子命令专属参数不能乱用", () => {
  assert.equal(parseArgs([]).command, "check");
  assert.deepEqual(
    (({ command, save, diff, reveal }) => ({ command, save, diff, reveal }))(parseArgs(["fp", "--save", "--diff", "latest", "--reveal"])),
    { command: "fingerprint", save: true, diff: "latest", reveal: true },
  );
  assert.equal(parseArgs(["fingerprint", "--save", "out.json"]).save, "out.json");
  assert.equal(parseArgs(["update", "--check"]).checkOnly, true);
  assert.throws(() => parseArgs(["--reset"]), /只能用于/);
  assert.throws(() => parseArgs(["nope"]), /未知命令/);
  assert.throws(() => parseArgs(["fp", "--diff"]), /需要一个快照/);
});
