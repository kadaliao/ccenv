# ccenv

环境一致性检测 CLI：**逐层取事实 → 跨层找矛盾 → 取最高等级**。

它不回答「你像哪个国家」，也不给一个 0~100 的风险分。它回答的是：**你的各层画像（网络出口 / 系统时区 / 区域语言 / 字体 / DNS / 运行环境）之间，有没有互相矛盾的地方。**

零依赖，纯 Node（≥20），只支持 macOS（依赖 `scutil` / `defaults` / `sysctl` 等系统命令）。

```bash
git clone https://github.com/kadaliao/ccenv.git && cd ccenv
node bin/ccenv.js

# 或安装为全局命令
npm link && ccenv
```

```bash
node bin/ccenv.js                 # 完整检测
node bin/ccenv.js --explain       # 附带每项的「影响」与「处理」建议
node bin/ccenv.js --json          # 结构化输出，给脚本/CI 用
node bin/ccenv.js --offline       # 只查本地，不联网
node bin/ccenv.js --samples 12    # 出口 IP 采样次数（越多越能抓到漂移）
node bin/ccenv.js --exit-code     # 有 high 级冲突时退出码 1
```

也可 `npm link` 后直接用 `ccenv`。

## 为什么重写

这个项目最初是 https://github.com/yacuo/check-cc 的检测逻辑分析产物。原项目的做法是「把 11 个信号各自乘一个手拍权重后相加，超过阈值就算高危」，存在几个结构性问题：

| 原项目问题 | 这里的做法 |
|---|---|
| 只有「像不像中国大陆」一个维度，美国/日本/欧洲出口永远得 0 分 | 判定改为跨层**矛盾**，任何国家都能检测（出口国家 vs 本地时区/语言/DNS） |
| 号称「服务端 IP 情报」，实际 `enabled: false` 且仓库里没有该接口 | 真实查询 3 个 IP 情报源，出口 IP **采样多次**，还能发现出口池轮询 |
| 权重 26/20/16/12… 无来源，阈值 31/70 是拍的 | 不做加权求和；每条规则只输出离散等级，结论取最高等级 |
| `language` / `languageVariant` / `locale` / `timezoneOffset` 测同一个事实却各自加分 | **一条规则只对应一个底层事实**，不重复计权 |
| macOS 预装的 Hiragino Sans GB / STHeiti / STSong 被当成「中国字体」白送 16 分 | 字体分三桶：系统预装（零信息量，永不计分）/ Office 系 / 整机厂商定制（强证据） |
| 号称「信号一致性校验」，代码里只有匹配加分，没有矛盾检测 | 矛盾检测就是本项目的主体 |
| 进度条 `sleep()` 表演、`recommendations()` 死代码、逻辑在 plugin 与 engine 里各写一遍 | 无表演逻辑；每层一个采集模块，每条规则一个函数 |

一个具体数字对比（同一台机器）：

- 原模型：55/100「需要进一步确认」——其中 51 分来自语言和 macOS 自带字库，跟出口 IP 毫无关系
- 本工具：`high` × 2（出口时区差 9 小时、出口属机房段）+ `medium` × 1（出口 IP 池轮询）——每一项都能指出具体证据

## 规则

一致性冲突（`--json` 里 `group: consistency`）：

| id | 检测什么 |
|---|---|
| `egress-timezone` | 出口时区 ↔ 系统时区（差几小时） |
| `egress-locale` | 出口国家 ↔ 系统区域/语言 |
| `ip-stability` | 出口 IP 是否在采样窗口内漂移（含多源交叉验证） |
| `ip-intel-consistency` | 多个 GeoIP 源对同一 IP 的国家/ASN 是否一致 |
| `tz-layer` | `TZ` 环境变量 / `/etc/localtime` / `Intl` 三层是否自洽 |
| `locale-layer` | 系统首选语言 / `AppleLocale` / `Shell LANG` 三层是否自洽 |
| `ipv6` | IPv6 出口是否与 IPv4 出口同国（v6 泄漏） |
| `dns-path` | 默认 DNS 是否被代理接管（区分 split DNS，不算误报） |
| `runtime-arch` | Node 架构 / Rosetta / 机器架构 |

画像风险（`group: profile`）：

| id | 检测什么 |
|---|---|
| `ip-kind` | 出口是住宅/运营商段还是机房/托管/代理段（输出判定依据） |
| `vendor-fonts` | 是否存在整机厂商定制字体（MiSans / HarmonyOS Sans / OPPO Sans…） |

等级：`high` / `medium` / `low` / `info` / `ok`。结论取最高等级，另给出 `skipped` 项说明哪些规则因离线或情报源失败没跑成——**不把「没测」伪装成「通过」**。

## 输出示例（示例数据，非真实出口）

```text
出口层（真实 IP / ASN）
  出口 IP    198.51.100.24 / 198.51.100.25  (6 次采样)
  归属       美国 · Washington · Seattle  (US)
  ASN        AS64500 Example Hosting, Inc.
  rDNS       mail4.example.com
  类型       机房/托管/代理段  置信 high
  出口时区   America/Los_Angeles (UTC-07:00)

[HIGH  ] egress-timezone — 出口与系统时区相差超过 5 小时
    出口时区  America/Los_Angeles (UTC-07:00)
    系统时区  Asia/Singapore (UTC+08:00)
    相差      9 小时 0 分

[MEDIUM] ip-stability — 同一出口池在 2 个 IP 之间轮询，会话中出口会变
    观测到的 IP  198.51.100.24（6 次） / 198.51.100.25（3 次）
    是否同 /24   是（同一出口池轮询）
```

## 已知边界

- **IP 类型判定是启发式的**。ipapi.is / ipinfo 免费层都不返回 `is_datacenter` 之类的字段，所以 `ip-kind` 用的是「已知托管 ASN 名单 + 组织名关键字 + rDNS 形态」，并把命中依据原样打印出来。它会给方向，不给你判决。
- **矛盾 ≠ 风险**。跨国办公、公司共享出口、系统中文但人在国外，都能合理触发 `egress-timezone` / `egress-locale`。这些规则证明的是「画像不自洽」，不是「账号有问题」。
- 不检测账号侧信息（不读 cookie、不读本地配置里的身份、不联网上报任何东西）。
- 网络层只连 ipify / Cloudflare / ipwho.is / ipinfo.io / ipapi.is 这几个公开回显与情报接口。

## 结构

```text
bin/ccenv.js      参数解析 + 编排
src/system.js     时区 / 区域语言 / 硬件 / 代理 / DNS 采集
src/network.js    出口 IP 采样 + 多源情报 + IPv6 探测
src/fonts.js      字体分桶（预装 / 三方 / 厂商）
src/classify.js   ASN 类型归类 + 地区名 + 语言-地区映射
src/rules.js      11 条规则 + 等级聚合
src/report.js     终端渲染 / JSON 输出
```

## 许可与致谢

MIT。代码全部重写，没有复制原项目源码；方法论上的对比对象是 https://github.com/yacuo/check-cc （MIT），
其「信号拆解 + 可解释」的思路值得借鉴，而本项目的重点是把它的加权求和改成矛盾检测、
并把它写死禁用的 IP 情报层真正接上。
