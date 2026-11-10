import SwiftUI
import PoolCore

struct RoutingPage: View {
    @Bindable var model: PoolAppModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private var orderedAccounts: [PoolAccount] { model.orderedRoutingAccounts }
    /// Accounts held by a limit or that cannot serve, soonest back first.
    private var waitingAccounts: [PoolAccount] {
        model.rankedAccounts.filter { $0.standing(at: model.now) > .unread }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            RoutingFlowView(model: model)
            policy
            if !waitingAccounts.isEmpty {
                PoolCard {
                    DisclosureGroup {
                        VStack(spacing: 10) {
                            ForEach(waitingAccounts) { account in
                                HStack(spacing: 8) {
                                    Text(model.accountName(account.id)).font(.system(size: 11)).fixedSize(horizontal: false, vertical: true)
                                    brief(account)
                                    Spacer(minLength: 4)
                                    Text(recoveryText(account)).font(.system(size: 10)).foregroundStyle(PoolPalette.amber)
                                        .help(recoveryText(account, precise: true))
                                }
                            }
                        }.padding(.top, 10)
                    } label: {
                        Label(model.t("Waiting accounts: {0}", "\(waitingAccounts.count)"), systemImage: "clock.badge.exclamationmark")
                            .font(.system(size: 11, weight: .medium))
                    }.accessibilityIdentifier("routing.waitingAccounts")
                }
            }
            VStack(alignment: .leading, spacing: 9) {
                Text(model.t("Recent decisions")).font(.system(size: 12, weight: .semibold))
                PoolCard(padding: 0) {
                    if model.snapshot.routeDecisions.isEmpty {
                        Text(model.t("Routing decisions will appear here as requests arrive."))
                            .font(.system(size: 11)).foregroundStyle(.secondary).padding(14)
                    } else {
                        VStack(spacing: 0) {
                            ForEach(Array(model.snapshot.routeDecisions.suffix(8).reversed())) { decision in
                                decisionRow(decision).transition(.opacity.combined(with: .move(edge: .top)))
                            }
                        }.animation(reduceMotion ? nil : .easeInOut(duration: 0.22), value: model.snapshot.routeDecisions.last?.id)
                    }
                }
            }
        }
    }
    private var policy: some View {
        PoolCard {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 10) {
                    Text(model.t("Account selection")).font(.system(size: 11, weight: .medium))
                    Spacer()
                    Picker(model.t("Account selection"), selection: Binding(get: { model.preferences.routingPolicy.strategy }, set: { model.setRoutingStrategy($0) })) {
                        Text(model.t("More headroom")).tag(RoutingStrategy.mostHeadroom)
                        Text(model.t("Account order")).tag(RoutingStrategy.ordered)
                    }.labelsHidden().controlSize(.small).frame(width: 155, alignment: .trailing).disabled(model.isWorking)
                        .accessibilityIdentifier("routing.strategy")
                }
                NumericSettingRow(model: model, title: "Switch threshold", value: model.preferences.routingPolicy.reservePercent,
                                  range: 0...25, unit: "%", identifier: "routing.reserve", integerOnly: true) {
                    await model.saveRoutingReserve($0)
                }
                Text(model.t("Below this, a conversation moves to an account with more left at your next message. A reply under way finishes first."))
                    .font(.system(size: 10)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                if model.preferences.routingPolicy.strategy == .ordered {
                    Divider()
                    ForEach(Array(orderedAccounts.enumerated()), id: \.element.id) { index, account in
                        HStack(spacing: 7) {
                            Text("\(index + 1)").monospacedDigit().foregroundStyle(.tertiary).frame(width: 15)
                            Text(model.accountName(account.id)).fixedSize(horizontal: false, vertical: true)
                            brief(account)
                            Spacer(minLength: 3)
                            Button { model.moveRoutingAccount(account.id, by: -1) } label: { Image(systemName: "arrow.up") }
                                .disabled(index == 0 || model.isWorking).accessibilityLabel(model.t("Move account up"))
                                .accessibilityIdentifier("routing.up.\(index)")
                            Button { model.moveRoutingAccount(account.id, by: 1) } label: { Image(systemName: "arrow.down") }
                                .disabled(index == orderedAccounts.count - 1 || model.isWorking).accessibilityLabel(model.t("Move account down"))
                                .accessibilityIdentifier("routing.down.\(index)")
                        }.font(.system(size: 11))
                    }
                }
            }
        }
    }
    /// The account's tightest model limit, after its name.
    @ViewBuilder private func brief(_ account: PoolAccount) -> some View {
        if let text = model.accountBrief(account) {
            Text(text).font(.system(size: 10)).foregroundStyle(.secondary).monospacedDigit().lineLimit(1).fixedSize()
                .help(model.accountQuotaSummary(account))
        }
    }
    private func recoveryText(_ account: PoolAccount, precise: Bool = false) -> String {
        switch QuotaRecovery.account(account, model: PoolRouting.anyModel, now: model.now) {
        case .available: return model.stateTitle(account.effectiveState(at: model.now))
        case .scheduled(let date):
            return model.t("Recovery: {0}", precise ? model.exactTime(date) : model.clockTime(date))
        case .unknown: return model.t("Recovery time unknown")
        case .unavailable: return model.stateTitle(account.effectiveState(at: model.now))
        }
    }
    private func decisionRow(_ decision: RouteDecision) -> some View {
        HStack(alignment: .top, spacing: 9) {
            Circle().fill(decision.reason == .failover || decision.reason == .quotaExhausted ? PoolPalette.amber : PoolPalette.accent.opacity(0.65))
                .frame(width: 5, height: 5).padding(.top, 4).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(model.routeReason(decision.reason)).font(.system(size: 11, weight: .medium))
                Text([decision.accountID.map { model.accountName($0) }, decision.model].compactMap { $0 }.joined(separator: " · "))
                    .font(.system(size: 10)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 3)
            Text(model.timeText(decision.timestamp)).font(.system(size: 9, design: .monospaced)).foregroundStyle(.secondary)
                .help(model.exactTime(decision.timestamp))
        }.padding(.horizontal, 14).padding(.vertical, 10).accessibilityElement(children: .combine)
    }
}
