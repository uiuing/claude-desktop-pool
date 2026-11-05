import SwiftUI
import PoolCore

/// A newer Claude Pool, said where it is seen: on top of every page and under the menu panel's header.
/// Dismissing it hides that version's banner; Settings › About still shows it.
struct UpdateBanner: View {
    @Bindable var model: PoolAppModel
    @Bindable var updates: AppUpdates
    var compact = false
    /// Runs before the update starts, so the menu panel can close itself.
    var beforeUpdate: () -> Void = {}
    var body: some View {
        let busy = updates.install == .downloading || updates.install == .restarting
        HStack(alignment: .center, spacing: 8) {
            Image(systemName: updates.install == .failed ? "exclamationmark.triangle.fill" : "arrow.down.circle.fill")
                .foregroundStyle(updates.install == .failed ? PoolPalette.amber : PoolPalette.accent)
            Text(updates.install == .idle ? model.t("Claude Pool {0} is available.", updates.latestVersion?.description ?? "—")
                                          : updates.statusText(model.t))
                .font(.system(size: compact ? 11 : 12, weight: .medium)).lineLimit(2).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 4)
            if busy { ProgressView().controlSize(.small) }
            else {
                Button(model.t(updates.canInstall || model.demo ? "Update and restart" : "Download")) {
                    beforeUpdate(); Task { await updates.installAndRestart() }
                }.controlSize(.small).disabled(model.demo).accessibilityIdentifier(compact ? "menu.update" : "banner.update")
                Button { updates.dismissBanner() } label: { Image(systemName: "xmark").font(.system(size: 9, weight: .semibold)) }
                    .buttonStyle(.plain).foregroundStyle(.secondary).help(model.t("Dismiss")).accessibilityLabel(model.t("Dismiss"))
            }
        }.padding(compact ? 9 : 11)
            .background(PoolPalette.accent.opacity(0.08), in: RoundedRectangle(cornerRadius: 9))
            .accessibilityElement(children: .contain)
    }
}
