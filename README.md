# ccenv

ccenv 是一个零依赖的 Node CLI，目前只支持 macOS 环境。它需要 Node 20 以上版本，底层依赖 scutil、defaults、sysctl 等系统原生命令。

这个工具用来采集本机的网络出口、系统时区、区域语言、字体、DNS 和进程架构信息，对比找出这些层面之间互相矛盾的地方，最后输出一份带有具体证据的冲突清单。它只做事实核对，不打综合风险分，也不会判断环境到底像哪个国家。工具不读取任何账号信息，所有比对都在本地跑完，不联网上传数据。

写这堆代码最初是为了搞清楚 [yacuo/check-cc](https://github.com/yacuo/check-cc) 的底层逻辑，后来发现里面有些计分方式会导致同一份证据被重复计算。在这里一条规则只对应一个底层事实。比如系统偏好如果设成了中文，原项目会将其拆成语言、变体等四项各自给分，ccenv 砍掉了这种加权求和，直接找冲突点。字体的处理也做了调整，每台 Mac 都有出厂自带的中文字体，这跟使用者当前在哪个国家无关，所以系统预装的那批字体永远不计入风险。DNS 解析路径也做了严格区分，避免把内网下发的特定域名 split DNS 误报成默认解析器泄漏。

你可以全局 npm link 然后直接用 ccenv 命令，或者用 node 执行入口文件。

```bash
node bin/ccenv.js                 # 完整检测，约 7 秒
node bin/ccenv.js --explain       # 冲突项附带影响和处理说明
node bin/ccenv.js --json          # 结构化输出
node bin/ccenv.js --offline       # 不联网，只查本地层
node bin/ccenv.js --samples 12    # 出口 IP 采样次数，默认 6
node bin/ccenv.js --timeout 5000  # 单次网络超时
node bin/ccenv.js --exit-code     # 有 high 级冲突时退出码 1
node bin/ccenv.js -h              # 帮助；-v 查看版本
```

跑完的输出结构大概如下。冲突等级分 high、medium、low、info、ok 五档，整体结论直接取最高那一档。因为离线或者情报源报错没跑成的规则会单列为跳过项，不当成通过。

```text
出口 IP    198.51.100.24 / 198.51.100.25  (6 次采样)
归属       美国 · Washington · Seattle  (US)
ASN        AS64500 Example Hosting, Inc.
rDNS       mail4.example.com
类型       机房/托管/代理段  置信 high
出口时区   America/Los_Angeles (UTC-07:00)
[HIGH  ] egress-timezone — 出口与系统时区相差超过 5 小时
[MEDIUM] ip-stability — 同一出口池在 2 个 IP 之间轮询
```

目前的 11 条检测规则分了两组。

| 分组 | 规则 ID | 说明 |
| --- | --- | --- |
| consistency | egress-timezone | 出口 IP 的归属时区和当前机器的系统时区差了几个小时。 |
| consistency | egress-locale | 出口所在国家和系统的区域语言设置对应不上。 |
| consistency | ip-stability | 采样窗口内出口 IP 发生了漂移，这里会使用多个回显服务做交叉验证。 |
| consistency | ip-intel-consistency | 几个独立的 GeoIP 源对同一个 IP 的国家或 ASN 结论有分歧。 |
| consistency | tz-layer | TZ 环境变量、/etc/localtime 和 Intl 这三层时区数据不自洽。 |
| consistency | locale-layer | 系统首选语言、AppleLocale 和 Shell LANG 这三层语言设定存在冲突。 |
| consistency | ipv6 | IPv6 出口和 IPv4 出口落在了不同的国家。 |
| consistency | dns-path | 系统默认 DNS 解析路径被代理程序接管了。 |
| consistency | runtime-arch | Node 进程架构与机器实际架构不同，或者正在通过 Rosetta 运行。 |
| profile | ip-kind | 出口属于机房、托管或代理段，命中依据会原样打印出来。 |
| profile | vendor-fonts | 本机安装了整机厂商定制的特定字体。 |

有一些已知的情况需要提前说明。`ip-kind` 的判断完全是启发式的，因为免费接口不返回数据中心标记，这里只能靠已知托管 ASN 名单、组织名关键字以及 rDNS 的形态来推测方向。检测出来的矛盾也不等于真的有风险。跨国办公或者使用了公司共享出口，甚至系统设为中文但人确实在国外，都会合理触发时区或区域规则。另外代码目前只在 macOS 上跑过，Linux 的降级分支没做过测试。网络层连的也全是 ipify、Cloudflare trace、ipwho.is、ipinfo.io 和 ipapi.is 这几个公开接口。

本项目代码全部重写，未包含原项目源码。GitHub 仓库在 kadaliao/ccenv，采用 MIT 许可。