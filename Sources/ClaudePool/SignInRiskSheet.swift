import SwiftUI

/// Said before the first account signs in, and only then: nothing starts until the person accepts it.
struct SignInRiskSheet: View {
    @Bindable var model: PoolAppModel
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 20)).foregroundStyle(PoolPalette.amber)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 8) {
                    Text(model.t("Claude accounts can be suspended")).font(.system(size: 14, weight: .semibold))
                    Text(model.t("Anthropic may suspend or ban a Claude account it sees used outside its own apps. Claude Pool sends requests through Claude Code, but Anthropic may still act on them; you use it at your own risk. Use an account you can afford to lose."))
                        .font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            HStack(spacing: 8) {
                Spacer()
                Button(model.t("Cancel")) { model.cancelSignInRisk() }.keyboardShortcut(.cancelAction)
                    .accessibilityIdentifier("signInRisk.cancel")
                // No default key: going on takes a deliberate click.
                Button(model.t("Sign in anyway")) { model.acceptSignInRisk() }.buttonStyle(.borderedProminent)
                    .accessibilityIdentifier("signInRisk.accept")
            }
        }.padding(20).frame(width: 420).background(PoolPalette.background)
            .tint(PoolPalette.accent).environment(\.locale, model.locale).preferredColorScheme(model.preferredColorScheme)
    }
}
