// CLI 参数解析与帮助文本。拆出来是为了能单独测试。

export const HELP = `ccenv — 环境一致性检测（一致性冲突 + 真实 IP/ASN 查询）

它不回答「你像哪个国家」，而是回答「你的各层画像之间有没有互相矛盾」。

选项:
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

export function parseArgs(argv) {
  const opts = { samples: 6, intervalMs: 350, timeoutMs: 8000, json: false, explain: false, offline: false, exitCode: false };
  for (let i = 0; i < argv.length; i += 1) {
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
