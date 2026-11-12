import SwiftUI
import PoolCore

struct PoolSettingsPage: View {
    @Bindable var model: PoolAppModel
    @State private var showsPrivacy = false
    init(model: PoolAppModel) { self.model = model }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            SettingsTabs(model: model)
            switch model.settingsTab {
            case .general:
                PoolCard {
                    VStack(spacing: 12) {
                        HStack(spacing: 12) {
                            PoolSettingLabel(title: model.t("Appearance"), systemImage: "circle.lefthalf.filled").font(.system(size: 12, weight: .medium))
                            Spacer()
                            Picker(model.t("Appearance"), selection: Binding(get: { model.preferences.appearance }, set: { model.perform(.appearance($0)) })) {
                                Text(model.t("Follow system")).tag("system")
                                Text(model.t("Light")).tag("light")
                                Text(model.t("Dark")).tag("dark")
                            }.labelsHidden().controlSize(.small).frame(width: 160, alignment: .trailing).disabled(model.isWorking).accessibilityIdentifier("settings.appearance")
                        }
                        HStack(spacing: 12) {
                            PoolSettingLabel(title: model.t("Language"), systemImage: "globe").font(.system(size: 12, weight: .medium))
                            Spacer()
                            Picker(model.t("Language"), selection: Binding(get: { model.preferences.language }, set: { model.perform(.language($0)) })) {
                                Text(model.t("Follow system")).tag("system")
                                ForEach(L10n.languages, id: \.code) { Text($0.name).tag($0.code) }
                            }.labelsHidden().controlSize(.small).frame(width: 160, alignment: .trailing).disabled(model.isWorking).accessibilityIdentifier("settings.language")
                        }
                        HStack(spacing: 12) {
                            VStack(alignment: .leading, spacing: 4) {
                                PoolSettingLabel(title: model.t("Hide email addresses"), systemImage: "eye.slash").font(.system(size: 12, weight: .medium))
                                Text(model.t("Masks the part before @, keeping its first and last characters."))
                                    .font(.system(size: 10)).foregroundStyle(.secondary).padding(.leading, 24)
                            }
                            Spacer()
                            Toggle(model.t("Hide email addresses"), isOn: Binding(get: { model.preferences.maskEmail }, set: { model.perform(.maskEmail($0)) }))
                                .toggleStyle(.switch).labelsHidden().controlSize(.small).disabled(model.isWorking)
                                .accessibilityIdentifier("settings.maskEmail")
                        }
                        HStack(spacing: 12) {
                            VStack(alignment: .leading, spacing: 4) {
                                PoolSettingLabel(title: model.t("Log"), systemImage: "doc.text.magnifyingglass").font(.system(size: 12, weight: .medium))
                                Text(model.t("What Pool did, for a bug report. No messages, keys or emails."))
                                    .font(.system(size: 10)).foregroundStyle(.secondary).padding(.leading, 24)
                            }
                            Spacer()
                            Button(model.t("Show in Finder")) { model.perform(.showLog) }.controlSize(.small)
                                .accessibilityIdentifier("settings.showLog")
                        }
                        FullLogSetting(model: model)
                    }
                }
                PoolCard { WarmUpSettings(model: model) }
            case .services:
                PoolCard {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack(alignment: .top, spacing: 12) {
                            VStack(alignment: .leading, spacing: 5) {
                                PoolSettingLabel(title: model.t("Claude Code"), systemImage: "terminal").font(.system(size: 12, weight: .semibold))
                                Text(model.runtime.installedVersion.map { model.t("Version {0}", $0) } ?? model.t("Not installed"))
                                    .font(.system(size: 11)).foregroundStyle(.secondary).padding(.leading, 24)
                                if let version = model.runtime.availableVersion, model.runtime.phase == .updateAvailable {
                                    Text(model.t("Version {0} is available.", version)).font(.system(size: 10)).foregroundStyle(PoolPalette.accent)
                                        .padding(.leading, 24)
                                }
                                if let message = model.runtime.updateCheckMessage {
                                    Text(message).font(.system(size: 10)).foregroundStyle(PoolPalette.amber)
                                        .fixedSize(horizontal: false, vertical: true).padding(.leading, 24)
                                }
                            }
                            Spacer(minLength: 4)
                            if !model.runtime.busy {
                                VStack(alignment: .trailing, spacing: 6) {
                                    RuntimeActionButton(model: model)
                                    // Updates install by themselves; going back is offered only when one went wrong.
                                    if let version = model.runtime.previousVersion, model.runtime.phase == .failed || model.runtime.updateCheckMessage != nil {
                                        Button(model.t("Use previous version")) { model.perform(.rollbackRuntime) }
                                            .buttonStyle(.link).controlSize(.small).font(.system(size: 10))
                                            .help(model.t("Use version {0} for new sessions.", version))
                                            .disabled(model.isWorking)
                                    }
                                }
                            }
                        }
                        if model.runtime.busy { RuntimeInstallStatus(model: model).padding(.leading, 24) }
                    }
                }
                PoolCard { VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 10) {
                        VStack(alignment: .leading, spacing: 5) {
                            PoolSettingLabel(title: model.t("Sensitive data redaction"), systemImage: "shield.lefthalf.filled").font(.system(size: 12, weight: .semibold))
                            Text(model.privacyModelLine).font(.system(size: 11)).foregroundStyle(.secondary).padding(.leading, 24)
                                .accessibilityIdentifier("settings.privacyModel")
                            if let message = model.privacy.updateMessage {
                                Text(message).font(.system(size: 10)).foregroundStyle(PoolPalette.amber)
                                    .fixedSize(horizontal: false, vertical: true).padding(.leading, 24)
                            }
                        }
                        Spacer(minLength: 4)
                        Text(model.privacyStatusTitle).font(.system(size: 10)).foregroundStyle(.secondary)
                        Button(model.t("Details…")) { showsPrivacy = true }.controlSize(.small)
                            .accessibilityIdentifier("settings.privacy")
                        Toggle(model.t("Sensitive data redaction"), isOn: Binding(get: { model.preferences.redaction }, set: { model.perform(.redaction($0)) }))
                            .toggleStyle(.switch).controlSize(.small).labelsHidden()
                            .accessibilityIdentifier("settings.redaction")
                    }
                    if !model.preferences.redaction {
                        Text(model.t("Requests go to Claude exactly as written."))
                            .font(.system(size: 10)).foregroundStyle(PoolPalette.amber).padding(.leading, 24)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                } }
                PoolCard { DesktopConnectionRow(model: model) }
            case .about:
                PoolCard { AboutSettings(model: model, updates: model.updates) }
            }
        }.sheet(isPresented: $showsPrivacy) { PrivacyDetailsSheet(model: model) }
    }
}

/// Settings in three short groups, so each fits the window; About carries a dot when a newer version is out.
struct SettingsTabs: View {
    @Bindable var model: PoolAppModel
    var body: some View {
        HStack(spacing: 2) {
            ForEach(SettingsTab.allCases) { tab in
                let selected = model.settingsTab == tab
                Button { model.settingsTab = tab } label: {
                    HStack(spacing: 5) {
                        Text(model.t(tab.title)).font(.system(size: 12, weight: selected ? .semibold : .regular))
                        if tab == .about, model.updates.hasUpdate {
                            Circle().fill(PoolPalette.accent).frame(width: 6, height: 6).accessibilityLabel(model.t("Update available"))
                        }
                    }.frame(maxWidth: .infinity).padding(.vertical, 6)
                        .foregroundStyle(selected ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
                        .background(selected ? PoolPalette.background : .clear, in: RoundedRectangle(cornerRadius: 6))
                        .shadow(color: .black.opacity(selected ? 0.08 : 0), radius: 1, y: 0.5)
                        .contentShape(RoundedRectangle(cornerRadius: 6))
                }.buttonStyle(.plain).accessibilityAddTraits(selected ? .isSelected : []).accessibilityIdentifier("settings.tab.\(tab.rawValue)")
            }
        }.padding(2).background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
            .poolAnimation(PoolMotion.quick, value: model.settingsTab)
    }
}

/// Claude Pool's version, its release check and the project's GitHub links.
struct AboutSettings: View {
    @Bindable var model: PoolAppModel
    @Bindable var updates: AppUpdates
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 5) {
                    PoolSettingLabel(title: "Claude Pool", systemImage: "info.circle").font(.system(size: 12, weight: .semibold))
                    Text(model.t("Version {0}", updates.currentVersion)).font(.system(size: 11)).foregroundStyle(.secondary)
                        .padding(.leading, 24).accessibilityIdentifier("settings.appVersion")
                    HStack(alignment: .firstTextBaseline, spacing: 5) {
                        if updates.isChecking { ProgressView().controlSize(.mini) }
                        else if updates.install == .failed { Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(PoolPalette.amber) }
                        else if updates.hasUpdate { Image(systemName: "arrow.down.circle.fill").foregroundStyle(PoolPalette.accent) }
                        Text(updates.statusText(model.t)).fixedSize(horizontal: false, vertical: true)
                            .foregroundStyle(updates.hasUpdate ? AnyShapeStyle(PoolPalette.accent)
                                             : updates.status == .failed || updates.install == .failed ? AnyShapeStyle(PoolPalette.amber) : AnyShapeStyle(.secondary))
                    }.font(.system(size: 10)).padding(.leading, 24).accessibilityIdentifier("settings.updateStatus")
                }
                Spacer(minLength: 4)
                if updates.hasUpdate {
                    if updates.install == .downloading || updates.install == .restarting { ProgressView().controlSize(.small) }
                    else if updates.canInstall || model.demo {
                        Button(model.t("Update and restart")) { Task { await updates.installAndRestart() } }.controlSize(.small)
                            .disabled(model.demo).accessibilityIdentifier("settings.installUpdate")
                    } else {
                        Button(model.t("Download")) { ProjectLink.open(ProjectLink.releases) }.controlSize(.small)
                            .accessibilityIdentifier("settings.downloadUpdate")
                    }
                } else {
                    Button(model.t("Check for updates")) { Task { await updates.check(manual: true) } }.controlSize(.small)
                        .disabled(updates.isChecking || model.demo).accessibilityIdentifier("settings.checkUpdates")
                }
            }
            Rectangle().fill(PoolPalette.line).frame(height: 1)
            VStack(alignment: .leading, spacing: 6) {
                Text(model.t("All your Claude accounts, one pool for Claude Desktop."))
                    .font(.system(size: 11, weight: .medium)).fixedSize(horizontal: false, vertical: true)
                ForEach(Self.features, id: \.text) { feature in
                    Label {
                        Text(model.t(feature.text)).fixedSize(horizontal: false, vertical: true)
                    } icon: {
                        Image(systemName: feature.symbol).foregroundStyle(PoolPalette.accent).frame(width: 14)
                    }.font(.system(size: 10)).foregroundStyle(.secondary)
                }
            }.padding(.leading, 24).accessibilityElement(children: .combine).accessibilityIdentifier("settings.aboutPool")
            Rectangle().fill(PoolPalette.line).frame(height: 1)
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    PoolSettingLabel(title: model.t("Check for updates automatically"), systemImage: "arrow.triangle.2.circlepath")
                        .font(.system(size: 12, weight: .medium))
                    Text(model.t("Checks GitHub once a day while Pool is open. A new version installs when you choose Update and restart."))
                        .font(.system(size: 10)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true).padding(.leading, 24)
                }
                Spacer(minLength: 8)
                Toggle(model.t("Check for updates automatically"), isOn: Binding(get: { updates.automatic }, set: updates.setAutomatic))
                    .toggleStyle(.switch).labelsHidden().controlSize(.small).disabled(model.demo)
                    .accessibilityIdentifier("settings.autoUpdates")
            }
            Rectangle().fill(PoolPalette.line).frame(height: 1)
            HStack(spacing: 14) {
                link("GitHub", symbol: ProjectLink.symbol, url: ProjectLink.repository)
                link(model.t("Report an issue"), symbol: "bubble.left", url: ProjectLink.issues)
                link(model.t("View latest version"), symbol: "arrow.down.circle", url: ProjectLink.releases)
                Spacer(minLength: 0)
            }.padding(.leading, 24)
        }
    }
    /// What the pool does, in the order a person meets it.
    static let features: [(text: String, symbol: String)] = [
        ("Each conversation, subagent and task goes to the account best placed for it: what its limits have left, when they reset, and what the work costs there.", "arrow.triangle.branch"),
        ("Each conversation stays on its account to read its prompt cache, and moves only when that costs less.", "bolt"),
        ("A conversation's subagents run on different accounts at once, by what each has left and how busy it is.", "square.stack.3d.up"),
        ("When every account is at its limit, Desktop is told when the first is back, and you get a notification.", "bell.badge"),
        ("Keys, passwords and personal info are hidden on this Mac before anything is sent.", "lock.shield")
    ]
    private func link(_ title: String, symbol: String, url: URL) -> some View {
        Link(destination: url) {
            HStack(spacing: 3) {
                Label(title, systemImage: symbol)
                Image(systemName: "arrow.up.right").font(.system(size: 8, weight: .semibold))
            }.font(.system(size: 11))
        }.help(url.absoluteString)
    }
}

struct RuntimeInstallStatus: View {
    @Bindable var model: PoolAppModel
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                if model.runtime.progress == nil { ProgressView().controlSize(.small) }
                Text(model.t(model.runtime.stage ?? (model.runtime.phase == .checking ? "Checking release…" : "Installing…")))
                    .font(.system(size: 11, weight: .medium))
                Spacer(minLength: 4)
                if let version = model.runtime.targetVersion {
                    Text(model.t("Version {0}", version)).font(.system(size: 10)).foregroundStyle(.secondary)
                }
            }
            if let progress = model.runtime.progress {
                ProgressView(value: progress).tint(PoolPalette.accent)
                    .accessibilityLabel(model.t("Claude Code"))
            }
            if model.runtime.downloadedBytes != nil || model.runtime.progress != nil {
                HStack(alignment: .firstTextBaseline) {
                    if let downloaded = model.runtime.downloadedBytes {
                        if let total = model.runtime.totalBytes {
                            Text(model.t("{0} of {1} MB", megabytes(downloaded), megabytes(total)))
                        } else {
                            Text(model.t("{0} MB downloaded", megabytes(downloaded)))
                        }
                    }
                    Spacer(minLength: 4)
                    if let progress = model.runtime.progress { Text("\(Int((progress * 100).rounded()))%") }
                }.font(.system(size: 10)).foregroundStyle(.secondary).monospacedDigit()
            }
        }.accessibilityIdentifier("runtime.progress")
    }
    private func megabytes(_ bytes: Int64) -> String {
        (Double(bytes) / 1_000_000).formatted(.number.precision(.fractionLength(1)).locale(model.locale))
    }
}

struct RuntimeActionButton: View {
    @Bindable var model: PoolAppModel
    var body: some View {
        switch model.runtime.phase {
        case .checking, .installing:
            RuntimeInstallStatus(model: model).frame(width: 230)
        case .updateAvailable:
            Button(model.t("Update Claude Code")) { model.perform(.updateRuntime) }.controlSize(.small).disabled(model.isWorking)
        case .ready:
            // Updates come by themselves every few hours; a new model need not wait for the next look.
            VStack(alignment: .trailing, spacing: 4) {
                Button(model.t("Check for updates")) { model.perform(.checkAndUpdateRuntime) }
                    .controlSize(.small).disabled(model.isWorking).accessibilityIdentifier("settings.checkRuntime")
                Text(model.t("Updates automatically")).font(.system(size: 10)).foregroundStyle(.secondary)
            }
        case .notInstalled, .failed:
            Button(model.t(model.runtime.phase == .failed ? "Try again" : "Install Claude Code")) { model.perform(.installRuntime) }
                .controlSize(.small).disabled(model.isWorking)
        }
    }
}

/// When the pool starts accounts' limits itself: at their resets, and at set times of day.
struct WarmUpSettings: View {
    @Bindable var model: PoolAppModel
    var body: some View {
        let warmUp = model.preferences.warmUp
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    PoolSettingLabel(title: model.t("Start limits at reset"), systemImage: "sunrise").font(.system(size: 12, weight: .semibold))
                    Text(model.t("One short request through Claude Code starts a limit that isn't running, so the next one is back sooner."))
                        .font(.system(size: 10)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true).padding(.leading, 24)
                }
                Spacer(minLength: 8)
                Picker(model.t("Start limits at reset"), selection: Binding(get: { warmUp.onReset }, set: { set(onReset: $0) })) {
                    Text(model.t("Off")).tag(WarmUpPreferences.Reset.off)
                    Text(model.t("Weekly")).tag(WarmUpPreferences.Reset.week)
                    Text(model.t("Weekly and 5-hour")).tag(WarmUpPreferences.Reset.all)
                }.labelsHidden().controlSize(.small).frame(width: 168, alignment: .trailing).disabled(model.isWorking)
                    .accessibilityIdentifier("settings.warmUp")
            }
            Rectangle().fill(PoolPalette.line).frame(height: 1)
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    PoolSettingLabel(title: model.t("Start 5-hour limits at set times"), systemImage: "clock").font(.system(size: 12, weight: .medium))
                    Text(model.t("Each account's 5-hour limit starts at these times if it isn't running. A Mac asleep then starts it on waking, up to an hour late."))
                        .font(.system(size: 10)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true).padding(.leading, 24)
                }
                Spacer(minLength: 8)
                Toggle(model.t("Start 5-hour limits at set times"), isOn: Binding(get: { !warmUp.dailyTimes.isEmpty },
                                                                                  set: { set(times: $0 ? ["06:00"] : []) }))
                    .toggleStyle(.switch).labelsHidden().controlSize(.small).disabled(model.isWorking)
                    .accessibilityIdentifier("settings.warmUpTimes")
            }
            if !warmUp.dailyTimes.isEmpty {
                HStack(spacing: 6) {
                    ForEach(Array(warmUp.dailyTimes.enumerated()), id: \.offset) { index, time in timeField(index, time, all: warmUp.dailyTimes) }
                    if warmUp.dailyTimes.count < 6 {
                        Button { add(after: warmUp.dailyTimes) } label: { Image(systemName: "plus").font(.system(size: 10, weight: .semibold)) }
                            .buttonStyle(PoolPressStyle()).frame(width: 22, height: 22)
                            .background(Color.primary.opacity(0.06), in: Circle())
                            .help(model.t("Add a time five hours after the last")).accessibilityLabel(model.t("Add a time five hours after the last"))
                    }
                }.padding(.leading, 24).transition(.opacity.combined(with: .move(edge: .top)))
            }
            if let status = model.warmUpStatusText {
                Text(status).font(.system(size: 10)).foregroundStyle(.tertiary).lineLimit(2)
                    .padding(.leading, 24).contentTransition(.opacity).accessibilityIdentifier("settings.warmUpStatus")
            }
        }.poolAnimation(PoolMotion.quick, value: warmUp)
    }
    private func timeField(_ index: Int, _ time: String, all: [String]) -> some View {
        HStack(spacing: 2) {
            DatePicker(model.t("Time"), selection: Binding(get: { date(time) }, set: { replace(index, with: $0, in: all) }),
                       displayedComponents: .hourAndMinute)
                .labelsHidden().datePickerStyle(.field).controlSize(.small).environment(\.locale, Locale(identifier: "en_GB"))
            if all.count > 1 {
                Button { set(times: all.enumerated().filter { $0.offset != index }.map(\.element)) } label: {
                    Image(systemName: "xmark").font(.system(size: 8, weight: .bold))
                }.buttonStyle(PoolPressStyle()).foregroundStyle(.secondary).help(model.t("Remove this time")).accessibilityLabel(model.t("Remove this time"))
            }
        }
    }
    private func date(_ time: String) -> Date {
        let minutes = WarmUpPreferences.minutes(time) ?? 360
        return Calendar.current.date(bySettingHour: minutes / 60, minute: minutes % 60, second: 0, of: model.now) ?? model.now
    }
    private func replace(_ index: Int, with date: Date, in all: [String]) {
        let parts = Calendar.current.dateComponents([.hour, .minute], from: date)
        var times = all
        guard times.indices.contains(index) else { return }
        times[index] = String(format: "%02d:%02d", parts.hour ?? 0, parts.minute ?? 0)
        set(times: times)
    }
    private func add(after times: [String]) {
        let last = times.compactMap(WarmUpPreferences.minutes).max() ?? 360
        set(times: times + [{ let next = (last + 300) % 1440; return String(format: "%02d:%02d", next / 60, next % 60) }()])
    }
    private func set(onReset: WarmUpPreferences.Reset) {
        model.perform(.warmUpPreferences(.init(onReset: onReset, dailyTimes: model.preferences.warmUp.dailyTimes)))
    }
    private func set(times: [String]) {
        model.perform(.warmUpPreferences(.init(onReset: model.preferences.warmUp.onReset, dailyTimes: times)))
    }
}

/// Where Claude Desktop stands and the one action that fixes it.
struct DesktopConnectionRow: View {
    @Bindable var model: PoolAppModel
    var body: some View {
        let link = model.snapshot.desktop
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 6) {
                PoolSettingLabel(title: model.t("Claude Desktop"), systemImage: "desktopcomputer").font(.system(size: 12, weight: .semibold))
                Text(model.desktopStatus).font(.system(size: 11))
                    .foregroundStyle(link == .connected ? AnyShapeStyle(.secondary) : AnyShapeStyle(PoolPalette.amber)).padding(.leading, 24)
                    .accessibilityIdentifier("settings.desktopStatus")
                if let check = model.desktopCheckText {
                    Text(check).font(.system(size: 10)).monospacedDigit().fixedSize(horizontal: false, vertical: true)
                        .foregroundStyle(model.desktopCheck?.failure == nil ? AnyShapeStyle(.tertiary) : AnyShapeStyle(PoolPalette.amber))
                        .padding(.leading, 24).accessibilityIdentifier("settings.desktopCheck")
                }
            }
            Spacer(minLength: 0)
            switch link {
            case .notInstalled:
                Link(model.t("Get Claude Desktop"), destination: URL(string: "https://claude.ai/download")!).font(.system(size: 12))
            case .disconnected:
                Button(model.t("Connect")) { model.perform(.connectDesktop) }.controlSize(.small)
                    .disabled(!model.hasSignedInAccount || model.isWorking).accessibilityIdentifier("settings.connectDesktop")
            case .needsRestart:
                Button(model.t("Restart Desktop")) { model.perform(.restartDesktop) }.controlSize(.small).disabled(model.isWorking)
                Button(model.t("Disconnect")) { model.perform(.disconnectDesktop) }.controlSize(.small).disabled(model.isWorking)
            case .outdated:
                Button(model.t("Update")) { model.perform(.connectDesktop) }.controlSize(.small).disabled(model.isWorking)
                    .accessibilityIdentifier("settings.updateDesktop")
            case .changed:
                Button(model.t("Reconnect")) { model.perform(.connectDesktop) }.controlSize(.small).disabled(model.isWorking)
                Button(model.t("Disconnect")) { model.perform(.disconnectDesktop) }.controlSize(.small).disabled(model.isWorking)
            case .connected:
                Button(model.t("Disconnect")) { model.perform(.disconnectDesktop) }.controlSize(.small).disabled(model.isWorking)
                    .accessibilityIdentifier("settings.disconnectDesktop")
            }
        }
    }
}
