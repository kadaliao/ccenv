import SwiftUI
import CCEnvCore

extension Level {
    var color: Color {
        switch self {
        case .high: return .red
        case .medium: return .orange
        case .low: return .blue
        case .info: return .gray
        case .ok: return .green
        }
    }

    var symbol: String {
        switch self {
        case .high: return "xmark.octagon.fill"
        case .medium: return "exclamationmark.triangle.fill"
        case .low: return "info.circle.fill"
        case .info: return "circle.dotted"
        case .ok: return "checkmark.circle.fill"
        }
    }

    var chinese: String {
        switch self {
        case .high: return "高"
        case .medium: return "中"
        case .low: return "低"
        case .info: return "提示"
        case .ok: return "通过"
        }
    }
}

extension Verdict {
    var color: Color {
        switch self {
        case .severe: return .red
        case .notable: return .orange
        case .minor: return .blue
        case .consistent: return .green
        }
    }

    var symbol: String {
        switch self {
        case .severe: return "xmark.octagon.fill"
        case .notable: return "exclamationmark.triangle.fill"
        case .minor: return "info.circle.fill"
        case .consistent: return "checkmark.seal.fill"
        }
    }

    var subtitle: String {
        switch self {
        case .severe: return "有至少一条高等级矛盾，IP 画像和设备画像指向不同地方。"
        case .notable: return "有中等级矛盾，单独看不致命，叠加起来会降低画像确定性。"
        case .minor: return "只有轻度差异，多数属于常见的个人设置习惯。"
        case .consistent: return "各层事实互相自洽，没有发现跨层矛盾。"
        }
    }
}

/// 国家代码 → 旗帜 emoji（区域指示符）。
func flag(_ code: String?) -> String {
    guard let code, code.count == 2 else { return "" }
    var s = ""
    for u in code.uppercased().unicodeScalars {
        guard let scalar = UnicodeScalar(127397 + u.value) else { return "" }
        s.unicodeScalars.append(scalar)
    }
    return s
}

struct Card<Content: View>: View {
    var title: String
    var symbol: String
    var trailing: AnyView? = nil
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: symbol).foregroundStyle(.secondary)
                Text(title).font(.headline)
                Spacer()
                trailing
            }
            content()
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(.quaternary, lineWidth: 1))
    }
}

struct LevelBadge: View {
    var level: Level
    var compact = false

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: level.symbol).font(.caption2)
            if !compact { Text(level.chinese).font(.caption.weight(.semibold)) }
        }
        .padding(.horizontal, compact ? 5 : 8)
        .padding(.vertical, 4)
        .foregroundStyle(level.color)
        .background(level.color.opacity(0.14), in: Capsule())
        .accessibilityLabel(level.label)
    }
}

struct Pill: View {
    var text: String
    var color: Color = .secondary
    var body: some View {
        Text(text)
            .font(.caption.weight(.medium))
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .foregroundStyle(color)
            .background(color.opacity(0.12), in: Capsule())
    }
}

struct FactRow: View {
    var label: String
    var value: String
    var mono = false
    var hint: String? = nil
    var accent: Color? = nil

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(label)
                .foregroundStyle(.secondary)
                .frame(width: 64, alignment: .leading)
            VStack(alignment: .leading, spacing: 2) {
                Text(value)
                    .font(mono ? .body.monospaced() : .body)
                    .foregroundStyle(accent ?? .primary)
                    .textSelection(.enabled)
                if let hint {
                    Text(hint).font(.caption).foregroundStyle(.tertiary).textSelection(.enabled)
                }
            }
            Spacer(minLength: 0)
        }
        .font(.callout)
    }
}
