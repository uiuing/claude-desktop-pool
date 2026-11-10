import AppKit
import SwiftUI
import PoolCore

/// What the replies Pool served used: tokens, what they would cost at API list prices, and the cache
/// that kept that down, by model, plan and account. The page reads one summary the model computes once
/// per change; the chart and sparklines are Canvas drawings, and the account list is lazy and paged,
/// so a pool of a hundred accounts over a year stays light.
struct UsagePage: View {
    @Bindable var model: PoolAppModel
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if model.usage.isEmpty {
                emptyState
            } else {
                let summary = model.usageSummary
                UsageFilterBar(model: model)
                UsageKPIs(model: model, summary: summary)
                UsageTrend(model: model, summary: summary)
                UsageModels(model: model, summary: summary)
                UsageCache(model: model, totals: summary.totals)
                UsageAccounts(model: model, summary: summary)
                Text(model.t("Cost is estimated at Anthropic API list prices ({0}). Subscriptions are not charged per token.", ModelPricing.asOf))
                    .font(.system(size: 10)).foregroundStyle(.secondary).frame(maxWidth: .infinity).multilineTextAlignment(.center)
            }
        }
    }
    private var emptyState: some View {
        PoolCard(padding: 28) {
            VStack(spacing: 9) {
                Image(systemName: "chart.bar.xaxis").font(.system(size: 26, weight: .light)).foregroundStyle(PoolPalette.accent)
                Text(model.t("No usage yet")).font(.system(size: 13, weight: .semibold))
                Text(model.t("Each reply Pool serves adds its tokens and estimated cost here, by model, plan and account."))
                    .font(.system(size: 11)).foregroundStyle(.secondary).multilineTextAlignment(.center)
            }.frame(maxWidth: .infinity)
        }
    }
}

extension PoolAppModel {
    /// Compact, in the reader's language: 1.23M, 45.6K.
    func tokenText(_ value: Int) -> String {
        value.formatted(.number.notation(.compactName).precision(.significantDigits(1...3)).locale(locale))
    }
    func percentText(_ value: Double) -> String {
        value.formatted(.percent.precision(.fractionLength(value > 0 && value < 0.1 ? 1 : 0)).locale(locale))
    }
    func costText(_ value: Double) -> String {
        if value > 0 && value < 0.01 { return "<" + (0.01).formatted(.currency(code: "USD").locale(locale)) }
        return value.formatted(.currency(code: "USD").precision(.fractionLength(value >= 100 ? 0 : 2)).locale(locale))
    }
    func usageValue(_ tally: TokenTally) -> Double { usageMetric == .cost ? tally.cost : Double(tally.total) }
    func usageValue(_ amount: UsageAmount) -> Double { usageMetric == .cost ? amount.cost : Double(amount.tokens) }
    func usageText(_ value: Double) -> String { usageMetric == .cost ? costText(value) : tokenText(Int(value.rounded())) }
    /// A grid label: whole dollars once the scale allows it.
    func usageAxisText(_ value: Double) -> String {
        guard usageMetric == .cost, value >= 10 || value == 0 else { return usageText(value) }
        return value.formatted(.currency(code: "USD").precision(.fractionLength(0)).locale(locale))
    }
    func usageAccountName(_ id: String) -> String {
        guard let uuid = UUID(uuidString: id), snapshot.accounts.contains(where: { $0.id == uuid }) else { return t("Removed account") }
        return accountName(uuid)
    }
    func usagePlanName(_ plan: String) -> String { plan.isEmpty ? t("Plan not reported") : t(plan) }
    func usageSeriesName(_ share: UsageShare, grouping: UsageGrouping) -> String {
        if share.id == UsageSummary.other {
            switch grouping {
            case .model: return t("Other models")
            case .plan: return t("Other plans")
            case .account: return t("Other accounts")
            }
        }
        switch grouping {
        case .model: return share.name
        case .plan: return usagePlanName(share.id)
        case .account: return usageAccountName(share.id)
        }
    }
    /// The accounts the page is narrowed to, as the filter names them.
    var usageScopeTitle: String {
        guard let ids = usageFilter.accounts else { return t("All accounts") }
        if ids.count == 1, let id = ids.first { return accountName(id) }
        let plans = usagePlans
        let chosen = Set(ids.compactMap { plans[$0] })
        if chosen.count == 1, let plan = chosen.first, Set(plans.filter { $0.value == plan }.keys) == ids {
            return t("All {0}", usagePlanName(plan))
        }
        return t("{0} accounts", "\(ids.count)")
    }
    func toggleUsageAccounts(_ ids: Set<UUID>) {
        usageFilter.accounts = usageFilter.accounts == ids ? nil : ids
    }
}

// MARK: - Colors

private func adaptive(_ light: (CGFloat, CGFloat, CGFloat), _ dark: (CGFloat, CGFloat, CGFloat)) -> Color {
    Color(nsColor: NSColor(name: nil) { appearance in
        let value = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
        return NSColor(red: value.0, green: value.1, blue: value.2, alpha: 1)
    })
}

/// The chart's series colors in order; whatever is folded into "other" is grey.
enum UsagePalette {
    static let colors: [Color] = [
        PoolPalette.accent,
        adaptive((0.30, 0.47, 0.68), (0.49, 0.66, 0.88)),
        adaptive((0.33, 0.55, 0.42), (0.50, 0.75, 0.59)),
        adaptive((0.56, 0.42, 0.66), (0.73, 0.60, 0.84)),
        adaptive((0.24, 0.55, 0.58), (0.45, 0.76, 0.78)),
        adaptive((0.70, 0.52, 0.18), (0.90, 0.72, 0.38)),
    ]
    static let other = Color.secondary.opacity(0.4)
    static func color(index: Int, id: String) -> Color {
        id == UsageSummary.other ? other : colors[index % colors.count]
    }
    static func color(of id: String, in series: [UsageShare]) -> Color? {
        series.firstIndex { $0.id == id }.map { color(index: $0, id: id) }
    }
}

private enum UsageTokenKind: CaseIterable, Identifiable {
    case input, output, cacheRead, fiveMinuteWrite, oneHourWrite
    var id: Self { self }
    var title: String {
        switch self {
        case .input: return "Input"
        case .output: return "Output"
        case .cacheRead: return "Cache read"
        case .fiveMinuteWrite: return "5-min write"
        case .oneHourWrite: return "1-hour write"
        }
    }
    /// What a token of this kind costs against an input token.
    var rate: String {
        switch self {
        case .input: return "1×"
        case .output: return "5×"
        case .cacheRead: return "0.1×"
        case .fiveMinuteWrite: return "1.25×"
        case .oneHourWrite: return "2×"
        }
    }
    var color: Color {
        switch self {
        case .input: return PoolPalette.accent
        case .output: return adaptive((0.47, 0.24, 0.16), (0.98, 0.76, 0.64))
        case .cacheRead: return adaptive((0.89, 0.75, 0.62), (0.58, 0.44, 0.36))
        case .fiveMinuteWrite: return Color.secondary.opacity(0.45)
        case .oneHourWrite: return adaptive((0.45, 0.52, 0.62), (0.56, 0.64, 0.76))
        }
    }
    func value(_ tally: TokenTally) -> Int {
        switch self {
        case .input: return tally.input
        case .output: return tally.output
        case .cacheRead: return tally.cacheRead
        case .fiveMinuteWrite: return tally.fiveMinuteWrites
        case .oneHourWrite: return tally.oneHourWrites
        }
    }
}

// MARK: - Filters

private struct UsageFilterBar: View {
    @Bindable var model: PoolAppModel
    @State private var picking = false
    var body: some View {
        HStack(spacing: 8) {
            Button { picking = true } label: {
                chip(model.usageScopeTitle, symbol: "person.2", active: model.usageFilter.accounts != nil)
            }.buttonStyle(.plain).popover(isPresented: $picking, arrowEdge: .bottom) { UsageAccountPicker(model: model) }
                .accessibilityIdentifier("usage.accountFilter")
            Menu {
                Button(model.t("All models")) { model.usageFilter.model = nil }
                Divider()
                ForEach(model.usage.modelNames.sorted { $0.value < $1.value }, id: \.key) { id, name in
                    Button(name) { model.usageFilter.model = id }
                }
            } label: {
                chip(model.usageFilter.model.flatMap { model.usage.modelNames[$0] } ?? model.t("All models"), symbol: "cpu",
                     active: model.usageFilter.model != nil)
            }.menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize().accessibilityIdentifier("usage.modelFilter")
            if !model.usageFilter.isEmpty {
                Button(model.t("Clear")) { model.usageFilter = .init() }.buttonStyle(.plain)
                    .font(.system(size: 11)).foregroundStyle(PoolPalette.accent).accessibilityIdentifier("usage.clearFilter")
            }
            Spacer(minLength: 4)
            Picker(model.t("Show"), selection: $model.usageMetric) {
                Text(model.t("Tokens")).tag(UsageMetric.tokens)
                Text(model.t("Cost")).tag(UsageMetric.cost)
            }.pickerStyle(.segmented).labelsHidden().controlSize(.small).fixedSize().accessibilityIdentifier("usage.metric")
        }.poolAnimation(PoolMotion.quick, value: model.usageFilter)
    }
    private func chip(_ title: String, symbol: String, active: Bool) -> some View {
        HStack(spacing: 5) {
            Image(systemName: symbol).font(.system(size: 10))
            Text(title).fixedSize(horizontal: true, vertical: false)
            Image(systemName: "chevron.down").font(.system(size: 8, weight: .semibold)).foregroundStyle(.secondary)
        }
        .font(.system(size: 11, weight: .medium)).foregroundStyle(active ? PoolPalette.accent : .primary)
        .padding(.horizontal, 9).padding(.vertical, 5)
        .background(active ? PoolPalette.accent.opacity(0.1) : Color.primary.opacity(0.05), in: Capsule())
        .contentShape(Capsule())
    }
}

/// Every account, idle ones too, searchable, with each plan as a shortcut: the way to narrow a pool of a hundred.
private struct UsageAccountPicker: View {
    @Bindable var model: PoolAppModel
    @State private var query = ""
    var body: some View {
        let plans = Dictionary(grouping: model.snapshot.accounts) { $0.plan ?? "" }.sorted { $0.key < $1.key }
        let matches = model.snapshot.accounts.filter { account in
            query.isEmpty || (account.email ?? "").localizedCaseInsensitiveContains(query) || (account.plan ?? "").localizedCaseInsensitiveContains(query)
        }
        VStack(alignment: .leading, spacing: 8) {
            TextField(model.t("Search accounts"), text: $query).textFieldStyle(.roundedBorder).controlSize(.small)
                .accessibilityIdentifier("usage.accountSearch")
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    option(model.t("All accounts"), detail: "\(model.snapshot.accounts.count)", selected: model.usageFilter.accounts == nil) {
                        model.usageFilter.accounts = nil
                    }
                    if query.isEmpty && plans.count > 1 {
                        heading(model.t("Plans"))
                        ForEach(plans, id: \.key) { plan, accounts in
                            let ids = Set(accounts.map(\.id))
                            option(model.t("All {0}", model.usagePlanName(plan)), detail: "\(accounts.count)", selected: model.usageFilter.accounts == ids) {
                                model.toggleUsageAccounts(ids)
                            }
                        }
                    }
                    heading(model.t("Accounts"))
                    ForEach(matches) { account in
                        option(model.accountName(account.id), detail: account.plan.map { model.t($0) }, selected: model.usageFilter.accounts?.contains(account.id) == true) {
                            var chosen = model.usageFilter.accounts ?? []
                            if chosen.contains(account.id) { chosen.remove(account.id) } else { chosen.insert(account.id) }
                            model.usageFilter.accounts = chosen.isEmpty ? nil : chosen
                        }
                    }
                    if matches.isEmpty {
                        Text(model.t("No matching accounts")).font(.system(size: 11)).foregroundStyle(.secondary).padding(8)
                    }
                }
            }.frame(height: min(320, CGFloat(model.snapshot.accounts.count + plans.count + 4) * 26))
        }.padding(12).frame(width: 290)
    }
    private func heading(_ title: String) -> some View {
        Text(title).font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary).padding(.horizontal, 8).padding(.top, 8).padding(.bottom, 3)
    }
    private func option(_ title: String, detail: String?, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: "checkmark").font(.system(size: 9, weight: .semibold)).opacity(selected ? 1 : 0).frame(width: 12)
                Text(title).fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 4)
                if let detail { Text(detail).foregroundStyle(.tertiary).monospacedDigit() }
            }.font(.system(size: 11)).padding(.horizontal, 8).padding(.vertical, 5)
                .background(selected ? PoolPalette.accent.opacity(0.08) : .clear, in: RoundedRectangle(cornerRadius: 5))
                .contentShape(Rectangle())
        }.buttonStyle(.plain)
    }
}

// MARK: - Headline figures

private struct UsageChange: View {
    let model: PoolAppModel
    let change: Double?
    let range: UsageRange
    var body: some View {
        if let change {
            let flat = abs(change) < 0.005
            HStack(spacing: 2) {
                Image(systemName: flat ? "equal" : change > 0 ? "arrow.up.right" : "arrow.down.right").font(.system(size: 8, weight: .bold))
                Text(model.percentText(abs(change)))
            }.font(.system(size: 10)).foregroundStyle(.secondary).monospacedDigit().fixedSize(horizontal: false, vertical: true).help(comparison)
        } else {
            Text(model.t(range == .all ? "All time" : "No earlier data")).font(.system(size: 10)).foregroundStyle(.tertiary).fixedSize(horizontal: false, vertical: true)
        }
    }
    private var comparison: String {
        switch range {
        case .today: return model.t("vs yesterday by now")
        case .week: return model.t("vs previous 7 days")
        case .month: return model.t("vs previous 30 days")
        case .all: return ""
        }
    }
}

private struct UsageKPIs: View {
    let model: PoolAppModel
    let summary: UsageSummary
    var body: some View {
        let totals = summary.totals
        // Four tiles in one row at every window width: an adaptive grid left an empty cell whenever the
        // width fitted three or five columns.
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8, alignment: .top), count: 4), spacing: 8) {
            tile(model.t("API cost"), model.costText(totals.cost), identifier: "usage.cost") {
                HStack(spacing: 4) {
                    UsageChange(model: model, change: summary.costChange, range: summary.range)
                    if totals.unpriced > 0 {
                        Image(systemName: "exclamationmark.circle").font(.system(size: 9)).foregroundStyle(PoolPalette.amber)
                            .help(model.t("{0} replies of models without a list price are not in the cost.", "\(totals.unpriced)"))
                    }
                }
            }.help(model.t("What these replies would cost on the Anthropic API at list price."))
            tile(model.t("Tokens"), model.tokenText(totals.total), identifier: "usage.total") {
                UsageChange(model: model, change: summary.tokenChange, range: summary.range)
            }
            tile(model.t("Replies"), totals.replies.formatted(.number.locale(model.locale)), identifier: "usage.replies") {
                UsageChange(model: model, change: summary.replyChange, range: summary.range)
            }
            tile(model.t("Cache hits"), totals.cacheHitRate.map(model.percentText) ?? "—", identifier: "usage.cacheRate") {
                Text(totals.cacheSaving > 0.005 ? model.t("Saved {0}", model.costText(totals.cacheSaving)) : model.t("Nothing saved yet"))
                    .font(.system(size: 10)).foregroundStyle(totals.cacheSaving > 0.005 ? PoolPalette.good : .secondary).fixedSize(horizontal: false, vertical: true)
            }.help(model.t("Prompt tokens read from Claude's cache, and what that saved against sending them as input."))
        }
    }
    private func tile<Detail: View>(_ title: String, _ value: String, identifier: String, @ViewBuilder detail: () -> Detail) -> some View {
        PoolCard(padding: 11) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.system(size: 10, weight: .medium)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Text(value).font(.system(size: 19, weight: .semibold, design: .rounded)).monospacedDigit()
                    .lineLimit(1).minimumScaleFactor(0.6)
                detail()
            }
        }.accessibilityElement(children: .combine).accessibilityIdentifier(identifier)
    }
}

// MARK: - Trend

struct UsageChartLayout {
    static let plot: CGFloat = 136, axis: CGFloat = 16, labels: CGFloat = 54
    static var height: CGFloat { plot + axis }
    let origin: CGFloat, slot: CGFloat, bar: CGFloat, count: Int
    init(width: CGFloat, count: Int) {
        self.count = max(1, count)
        origin = Self.labels
        slot = max(0.5, (width - origin) / CGFloat(self.count))
        bar = max(1, min(slot * (count > 60 ? 0.85 : 0.62), 22))
    }
    func x(_ index: Int) -> CGFloat { origin + slot * (CGFloat(index) + 0.5) }
    func index(at x: CGFloat) -> Int? {
        let index = Int(floor((x - origin) / slot))
        return (0..<count).contains(index) ? index : nil
    }
    /// Beside the bar, on whichever side has room.
    func tooltipX(_ index: Int, width: CGFloat, tooltip: CGFloat) -> CGFloat {
        let x = self.x(index)
        return x + 12 + tooltip <= width ? x + 12 : max(0, x - 12 - tooltip)
    }
    /// The smallest 1, 2, 2.5 or 5 times a power of ten at or above `value`, so grid labels read cleanly.
    static func ceiling(_ value: Double) -> Double {
        guard value > 0 else { return 0 }
        let power = pow(10, floor(log10(value)))
        for step in [1, 2, 2.5, 5, 10] where step * power >= value * 0.999 { return step * power }
        return 10 * power
    }
}

private struct UsageTrend: View {
    @Bindable var model: PoolAppModel
    let summary: UsageSummary
    @State private var hovered: Int?
    private static let tooltip: CGFloat = 180
    var body: some View {
        let scale = UsageChartLayout.ceiling(summary.buckets.map { model.usageValue($0.total) }.max() ?? 0)
        PoolCard {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    Text(title).font(.system(size: 12, weight: .semibold))
                    Spacer(minLength: 4)
                    Picker(model.t("Group by"), selection: $model.usageGrouping) {
                        Text(model.t("Model")).tag(UsageGrouping.model)
                        Text(model.t("Plan")).tag(UsageGrouping.plan)
                        Text(model.t("Account")).tag(UsageGrouping.account)
                    }.pickerStyle(.segmented).labelsHidden().controlSize(.small).fixedSize().accessibilityIdentifier("usage.grouping")
                }
                GeometryReader { proxy in
                    let layout = UsageChartLayout(width: proxy.size.width, count: summary.buckets.count)
                    ZStack(alignment: .topLeading) {
                        Canvas { context, size in
                            UsageChartDrawing(model: model, summary: summary, layout: layout, scale: scale, hovered: hovered).draw(&context, size: size)
                        }
                        if let hovered, summary.buckets.indices.contains(hovered) {
                            UsageTooltip(model: model, summary: summary, bucket: summary.buckets[hovered])
                                .frame(width: Self.tooltip)
                                .offset(x: layout.tooltipX(hovered, width: proxy.size.width, tooltip: Self.tooltip), y: 0)
                                .allowsHitTesting(false)
                        }
                    }
                    .contentShape(Rectangle())
                    .onContinuousHover { phase in
                        switch phase {
                        case .active(let point): hovered = layout.index(at: point.x)
                        case .ended: hovered = nil
                        }
                    }
                }
                .frame(height: UsageChartLayout.height)
                .overlay {
                    if summary.totals.total == 0 {
                        Text(model.t("No replies in this period")).font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                }
                .accessibilityElement().accessibilityLabel(title).accessibilityValue(model.usageText(model.usageValue(summary.totals)))
                legend
            }
        }
    }
    private var title: String {
        let hourly = summary.range == .today
        switch model.usageMetric {
        case .tokens: return model.t(hourly ? "Tokens by hour" : "Tokens by day")
        case .cost: return model.t(hourly ? "Cost by hour" : "Cost by day")
        }
    }
    private var legend: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 136), spacing: 10, alignment: .leading)], alignment: .leading, spacing: 5) {
            ForEach(Array(summary.series.enumerated()), id: \.element.id) { index, share in
                HStack(spacing: 4) {
                    Circle().fill(UsagePalette.color(index: index, id: share.id)).frame(width: 6, height: 6)
                    Text(model.usageSeriesName(share, grouping: summary.grouping)).fixedSize(horizontal: false, vertical: true)
                    if share.id == UsageSummary.other { Text(model.t("{0} more", "\(share.trend.first ?? 0)")).foregroundStyle(.tertiary).lineLimit(1).fixedSize() }
                    Text(model.percentText(summary.totals.total > 0 ? Double(share.tally.total) / Double(summary.totals.total) : 0))
                        .foregroundStyle(.tertiary).monospacedDigit()
                }.help(model.usageText(model.usageValue(share.tally)))
            }
        }.font(.system(size: 10)).foregroundStyle(.secondary)
    }
}

@MainActor
private struct UsageChartDrawing {
    let model: PoolAppModel
    let summary: UsageSummary
    let layout: UsageChartLayout
    let scale: Double
    let hovered: Int?
    func draw(_ context: inout GraphicsContext, size: CGSize) {
        let plot = UsageChartLayout.plot, top: CGFloat = 6
        for step in 0...2 {
            let y = top + (plot - top) * (1 - CGFloat(step) / 2)
            var line = Path(); line.move(to: CGPoint(x: layout.origin, y: y)); line.addLine(to: CGPoint(x: size.width, y: y))
            context.stroke(line, with: .color(.primary.opacity(step == 0 ? 0.12 : 0.06)), lineWidth: 1)
            if scale > 0 {
                context.draw(Text(model.usageAxisText(scale * Double(step) / 2)).font(.system(size: 9)).foregroundColor(.secondary),
                             at: CGPoint(x: layout.origin - 6, y: y), anchor: .trailing)
            }
        }
        guard scale > 0 else { return }
        for bucket in summary.buckets {
            let total = model.usageValue(bucket.total)
            guard total > 0 else { continue }
            let height = max(1.5, (plot - top) * CGFloat(total / scale))
            let rect = CGRect(x: layout.x(bucket.id) - layout.bar / 2, y: plot - height, width: layout.bar, height: height)
            var bar = context
            bar.clip(to: Path(roundedRect: rect, cornerRadius: min(3, layout.bar / 3), style: .continuous))
            if let hovered, hovered != bucket.id { bar.opacity = 0.35 }
            var y = plot
            for (index, share) in summary.series.enumerated() {
                let value = bucket.parts[share.id].map { model.usageValue($0) } ?? 0
                guard value > 0 else { continue }
                let part = height * CGFloat(value / total)
                bar.fill(Path(CGRect(x: rect.minX, y: y - part, width: rect.width, height: part + 0.5)),
                         with: .color(UsagePalette.color(index: index, id: share.id)))
                y -= part
            }
        }
        let count = summary.buckets.count
        let marks: [Int] = summary.range == .today ? [0, 6, 12, 18, 23]
            : count <= 7 ? Array(0..<count) : Array(Set([0, count / 4, count / 2, 3 * count / 4, count - 1])).sorted()
        for index in marks where summary.buckets.indices.contains(index) {
            let date = summary.buckets[index].start
            let label = summary.range == .today
                ? date.formatted(.dateTime.hour().locale(model.locale))
                : date.formatted(.dateTime.month(.defaultDigits).day().locale(model.locale))
            let first = index == 0 && count > 7, last = index == count - 1 && count > 7
            let anchor: UnitPoint = first ? .topLeading : last ? .topTrailing : .top
            let x = first ? layout.x(index) - layout.bar / 2 : last ? layout.x(index) + layout.bar / 2 : layout.x(index)
            context.draw(Text(label).font(.system(size: 9)).foregroundColor(.secondary), at: CGPoint(x: x, y: plot + 4), anchor: anchor)
        }
    }
}

private struct UsageTooltip: View {
    let model: PoolAppModel
    let summary: UsageSummary
    let bucket: UsageBucket
    var body: some View {
        let rows: [(index: Int, share: UsageShare, value: Double)] = summary.series.enumerated().compactMap { index, share in
            let value = bucket.parts[share.id].map { model.usageValue($0) } ?? 0
            return value > 0 ? (index, share, value) : nil
        }.sorted { $0.value > $1.value }
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Text(when).foregroundStyle(.secondary)
                Spacer(minLength: 6)
                Text(model.usageText(model.usageValue(bucket.total))).fontWeight(.semibold)
            }
            if !rows.isEmpty {
                Text(model.usageMetric == .tokens ? model.costText(bucket.total.cost) : model.t("{0} tokens", model.tokenText(bucket.total.tokens)))
                    .foregroundStyle(.tertiary)
                Divider()
            }
            ForEach(rows, id: \.share.id) { row in
                HStack(spacing: 5) {
                    Circle().fill(UsagePalette.color(index: row.index, id: row.share.id)).frame(width: 6, height: 6)
                    Text(model.usageSeriesName(row.share, grouping: summary.grouping)).fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 6)
                    Text(model.usageText(row.value))
                }
            }
            if rows.isEmpty { Text(model.t("No replies")).foregroundStyle(.secondary) }
        }
        .font(.system(size: 10)).monospacedDigit().padding(8)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(PoolPalette.line))
        .shadow(color: .black.opacity(0.12), radius: 6, y: 2)
    }
    private var when: String {
        summary.range == .today
            ? bucket.start.formatted(.dateTime.hour().locale(model.locale))
            : bucket.start.formatted(.dateTime.month(.abbreviated).day().weekday(.abbreviated).locale(model.locale))
    }
}

// MARK: - Shared row parts

private struct UsageShareBar: View {
    let fraction: Double
    let color: Color
    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.06))
                Capsule().fill(color).frame(width: max(fraction > 0 ? 3 : 0, proxy.size.width * min(1, fraction)))
            }
        }.frame(height: 4).accessibilityHidden(true)
    }
}

private struct UsageSparkline: View {
    let values: [Int]
    var color: Color = PoolPalette.accent
    var body: some View {
        Canvas { context, size in
            guard values.count > 1, let peak = values.max(), peak > 0 else {
                var base = Path(); base.move(to: CGPoint(x: 0, y: size.height - 1)); base.addLine(to: CGPoint(x: size.width, y: size.height - 1))
                context.stroke(base, with: .color(.primary.opacity(0.1)), lineWidth: 1); return
            }
            var line = Path()
            for (index, value) in values.enumerated() {
                let point = CGPoint(x: size.width * CGFloat(index) / CGFloat(values.count - 1),
                                    y: size.height - 1 - (size.height - 2) * CGFloat(value) / CGFloat(peak))
                if index == 0 { line.move(to: point) } else { line.addLine(to: point) }
            }
            var area = line
            area.addLine(to: CGPoint(x: size.width, y: size.height)); area.addLine(to: CGPoint(x: 0, y: size.height)); area.closeSubpath()
            context.fill(area, with: .color(color.opacity(0.14)))
            context.stroke(line, with: .color(color.opacity(0.85)), style: StrokeStyle(lineWidth: 1.2, lineJoin: .round))
        }.accessibilityHidden(true)
    }
}

private struct UsageTableHeader: View {
    let title: String
    var detail: String?
    let columns: [(String, CGFloat)]
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(title).font(.system(size: 12, weight: .semibold)).foregroundStyle(.primary)
            if let detail { Text(detail).foregroundStyle(.tertiary).fixedSize(horizontal: false, vertical: true) }
            Spacer(minLength: 4)
            ForEach(columns.indices, id: \.self) { index in
                Text(columns[index].0).multilineTextAlignment(.trailing).fixedSize(horizontal: false, vertical: true).frame(width: columns[index].1, alignment: .trailing)
            }
        }.font(.system(size: 10)).foregroundStyle(.secondary).padding(.horizontal, 12).padding(.top, 10).padding(.bottom, 6)
    }
}

// MARK: - Models

private struct UsageModels: View {
    let model: PoolAppModel
    let summary: UsageSummary
    var body: some View {
        let total = model.usageValue(summary.totals)
        PoolCard(padding: 0) {
            VStack(alignment: .leading, spacing: 0) {
                UsageTableHeader(title: model.t("Models"), columns: [(model.t("Replies"), 40), (model.t("Speed"), 68), (model.t("Cache hits"), 48),
                                                                    (model.t("Tokens"), 52), (model.t("Cost"), 58)])
                if summary.models.isEmpty {
                    Text(model.t("No replies in this period")).font(.system(size: 11)).foregroundStyle(.secondary).padding(.horizontal, 12).padding(.bottom, 12)
                }
                ForEach(summary.models) { share in
                    Divider().padding(.leading, 12)
                    row(share, total: total)
                }
            }
        }.accessibilityIdentifier("usage.models")
    }
    private func row(_ share: UsageShare, total: Double) -> some View {
        let value = model.usageValue(share.tally)
        let fraction = total > 0 ? value / total : 0
        let color = summary.grouping == .model ? UsagePalette.color(of: share.id, in: summary.series) ?? UsagePalette.other : PoolPalette.accent.opacity(0.75)
        let selected = model.usageFilter.model == share.id
        return Button { model.usageFilter.model = selected ? nil : share.id } label: {
            HStack(spacing: 8) {
                Circle().fill(color).frame(width: 7, height: 7)
                VStack(alignment: .leading, spacing: 4) {
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: 6) {
                            Text(share.name).font(.system(size: 11, weight: .medium)).lineLimit(1).fixedSize()
                            priceText(share.id)
                        }
                        VStack(alignment: .leading, spacing: 2) {
                            Text(share.name).font(.system(size: 11, weight: .medium)).fixedSize(horizontal: false, vertical: true)
                            priceText(share.id)
                        }
                    }
                    HStack(spacing: 6) {
                        UsageShareBar(fraction: fraction, color: color)
                        Text(model.percentText(fraction)).font(.system(size: 10)).foregroundStyle(.secondary).frame(width: 34, alignment: .trailing)
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
                Text(share.tally.replies.formatted(.number.locale(model.locale))).foregroundStyle(.secondary).frame(width: 40, alignment: .trailing)
                Text(share.tally.tokensPerSecond.map { model.t("{0} tok/s", $0.formatted(.number.precision(.fractionLength($0 < 10 ? 1 : 0)).locale(model.locale))) } ?? "—")
                    .foregroundStyle(.secondary).lineLimit(1).minimumScaleFactor(0.8).frame(width: 68, alignment: .trailing)
                    .help(model.t("Output tokens per second of generation, from replies that reported a time. Tool waits are not counted."))
                Text(share.tally.cacheHitRate.map(model.percentText) ?? "—").foregroundStyle(.secondary).frame(width: 48, alignment: .trailing)
                Text(model.tokenText(share.tally.total)).foregroundStyle(.secondary).frame(width: 52, alignment: .trailing)
                Text(ModelPricing.price(for: share.id) == nil ? "—" : model.costText(share.tally.cost)).fontWeight(.medium).frame(width: 58, alignment: .trailing)
            }
            .font(.system(size: 11)).monospacedDigit().padding(.horizontal, 12).padding(.vertical, 8)
            .background(selected ? PoolPalette.accent.opacity(0.06) : .clear).contentShape(Rectangle())
        }.buttonStyle(.plain).help(model.t(selected ? "Show all models" : "Show only this model"))
            .accessibilityElement(children: .combine)
    }
    @ViewBuilder private func priceText(_ id: String) -> some View {
        if let price = ModelPricing.price(for: id) {
            Text(model.t("{0} in · {1} out /MTok", model.costText(price.input), model.costText(price.output)))
                .font(.system(size: 9)).foregroundStyle(.tertiary).lineLimit(1).fixedSize()
        } else {
            Text(model.t("No list price")).font(.system(size: 9)).foregroundStyle(PoolPalette.amber).fixedSize(horizontal: false, vertical: true)
        }
    }
}

// MARK: - Cache

private struct UsageCache: View {
    let model: PoolAppModel
    let totals: TokenTally
    var body: some View {
        PoolCard {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(model.t("Prompt cache")).font(.system(size: 12, weight: .semibold))
                    Text(totals.cacheHitRate.map { model.t("{0} of prompt read from cache", model.percentText($0)) } ?? "")
                        .font(.system(size: 10)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 4)
                    if totals.cacheSaving > 0.005 {
                        Text(model.t("Saved {0}", model.costText(totals.cacheSaving))).font(.system(size: 11, weight: .medium))
                            .foregroundStyle(PoolPalette.good).monospacedDigit()
                    }
                }
                Canvas { context, size in
                    let parts = UsageTokenKind.allCases.map { ($0, $0.value(totals)) }.filter { $0.1 > 0 }
                    context.clip(to: Path(roundedRect: CGRect(origin: .zero, size: size), cornerRadius: size.height / 2))
                    guard totals.total > 0 else {
                        context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(.primary.opacity(0.065))); return
                    }
                    let gap: CGFloat = 1.5, usable = size.width - gap * CGFloat(parts.count - 1)
                    var x: CGFloat = 0
                    for (kind, value) in parts {
                        let width = max(2, usable * CGFloat(value) / CGFloat(totals.total))
                        context.fill(Path(CGRect(x: x, y: 0, width: width, height: size.height)), with: .color(kind.color))
                        x += width + gap
                    }
                }.frame(height: 8).accessibilityHidden(true)
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 168), spacing: 10, alignment: .leading)], alignment: .leading, spacing: 6) {
                    ForEach(UsageTokenKind.allCases) { kind in
                        HStack(spacing: 4) {
                            Circle().fill(kind.color).frame(width: 6, height: 6)
                            Text(model.t(kind.title)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                            Text(model.tokenText(kind.value(totals))).fontWeight(.medium)
                            Text(kind.rate).foregroundStyle(.tertiary)
                        }.fixedSize(horizontal: false, vertical: true).accessibilityElement(children: .combine)
                    }
                }.font(.system(size: 10)).monospacedDigit()
                Text(model.t("Rates are against input. Pool's sessions keep their cache for an hour, so most writes are 1-hour writes."))
                    .font(.system(size: 10)).foregroundStyle(.tertiary).fixedSize(horizontal: false, vertical: true)
            }
        }.accessibilityIdentifier("usage.cache")
    }
}

// MARK: - Accounts

/// Built for one account or a hundred: plan totals first, then the accounts ranked, searchable and paged.
private struct UsageAccounts: View {
    @Bindable var model: PoolAppModel
    let summary: UsageSummary
    @State private var query = ""
    @State private var order = Order.usage
    @State private var shown = Self.page
    private static let page = 10
    enum Order: Hashable { case usage, replies, cache, name }
    var body: some View {
        let rows = sorted(filtered)
        let total = model.usageValue(summary.totals)
        PoolCard(padding: 0) {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 8) {
                    Text(model.t("Accounts")).font(.system(size: 12, weight: .semibold))
                    Text(countText).font(.system(size: 10)).foregroundStyle(.tertiary).fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 4)
                    Menu {
                        Picker(model.t("Sort by"), selection: $order) {
                            Text(model.t(model.usageMetric == .cost ? "Cost" : "Tokens")).tag(Order.usage)
                            Text(model.t("Replies")).tag(Order.replies)
                            Text(model.t("Cache hits")).tag(Order.cache)
                            Text(model.t("Name")).tag(Order.name)
                        }.pickerStyle(.inline)
                    } label: {
                        Label(model.t("Sort"), systemImage: "arrow.up.arrow.down").font(.system(size: 10)).foregroundStyle(.secondary)
                    }.menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize().accessibilityIdentifier("usage.accountSort")
                }.padding(.horizontal, 12).padding(.top, 10).padding(.bottom, 8)
                if summary.plans.count > 1 { planStrip.padding(.bottom, 8) }
                if summary.accounts.count > 8 {
                    TextField(model.t("Search accounts"), text: $query).textFieldStyle(.roundedBorder).controlSize(.small)
                        .padding(.horizontal, 12).padding(.bottom, 8).accessibilityIdentifier("usage.accountListSearch")
                }
                if rows.isEmpty {
                    Text(model.t(summary.accounts.isEmpty ? "No replies in this period" : "No matching accounts"))
                        .font(.system(size: 11)).foregroundStyle(.secondary).padding(.horizontal, 12).padding(.bottom, 12)
                }
                LazyVStack(spacing: 0) {
                    ForEach(Array(rows.prefix(shown).enumerated()), id: \.element.id) { index, share in
                        Divider().padding(.leading, 12)
                        row(share, rank: index + 1, total: total)
                    }
                }
                if rows.count > shown {
                    Divider().padding(.leading, 12)
                    Button { shown += 25 } label: {
                        Text(rows.count - shown <= 25 ? model.t("Show the other {0}", "\(rows.count - shown)")
                             : model.t("Show {0} more of {1}", "25", "\(rows.count - shown)"))
                            .font(.system(size: 11)).foregroundStyle(PoolPalette.accent).frame(maxWidth: .infinity).padding(.vertical, 8)
                            .contentShape(Rectangle())
                    }.buttonStyle(.plain).accessibilityIdentifier("usage.accounts.more")
                }
            }
        }
        .accessibilityIdentifier("usage.accounts")
        .onChange(of: query) { shown = Self.page }
        .onChange(of: model.usageRange) { shown = Self.page }
    }
    private var countText: String {
        let used = summary.accounts.count
        let scope = model.usageFilter.accounts?.count ?? model.snapshot.accounts.count
        let idle = max(0, scope - summary.accounts.filter { id in UUID(uuidString: id.id).map { uuid in model.snapshot.accounts.contains { $0.id == uuid } } ?? false }.count)
        return idle > 0 ? model.t("{0} used · {1} idle", "\(used)", "\(idle)") : model.t("{0} used", "\(used)")
    }
    private var filtered: [UsageShare] {
        guard !query.isEmpty else { return summary.accounts }
        let accounts = Dictionary(model.snapshot.accounts.map { ($0.id.uuidString, $0) }, uniquingKeysWith: { first, _ in first })
        return summary.accounts.filter { share in
            guard let account = accounts[share.id] else { return false }
            return (account.email ?? "").localizedCaseInsensitiveContains(query) || (account.plan ?? "").localizedCaseInsensitiveContains(query)
        }
    }
    private func sorted(_ shares: [UsageShare]) -> [UsageShare] {
        switch order {
        case .usage: return shares.sorted { model.usageValue($0.tally) > model.usageValue($1.tally) }
        case .replies: return shares.sorted { $0.tally.replies > $1.tally.replies }
        case .cache: return shares.sorted { ($0.tally.cacheHitRate ?? 0) > ($1.tally.cacheHitRate ?? 0) }
        case .name:
            let names = Dictionary(shares.map { ($0.id, model.usageAccountName($0.id)) }, uniquingKeysWith: { first, _ in first })
            return shares.sorted { (names[$0.id] ?? "").localizedStandardCompare(names[$1.id] ?? "") == .orderedAscending }
        }
    }
    /// Each plan's share: with dozens of accounts this is the overview, and a click narrows to the plan.
    private var planStrip: some View {
        let plans = model.usagePlans
        let total = model.usageValue(summary.totals)
        return ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(summary.plans) { plan in
                    let ids = Set(plans.filter { $0.value == plan.id }.keys)
                    let selected = !ids.isEmpty && model.usageFilter.accounts == ids
                    let value = model.usageValue(plan.tally)
                    Button { if !ids.isEmpty { model.toggleUsageAccounts(ids) } } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 4) {
                                Text(model.usagePlanName(plan.id)).font(.system(size: 11, weight: .medium)).fixedSize(horizontal: false, vertical: true)
                                Text("\(ids.count)").font(.system(size: 10)).foregroundStyle(.tertiary)
                            }
                            Text("\(model.usageText(value)) · \(model.percentText(total > 0 ? value / total : 0))")
                                .font(.system(size: 10)).foregroundStyle(.secondary).monospacedDigit()
                        }
                        .padding(.horizontal, 9).padding(.vertical, 6)
                        .background(selected ? PoolPalette.accent.opacity(0.1) : Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 7))
                        .overlay(RoundedRectangle(cornerRadius: 7).stroke(selected ? PoolPalette.accent.opacity(0.4) : .clear))
                        .contentShape(RoundedRectangle(cornerRadius: 7))
                    }.buttonStyle(.plain).help(model.t(selected ? "Show all accounts" : "Show only this plan"))
                }
            }.padding(.horizontal, 12)
        }
    }
    private func row(_ share: UsageShare, rank: Int, total: Double) -> some View {
        let uuid = UUID(uuidString: share.id)
        let selected = uuid.map { model.usageFilter.accounts == [$0] } ?? false
        let value = model.usageValue(share.tally)
        let color = summary.grouping == .account ? UsagePalette.color(of: share.id, in: summary.series) ?? UsagePalette.other : PoolPalette.accent.opacity(0.75)
        let plan = uuid.flatMap { id in model.snapshot.accounts.first { $0.id == id }?.plan }
        return Button { if let uuid { model.toggleUsageAccounts([uuid]) } } label: {
            HStack(spacing: 8) {
                Text("\(rank)").font(.system(size: 10)).foregroundStyle(.tertiary).frame(width: 22, alignment: .trailing)
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 5) {
                        Text(model.usageAccountName(share.id)).font(.system(size: 11, weight: .medium)).fixedSize(horizontal: false, vertical: true)
                        if let plan { Text(model.t(plan)).font(.system(size: 9)).foregroundStyle(.tertiary).fixedSize(horizontal: false, vertical: true) }
                    }
                    HStack(spacing: 6) {
                        UsageShareBar(fraction: total > 0 ? value / total : 0, color: color)
                        Text(model.percentText(total > 0 ? value / total : 0)).font(.system(size: 10)).foregroundStyle(.secondary)
                            .frame(width: 34, alignment: .trailing)
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
                UsageSparkline(values: share.trend, color: summary.grouping == .account ? color : PoolPalette.accent).frame(width: 54, height: 16)
                Text(share.tally.replies.formatted(.number.locale(model.locale))).foregroundStyle(.secondary).frame(width: 40, alignment: .trailing)
                Text(model.usageText(value)).fontWeight(.medium).frame(width: 58, alignment: .trailing)
            }
            .font(.system(size: 11)).monospacedDigit().padding(.horizontal, 12).padding(.vertical, 7)
            .background(selected ? PoolPalette.accent.opacity(0.06) : .clear).contentShape(Rectangle())
        }.buttonStyle(.plain)
            .help(model.t("{0} · {1} · cache hits {2}", model.tokenText(share.tally.total), model.costText(share.tally.cost),
                          share.tally.cacheHitRate.map(model.percentText) ?? "—"))
            .accessibilityElement(children: .combine)
    }
}
