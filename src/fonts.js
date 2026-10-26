// 字体层：区分「系统预装 CJK 字体」和「厂商定制字体」。
//
// 这是 check-cc 最大的误报来源：它的 chineseFonts 名单里包含 Hiragino Sans GB / STHeiti / STSong，
// 而这三个是每台 Mac 出厂自带（跟你在哪个国家、用哪种语言无关），于是任何 Mac 白送 ~16 分。
// 这里显式分三桶：
//   stock    —— 操作系统预装，零信息量，永不作为地区证据
//   thirdParty —— Office/Windows 系移植字体（装了 Office 就有），弱证据
//   vendor   —— 手机/整机厂商定制字体（MiSans/HarmonyOS Sans/OPPO Sans…），强证据

import { readdirSync } from "node:fs";
import os from "node:os";
import path from "node:path";

const FONT_DIRS = [
  "/System/Library/Fonts",
  "/System/Library/Fonts/Supplemental",
  "/Library/Fonts",
  path.join(os.homedir(), "Library/Fonts"),
];

const STOCK_CJK = [
  /^pingfang/i, /^hiragino\s*sans\s*g[bc]/i, /^hiragino\s*sans\s*cns/i,
  /^stheiti/i, /^stsong/i, /^songti/i, /^kaiti/i, /^stkaiti/i, /^yuanti/i,
  /^libian/i, /^weibei/i, /^lingwai/i, /^baoli/i, /^xingkai/i, /^wawati/i,
  /^hannotate/i, /^hanzipen/i, /^apple\s*ligothic/i, /^apple\s*lisung/i,
  /^ヒラギノ/i, /^ヒラギノ丸ゴ/i, /^osaka/i, /^toppan\s*bunbun/i,
  /^apple\s*sd\s*gothic/i, /^applegothic/i, /^nanum/i, /^malgun/i,
  /^cjk/i, /^noto\s*sans\s*cjk\s*(jp|kr)/i,
];

const THIRD_PARTY_CJK = [
  /^microsoft\s*yahei/i, /^msyh/i, /^simsun/i, /^simhei/i, /^simkai/i,
  /^nsimsun/i, /^dengxian/i, /^fangsong/i, /^microsoft\s*jhenghei/i, /^mingliu/i,
  /^pmingliu/i, /^dfkai/i, /^mplus/i, /^source\s*han\s*(sans|serif)/i,
  /^noto\s*sans\s*(sc|tc|hans|hant)/i, /^noto\s*serif\s*(sc|tc|cjk)/i,
  /^sarasa/i, /^lxgw/i, /^wenquanyi/i, /^wqy/i, /^ar\s*pl/i, /^fandol/i,
];

const VENDOR_CJK = [
  /^misans/i, /^mi\s*sans/i, /^harmonyos\s*sans/i, /^harmonyos/i,
  /^oppo\s*sans/i, /^vivo\s*sans/i, /^honor\s*sans/i, /^alibaba\s*puhuiti/i,
  /^alimama/i, /^hanyi/i, /^hyqihei/i, /^fz[a-z]/i, /^方正/i, /^汉仪/i,
  /^wps/i, /^kingsoft/i, /^xiaomi/i, /^redmi/i, /^huawei/i, /^flyme/i,
  /^coloros/i, /^originsans/i, /^meizu/i, /^smartisan/i,
];

function scanDir(dir) {
  try {
    return readdirSync(dir, { withFileTypes: true })
      .filter((d) => d.isFile() && /\.(ttf|otf|ttc|otc|dfont)$/i.test(d.name))
      .map((d) => d.name);
  } catch {
    return [];
  }
}

function bucketOf(filename) {
  if (STOCK_CJK.some((re) => re.test(filename))) return "stock";
  if (THIRD_PARTY_CJK.some((re) => re.test(filename))) return "thirdParty";
  if (VENDOR_CJK.some((re) => re.test(filename))) return "vendor";
  return null;
}

export function collectFonts() {
  const seen = new Set();
  const buckets = { stock: [], thirdParty: [], vendor: [] };

  for (const dir of FONT_DIRS) {
    for (const file of scanDir(dir)) {
      if (seen.has(file)) continue;
      seen.add(file);
      const bucket = bucketOf(file);
      if (bucket) buckets[bucket].push({ file, dir });
    }
  }

  const hasEmoji = [...seen].some((f) => /emoji/i.test(f));

  return {
    scannedFiles: seen.size,
    stock: buckets.stock.map((f) => f.file),
    thirdParty: buckets.thirdParty.map((f) => f.file),
    vendor: buckets.vendor.map((f) => f.file),
    hasEmoji,
    // 只有 vendor 桶算强地区证据；stock 桶仅供展示，绝不参与判定
    cjkPresent: buckets.stock.length + buckets.thirdParty.length + buckets.vendor.length > 0,
  };
}
