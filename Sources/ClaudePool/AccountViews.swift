import SwiftUI
import PoolCore

struct SetupCard: View {
    @Bindable var model: PoolAppModel
    var body: some View {
        PoolCard(padding: 16) {
            VStack(alignment: .leading, spacing: 14) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(model.t("A simple start")).font(.system(size: 14, weight: .semibold))
                }
                VStack(spacing: 0) {
                    step(1, title: "Install Claude Code", detail: "Claude Pool uses its own official client.", done: model.snapshot.executableReady) {
                        if !model.runtime.busy { RuntimeActionButton(model: model) }
                    }
                    if model.runtime.busy {
                        RuntimeInstallStatus(model: model).padding(.leading, 35).padding(.top, 10)
                    } else if let version = model.runtime.installedVersion {
                        Text(model.t("Version {0}", version)).font(.system(size: 10)).foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading).padding(.leading, 35).padding(.top, 6)
                    }
                    if model.snapshot.executableReady && !model.redactionReady {
                        PrivacyPreparationRow(model: model).padding(.leading, 35).padding(.top, 12)
                    }
                    Divider().padding(.leading, 35).padding(.vertical, 12)
                    step(2, title: "Add your first account", detail: "Sign in with Claude in a separate account space.", done: model.hasSignedInAccount) {
                        Button(model.t(model.pendingSignInID == nil ? "Add account" : "Continue sign-in")) { model.perform(.addAccount) }.buttonStyle(PoolSecondaryButton())
                            .disabled(!model.snapshot.executableReady || model.runtime.busy || model.isWorking)
                    }
                    Divider().padding(.leading, 35).padding(.vertical, 12)
                    step(3, title: "Connect Claude Desktop",
                         detail: model.snapshot.desktop == .notInstalled ? "Install Claude Desktop, then connect it." : "One click. Pool sets up Desktop for you and can undo it.",
                         done: model.snapshot.desktop.isLinked) {
                        if model.snapshot.desktop == .notInstalled {
                            Link(model.t("Get Claude Desktop"), destination: URL(string: "https://claude.ai/download")!).font(.system(size: 12))
                        } else if !model.snapshot.desktop.isLinked {
                            Button(model.t("Connect")) { model.perform(.connectDesktop) }.buttonStyle(PoolSecondaryButton())
                                .disabled(!model.hasSignedInAccount || model.isWorking).accessibilityIdentifier("setup.connectDesktop")
                        }
                    }
                }
            }
        }
    }
    private func step<Control: View>(_ number: Int, title: String, detail: String, done: Bool,
                                     @ViewBuilder control: () -> Control) -> some View {
        HStack(alignment: .center, spacing: 10) {
            ZStack {
                Circle().fill(done ? PoolPalette.good.opacity(0.10) : Color.primary.opacity(0.045))
                if done { Image(systemName: "checkmark").font(.system(size: 12, weight: .semibold)).foregroundStyle(PoolPalette.good) }
                else { Text("\(number)").font(.system(size: 13, weight: .medium)).foregroundStyle(.secondary) }
            }.frame(width: 25, height: 25).accessibilityLabel(model.t(done ? "Complete" : "Step {0}", "\(number)"))
            VStack(alignment: .leading, spacing: 5) {
                Text(model.t(title)).font(.system(size: 12, weight: .semibold))
                Text(model.t(detail)).font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            control()
        }
    }
}

struct AccountsPage: View {
    @Bindable var model: PoolAppModel
    @State private var removing: PoolAccount?
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if model.snapshot.accounts.isEmpty {
                PoolCard(padding: 20) {
                    VStack(spacing: 16) {
                        Image(systemName: "person.crop.circle.badge.plus").font(.system(size: 32, weight: .light)).foregroundStyle(PoolPalette.accent)
                        Text(model.t("Your first account starts here")).font(.system(size: 16, weight: .semibold))
                        Text(model.t("Sign in through Claude. Your email will appear here.")).font(.system(size: 12)).foregroundStyle(.secondary)
                        Button(model.t(model.pendingSignInID == nil ? "Add account" : "Continue sign-in")) { model.perform(.addAccount) }
                            .buttonStyle(.borderedProminent).controlSize(.large)
                            .disabled(!model.snapshot.executableReady || model.runtime.busy || model.isWorking)
                        if !model.snapshot.executableReady || model.runtime.busy {
                            RuntimeActionButton(model: model)
                        } else if let version = model.runtime.installedVersion {
                            Text(model.t("Claude Code") + " · " + model.t("Version {0}", version))
                                .font(.system(size: 11)).foregroundStyle(.secondary)
                        }
                        if model.snapshot.executableReady && !model.redactionReady {
                            PrivacyPreparationRow(model: model).frame(maxWidth: 320)
                        }
                    }.frame(maxWidth: .infinity).padding(.vertical, 16)
                }
            } else {
                // Best first, as in the menu: usable accounts lead and unusable ones sink to the end.
                let accounts = model.rankedAccounts
                VStack(spacing: 12) {
                    ForEach(accounts) { account in accountCard(account) }
                }.poolAnimation(PoolMotion.list, value: accounts.map(\.id))
            }
        }
        .confirmationDialog(model.t("Remove {0}?", removing.map { model.accountName($0.id) } ?? ""),
            isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }), titleVisibility: .visible) {
                Button(model.t("Remove account"), role: .destructive) {
                    if let account = removing { model.perform(.removeAccount(account.id)) }
                    removing = nil
                }
                Button(model.t("Cancel"), role: .cancel) { removing = nil }
            } message: { Text(model.t("This account will no longer be used by the pool.")) }
    }
    /// Two lines per account: who and in what state, then each limit with what is left and when it resets.
    private func accountCard(_ account: PoolAccount) -> some View {
        let signedIn = account.email?.isEmpty == false && account.state != .signedOut
        let refresh = model.quotaRefresh[account.id]
        return PoolCard(padding: 11) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 7) {
                    Circle().fill(model.accountColor(account)).frame(width: 7, height: 7)
                    Text(model.accountName(account.id)).font(.system(size: 12, weight: .semibold)).fixedSize(horizontal: false, vertical: true)
                        .help(model.lastQuotaUpdate(account).map { model.t("Last updated {0}", model.exactTime($0)) } ?? model.accountName(account.id))
                    Text(account.plan.map { model.t($0) } ?? model.t("Plan not reported")).font(.system(size: 11)).foregroundStyle(.secondary).fixedSize()
                    AccountUseBadges(model: model, use: model.accountUse[account.id])
                    Spacer(minLength: 6)
                    if signedIn && [.ready, .limited, .needsAttention].contains(account.state) {
                        Button { model.perform(.refreshQuota(account.id)) } label: {
                            if refresh?.busy == true { ProgressView().controlSize(.mini).frame(width: 16) }
                            else { Image(systemName: "arrow.clockwise").font(.system(size: 11)).frame(width: 16) }
                        }.buttonStyle(.plain).disabled(model.isWorking || refresh?.busy == true)
                            .help(model.t("Refresh quota")).accessibilityLabel(model.t("Refresh quota"))
                    }
                    Menu {
                        Button(model.t("Check sign-in")) { model.perform(.checkAccount(account.id)) }
                        Button(model.t("Sign in again")) { model.perform(.signIn(account.id)) }
                        Divider()
                        Button(model.t("Remove account"), role: .destructive) { removing = account }
                            .disabled(model.snapshot.sessions.contains { $0.accountID == account.id && ![.idle, .ended].contains($0.state) })
                    } label: {
                        Image(systemName: "ellipsis").font(.system(size: 12, weight: .semibold)).frame(width: 18, height: 18)
                    }.menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                        .accessibilityLabel(model.t("Account actions")).disabled(model.isWorking)
                }
                // The limits below already say what is left; this line speaks only when the account cannot be used.
                if account.standing(at: model.now) != .usable && account.standing(at: model.now) != .unread {
                    Text(model.accountStatus(account)).font(.system(size: 11)).foregroundStyle(model.accountColor(account))
                        .fixedSize(horizontal: false, vertical: true)
                }
                if !signedIn {
                    actionLine(model.t("Sign in to use this account."), button: model.t("Sign in"), prominent: true) { model.perform(.signIn(account.id)) }
                } else if account.state == .subscriptionRequired {
                    actionLine(model.t("This account's Claude subscription can't be used: it may have ended, or a payment may be past due. Check it again once that is settled."), button: model.t("Check sign-in")) { model.perform(.checkAccount(account.id)) }
                } else if account.state == .suspended {
                    actionLine(model.t("Anthropic restricted this account, so the pool leaves it out. Check it again once that is resolved."),
                               button: model.t("Check sign-in")) { model.perform(.checkAccount(account.id)) }
                } else if account.state == .disabled {
                    Text(model.t("This sign-in is already in the pool as another account, so it is left out."))
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                } else if account.state == .needsAttention {
                    actionLine(model.t("Check this account's sign-in to continue."), button: model.t("Check sign-in")) { model.perform(.checkAccount(account.id)) }
                } else if let refresh, refresh.phase == .failed {
                    actionLine(model.t(refresh.message ?? "Quota could not be refreshed. Try again."), button: model.t("Try again"), warning: true) {
                        model.perform(.refreshQuota(account.id))
                    }
                } else if model.displayedWindows(account).isEmpty {
                    Text(model.t(refresh?.busy == true ? "Reading quota from Claude…" : "Quota appears when Claude reports it."))
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }
                if signedIn, !model.displayedWindows(account).isEmpty {
                    // Two limits sit side by side; with model limits too they go two to a row so no title is cut.
                    let windows = model.displayedWindows(account)
                    if windows.count <= 2 {
                        HStack(alignment: .top, spacing: 18) {
                            ForEach(windows) { window in accountQuota(account, id: window.id) }
                        }
                    } else {
                        LazyVGrid(columns: [GridItem(.flexible(), spacing: 18, alignment: .top), GridItem(.flexible(), alignment: .top)], alignment: .leading, spacing: 10) {
                            ForEach(windows) { window in accountQuota(account, id: window.id) }
                        }
                    }
                }
            }
        }
    }
    private func actionLine(_ text: String, button: String, prominent: Bool = false, warning: Bool = false, action: @escaping () -> Void) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(text).font(.system(size: 11)).foregroundStyle(warning ? PoolPalette.amber : .secondary).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            if prominent { Button(button, action: action).buttonStyle(.borderedProminent).controlSize(.small).disabled(model.isWorking) }
            else { Button(button, action: action).controlSize(.small).disabled(model.isWorking) }
        }
    }
    private func accountQuota(_ account: PoolAccount, id: String) -> some View {
        let remaining = model.remaining(account, window: id)
        return QuotaLine(title: model.quotaTitle(id), reset: model.shortReset(account, window: id),
                         valueText: remaining.map { model.t("{0}% left", "\(Int($0.rounded()))") } ?? model.quotaText(account, window: id), value: remaining)
            .help(model.refusedNote(account, window: id) ?? account.windows.first(where: { $0.id == id })?.resetsAt.map { model.t("Resets {0}", model.exactTime($0)) + " · " + model.countdown($0) } ?? model.resetText(account, window: id))
            .accessibilityElement(children: .combine)
    }
}
