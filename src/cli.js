// CLI 参数解析与帮助文本。拆出来是为了能单独测试。

export const HELP = `ccenv — 环境一致性检测（一致性冲突 + 真实 IP/ASN 查询）

它不回答「你像哪个国家」，而是回答「你的各层画像之间有没有互相矛盾」。

命令:
  ccenv [选项]                 环境一致性检测（默认）
  ccenv fingerprint [选项]     查看 Claude 在本机留下的标识（别名 fp）
      --reveal                 显示完整值（默认打码）
      --json                   输出结构化 JSON
      --save [文件]            保存快照，默认存到 ~/.ccenv/fingerprints/
      --diff <文件|latest>     和一份快照逐项对比
      --reset                  重新生成 Claude Code 的随机 ID（userID / machineID），先自动存快照和备份
      --yes                    --reset 时跳过确认
  ccenv update [--check]       检查并安装新版本；--check 只检查不安装

检测选项:
  --json               输出结构化 JSON
  --explain            对每个冲突项输出影响说明与处理建议
  --offline            跳过网络层（只检测时区/语言/字体/代理/DNS）
  --samples <n>        出口 IP 采样次数，默认 6
  --interval <ms>      采样间隔，默认 350
  --timeout <ms>       单次网络超时，默认 8000
  --no-color           关闭颜色
  --exit-code          存在 high 级冲突时以退出码 1 结束
  -v, --version        显示版本
  -h, --help           显示帮助

规则（每条只对应一个底层事实，不做加权求和）:
  一致性  出口时区↔系统时区 · 出口国家↔区域语言 · 出口 IP 稳定性 · 多源情报自洽 ·
          本机时钟偏差 · 时区三层 · 语言三层 · IPv6 出口 · DNS 路径 · 运行时架构
  画像    出口 IP 类型（住宅/机房） · 设备厂商定制字体
`;

const COMMANDS = { fingerprint: "fingerprint", fp: "fingerprint", update: "update", check: "check" };

export function parseArgs(argv) {
  const opts = { command: "check", samples: 6, intervalMs: 350, timeoutMs: 8000, json: false, explain: false, offline: false, exitCode: false };
  let start = 0;
  if (argv[0] && !argv[0].startsWith("-")) {
    opts.command = COMMANDS[argv[0]];
    if (!opts.command) throw new Error(`未知命令: ${argv[0]}`);
    start = 1;
  }
  const only = (arg, ...commands) => {
    if (!commands.includes(opts.command)) throw new Error(`${arg} 只能用于 ccenv ${commands.join(" / ")}`);
  };
  for (let i = start; i < argv.length; i += 1) {
    const arg = argv[i];
    const nextNumber = ({ min, fallback }) => {
      const v = argv[i + 1];
      if (v == null || v.startsWith("-")) throw new Error(`${arg} 缺少取值`);
      i += 1;
      const n = Number(v);
      if (!Number.isFinite(n)) throw new Error(`${arg} 需要一个数字，收到「${v}」`);
      return Math.max(min, Math.floor(n)) || fallback;
    };
    switch (arg) {
      case "--json":
        opts.json = true;
        break;
      case "--explain":
        opts.explain = true;
        break;
      case "--offline":
        opts.offline = true;
        break;
      case "--no-color":
        process.env.NO_COLOR = "1";
        break;
      case "--exit-code":
        opts.exitCode = true;
        break;
      case "--samples":
        opts.samples = nextNumber({ min: 1, fallback: 1 });
        break;
      case "--interval":
        opts.intervalMs = nextNumber({ min: 0, fallback: 0 });
        break;
      case "--timeout":
        opts.timeoutMs = nextNumber({ min: 1000, fallback: 1000 });
        break;
      case "--reveal":
        only(arg, "fingerprint");
        opts.reveal = true;
        break;
      case "--save": {
        only(arg, "fingerprint");
        const v = argv[i + 1];
        opts.save = v && !v.startsWith("-") ? (i += 1, v) : true;
        break;
      }
      case "--diff": {
        only(arg, "fingerprint");
        const v = argv[i + 1];
        if (v == null || v.startsWith("-")) throw new Error("--diff 需要一个快照文件，或 latest");
        opts.diff = v;
        i += 1;
        break;
      }
      case "--reset":
        only(arg, "fingerprint");
        opts.reset = true;
        break;
      case "--yes":
      case "-y":
        opts.yes = true;
        break;
      case "--check":
        only(arg, "update");
        opts.checkOnly = true;
        break;
      case "-v":
      case "--version":
        opts.version = true;
        break;
      case "-h":
      case "--help":
        opts.help = true;
        break;
      default:
        throw new Error(`未知参数: ${arg}`);
    }
  }
  return opts;
}
