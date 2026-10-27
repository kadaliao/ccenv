import SwiftUI
import CCEnvCore

// MARK: - Claude 指纹页

struct FingerprintView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                header
                if let baseline = model.baseline { compareBar(baseline) }
                if let fp = model.fingerprint {
                    let diff = model.diffRows
                    ForEach(fp.groups, id: \.self) { group in
                        FingerprintGroupCard(
                            group: group,
                            items: fp.items.filter { $0.group == group },
                            removed: model.removedItems.filter { $0.group == group },
                            diff: diff,
                            comparing: model.baseline != nil
                        )
                    }
                    let orphanGroups = Set(model.removedItems.map(\.group)).subtracting(fp.groups).sorted()
                    ForEach(orphanGroups, id: \.self) { group in
                        FingerprintGroupCard(group: group, items: [], removed: model.removedItems.filter { $0.group == group }, diff: diff, comparing: true)
                    }
                } else {
                    ProgressView().frame(maxWidth: .infinity).padding(40)
                }
                footer
            }
            .padding(24)
            .frame(maxWidth: 1080)
            .frame(maxWidth: .infinity)
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .task { if model.fingerprint == nil { model.refreshFingerprint() } }
        .confirmationDialog(
            "重新生成 Claude Code 的随机 ID？",
            isPresented: Binding(get: { model.regenerateConfirm != nil }, set: { if !$0 { model.regenerateConfirm = nil } }),
            titleVisibility: .visible
        ) {
            Button("重新生成", role: .destructive) { model.regenerateIds() }
            Button("取消", role: .cancel) {}
        } message: {
            Text(regenerateMessage)
        }
    }

    private var regenerateMessage: String {
        var lines = ["会把 userID / machineID 换成新的随机值，和 Claude Code 首次运行时生成的格式一样。改之前会自动存一份快照并备份原文件到 ~/.ccenv/backups，改完直接显示前后对比。",
                     "账号 UUID、邮箱、硬件 UUID 不会变。"]
        if let n = model.regenerateConfirm, n > 0 {
            lines.append("现在有 \(n) 个 Claude Code 进程在运行，它们内存里还是旧 ID，建议先退出，改完再重启。")
        }
        return lines.joined(separator: "\n\n")
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 18) {
            ZStack {
                Circle().fill(Color.accentColor.opacity(0.15)).frame(width: 64, height: 64)
                Image(systemName: "touchid")
                    .font(.system(size: 30, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
                    .symbolEffect(.pulse, isActive: model.fingerprintBusy)
            }
            VStack(alignment: .leading, spacing: 6) {
                Text("Claude 本机指纹")
                    .font(.system(size: 28, weight: .bold, design: .rounded))
                Text("Claude Code 和桌面版在这台 Mac 上留下的标识。存一份快照，改动之后可以逐项对比。")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                if let fp = model.fingerprint {
                    HStack(spacing: 8) {
                        Text("\(fp.items.count) 项")
                        Text("· \(fp.items.filter(\.resettable).count) 项可重新生成")
                        Text("· \(model.recentSnapshots.count) 份快照")
                        if let date = ISO8601DateFormatter.withFraction.date(from: fp.generatedAt) {
                            Text("· \(date.formatted(date: .omitted, time: .standard)) 读取")
                        }
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.top, 2)
                }
            }
            Spacer()
            if model.fingerprintBusy { ProgressView() }
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.accentColor.opacity(0.06), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Color.accentColor.opacity(0.2), lineWidth: 1))
    }

    private func compareBar(_ baseline: AppModel.Baseline) -> some View {
        let rows = model.diffRows.values
        let count = { (s: DiffStatus) in rows.filter { $0.status == s }.count }
        let removed = model.removedItems.count
        return HStack(spacing: 10) {
            Image(systemName: "arrow.left.arrow.right").foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 3) {
                Text("对比 \(baseline.name)").font(.callout.weight(.medium))
                HStack(spacing: 10) {
                    DiffCount(n: count(.changed), text: "变化", status: .changed)
                    DiffCount(n: count(.added), text: "新增", status: .added)
                    DiffCount(n: removed, text: "消失", status: .removed)
                    Text("\(count(.same)) 项未变").foregroundStyle(.secondary)
                    if let d = ISO8601DateFormatter.withFraction.date(from: baseline.fp.generatedAt) {
                        Text("· 快照时间 \(d.formatted(date: .abbreviated, time: .standard))").foregroundStyle(.tertiary)
                    }
                }
                .font(.caption)
            }
            Spacer()
            Button("结束对比") { model.clearBaseline() }
                .controlSize(.small)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(.quaternary, lineWidth: 1))
    }

    private var footer: some View {
        HStack(spacing: 6) {
            Image(systemName: "lock.shield").foregroundStyle(.tertiary)
            Text("只读取上面列出的标识字段，不读令牌、会话和项目数据，也不上传任何内容。快照存在 ~/.ccenv/fingerprints，和命令行 ccenv fingerprint 共用。")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .padding(.top, 4)
    }
}

struct DiffCount: View {
    var n: Int
    var text: String
    var status: DiffStatus
    var body: some View {
        HStack(spacing: 4) {
            Circle().fill(n > 0 ? status.color : Color.secondary.opacity(0.4)).frame(width: 7, height: 7)
            Text("\(n) \(text)").foregroundStyle(n > 0 ? .primary : .secondary)
        }
    }
}

struct FingerprintGroupCard: View {
    @Environment(AppModel.self) private var model
    var group: String
    var items: [FingerprintItem]
    var removed: [FingerprintItem]
    var diff: [String: FingerprintDiffRow]
    var comparing: Bool

    var body: some View {
        Card(title: group, symbol: symbol) {
            VStack(alignment: .leading, spacing: 0) {
                let rows = items.map { ($0, diff[$0.id]?.status) } + removed.map { ($0, DiffStatus.removed) }
                ForEach(Array(rows.enumerated()), id: \.element.0.id) { i, pair in
                    FingerprintRow(item: pair.0, status: comparing ? pair.1 : nil, before: diff[pair.0.id]?.before)
                    if i < rows.count - 1 { Divider().padding(.vertical, 6) }
                }
            }
        }
    }

    private var symbol: String {
        if group.hasPrefix("Claude Code") { return "terminal" }
        if group.contains("桌面") { return "macwindow" }
        return "cpu"
    }
}

struct FingerprintRow: View {
    @Environment(AppModel.self) private var model
    var item: FingerprintItem
    var status: DiffStatus?
    var before: String?

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(item.label)
                .foregroundStyle(.secondary)
                .frame(width: 140, alignment: .leading)
            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(status == .removed ? "已消失" : item.display(reveal: model.reveal))
                        .font(.body.monospaced())
                        .foregroundStyle(status == .removed ? .secondary : .primary)
                        .strikethrough(status == .removed)
                        .textSelection(.enabled)
                        .lineLimit(model.reveal ? nil : 1)
                    if item.resettable { Pill(text: "可重新生成", color: .accentColor) }
                }
                if status == .changed {
                    Text("之前 " + Fingerprints.mask(before, masked: item.masked && !model.reveal, sensitive: item.sensitive && !model.reveal))
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                } else if status == .removed {
                    Text("之前 " + item.display(reveal: model.reveal))
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                }
                Text([item.source, item.note].compactMap { $0 }.joined(separator: " · "))
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            Spacer(minLength: 8)
            if let status, status != .same {
                Pill(text: status.text, color: status.color)
            }
            if status != .removed {
                Button {
                    model.copyValue(item)
                } label: {
                    Image(systemName: "doc.on.doc")
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
                .help("复制完整值")
            }
        }
        .font(.callout)
    }
}

extension DiffStatus {
    var text: String {
        switch self {
        case .same: return "未变"
        case .changed: return "已变化"
        case .added: return "新增"
        case .removed: return "消失"
        }
    }

    var color: Color {
        switch self {
        case .same: return .secondary
        case .changed: return .orange
        case .added: return .green
        case .removed: return .red
        }
    }
}

extension ISO8601DateFormatter {
    static let withFraction: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
}

// MARK: - 指纹页工具栏

struct FingerprintToolbar: ToolbarContent {
    @Environment(AppModel.self) private var model

    var body: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            Button {
                model.refreshFingerprint()
            } label: {
                Label("刷新", systemImage: "arrow.clockwise")
            }
            .labelStyle(.titleAndIcon)
            .help("重新读取")
            .disabled(model.fingerprintBusy)

            Toggle(isOn: Binding(get: { model.reveal }, set: { model.reveal = $0 })) {
                Label(model.reveal ? "隐藏完整值" : "显示完整值", systemImage: model.reveal ? "eye.slash" : "eye")
            }
            .help("默认打码，只显示头尾几位")

            Menu {
                Button("存为快照", systemImage: "camera") { model.saveSnapshot() }
                Button("导出到文件…", systemImage: "square.and.arrow.up") { model.exportFingerprint() }
                Divider()
                if !model.recentSnapshots.isEmpty {
                    Section("和快照对比") {
                        ForEach(model.recentSnapshots, id: \.self) { url in
                            Button(url.deletingPathExtension().lastPathComponent.replacingOccurrences(of: "fingerprint-", with: "")) {
                                model.compare(with: url)
                            }
                        }
                    }
                }
                Button("从文件选择快照对比…", systemImage: "folder") { model.pickSnapshotToCompare() }
                if model.baseline != nil {
                    Button("结束对比", systemImage: "xmark") { model.clearBaseline() }
                }
            } label: {
                Label("快照", systemImage: "camera")
            }
            .help("存快照 / 导出 / 对比")
            .disabled(model.fingerprint == nil)

            Button {
                model.askRegenerate()
            } label: {
                Label("重新生成 ID", systemImage: "arrow.triangle.2.circlepath")
            }
            .help("重新生成 Claude Code 的 userID / machineID")
            .disabled(model.fingerprintBusy || !(model.fingerprint?.hasResettable ?? false))
        }
    }
}

// MARK: - 更新横幅

struct UpdateBanner: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let u = model.updater
        Group {
            switch u.state {
            case .available(let r):
                bar(symbol: "arrow.down.circle.fill", color: .accentColor, text: "发现新版本 \(r.version)（当前 \(u.currentVersion)）", release: r) {
                    Button("下载并安装") { u.downloadAndInstall() }
                        .controlSize(.small)
                        .buttonStyle(.borderedProminent)
                }
            case .downloading(let r):
                bar(symbol: "arrow.down.circle", color: .accentColor, text: "正在下载 \(r.version)…", release: r) {
                    ProgressView().controlSize(.small)
                }
            case .ready(let r, _):
                bar(symbol: "checkmark.circle.fill", color: .green, text: "新版本 \(r.version) 已下载并通过签名校验，退出时自动安装", release: r) {
                    Button("立即重启") { u.installNow() }
                        .controlSize(.small)
                        .buttonStyle(.borderedProminent)
                }
            case .failed(let msg):
                bar(symbol: "exclamationmark.triangle.fill", color: .orange, text: msg, release: nil) {
                    Button("Releases 页面") {
                        NSWorkspace.shared.open(URL(string: "https://github.com/\(UpdateCheck.repo)/releases/latest")!)
                    }
                    .controlSize(.small)
                    Button { u.dismissFailure() } label: { Image(systemName: "xmark") }
                        .buttonStyle(.borderless)
                }
            default:
                EmptyView()
            }
        }
        .animation(.snappy, value: u.state)
    }

    private func bar<Trailing: View>(symbol: String, color: Color, text: String, release: ReleaseInfo?, @ViewBuilder trailing: () -> Trailing) -> some View {
        HStack(spacing: 10) {
            Image(systemName: symbol).foregroundStyle(color)
            Text(text).font(.callout)
            if let release {
                Link("更新说明", destination: release.htmlURL).font(.callout)
            }
            Spacer()
            trailing()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 9)
        .background(color.opacity(0.08))
        .overlay(alignment: .bottom) { Divider() }
        .transition(.move(edge: .top).combined(with: .opacity))
    }
}
