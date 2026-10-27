# ccenv

ccenv 用来回答一个很具体的问题：这台 Mac 的网络出口、系统时区、区域语言、字体、DNS、时钟和进程架构这几层画像之间，有没有互相矛盾的地方。它只做事实核对，输出一份带具体证据的冲突清单，不打综合风险分，也不判断环境「像哪个国家」。所有比对都在本地完成，检测本身不读取任何账号信息，网络层只向几个公开的 IP 回显 / GeoIP 接口发请求。

另外附带两个小功能：查看 Claude 在本机留下的标识（「指纹」），可以存快照、前后对比、重新生成 Claude Code 和桌面版的随机 ID；以及 macOS 应用的自动更新。

正式发布的只有 **macOS 应用**：原生 SwiftUI 写的 `ccenv.app`，不需要装 Node，打开就跑，到 [Releases](https://github.com/kadaliao/ccenv/releases/latest) 下载。仓库里还有一份零依赖的 Node CLI，和应用共用同一套规则，用来做对拍和脚本化检测，只从源码运行，不发 npm 包。

## 为什么重写

最初是为了搞清楚 [yacuo/check-cc](https://github.com/yacuo/check-cc) 的底层逻辑，后来发现它的计分方式会让同一份证据被重复计算。这里换了一种思路：一条规则只对应一个底层事实，规则只给离散等级，结论取最高等级，不做加权求和。几个具体差异：

- 系统语言设成中文，原项目会拆成语言、变体等四项各自给分；这里只问「语言/区域和出口国家对不对得上」。
- 每台 Mac 出厂都带 PingFang、Hiragino、STHeiti 这批中文字体，跟使用者在哪无关，所以预装字体永远不计入风险，只看 MiSans、HarmonyOS Sans 这类整机厂商定制字体。
- DNS 严格区分默认解析路径和按域名 / 按接口限定的解析器，公司内网下发的 split DNS 不会被当成泄漏。
- macOS 自带的 utun0~utun3 只有链路本地地址，不算 VPN / 代理隧道；只有拿到了实际地址的隧道接口才算在用。
- 出口 IP 的 v4 和 v6 观测分开统计。双栈机器上 Cloudflare、ipinfo 这类回显会优先回 v6，混进 v4 池会被误判成「跨网段漂移」。

## 命令行

只从源码运行，Node 20 以上，零依赖。不发 npm 包；npm 上的 `ccenv` 是另一个不相关的项目。

```bash
git clone https://github.com/kadaliao/ccenv && cd ccenv
node bin/ccenv.js            # 直接运行
npm link                     # 或者链接成全局的 ccenv 命令，之后 git pull 即更新
```

```bash
ccenv                        # 完整检测，约 4 秒
ccenv --explain              # 每个冲突项附带影响说明和处理建议
ccenv --json                 # 结构化输出（schema 2）
ccenv --offline              # 不联网，只查本地层
ccenv --samples 12           # 出口 IP 采样次数，默认 6
ccenv --timeout 5000         # 单次网络超时，默认 8000 ms
ccenv --exit-code            # 有 high 级冲突时退出码 1，给 CI 用
ccenv -h                     # 帮助；-v 查看版本
```

输出分三块：结论、事实面板、规则清单。

```text
结论  严重冲突   最高等级 high

出口层（真实 IP / ASN）
  出口 IP            198.51.100.24 / 198.51.100.25  (6 次采样)
  归属               美国 · Washington · Seattle  (US)
  ASN                AS64500 Example Hosting, Inc.
  类型               机房/托管/代理段  置信 high
  出口时区           America/Los_Angeles (UTC-07:00)

系统层
  时区               Asia/Singapore (UTC+08:00) ← 与出口不一致
  链路               经代理 apps=[mihomo] tun=[utun5(198.18.0.1)]
  DNS                127.0.0.1 (默认走代理)

一致性冲突（3）
  [HIGH  ] egress-timezone — 出口与系统时区相差超过 5 小时
  [MEDIUM] ip-stability — 同一出口池在 2 个 IP 之间轮询
  [LOW   ] locale-layer — 语言标签不一致：zh / en
```

冲突等级分 high、medium、low、info、ok 五档。离线或情报源失败导致没跑成的规则会单列为跳过项，不算通过。

## Claude 本机指纹

`ccenv fingerprint`（简写 `ccenv fp`）列出 Claude 在这台机器上留下的标识，只读下面这些字段，不读令牌、会话和项目数据：

| 来源 | 字段 |
| --- | --- |
| `~/.claude.json`、`~/.claude/.claude.json`、`$CLAUDE_CONFIG_DIR/.claude.json` | `userID`（遥测 device_id）、`machineID`、`summonSidKey`、首次启动时间和版本、安装方式、账号 / 组织 UUID、账号邮箱 |
| `~/Library/Application Support/Claude/` | 桌面版的 `ant-did`、`ccd-ids.json` 的盐、设备登记过的账号、最近账号 UUID、首次启动时间 |
| `ioreg` | 硬件 UUID（Claude Code 的 OpenTelemetry 拿它当 host.id，只在开启 OTel 时上报）、主机名 |

```bash
ccenv fp                     # 查看，标识默认打码
ccenv fp --reveal            # 显示完整值
ccenv fp --save              # 存快照到 ~/.ccenv/fingerprints/，也可以 --save 指定文件
ccenv fp --diff latest       # 和最近一份快照逐项对比：变化 / 新增 / 消失
ccenv fp --reset             # 重新生成 Claude Code 和桌面版的随机 ID
ccenv fp --json              # 结构化输出，带 --diff 时附上对比结果
```

`--reset` 只改首次运行时随机生成、文件缺失时会自动重建的标识，换成同样格式的新随机值：

- Claude Code 的 `userID`、`machineID`、`summonSidKey`（64 位十六进制）。只替换值，其它字节原样保留；写入时拿和 Claude Code 相同的配置锁（`<文件>.lock`）。正在运行的 Claude Code 内存里还是旧 ID，重启后才用新的。
- 桌面版的 `ant-did`（base64 编码的随机 UUID）和 `ccd-ids.json` 的 `salt`。桌面版只在启动时读它们，所以只在桌面版退出时改：命令行遇到桌面版在运行会跳过这两项；应用里可以选「退出桌面版并全部重新生成」，改完自动重新打开桌面版。

动手前会自动存一份快照、把原文件备份到 `~/.ccenv/backups/`，完成后直接显示前后对比；要恢复，把备份拷回原处即可。账号 UUID、邮箱、硬件 UUID 不在重新生成范围内；桌面版的设备登记背后是钥匙串 / Secure Enclave 里的硬件密钥，是把这台 Mac 和账号绑定的安全凭据，也不碰。

快照是带 `kind: "fingerprint"` 的 JSON，命令行和 macOS 应用存的格式相同，可以互相对比。快照里是完整值，文件权限 600。

## macOS 应用

直接下载：到 [Releases](https://github.com/kadaliao/ccenv/releases/latest) 拿 `ccenv-<版本>.dmg`，打开后把 ccenv 拖进 Applications。dmg 用 Developer ID 签名并经过 Apple 公证，双击即可打开。最低支持 macOS 14。

界面是一个窗口：顶部是结论横幅，中间两张卡片分别是出口层和系统层的事实，下面是按等级排好的冲突清单，点开任意一条能看证据、影响和处理建议。工具栏可以重新检测（⌘R）、复制文本报告 / JSON、导出 JSON 文件，选项里能切换离线模式、采样次数和超时。「分享 › 分享图片」会生成一张结论卡片，只列结论和每个问题的一句话摘要，不含 IP、ASN、DNS 这些细节，可以复制、存成 PNG、走系统分享，或者直接拖进聊天窗口。深色模式自动适配。

工具栏左边切换「环境检测」和「Claude 指纹」两页（⌘1 / ⌘2）。指纹页能显示 / 隐藏完整值、单项复制、存快照、导出到文件、选一份快照对比（变化项标出旧值），以及「重新生成 ID」：确认框会说明要改哪些 ID、有几个 Claude Code 进程在运行；桌面版在运行时可以选择先退出它再一起重新生成。工具栏按钮和图标悬停都有说明。

更新：启动时（每 20 小时最多一次）查 GitHub Releases 的最新版本。发现新版本后默认在后台下载 zip，校验是同一个 Developer ID（Team ID、bundle id、版本号都要对得上）签名的包，然后在退出时替换掉当前 app；顶部横幅也可以「立即重启」。「选项」里能关掉自动检查或自动下载，菜单「ccenv › 检查更新…」手动检查。从 dmg 或下载目录直接运行时不会自动替换，要先拖进「应用程序」。

自己构建需要 Xcode 15 以上（Swift 5.9+），不需要 Xcode 工程：

```bash
npm run app                  # 等价于 macos/build.sh，产出 macos/dist/ccenv.app
macos/build.sh --dmg --zip   # 另外打出 dmg 和 zip
open macos/dist/ccenv.app
```

本地构建的 app 是 ad-hoc 签名，没有 quarantine 标记，直接就能打开。推 `v*` 标签会触发 GitHub Actions 跑测试并验证打包；正式发布的 dmg 在本地签名公证后上传，因为证书和公证凭据只在本机：

```bash
xcrun notarytool store-credentials ccenv-notary --apple-id <Apple ID> --team-id <TEAMID>   # 一次性，密码用 App 专用密码
CCENV_SIGN_IDENTITY="Developer ID Application: <Name> (<TEAMID>)" CCENV_NOTARY_PROFILE=ccenv-notary macos/build.sh --dmg --zip
gh release upload v<版本> macos/dist/ccenv-<版本>.dmg macos/dist/ccenv-<版本>-macos.zip --clobber
```

### 两套实现怎么保持一致

`macos/Sources/CCEnvCore` 是 `src/` 的 Swift 移植，文件一一对应（`SystemFacts.swift` ↔ `system.js`，`Rules.swift` ↔ `rules.js`，以此类推），规则 ID、阈值、文案、JSON schema 都相同。改规则时两边一起改，然后跑对拍：

```bash
npm run parity               # 同一台机器上跑 Node 和 Swift，逐条比较规则等级
npm run parity -- --offline  # 只比本地层
npm test                     # Node 单元测试
cd macos && swift test       # Swift 单元测试
```

## 规则

| 分组 | 规则 ID | 看什么 |
| --- | --- | --- |
| consistency | egress-timezone | 出口 IP 的归属时区和系统时区差了几个小时。1 小时内 low，1~5 小时 medium，超过 5 小时 high。 |
| consistency | egress-locale | 出口国家和系统区域 / 语言对不对得上。语言在出口国也常用只算 low。 |
| consistency | ip-stability | 采样窗口内出口 IP 有没有漂移。同 /24 轮询 medium，跨网段 high。 |
| consistency | ip-intel-consistency | 几个独立 GeoIP 源对同一个 IP 的国家或 ASN 有没有分歧。 |
| consistency | clock-skew | 本机时钟和服务器时间戳的偏差。1.5 秒内算一致，超过 5 分钟 high。 |
| consistency | tz-layer | TZ 环境变量、/etc/localtime 和系统解析出的时区三层是否自洽。 |
| consistency | locale-layer | 系统首选语言、AppleLocale 和 Shell LANG 三层是否自洽。 |
| consistency | ipv6 | IPv6 出口和 IPv4 出口是否落在同一个国家。 |
| consistency | dns-path | 默认 DNS 解析路径有没有被代理接管。 |
| consistency | runtime-arch | 进程架构和机器架构是否一致，是否在 Rosetta 下运行。 |
| profile | ip-kind | 出口属于机房 / 托管 / 代理段还是运营商段，命中依据会原样打印。 |
| profile | vendor-fonts | 本机有没有整机厂商定制字体。 |

## 已知限制

`ip-kind` 完全是启发式的。免费接口大多不返回数据中心标记，只能靠已知托管 ASN 名单、组织名关键字和 rDNS 形态推测，有标记时才会直接采信。检测出来的矛盾也不等于真有风险：跨国办公、公司共享出口、系统设中文但人确实在国外，都会合理触发时区或区域规则。代码只在 macOS 上跑过，CLI 在 Linux 上的降级分支没测过。网络层连的是 ipify、Cloudflare trace、ipwho.is、ipinfo.io 和 ipapi.is 这几个公开接口；macOS 应用检查更新时另外访问 api.github.com。

本项目代码全部重写，未包含原项目源码。GitHub 仓库在 kadaliao/ccenv，MIT 许可。
