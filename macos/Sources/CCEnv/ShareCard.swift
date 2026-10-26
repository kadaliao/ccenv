// 分享图片：把检测结论渲染成一张固定浅色、固定宽度的卡片。
// 只放结论和问题摘要（短标题 + 一句话），不放 IP、ASN、DNS 等细节，发出去不用再打码。
import AppKit
import SwiftUI
import CCEnvCore

struct ShareCard: View {
    let report: Report
    static let width: CGFloat = 540

    private var verdict: Verdict { report.verdict.value }
    private var tint: Color { verdict.cardTint }
    /// 只上真正的问题；info 级（比如「没有 IPv6 出口」）是说明，不算问题。
    private var problems: [RuleResult] { report.conflicts.filter { $0.level <= .low } }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            brandRow
            card
            footer
        }
        .padding(28)
        .frame(width: Self.width, alignment: .leading)
        .background(background)
        .environment(\.colorScheme, .light)
    }

    private var background: some View {
        ZStack {
            CardPalette.canvas
            LinearGradient(colors: [tint.opacity(0.20), tint.opacity(0.03)], startPoint: .topLeading, endPoint: .bottomTrailing)
        }
    }

    private var brandRow: some View {
        HStack(spacing: 8) {
            BrandMark().frame(width: 22, height: 22)
            Text("ccenv").font(.system(size: 15, weight: .bold, design: .rounded)).foregroundStyle(CardPalette.ink)
            Text("环境一致性检测").font(.system(size: 13)).foregroundStyle(CardPalette.secondary)
            Spacer()
        }
        .padding(.horizontal, 4)
    }

    private var card: some View {
        VStack(alignment: .leading, spacing: 0) {
            header.padding(24)
            ForEach(problems) { rule in
                Rectangle().fill(CardPalette.hairline).frame(height: 1).padding(.horizontal, 24)
                ProblemRow(rule: rule).padding(.horizontal, 24).padding(.vertical, 16)
            }
        }
        .padding(.bottom, problems.isEmpty ? 0 : 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            // 阴影只挂在底板上，挂在整个 VStack 上会漏到里面每个元素
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(Color.white)
                .shadow(color: .black.opacity(0.06), radius: 18, y: 6)
        )
    }

    private var headline: String {
        let passed = "\(report.passed.count) 项检查"
        var parts = problems.isEmpty
            ? [report.skipped.isEmpty ? "\(passed)全部通过" : "\(passed)通过"]
            : ["发现 \(problems.count) 个问题", "\(passed)通过"]
        if !report.skipped.isEmpty { parts.append("\(report.skipped.count) 项跳过") }
        return parts.joined(separator: " · ")
    }

    private var header: some View {
        HStack(spacing: 16) {
            ZStack {
                Circle().fill(tint.opacity(0.13))
                Image(systemName: verdict.symbol)
                    .font(.system(size: 26, weight: .semibold))
                    .foregroundStyle(tint)
            }
            .frame(width: 56, height: 56)
            VStack(alignment: .leading, spacing: 5) {
                Text(verdict.text)
                    .font(.system(size: 28, weight: .bold, design: .rounded))
                    .foregroundStyle(tint)
                Text(headline)
                    .font(.system(size: 14))
                    .foregroundStyle(CardPalette.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if !report.facts.egress.ok {
                    // 离线时「未发现冲突」只代表本地层，要写明，免得被当成全量结论
                    Label("网络层未检测，出口相关规则已跳过", systemImage: "wifi.slash")
                        .font(.system(size: 12))
                        .foregroundStyle(CardPalette.tertiary)
                        .padding(.top, 2)
                }
            }
            Spacer(minLength: 0)
        }
    }

    private var footer: some View {
        HStack {
            Text(report.generatedDate.map { ShareImage.format($0, "yyyy-MM-dd HH:mm") } ?? "")
                .monospacedDigit()
            Spacer()
            Text("github.com/kadaliao/ccenv")
        }
        .font(.system(size: 12))
        .foregroundStyle(CardPalette.secondary)
        .padding(.horizontal, 4)
    }
}

private struct ProblemRow: View {
    let rule: RuleResult

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(rule.level.chinese)
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 26, height: 20)
                .background(rule.level.cardTint, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            VStack(alignment: .leading, spacing: 4) {
                Text(rule.shortTitle)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(CardPalette.ink)
                Text(rule.summary)
                    .font(.system(size: 14))
                    .foregroundStyle(CardPalette.secondary)
                    .lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
    }
}

/// 应用图标的缩小版：三条画像层，中间一条错位，琥珀色点标出矛盾。
private struct BrandMark: View {
    var body: some View {
        Canvas { ctx, size in
            let s = size.width
            let bg = Path(roundedRect: CGRect(origin: .zero, size: size), cornerRadius: s * 0.225, style: .continuous)
            ctx.fill(bg, with: .linearGradient(
                Gradient(colors: [Color(red: 0.11, green: 0.42, blue: 0.62), Color(red: 0.08, green: 0.16, blue: 0.34)]),
                startPoint: .zero, endPoint: CGPoint(x: s, y: s)))
            let barH = s * 0.12, barW = s * 0.46, gap = s * 0.09, shift = s * 0.10
            let top = (s - barH * 3 - gap * 2) / 2
            let x0 = s * 0.13
            for i in 0..<3 {
                let r = CGRect(x: x0 + (i == 1 ? shift : 0), y: top + CGFloat(i) * (barH + gap), width: barW, height: barH)
                ctx.fill(Path(roundedRect: r, cornerRadius: barH / 2), with: .color(.white))
            }
            let dotR = s * 0.07
            let c = CGPoint(x: x0 + shift + barW + s * 0.04 + dotR, y: top + barH + gap + barH / 2)
            ctx.fill(Path(ellipseIn: CGRect(x: c.x - dotR, y: c.y - dotR, width: dotR * 2, height: dotR * 2)),
                     with: .color(Color(red: 1.0, green: 0.68, blue: 0.16)))
        }
    }
}

/// 卡片固定用浅色，不跟随系统外观：图片是给别人看的。
private enum CardPalette {
    static let canvas = Color(red: 0.965, green: 0.969, blue: 0.976)
    static let ink = Color(red: 0.10, green: 0.11, blue: 0.14)
    static let secondary = Color(red: 0.38, green: 0.41, blue: 0.46)
    static let tertiary = Color(red: 0.58, green: 0.61, blue: 0.66)
    static let hairline = Color(red: 0.925, green: 0.93, blue: 0.945)
}

extension Level {
    /// 白底上可读的固定色，不随深浅色变化。
    var cardTint: Color {
        switch self {
        case .high: return Color(red: 0.87, green: 0.22, blue: 0.24)
        case .medium: return Color(red: 0.93, green: 0.49, blue: 0.10)
        case .low: return Color(red: 0.20, green: 0.45, blue: 0.90)
        case .info: return Color(red: 0.55, green: 0.58, blue: 0.62)
        case .ok: return Color(red: 0.16, green: 0.62, blue: 0.38)
        }
    }
}

extension Verdict {
    var cardTint: Color {
        switch self {
        case .severe: return Level.high.cardTint
        case .notable: return Level.medium.cardTint
        case .minor: return Level.low.cardTint
        case .consistent: return Level.ok.cardTint
        }
    }
}

extension RuleResult {
    /// 去掉标题末尾的括号说明：「出口 IP 类型（住宅/运营商 vs 机房/托管）」→「出口 IP 类型」。
    var shortTitle: String {
        guard let i = title.firstIndex(of: "（") else { return title }
        return title[..<i].trimmingCharacters(in: .whitespaces)
    }
}

extension Report {
    var generatedDate: Date? {
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return iso.date(from: generatedAt)
    }
}

/// 渲染好的分享图：预览用的 NSImage、PNG 数据，以及给系统分享 / 拖拽用的临时文件。
struct ShareImage: Identifiable {
    let id = UUID()
    let image: NSImage
    let png: Data
    let fileURL: URL

    var fileName: String { fileURL.lastPathComponent }

    @MainActor
    static func render(_ report: Report) -> ShareImage? {
        let renderer = ImageRenderer(content: ShareCard(report: report))
        renderer.scale = 2 // 540pt → 1080px 宽
        guard let cg = renderer.cgImage else { return nil }
        let rep = NSBitmapImageRep(cgImage: cg)
        rep.size = NSSize(width: CGFloat(cg.width) / renderer.scale, height: CGFloat(cg.height) / renderer.scale)
        guard let png = rep.representation(using: .png, properties: [:]) else { return nil }
        let image = NSImage(size: rep.size)
        image.addRepresentation(rep)

        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ccenv-share", isDirectory: true)
        let stamp = format(report.generatedDate ?? Date(), "yyyyMMdd-HHmm")
        let url = dir.appendingPathComponent("ccenv-\(stamp).png")
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try png.write(to: url, options: .atomic)
        } catch {
            return nil
        }
        return ShareImage(image: image, png: png, fileURL: url)
    }

    static func format(_ date: Date, _ pattern: String) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = pattern
        return f.string(from: date)
    }
}
