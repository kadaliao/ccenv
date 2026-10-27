import SwiftUI
import CCEnvCore

struct ContentView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        ZStack(alignment: .bottom) {
            VStack(spacing: 0) {
                UpdateBanner()
                if model.tab == .check {
                    checkContent
                } else {
                    FingerprintView()
                }
            }

            if let toast = model.toast {
                Text(toast)
                    .font(.callout.weight(.medium))
                    .padding(.horizontal, 14)
                    .padding(.vertical, 9)
                    .background(.regularMaterial, in: Capsule())
                    .overlay(Capsule().strokeBorder(.quaternary))
                    .padding(.bottom, 18)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .toolbar { toolbar }
        .sheet(item: Binding(get: { model.shareImage }, set: { model.shareImage = $0 })) { img in
            SharePreviewSheet(share: img).environment(model)
        }
    }

    private var checkContent: some View {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    VerdictHeader()
                    if let report = model.report {
                        FactsGrid(report: report)
                        RulesSections(report: report)
                        footer(report)
                    } else if case .failed(let msg) = model.phase {
                        ContentUnavailableView("检测失败", systemImage: "exclamationmark.triangle", description: Text(msg))
                    }
                }
                .padding(24)
                .frame(maxWidth: 1080)
                .frame(maxWidth: .infinity)
            }
            .background(Color(nsColor: .windowBackgroundColor))
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .principal) {
            @Bindable var m = model
            Picker("页面", selection: $m.tab) {
                ForEach(AppModel.Tab.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .help("⌘1 环境检测 · ⌘2 Claude 指纹")
        }
        if model.tab == .check {
            checkToolbar
        } else {
            FingerprintToolbar()
        }
        ToolbarItem(placement: .primaryAction) { optionsMenu }
    }

    @ToolbarContentBuilder
    private var checkToolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            Button {
                model.run()
            } label: {
                Label("重新检测", systemImage: "arrow.clockwise")
            }
            .labelStyle(.titleAndIcon)
            .help("重新检测 (⌘R)")
            .disabled(model.isRunning)

            Menu {
                Button("分享图片…", systemImage: "photo") { model.presentShareImage() }
                Button("复制图片", systemImage: "photo.on.rectangle") { model.copyImage() }
                Divider()
                Button("复制文本报告", systemImage: "doc.on.doc") { model.copyText() }
                Button("复制 JSON", systemImage: "curlybraces") { model.copyJSON() }
                Divider()
                Button("导出 JSON…", systemImage: "square.and.arrow.up") { model.exportJSON() }
            } label: {
                Label("分享", systemImage: "square.and.arrow.up")
            }
            .help("复制或导出报告")
            .disabled(model.report == nil)
        }
    }

    private var optionsMenu: some View {
            Menu {
                @Bindable var m = model
                @Bindable var u = model.updater
                Toggle("离线模式（只查本地层）", isOn: $m.offline)
                Picker("出口采样次数", selection: $m.samples) {
                    Text("3 次（快）").tag(3)
                    Text("6 次（默认）").tag(6)
                    Text("12 次（更易发现漂移）").tag(12)
                }
                Picker("单次网络超时", selection: $m.timeoutMs) {
                    Text("5 秒").tag(5000)
                    Text("8 秒（默认）").tag(8000)
                    Text("15 秒").tag(15000)
                }
                Divider()
                Toggle("自动检查更新", isOn: $u.autoCheck)
                Toggle("自动下载更新，退出时安装", isOn: $u.autoInstall)
                    .disabled(!u.autoCheck)
                Button("立即检查更新…") { model.checkForUpdates() }
                    .disabled(u.isBusy)
            } label: {
                Label("选项", systemImage: "slider.horizontal.3")
            }
            .help("检测与更新选项")
    }

    private func footer(_ report: Report) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "lock.shield").foregroundStyle(.tertiary)
            Text("ccenv \(report.version) · 所有比对在本地完成，只向公开的 IP 回显服务发请求（检查更新时访问 GitHub），不读取任何账号信息。规则只找跨层矛盾，不给「像哪个国家」打分。")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .padding(.top, 4)
    }
}

// MARK: - 结论

struct VerdictHeader: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(alignment: .center, spacing: 18) {
            iconView
            VStack(alignment: .leading, spacing: 6) {
                Text(title)
                    .font(.system(size: 28, weight: .bold, design: .rounded))
                    .contentTransition(.opacity)
                Text(subtitle)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                if let report = model.report, !model.isRunning {
                    counts(report)
                }
            }
            Spacer()
            if model.isRunning {
                ProgressView().controlSize(.regular)
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(accent.opacity(0.08), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(accent.opacity(0.25), lineWidth: 1))
        .animation(.snappy, value: model.phase)
    }

    private var verdict: Verdict? { model.report?.verdict.value }

    private var accent: Color {
        if model.isRunning && model.report == nil { return .secondary }
        return verdict?.color ?? .secondary
    }

    private var title: String {
        switch model.phase {
        case .running(let stage) where model.report == nil: return stage.text + "…"
        case .failed: return "检测失败"
        default: return verdict?.text ?? "准备检测"
        }
    }

    private var subtitle: String {
        if case .running(let stage) = model.phase {
            return model.report == nil ? "大约需要 4 秒，期间会向多个公开回显服务请求出口 IP。" : "正在重新检测：\(stage.text)…"
        }
        if let v = verdict { return v.subtitle }
        return ""
    }

    @ViewBuilder
    private var iconView: some View {
        ZStack {
            Circle().fill(accent.opacity(0.15)).frame(width: 64, height: 64)
            if let v = verdict, !(model.isRunning && model.report == nil) {
                Image(systemName: v.symbol)
                    .font(.system(size: 30, weight: .semibold))
                    .foregroundStyle(accent)
                    .contentTransition(.symbolEffect(.replace))
            } else {
                Image(systemName: "waveform.path.ecg")
                    .font(.system(size: 28, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .symbolEffect(.pulse, isActive: model.isRunning)
            }
        }
    }

    private func counts(_ report: Report) -> some View {
        HStack(spacing: 8) {
            ForEach([Level.high, .medium, .low], id: \.self) { level in
                let n = report.count(of: level)
                if n > 0 {
                    HStack(spacing: 4) {
                        Circle().fill(level.color).frame(width: 7, height: 7)
                        Text("\(n) \(level.chinese)").font(.caption.weight(.medium))
                    }
                }
            }
            Text("· \(report.passed.count) 通过")
                .font(.caption).foregroundStyle(.secondary)
            if !report.skipped.isEmpty {
                Text("· \(report.skipped.count) 跳过").font(.caption).foregroundStyle(.secondary)
            }
            if let t = model.lastRun {
                Text("· \(t.formatted(date: .omitted, time: .shortened)) 检测")
                    .font(.caption).foregroundStyle(.secondary)
                if report.facts.egress.ok {
                    Text(String(format: "· 用时 %.1f 秒", Double(report.facts.egress.durationMs) / 1000))
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .padding(.top, 2)
    }
}

// MARK: - 事实

struct FactsGrid: View {
    var report: Report

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .top, spacing: 16) {
                EgressCard(report: report)
                SystemCard(report: report)
            }
            VStack(spacing: 16) {
                EgressCard(report: report)
                SystemCard(report: report)
            }
        }
    }
}

struct EgressCard: View {
    var report: Report

    var body: some View {
        let e = report.facts.egress
        Card(title: "出口层", symbol: "globe", trailing: e.primary.map { p in AnyView(kindPill(p.classification)) }) {
            if let p = e.primary, e.ok {
                VStack(alignment: .leading, spacing: 8) {
                    FactRow(label: "出口 IP", value: e.distinctIps.map { $0.ip }.joined(separator: "  /  "), mono: true,
                            hint: e.distinctCount > 1 ? "\(e.sampleCount) 次采样 + \(e.crossEchoes.filter { $0.ip != nil }.count) 个独立回显，观测到 \(e.distinctCount) 个 IP" : "\(e.sampleCount) 次采样与 \(e.crossEchoes.filter { $0.ip != nil }.count) 个独立回显均一致")
                    FactRow(label: "归属", value: "\(flag(p.country)) \(Classifier.regionName(p.country)) · \(p.region ?? "?") · \(p.city ?? "?")",
                            hint: p.countryConsistent ? nil : "情报源不一致：\(p.countries.joined(separator: " / "))")
                    FactRow(label: "ASN", value: "\(p.asn ?? "?")  \(p.isp ?? p.org ?? "")", hint: p.hostname.map { "rDNS \($0)" })
                    FactRow(label: "出口时区", value: "\(p.timezone ?? "?")  \(TimeZoneMath.format(TimeZoneMath.offsetMinutes(for: p.timezone)))", mono: true)
                    FactRow(label: "IPv6", value: e.v6 ?? "无 v6 出口", mono: e.v6 != nil,
                            hint: e.v6Intel.map { "\(flag($0.country)) \(Classifier.regionName($0.country)) \($0.asn ?? "")" })
                    FactRow(label: "情报源", value: p.sources.joined(separator: " · "), hint: String(format: "网络层用时 %.1f 秒", Double(e.durationMs) / 1000))
                }
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    Label(e.error ?? "无法取得出口 IP", systemImage: "wifi.slash")
                        .foregroundStyle(.secondary)
                    Text("网络相关规则会标记为「跳过」，不计入结论。")
                        .font(.caption).foregroundStyle(.tertiary)
                }
            }
        }
    }

    private func kindPill(_ c: Classification) -> some View {
        let color: Color = c.kind == .hosting ? .red : c.kind == .isp ? .green : .orange
        return Pill(text: c.kind.text, color: color)
            .help("置信 \(c.confidence.rawValue)：" + c.basis.joined(separator: "；"))
    }
}

struct SystemCard: View {
    var report: Report

    var body: some View {
        let s = report.facts.system
        let f = report.facts.fonts
        let geoOffset = TimeZoneMath.offsetMinutes(for: report.facts.egress.primary?.timezone)
        let tzMismatch = geoOffset.map { TimeZoneMath.circularMinutes($0, s.timezone.offsetMinutes) >= 120 } ?? false
        Card(title: "系统层", symbol: "desktopcomputer", trailing: AnyView(Pill(text: s.proxy.active ? "经代理" : "直连", color: s.proxy.active ? .green : .secondary))) {
            VStack(alignment: .leading, spacing: 8) {
                FactRow(label: "时区", value: "\(s.timezone.intl ?? "?")  \(s.timezone.offsetLabel)" + (tzMismatch ? "  ← 与出口不一致" : ""), mono: true,
                        hint: "localtime=\(s.timezone.localtimeLink ?? "?") · TZ=\(s.timezone.env ?? "未设")", accent: tzMismatch ? .red : nil)
                FactRow(label: "语言", value: s.locale.appleLanguages.joined(separator: ", ").nilIfEmptyUI ?? s.locale.envRaw ?? "?",
                        hint: "AppleLocale=\(s.locale.appleLocale ?? "?") · Shell LANG=\(s.locale.envRaw ?? "未设置")")
                FactRow(label: "字体", value: "预装 CJK \(f.stock.count) · 三方 \(f.thirdParty.count) · 厂商 \(f.vendor.count)",
                        hint: f.vendor.isEmpty ? "预装字体不计入判定" : f.vendor.prefix(4).joined(separator: ", "))
                FactRow(label: "链路", value: linkText(s.proxy),
                        hint: s.proxy.tunnels.isEmpty ? nil : s.proxy.tunnels.map { "\($0.name) \($0.addrs.first ?? "")" }.joined(separator: " · "))
                FactRow(label: "DNS", value: (s.dns.defaults.joined(separator: ", ").nilIfEmptyUI ?? "无默认解析器") + (s.dns.allThroughProxy ? "  (默认走代理)" : s.dns.defaults.isEmpty ? "" : "  (默认含公网)"), mono: true,
                        hint: s.dns.scoped.isEmpty ? nil : "+ \(s.dns.scoped.count) 个接口级限定解析器", accent: s.dns.defaults.isEmpty || s.dns.allThroughProxy ? nil : .orange)
                FactRow(label: "设备", value: "\(s.hardware.os) · \(s.hardware.chip ?? "?") · \(s.hardware.machineArch)" + (s.hardware.rosetta ? " (Rosetta)" : ""),
                        hint: s.hardware.model)
            }
        }
    }

    private func linkText(_ p: ProxyFacts) -> String {
        var parts: [String] = []
        if !p.apps.isEmpty { parts.append("进程 " + p.apps.joined(separator: ", ")) }
        if !p.tunnels.isEmpty { parts.append("隧道 \(p.tunnels.count) 个") }
        if p.system.https == true || p.system.http == true || p.system.socks == true { parts.append("系统代理开") }
        if !p.env.isEmpty { parts.append("环境变量代理") }
        return parts.isEmpty ? "未发现代理链路" : parts.joined(separator: " · ")
    }
}

extension String {
    var nilIfEmptyUI: String? { isEmpty ? nil : self }
}

// MARK: - 规则

struct RulesSections: View {
    @Environment(AppModel.self) private var model
    var report: Report
    @State private var showPassed = true
    @State private var showSkipped = false

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            ForEach([RuleGroup.consistency, .profile], id: \.self) { group in
                let items = report.conflicts.filter { $0.group == group }
                if !items.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        sectionTitle("\(group.title)", count: items.count, symbol: group == .consistency ? "arrow.left.arrow.right" : "person.crop.rectangle")
                        VStack(spacing: 8) {
                            ForEach(items) { rule in
                                RuleRow(rule: rule, expanded: model.expanded.contains(rule.id)) { model.toggle(rule.id) }
                            }
                        }
                    }
                }
            }

            if report.conflicts.isEmpty {
                Card(title: "没有需要处理的冲突", symbol: "checkmark.seal") {
                    Text("所有可评估的规则都通过了。").foregroundStyle(.secondary)
                }
            }

            compactGroup(title: "通过项", count: report.passed.count, symbol: "checkmark.circle", isOn: $showPassed, rules: report.passed)
            if !report.skipped.isEmpty {
                compactGroup(title: "跳过项", count: report.skipped.count, symbol: "minus.circle", isOn: $showSkipped, rules: report.skipped, note: "离线或情报源失败时跳过，不算通过。")
            }
        }
    }

    private func sectionTitle(_ title: String, count: Int, symbol: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: symbol).foregroundStyle(.secondary)
            Text(title).font(.title3.weight(.semibold))
            Text("\(count)").font(.callout.monospacedDigit()).foregroundStyle(.secondary)
        }
        .padding(.leading, 4)
    }

    private func compactGroup(title: String, count: Int, symbol: String, isOn: Binding<Bool>, rules: [RuleResult], note: String? = nil) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                withAnimation(.snappy(duration: 0.2)) { isOn.wrappedValue.toggle() }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: symbol).foregroundStyle(.secondary)
                    Text(title).font(.title3.weight(.semibold))
                    Text("\(count)").font(.callout.monospacedDigit()).foregroundStyle(.secondary)
                    if let note { Text(note).font(.caption).foregroundStyle(.tertiary) }
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.tertiary)
                        .rotationEffect(.degrees(isOn.wrappedValue ? 90 : 0))
                }
                .padding(.leading, 4)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if isOn.wrappedValue {
                VStack(spacing: 0) {
                    ForEach(Array(rules.enumerated()), id: \.element.id) { i, rule in
                        HStack(alignment: .firstTextBaseline, spacing: 10) {
                            Image(systemName: rule.skipped ? "minus.circle" : "checkmark.circle.fill")
                                .foregroundStyle(rule.skipped ? Color.secondary : Color.green)
                            Text(rule.title).font(.callout)
                            Text(rule.id).font(.caption.monospaced()).foregroundStyle(.tertiary)
                            Spacer()
                            Text(rule.summary).font(.callout).foregroundStyle(.secondary).lineLimit(1).truncationMode(.tail)
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 9)
                        if i < rules.count - 1 { Divider().padding(.leading, 40) }
                    }
                }
                .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(.quaternary, lineWidth: 1))
            }
        }
    }
}

struct RuleRow: View {
    var rule: RuleResult
    var expanded: Bool
    var toggle: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button(action: toggle) {
                HStack(alignment: .top, spacing: 12) {
                    LevelBadge(level: rule.level)
                        .padding(.top, 1)
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text(rule.title).font(.headline)
                            Text(rule.id).font(.caption.monospaced()).foregroundStyle(.tertiary)
                        }
                        Text(rule.summary).font(.callout).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 8)
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.tertiary)
                        .rotationEffect(.degrees(expanded ? 90 : 0))
                        .padding(.top, 4)
                }
                .padding(14)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if expanded {
                Divider().padding(.horizontal, 14)
                VStack(alignment: .leading, spacing: 12) {
                    if !rule.evidence.isEmpty {
                        Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 14, verticalSpacing: 6) {
                            ForEach(rule.evidence, id: \.self) { ev in
                                GridRow {
                                    Text(ev.label).foregroundStyle(.secondary).gridColumnAlignment(.leading)
                                    Text(ev.value).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                                }
                            }
                        }
                        .font(.callout)
                    }
                    VStack(alignment: .leading, spacing: 6) {
                        Label { Text(rule.impact).fixedSize(horizontal: false, vertical: true) } icon: { Image(systemName: "lightbulb") }
                            .foregroundStyle(.secondary)
                        ForEach(rule.fix, id: \.self) { f in
                            Label { Text(f).fixedSize(horizontal: false, vertical: true) } icon: { Image(systemName: "wrench.adjustable") }
                        }
                    }
                    .font(.callout)
                }
                .padding(14)
                .transition(.opacity)
            }
        }
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(rule.level <= .medium ? rule.level.color.opacity(0.35) : Color.clear, lineWidth: 1))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(.quaternary, lineWidth: 1))
    }
}

// MARK: - 分享图片

struct SharePreviewSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let share: ShareImage

    var body: some View {
        // 等比缩放到 400×520 以内，问题再多也一眼看全，不用滚动
        let size = share.image.size
        let scale = min(400 / max(size.width, 1), 520 / max(size.height, 1), 1)
        VStack(spacing: 14) {
            Image(nsImage: share.image)
                .resizable()
                .interpolation(.high)
                .frame(width: size.width * scale, height: size.height * scale)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(.quaternary))
                .onDrag { NSItemProvider(contentsOf: share.fileURL) ?? NSItemProvider() }
                .frame(width: 400)

            Text("图片只含结论和问题摘要，不含 IP 地址。也可以直接把图片拖出去。")
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack {
                Button("完成") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button("存储…") { model.saveShareImage(share) }
                ShareLink(item: share.fileURL, preview: SharePreview("ccenv 检测结果", image: Image(nsImage: share.image))) {
                    Text("分享…")
                }
                Button("复制图片") {
                    model.copyShareImage(share)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
    }
}
