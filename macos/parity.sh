#!/bin/sh
# 对拍：同一台机器上跑 Node CLI 和 Swift 引擎，比较每条规则的等级与结论。
# 出口 IP 相关规则（ip-stability）可能因为采样时机不同而不一致，脚本会标出但不算失败。
set -eu
cd "$(dirname "$0")"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

MODE="${1:-}"   # 传 --offline 只比本地层
echo "▸ Node CLI"
node ../bin/ccenv.js --json $MODE > "$TMP/node.json"
echo "▸ Swift engine"
swift build -c release --product ccenv-parity 2>&1 | grep -E 'error' || true
"$(swift build -c release --product ccenv-parity --show-bin-path)/ccenv-parity" $MODE > "$TMP/swift.json"

node - "$TMP/node.json" "$TMP/swift.json" <<'JS'
const fs = require("node:fs");
const [a, b] = process.argv.slice(2).map((p) => JSON.parse(fs.readFileSync(p, "utf8")));
const flaky = new Set(["ip-stability", "clock-skew", "ip-intel-consistency"]);
const byId = (r) => Object.fromEntries(r.rules.map((x) => [x.id, x]));
const A = byId(a), B = byId(b);
let hard = 0, soft = 0;
console.log(`\n${"rule".padEnd(24)} ${"node".padEnd(14)} swift`);
for (const id of Object.keys(A).sort()) {
  const x = A[id], y = B[id];
  const fx = `${x.level}${x.skipped ? "(skip)" : ""}`, fy = y ? `${y.level}${y.skipped ? "(skip)" : ""}` : "缺失";
  const same = y && x.level === y.level && x.skipped === y.skipped;
  const mark = same ? "  " : flaky.has(id) ? "~ " : "✗ ";
  if (!same) flaky.has(id) ? soft++ : hard++;
  console.log(`${mark}${id.padEnd(22)} ${fx.padEnd(14)} ${fy}`);
}
for (const id of Object.keys(B)) if (!A[id]) { hard++; console.log(`✗ ${id.padEnd(22)} 缺失          ${B[id].level}`); }
console.log(`\nverdict  node=${a.verdict.value}/${a.verdict.worst}  swift=${b.verdict.value}/${b.verdict.worst}`);
console.log(`schema   node=${a.schema}  swift=${b.schema}`);
if (hard) { console.log(`\n✗ ${hard} 条规则结论不一致`); process.exit(1); }
console.log(`\n✓ 规则结论一致${soft ? `（${soft} 条网络时序相关的差异已忽略）` : ""}`);
JS
