// 字体层：区分「系统预装 CJK」「Office/Windows 系」「整机厂商定制」三桶。对应 CLI 的 src/fonts.js。
// 只有 vendor 桶算地区证据；stock 桶每台 Mac 都有，零信息量。

import Foundation

public enum FontCollector {
    static let fontDirs: [String] = [
        "/System/Library/Fonts",
        "/System/Library/Fonts/Supplemental",
        "/Library/Fonts",
        NSHomeDirectory() + "/Library/Fonts",
    ]

    static let stock: [String] = [
        "^pingfang", "^hiragino\\s*sans\\s*g[bc]", "^hiragino\\s*sans\\s*cns",
        "^stheiti", "^stsong", "^songti", "^kaiti", "^stkaiti", "^yuanti",
        "^libian", "^weibei", "^lingwai", "^baoli", "^xingkai", "^wawati",
        "^hannotate", "^hanzipen", "^apple\\s*ligothic", "^apple\\s*lisung",
        "^ヒラギノ", "^osaka", "^toppan\\s*bunbun",
        "^apple\\s*sd\\s*gothic", "^applegothic", "^nanum", "^malgun",
        "^cjk", "^noto\\s*sans\\s*cjk\\s*(jp|kr)",
    ]

    static let thirdParty: [String] = [
        "^microsoft\\s*yahei", "^msyh", "^simsun", "^simhei", "^simkai",
        "^nsimsun", "^dengxian", "^fangsong", "^microsoft\\s*jhenghei", "^mingliu",
        "^pmingliu", "^dfkai", "^mplus", "^source\\s*han\\s*(sans|serif)",
        "^noto\\s*sans\\s*(sc|tc|hans|hant)", "^noto\\s*serif\\s*(sc|tc|cjk)",
        "^sarasa", "^lxgw", "^wenquanyi", "^wqy", "^ar\\s*pl", "^fandol",
    ]

    static let vendor: [String] = [
        "^misans", "^mi\\s*sans", "^harmonyos\\s*sans", "^harmonyos",
        "^oppo\\s*sans", "^vivo\\s*sans", "^honor\\s*sans", "^alibaba\\s*puhuiti",
        "^alimama", "^hanyi", "^hyqihei", "^fz[a-z]", "^方正", "^汉仪",
        "^wps", "^kingsoft", "^xiaomi", "^redmi", "^huawei", "^flyme",
        "^coloros", "^originsans", "^meizu", "^smartisan",
    ]

    public enum Bucket { case stock, thirdParty, vendor }

    public static func bucket(of filename: String) -> Bucket? {
        if stock.contains(where: { Rx.test($0, filename) }) { return .stock }
        if thirdParty.contains(where: { Rx.test($0, filename) }) { return .thirdParty }
        if vendor.contains(where: { Rx.test($0, filename) }) { return .vendor }
        return nil
    }

    static func scan(_ dir: String) -> [String] {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: dir) else { return [] }
        return names.filter { Rx.test("\\.(ttf|otf|ttc|otc|dfont)$", $0) }
    }

    public static func collect() -> FontFacts {
        var seen = Set<String>()
        var stockFiles: [String] = [], third: [String] = [], vend: [String] = []
        for dir in fontDirs {
            for file in scan(dir) where seen.insert(file).inserted {
                switch bucket(of: file) {
                case .stock: stockFiles.append(file)
                case .thirdParty: third.append(file)
                case .vendor: vend.append(file)
                case nil: break
                }
            }
        }
        return FontFacts(
            scannedFiles: seen.count,
            stock: stockFiles,
            thirdParty: third,
            vendor: vend,
            hasEmoji: seen.contains { $0.range(of: "emoji", options: .caseInsensitive) != nil }
        )
    }
}
