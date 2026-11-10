import SwiftUI
import AppKit
import PoolCore

/// The menu bar panel answers one question at a glance: how much is left, on which account, and
/// when it comes back. Actions sit as icons in the header; everything else is in the main window.
struct MenuPanel: View {
    @Bindable var model: PoolAppModel
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismiss) private var dismiss
    private let navigator: PoolWindowNavigator
    private let openMainWindow: (@MainActor () -> Void)?
    private let dismissMenu: (@MainActor () -> Void)?
    private let terminateApplication: @MainActor () -> Void
    @MainActor init(model: PoolAppModel, navigator: PoolWindowNavigator? = nil,
         openMainWindow: (@MainActor () -> Void)? = nil, dismissMenu: (@MainActor () -> Void)? = nil,
         terminateApplication: @escaping @MainActor () -> Void = { PoolQuit.request() }) {
        self.model = model; self.navigator = navigator ?? .shared
        self.openMainWindow = openMainWindow; self.dismissMenu = dismissMenu
        self.terminateApplication = terminateApplication
    }
    var body: some View {
        // Best first: the most usable accounts lead, those coming back soonest follow, unusable last.
        let accounts = model.rankedAccounts
        // Pool-wide facts are worked out once per update, not once per card.
        let showsPlan = model.planQuotas.count > 1
        let use = model.accountUse
        VStack(alignment: .leading, spacing: 0) {
            header.padding(.horizontal, 14).padding(.top, 12).padding(.bottom, 10)
            if model.updates.showsBanner {
                UpdateBanner(model: model, updates: model.updates, compact: true) {
                    if let dismissMenu { dismissMenu() } else { dismiss() }
                    if model.updates.canInstall { open(.settings); model.settingsTab = .about }
                }.padding(.horizontal, 12).padding(.bottom, 10)
            }
            if let step = model.setupStep {
                setup(step).padding(.horizontal, 12).padding(.bottom, accounts.isEmpty ? 12 : 10)
            }
            if !accounts.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    summary
                    sectionTitle(count: accounts.count)
                }.padding(.horizontal, 12)
                let cards = ForEach(accounts) { MenuAccountCard(model: model, account: $0, showsPlan: showsPlan, use: use[$0.id]) }
                if accounts.count > Self.eagerCards {
                    // A long list fills the panel's full height anyway; only the cards in view are built.
                    ScrollView {
                        LazyVStack(spacing: 6) { cards }.padding(.horizontal, 12).padding(.top, 6).padding(.bottom, 10)
                    }.frame(height: 360)
                } else {
                    ScrollView {
                        VStack(spacing: 6) { cards }.padding(.horizontal, 12).padding(.top, 6).padding(.bottom, 10)
                            .poolAnimation(PoolMotion.list, value: accounts.map(\.id))
                    }.frame(maxHeight: 360).fixedSize(horizontal: false, vertical: true)
                }
            }
            footer
        }.frame(width: 340).background(PoolPalette.background).tint(PoolPalette.accent)
            .onAppear { navigator.configure(opener: sceneOpener) }
            // Nothing here shows seconds: the time moves on each minute and at each limit's renewal.
            .task { await model.updateClock(every: 60) }
    }
    /// More cards than this overflow the 360-point list, so the list is built lazily at full height.
    static let eagerCards = 8

    private var header: some View {
        HStack(spacing: 8) {
            PoolMark(size: 18)
            Text("Claude Pool").font(.system(size: 14, weight: .semibold))
            Spacer()
            if !model.snapshot.accounts.isEmpty {
                MenuIconButton(symbol: "arrow.clockwise", help: model.t("Read now"), identifier: "menu.refresh", spinning: model.isRefreshingQuota) {
                    model.perform(.refreshQuota(nil))
                }.disabled(model.isWorking || !model.snapshot.executableReady)
            }
            MenuIconButton(symbol: "arrow.up.forward.app", help: model.t("Open Claude Pool"), identifier: "menu.open") { open(.pool) }
                .keyboardShortcut("o", modifiers: .command)
            MenuIconButton(symbol: "gearshape", help: model.t("Settings"), identifier: "menu.settings") { open(.settings) }
                .keyboardShortcut(",", modifiers: .command)
        }
    }

    /// The one setup step left, with the action that does it.
    private func setup(_ step: SetupStep) -> some View {
        HStack(alignment: .center, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text(model.t(step.title)).font(.system(size: 12, weight: .semibold))
                Text(model.t(step.detail(model))).font(.system(size: 10)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 6)
            switch step {
            case .installClient, .prepareRedaction:
                // These run by themselves; the window shows their progress and any retry.
                if model.runtime.busy || model.privacy.phase == .installing { ProgressView().controlSize(.small) }
                Button(model.t("Continue setup")) { open(.pool) }.controlSize(.small)
            case .addAccount:
                Button(model.t("Add account")) { open(.accounts); model.perform(.addAccount) }.buttonStyle(.borderedProminent).controlSize(.small)
                    .disabled(model.isWorking)
            case .getDesktop:
                Link(model.t("Get Claude Desktop"), destination: URL(string: "https://claude.ai/download")!).font(.system(size: 11))
            case .connectDesktop:
                Button(model.t("Connect")) { model.perform(.connectDesktop) }.buttonStyle(.borderedProminent).controlSize(.small)
                    .disabled(model.isWorking).accessibilityIdentifier("menu.connectDesktop")
            case .updateDesktop:
                Button(model.t("Update")) { model.perform(.connectDesktop) }.buttonStyle(.borderedProminent).controlSize(.small)
                    .disabled(model.isWorking).accessibilityIdentifier("menu.updateDesktop")
            }
        }.padding(12).frame(maxWidth: .infinity, alignment: .leading)
            .background(PoolPalette.panelCard, in: RoundedRectangle(cornerRadius: 10))
            .accessibilityIdentifier("menu.setup")
    }

    /// The shown plan's 5-hour and weekly limits side by side: what is left across the accounts
    /// in the plan, and when the next one resets. With several plans, a picker chooses the plan,
    /// which is also the one the menu bar shows.
    @ViewBuilder private var summary: some View {
        let plans = model.planQuotas
        if let plan = model.menuBarPlan {
            VStack(alignment: .leading, spacing: 10) {
                if plans.count > 1 {
                    Picker(model.t("Plan"), selection: Binding(get: { plan.id }, set: { model.perform(.menuBarPlan($0)) })) {
                        ForEach(plans) { Text($0.title).tag($0.id) }
                    }.pickerStyle(.segmented).labelsHidden().controlSize(.small).frame(maxWidth: .infinity).accessibilityIdentifier("menu.plan")
                        .help(model.t("The menu bar shows this plan's limits and its tightest model limit."))
                }
                HStack(alignment: .firstTextBaseline) {
                    Text(model.t("All {0} accounts", "\(plan.accountIDs.count)")).font(.system(size: 12, weight: .medium))
                    Spacer()
                    Text(model.planBreakdown(plan))
                        .font(.system(size: 11)).foregroundStyle(.secondary).monospacedDigit().multilineTextAlignment(.trailing)
                        .fixedSize(horizontal: false, vertical: true)
                        .help(model.t("Every account counts in these figures. Accounts that cannot be used are not read by themselves until they are fixed."))
                }
                // The 5-hour and weekly limits, then each model's weekly limit, in one two-column grid.
                let shown = ([plan.session, plan.week].compactMap { $0 }).isEmpty ? Array(plan.windows.prefix(2)) : [plan.session, plan.week].compactMap { $0 }
                let cells = shown + plan.modelLimits
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(Array(stride(from: 0, to: cells.count, by: 2)), id: \.self) { start in
                        HStack(alignment: .top, spacing: 14) {
                            limitColumn(cells[start])
                            if start + 1 < cells.count { limitColumn(cells[start + 1]) } else { Color.clear.frame(maxWidth: .infinity, maxHeight: 1) }
                        }
                    }
                }
                // One short line each, so neither is cut; the process count is the dashboard's detail.
                VStack(alignment: .leading, spacing: 4) {
                    Text(model.useSummaryText)
                        .help(model.runsInUseText + " · " + model.runsBreakdownText).accessibilityIdentifier("menu.runsInUse")
                    Text(model.newConversationText).foregroundStyle(model.newConversationAccount == nil ? PoolPalette.amber : .secondary)
                        .accessibilityIdentifier("menu.next")
                }.font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }.padding(12).background(PoolPalette.panelCard, in: RoundedRectangle(cornerRadius: 10))
        } else {
            Text(model.t(model.isReadingQuota ? "Reading quota…" : "Quota appears when Claude reports it."))
                .font(.system(size: 11)).foregroundStyle(.secondary).padding(12).frame(maxWidth: .infinity, alignment: .leading)
                .background(PoolPalette.panelCard, in: RoundedRectangle(cornerRadius: 10))
        }
    }

    private func limitColumn(_ group: QuotaPoolGroup) -> some View {
        let value = group.averageRemainingPercent
        return VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(model.limitName(group.windowID)).font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 2)
                Text(value.map { model.t("{0}% left", "\(Int($0.rounded()))") } ?? model.t("Not read"))
                    .font(.system(size: 12, weight: .semibold)).monospacedDigit().lineLimit(1).fixedSize()
                    .foregroundStyle(PoolPalette.quota(value)).poolNumeric(value)
            }
            PoolGauge(value: value, height: 5)
            Text(resetLine(group)).font(.system(size: 10)).foregroundStyle(.tertiary).monospacedDigit().fixedSize(horizontal: false, vertical: true)
        }.frame(maxWidth: .infinity, alignment: .leading).accessibilityElement(children: .combine)
            .help(group.nextResetAt.map { model.t("Resets {0}", model.exactTime($0)) } ?? "")
    }
    private func resetLine(_ group: QuotaPoolGroup) -> String {
        let parts = [group.nextResetAt.map { model.t("Resets {0}", model.clockTime($0)) },
                     group.unknownCount > 0 ? model.t("{0} unread", "\(group.unknownCount)") : nil].compactMap { $0 }
        // A blank line keeps the row's height when nothing resets soon, so the card does not jump.
        return parts.isEmpty ? " " : parts.joined(separator: " · ")
    }

    private func sectionTitle(count: Int) -> some View {
        HStack(spacing: 6) {
            ClaudeMarkView(size: 12)
            Text(model.t("Accounts").uppercased()).font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary).kerning(0.6)
            Text("\(count)").font(.system(size: 10, weight: .medium)).foregroundStyle(.secondary)
                .padding(.horizontal, 6).padding(.vertical, 1).background(Color.primary.opacity(0.07), in: Capsule())
            Spacer()
            Text(model.t("Left")).font(.system(size: 10)).foregroundStyle(.secondary)
                .padding(.horizontal, 7).padding(.vertical, 2).background(Color.primary.opacity(0.06), in: Capsule())
        }.padding(.top, 2)
    }

    private var footer: some View {
        HStack {
            Text(updatedText).font(.system(size: 10)).foregroundStyle(.tertiary).monospacedDigit()
                .contentTransition(.opacity).poolAnimation(PoolMotion.quick, value: updatedText)
            Spacer()
            Button(model.t("Quit")) {
                if let dismissMenu { dismissMenu() } else { dismiss() }
                terminateApplication()
            }.buttonStyle(.plain).font(.system(size: 12)).foregroundStyle(.secondary)
                .keyboardShortcut("q", modifiers: .command).accessibilityIdentifier("menu.quit")
        }.padding(.horizontal, 14).frame(height: 32)
            .overlay(alignment: .top) { Rectangle().fill(PoolPalette.line).frame(height: 1) }
    }
    /// When quota was last read, or that it is being read now.
    private var updatedText: String {
        if model.isReadingQuota { return model.t("Reading quota…") }
        guard let latest = model.snapshot.accounts.compactMap({ model.lastQuotaUpdate($0) }).max() else { return "" }
        return model.updatedText(latest)
    }

    private var sceneOpener: @MainActor () -> Void {
        if let openMainWindow { return openMainWindow }
        let action = openWindow
        return { action(id: PoolWindowNavigator.sceneID) }
    }
    private func open(_ page: PoolPage) {
        model.page = page
        let dismissAction = dismiss
        navigator.show(opener: sceneOpener, dismiss: dismissMenu ?? { dismissAction() })
    }
}

/// One account: who, when its next limit resets or why it cannot be used and until when, and a
/// ring per limit that applies to every model. Accounts out of rotation until a reset or a fix are dimmed.
struct MenuAccountCard: View {
    @Bindable var model: PoolAppModel
    let account: PoolAccount
    var showsPlan = false
    var use: AccountUse?
    var body: some View {
        let standing = account.standing(at: model.now)
        let windows = model.displayedWindows(account).filter { $0.isGlobal }.prefix(2).map(\.id)
        // An unread account keeps the rings' place, so its card does not grow when the first reading arrives.
        let limits = windows.isEmpty ? ["five_hour", "seven_day"] : Array(windows)
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                Text(model.accountName(account.id)).font(.system(size: 12, weight: .medium)).fixedSize(horizontal: false, vertical: true)
                if (showsPlan && account.plan != nil) || (use?.conversations ?? 0) > 0 {
                    HStack(spacing: 5) {
                        if showsPlan, let plan = account.plan { chip(model.t(plan), color: .secondary) }
                        AccountUseBadges(model: model, use: use)
                    }
                }
                statusLine(standing)
            }
            Spacer(minLength: 4)
            HStack(spacing: 8) {
                ForEach(limits, id: \.self) { id in
                    QuotaRing(value: standing == .unavailable ? nil : model.remaining(account, window: id), label: model.limitShortName(id))
                        .help(model.refusedNote(account, window: id) ?? "")
                }
                // The model limit with the least left, smaller than the two that apply to every model.
                if let tight = model.tightestModelLimit(account) {
                    QuotaRing(value: standing == .unavailable ? nil : tight.remaining, label: model.limitShortName(tight.window.id), size: 24)
                        .help(model.modelLimitHelp(account, window: tight.window, remaining: tight.remaining))
                }
            }.poolReading(model.quotaRefresh[account.id]?.phase == .refreshing)
        }.padding(.horizontal, 12).padding(.vertical, 10)
            .background(PoolPalette.panelCard, in: RoundedRectangle(cornerRadius: 9))
            .opacity(standing.isInRotation ? 1 : 0.62)
            .poolAnimation(PoolMotion.quick, value: standing)
            .help(([model.lastQuotaUpdate(account).map { model.t("Last updated {0}", model.exactTime($0)) }, model.accountQuotaSummary(account)]
                .compactMap { $0 }.filter { !$0.isEmpty }).joined(separator: "\n"))
            .accessibilityElement(children: .combine)
            .accessibilityValue(model.accountQuotaSummary(account))
    }
    /// When the limits reset, why the account cannot be used and until when, or that its figures
    /// are hours old because reads have been failing. A 5-hour limit that isn't running can be
    /// started from here.
    private func statusLine(_ standing: AccountStanding) -> some View {
        let stale = model.isStale(account)
        let starting = model.warmUp[account.id]?.sending == true
        let text = starting ? model.t("Starting…")
            : stale ? model.t("As of {0}", model.clockTime(model.lastQuotaUpdate(account) ?? model.now))
            : standing == .usable ? model.nextResetText(account) : model.accountStatus(account)
        let calm = (standing == .usable || standing == .unread) && !stale
        return VStack(alignment: .leading, spacing: 2) {
        HStack(spacing: 6) {
            let tone: AnyShapeStyle = calm ? AnyShapeStyle(.secondary) : AnyShapeStyle(stale ? PoolPalette.amber : model.accountColor(account))
            Text(text).foregroundStyle(tone)
                .font(.system(size: 10)).monospacedDigit().fixedSize(horizontal: false, vertical: true)
                .contentTransition(.opacity).poolReading(starting)
            if model.canWarmUp(account) {
                Button(model.t("Start")) { model.perform(.warmUpNow(account.id)) }
                    .buttonStyle(.plain).font(.system(size: 10, weight: .semibold)).foregroundStyle(PoolPalette.accent)
                    .help(model.t("Start this account's 5-hour limit now with one short request."))
                    .accessibilityIdentifier("menu.warmUp")
            }
        }
        // A model used up while the account still serves the others.
        if standing == .usable, let block = model.modelBlockText(account) {
            Text(block).font(.system(size: 10)).foregroundStyle(PoolPalette.amber).fixedSize(horizontal: false, vertical: true)
        }
        }
    }
    private func chip(_ title: String, color: Color) -> some View {
        Text(title).font(.system(size: 9, weight: .semibold)).foregroundStyle(color).lineLimit(1).fixedSize()
            .padding(.horizontal, 5).padding(.vertical, 1).background(color.opacity(0.12), in: Capsule())
    }
}

/// A small ring with what is left inside and the limit's name under it. The ring and the figure
/// glide to a new reading.
struct QuotaRing: View {
    let value: Double?
    let label: String
    var size: CGFloat = 30
    var body: some View {
        VStack(spacing: 2) {
            ZStack {
                Circle().stroke(Color.primary.opacity(0.09), lineWidth: size < 30 ? 2.5 : 3)
                Circle().trim(from: 0, to: CGFloat(min(100, max(0, value ?? 0))) / 100)
                    .stroke(PoolPalette.level(value), style: StrokeStyle(lineWidth: size < 30 ? 2.5 : 3, lineCap: .round))
                    .rotationEffect(.degrees(-90)).opacity(value == nil ? 0 : 1)
                Text(value.map { "\(Int($0.rounded()))" } ?? "—").font(.system(size: size < 30 ? 9 : 10, weight: .semibold)).monospacedDigit()
                    .poolNumeric(value)
            }.frame(width: size, height: size).frame(height: 30).poolAnimation(PoolMotion.value, value: value)
            Text(label).font(.system(size: 9)).foregroundStyle(.secondary)
        }
    }
}

struct MenuIconButton: View {
    let symbol: String
    let help: String
    let identifier: String
    /// Turns while the action it started is still running.
    var spinning = false
    let action: () -> Void
    @State private var hovering = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        Button(action: action) {
            TimelineView(.animation(minimumInterval: nil, paused: !spinning || reduceMotion)) { context in
                let turn = context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1.1) / 1.1
                Image(systemName: symbol).font(.system(size: 13))
                    .rotationEffect(.degrees(spinning && !reduceMotion ? turn * 360 : 0))
                    .opacity(spinning && reduceMotion ? 0.5 : 1)
            }.frame(width: 26, height: 24)
                .background(hovering ? Color.primary.opacity(0.08) : .clear, in: RoundedRectangle(cornerRadius: 6))
                .contentShape(Rectangle())
        }.buttonStyle(PoolPressStyle()).foregroundStyle(.secondary).onHover { hovering = $0 }
            .poolAnimation(PoolMotion.quick, value: hovering)
            .help(help).accessibilityLabel(help).accessibilityIdentifier(identifier)
    }
}
