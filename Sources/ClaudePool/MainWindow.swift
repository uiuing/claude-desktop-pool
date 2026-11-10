import SwiftUI
import PoolCore

struct MainWindow: View {
    @Bindable var model: PoolAppModel
    var body: some View {
        HStack(spacing: 0) {
            sidebar.frame(width: 128)
            Rectangle().fill(PoolPalette.line).frame(width: 1)
            VStack(spacing: 0) {
                HStack(spacing: 10) {
                    Text(model.t(model.page.title)).font(.system(size: 13, weight: .semibold))
                    Spacer()
                    if model.isWorking { ProgressView().controlSize(.small) }
                    if model.page == .pool || model.page == .accounts {
                        Button { model.perform(.addAccount) } label: { Label(model.t(model.pendingSignInID == nil ? "Add account" : "Continue sign-in"), systemImage: "plus") }
                            .controlSize(.small).disabled(!model.snapshot.executableReady || model.runtime.busy || model.isWorking)
                            .accessibilityIdentifier("accounts.add")
                    } else if model.page == .usage {
                        Picker(model.t("Range"), selection: $model.usageRange) {
                            Text(model.t("Today")).tag(UsageRange.today)
                            Text(model.t("7 days")).tag(UsageRange.week)
                            Text(model.t("30 days")).tag(UsageRange.month)
                            Text(model.t("All")).tag(UsageRange.all)
                        }.pickerStyle(.segmented).labelsHidden().controlSize(.small).fixedSize()
                            .accessibilityIdentifier("usage.range")
                    } else if model.snapshot.mode != .running { PoolBadge(title: model.modeTitle, color: PoolPalette.amber) }
                }.padding(.horizontal, 16).frame(height: 52)
                    .overlay(alignment: .bottom) { Rectangle().fill(PoolPalette.line).frame(height: 1) }
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        // Settings › About already says it in full.
                        if model.updates.showsBanner, model.page != .settings {
                            UpdateBanner(model: model, updates: model.updates).transition(.opacity.combined(with: .move(edge: .top)))
                        }
                        if let notice = model.notice ?? model.snapshot.notice {
                            noticeView(notice).transition(.opacity.combined(with: .move(edge: .top)))
                        }
                        // A page comes in with a short fade and rise; the one it replaces leaves at once.
                        Group {
                            switch model.page {
                            case .pool: PoolDashboard(model: model)
                            case .accounts: AccountsPage(model: model)
                            case .routing: RoutingPage(model: model)
                            case .usage: UsagePage(model: model)
                            case .settings: PoolSettingsPage(model: model)
                            }
                        }.id(model.page).transition(.asymmetric(insertion: .opacity.combined(with: .offset(y: 6)), removal: .identity))
                    }.padding(16).frame(maxWidth: .infinity)
                        .poolAnimation(PoolMotion.page, value: model.page)
                        .poolAnimation(PoolMotion.quick, value: model.notice ?? model.snapshot.notice)
                        .poolAnimation(PoolMotion.quick, value: model.updates.showsBanner)
                }
            }.frame(minWidth: 0, maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(PoolPalette.background).frame(minWidth: 640, minHeight: 520)
        .tint(PoolPalette.accent).environment(\.locale, model.locale)
        .task { await model.updateClock() }
        .preferredColorScheme(model.preferredColorScheme)
        .sheet(item: $model.terminal) { terminal in
            TerminalSheet(model: model, terminalID: terminal.id)
                .background(PoolSheetWindowReader().frame(width: 0, height: 0))
                .interactiveDismissDisabled()
        }
        .sheet(isPresented: $model.showsSignInRisk) { SignInRiskSheet(model: model).interactiveDismissDisabled() }
    }
    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                PoolMark(size: 23)
                Text("Claude Pool").font(.system(size: 11, weight: .semibold))
            }.padding(.horizontal, 12).padding(.top, 44).padding(.bottom, 18)
            VStack(spacing: 4) {
                ForEach(PoolPage.allCases.filter { $0 != .settings }) { page in navigationRow(page) }
            }.padding(.horizontal, 7)
            Spacer()
            VStack(alignment: .leading, spacing: 10) {
                if model.demo {
                    Label(model.t("Preview"), systemImage: "sparkles").font(.system(size: 10)).foregroundStyle(.secondary).padding(.horizontal, 8)
                }
                if model.updates.hasUpdate {
                    Button { model.showAbout(); Task { await model.updates.installAndRestart() } } label: {
                        Label(model.t(model.updates.canInstall ? "Update and restart" : "Update available"), systemImage: "arrow.down.circle.fill")
                            .font(.system(size: 11, weight: .medium)).foregroundStyle(PoolPalette.accent)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 8)
                    }.buttonStyle(.plain).disabled(model.updates.install == .downloading || model.updates.install == .restarting).help(model.t("Claude Pool {0} is available.", model.updates.latestVersion?.description ?? "—"))
                        .accessibilityIdentifier("sidebar.update")
                }
                Divider()
                navigationRow(.settings)
            }.padding(.horizontal, 7).padding(.bottom, 12)
        }.frame(maxHeight: .infinity).background(Color.primary.opacity(0.018))
    }
    private func navigationRow(_ page: PoolPage) -> some View {
        Button { model.page = page } label: {
            HStack(spacing: 7) {
                Image(systemName: page.symbol).font(.system(size: 12)).frame(width: 15)
                HStack(spacing: 3) {
                    Text(model.t(page.title)).font(.system(size: 12, weight: model.page == page ? .semibold : .regular))
                        .fixedSize(horizontal: false, vertical: true).layoutPriority(1)
                    Spacer(minLength: 0)
                    if page == .accounts && !model.snapshot.accounts.isEmpty {
                        Text("\(model.snapshot.accounts.count)").font(.system(size: 10)).foregroundStyle(.secondary).fixedSize()
                    }
                }
            }.padding(.horizontal, 8).padding(.vertical, 8)
                .foregroundStyle(model.page == page ? PoolPalette.accent : .primary)
                .background(model.page == page ? PoolPalette.accent.opacity(0.09) : .clear, in: RoundedRectangle(cornerRadius: 7))
                .contentShape(RoundedRectangle(cornerRadius: 7))
        }.buttonStyle(.plain).accessibilityAddTraits(model.page == page ? .isSelected : [])
            .accessibilityIdentifier("navigation.\(page.rawValue)")
    }
    private func noticeView(_ notice: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "info.circle").foregroundStyle(PoolPalette.accent)
            Text(model.t(notice)).font(.system(size: 11)).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 3)
            if model.notice != nil {
                Button { model.notice = nil } label: { Image(systemName: "xmark").font(.system(size: 9, weight: .semibold)) }
                    .buttonStyle(.plain).accessibilityLabel(model.t("Dismiss"))
            }
        }.padding(11).background(PoolPalette.accent.opacity(0.065), in: RoundedRectangle(cornerRadius: 9))
    }
}

struct PoolDashboard: View {
    @Bindable var model: PoolAppModel
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if !model.setupComplete { SetupCard(model: model) }
            if !model.snapshot.accounts.isEmpty {
                PoolCard(padding: 12) {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Text(model.useSummaryText)
                                .font(.system(size: 12, weight: .semibold)).fixedSize(horizontal: false, vertical: true)
                            Spacer(minLength: 6)
                            Button(model.t("View routing")) { model.page = .routing }.buttonStyle(.plain)
                                .font(.system(size: 11)).foregroundStyle(PoolPalette.accent)
                        }
                        Text(model.newConversationText).font(.system(size: 11)).fixedSize(horizontal: false, vertical: true)
                            .foregroundStyle(model.newConversationAccount == nil ? PoolPalette.amber : .secondary)
                        Text(model.t("{0}/{1} accounts usable", "\(model.confirmedReadyCount)", "\(model.snapshot.accounts.count)"))
                            .font(.system(size: 11)).foregroundStyle(.secondary)
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Text(model.runsInUseText).foregroundStyle(.secondary)
                            Text(model.runsBreakdownText).foregroundStyle(.tertiary).fixedSize(horizontal: false, vertical: true)
                        }.font(.system(size: 11)).help(model.runsExplainedText).accessibilityIdentifier("pool.runsInUse")
                        if model.quotaSummary.unknownAccounts > 0 {
                            HStack(spacing: 6) {
                                Text(model.t("Quota not read for {0} accounts", "\(model.quotaSummary.unknownAccounts)"))
                                Button(model.t("Read now")) { model.perform(.refreshQuota(nil)) }.buttonStyle(.plain)
                                    .foregroundStyle(PoolPalette.accent).disabled(model.isWorking)
                            }.font(.system(size: 11)).foregroundStyle(PoolPalette.amber)
                        }
                    }
                }
                QuotaOverview(model: model)
            }
        }
    }
}
