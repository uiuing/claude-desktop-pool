import SwiftUI
import PoolCore

struct QuotaOverview: View {
    @Bindable var model: PoolAppModel
    @State private var details: QuotaPoolGroup?
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Text(model.t("Quota left by plan")).font(.system(size: 13, weight: .semibold))
                Spacer(minLength: 0)
                RefreshAllButton(model: model)
            }
            PoolCard(padding: 0) {
                if model.planQuotas.isEmpty {
                    Text(model.t("Quota appears when Claude reports it.")).font(.system(size: 11)).foregroundStyle(.secondary).padding(12)
                } else {
                    VStack(spacing: 0) {
                        ForEach(Array(model.planQuotas.enumerated()), id: \.element.id) { index, plan in
                            if index > 0 { Divider().padding(.horizontal, 12) }
                            planRow(plan).padding(.horizontal, 12).padding(.vertical, 9)
                        }
                    }
                }
            }
        }.popover(item: $details) { group in quotaDetails(group) }
    }
    /// One plan per row: name and usable accounts, then each limit's average left and next reset.
    /// Plans have different capacities, so rows are never added together.
    private func planRow(_ plan: PlanQuota) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(plan.title).font(.system(size: 12, weight: .semibold)).fixedSize(horizontal: false, vertical: true)
                Text(model.t("{0}/{1} usable", "\(plan.usableCount)", "\(plan.accountIDs.count)")).font(.system(size: 11)).foregroundStyle(.secondary)
                    .monospacedDigit()
                Spacer(minLength: 4)
                Group {
                if let back = plan.nextRecovery, plan.usableCount < plan.accountIDs.count {
                    Text(model.t("Next back {0}", model.clockTime(back))).font(.system(size: 11)).foregroundStyle(PoolPalette.amber)
                        .help(model.exactTime(back))
                }
                }.multilineTextAlignment(.trailing).fixedSize(horizontal: false, vertical: true)
            }
            HStack(alignment: .top, spacing: 18) {
                ForEach(plan.windows) { group in quotaCell(group, stacked: plan.windows.count > 2) }
            }
        }
    }
    /// Title, what is left and a bar; the next reset sits beside the title when it fits, under the bar when not.
    private func quotaCell(_ group: QuotaPoolGroup, stacked: Bool) -> some View {
        Button { details = group } label: {
            QuotaLine(title: model.quotaTitle(group.windowID), reset: group.nextResetAt.map { model.t("Resets {0}", model.clockTime($0)) },
                      valueText: group.averageRemainingPercent.map { model.t("{0}% left", "\(Int($0.rounded()))") } ?? model.t("Not read"),
                      value: group.averageRemainingPercent, resetBelow: stacked)
                .contentShape(Rectangle())
        }.buttonStyle(.plain).help(model.t("Quota details")).accessibilityElement(children: .combine)
    }
    private func quotaDetails(_ group: QuotaPoolGroup) -> some View {
        VStack(alignment: .leading, spacing: 11) {
            Text(model.t("Quota details")).font(.system(size: 13, weight: .semibold))
            Text("\(group.plan ?? model.t("Plan not reported")) · \(model.quotaTitle(group.windowID))")
                .font(.system(size: 11)).foregroundStyle(.secondary)
            Text(model.t("{0}/{1} readings current", "\(group.knownCount)", "\(group.knownCount + group.unknownCount)"))
                .font(.system(size: 11))
            if let subtotal = group.remainingUnits {
                Text(model.t("Known subtotal: {0} full account limits", subtotal.formatted(.number.precision(.fractionLength(0...2)).locale(model.locale))))
                    .font(.system(size: 11))
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(model.rankedAccounts.filter { group.accountIDs.contains($0.id) }) { account in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(model.accountName(account.id)).font(.system(size: 11, weight: .medium))
                            Text(model.resetText(account, window: group.windowID)).font(.system(size: 10)).foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }.frame(maxHeight: 180).fixedSize(horizontal: false, vertical: true)
            Text(model.t("Percentages combine only accounts with the same plan and limit."))
                .font(.system(size: 10)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }.padding(16).frame(width: 290)
    }
}

/// The whole label takes the click, and its arrow turns from the tap until the readings are in.
private struct RefreshAllButton: View {
    @Bindable var model: PoolAppModel
    @State private var hovering = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        let spinning = model.isRefreshingQuota
        Button { model.perform(.refreshQuota(nil)) } label: {
            HStack(spacing: 4) {
                TimelineView(.animation(minimumInterval: nil, paused: !spinning || reduceMotion)) { context in
                    let turn = context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1.1) / 1.1
                    Image(systemName: "arrow.clockwise")
                        .rotationEffect(.degrees(spinning && !reduceMotion ? turn * 360 : 0))
                        .opacity(spinning && reduceMotion ? 0.5 : 1)
                }
                Text(model.t("Refresh all"))
            }.padding(.horizontal, 6).padding(.vertical, 3)
                .background(hovering ? PoolPalette.accent.opacity(0.09) : .clear, in: RoundedRectangle(cornerRadius: 5))
                .contentShape(Rectangle())
        }.buttonStyle(PoolPressStyle()).font(.system(size: 11)).foregroundStyle(PoolPalette.accent)
            .onHover { hovering = $0 }.poolAnimation(PoolMotion.quick, value: hovering)
            .disabled(model.isWorking || model.snapshot.accounts.isEmpty || !model.snapshot.executableReady)
            .accessibilityLabel(model.t("Refresh all")).accessibilityIdentifier("quota.refreshAll")
    }
}

/// One limit: its title, what is left, a bar, and when it resets. The reset goes beside the title when
/// the row has room and under the bar when it does not (or when asked), so no text is ever cut.
struct QuotaLine: View {
    let title: String
    let reset: String?
    let valueText: String
    let value: Double?
    var resetBelow = false
    var barHeight: CGFloat = 4
    var valueWeight: Font.Weight = .medium
    var body: some View {
        let figure = Text(valueText).font(.system(size: 12, weight: valueWeight)).monospacedDigit().foregroundStyle(PoolPalette.quota(value))
            .lineLimit(1).fixedSize().poolNumeric(value)
        let name = Text(title).font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true).layoutPriority(1)
        let when = reset.map { Text($0).font(.system(size: 10)).foregroundStyle(.tertiary).fixedSize(horizontal: false, vertical: true) }
        ViewThatFits(in: .horizontal) {
            if !resetBelow, let when {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(alignment: .firstTextBaseline, spacing: 6) { name; when; Spacer(minLength: 4); figure }
                    PoolGauge(value: value, height: barHeight)
                }
            }
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline, spacing: 6) { name; Spacer(minLength: 4); figure }
                PoolGauge(value: value, height: barHeight)
                if let when { when }
            }
            VStack(alignment: .leading, spacing: 4) {
                name
                figure
                PoolGauge(value: value, height: barHeight)
                if let when { when }
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}
