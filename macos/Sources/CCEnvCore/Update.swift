// 更新检查：读 GitHub Releases 的 latest，比较版本，挑出 macOS zip 产物。
// 下载、校验签名、替换 bundle 在 app 侧（CCEnv/Updater.swift）。

import Foundation
import Security

public struct ReleaseInfo: Codable, Sendable, Equatable {
    public struct Asset: Codable, Sendable, Equatable {
        public var name: String
        public var browserDownloadURL: URL
        public var size: Int?

        enum CodingKeys: String, CodingKey {
            case name, size
            case browserDownloadURL = "browser_download_url"
        }
    }

    public var tagName: String
    public var htmlURL: URL
    public var body: String?
    public var assets: [Asset]

    enum CodingKeys: String, CodingKey {
        case body, assets
        case tagName = "tag_name"
        case htmlURL = "html_url"
    }

    public var version: String { tagName.hasPrefix("v") ? String(tagName.dropFirst()) : tagName }

    /// build.sh --zip 的产物：ccenv-<版本>-macos.zip。
    public var macZip: Asset? {
        assets.first { $0.name == "ccenv-\(version)-macos.zip" } ?? assets.first { $0.name.hasSuffix("-macos.zip") }
    }
}

public enum UpdateCheck {
    public static let repo = "kadaliao/ccenv"
    public static var latestURL: URL { URL(string: "https://api.github.com/repos/\(repo)/releases/latest")! }

    /// 比较 x.y.z 版本号，忽略 v 前缀和预发布后缀。
    public static func compare(_ a: String, _ b: String) -> ComparisonResult {
        func parse(_ v: String) -> [Int] {
            let core = v.drop(while: { $0 == "v" }).split(whereSeparator: { $0 == "-" || $0 == "+" }).first ?? ""
            return core.split(separator: ".").map { Int($0) ?? 0 }
        }
        let pa = parse(a), pb = parse(b)
        for i in 0..<max(pa.count, pb.count) {
            let x = i < pa.count ? pa[i] : 0
            let y = i < pb.count ? pb[i] : 0
            if x != y { return x < y ? .orderedAscending : .orderedDescending }
        }
        return .orderedSame
    }

    public static func decode(_ data: Data) throws -> ReleaseInfo {
        try JSONDecoder().decode(ReleaseInfo.self, from: data)
    }

    public static func fetchLatest(timeout: TimeInterval = 10) async throws -> ReleaseInfo {
        var req = URLRequest(url: latestURL, timeoutInterval: timeout)
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        req.setValue("ccenv/\(coreVersion) (macOS app; update check)", forHTTPHeaderField: "User-Agent")
        let (data, resp) = try await URLSession.shared.data(for: req)
        if let http = resp as? HTTPURLResponse, http.statusCode != 200 {
            throw NSError(domain: "ccenv.update", code: http.statusCode, userInfo: [NSLocalizedDescriptionKey: "GitHub 返回 HTTP \(http.statusCode)"])
        }
        return try decode(data)
    }
}

public struct UpdateCheckError: LocalizedError {
    public var message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}

extension UpdateCheck {
    /// 校验下载到的 app：Apple 签发的 Developer ID 证书链、指定 Team ID 和 bundle id，以及版本号。
    public static func verify(app: URL, version: String?, bundleID: String, teamID: String) throws {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(app as CFURL, [], &code) == errSecSuccess, let code else { throw UpdateCheckError("读取签名失败") }
        var requirement: SecRequirement?
        let text = "anchor apple generic and identifier \"\(bundleID)\" and certificate leaf[subject.OU] = \"\(teamID)\""
        guard SecRequirementCreateWithString(text as CFString, [], &requirement) == errSecSuccess else { throw UpdateCheckError("签名要求无效") }
        let flags = SecCSFlags(rawValue: kSecCSCheckAllArchitectures | kSecCSStrictValidate | kSecCSCheckNestedCode)
        let status = SecStaticCodeCheckValidity(code, flags, requirement)
        guard status == errSecSuccess else { throw UpdateCheckError("签名校验未通过（\(status)），已放弃这个包") }
        let info = NSDictionary(contentsOf: app.appendingPathComponent("Contents/Info.plist"))
        guard info?["CFBundleIdentifier"] as? String == bundleID else { throw UpdateCheckError("bundle id 不符") }
        if let version, info?["CFBundleShortVersionString"] as? String != version { throw UpdateCheckError("包内版本号和 Release 不一致") }
    }
}
