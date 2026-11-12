import SwiftUI

/// The one way every page marks how an account is used: "2 conversations" when Desktop conversations
/// are on it, accent with a breathing dot while one is answering, quiet while they wait for the next
/// message. There is no "current" account: each conversation has its own.
struct AccountUseBadges: View {
    @Bindable var model: PoolAppModel
    let use: AccountUse?
    var body: some View {
        HStack(spacing: 4) {
            if let use, use.conversations > 0 {
                HStack(spacing: 3) {
                    if use.working { WorkingDot(color: PoolPalette.accent) }
                    Text(model.conversationCountText(use.conversations))
                }
                .poolBadge(color: use.working ? PoolPalette.accent : .secondary)
                .help(model.t(use.working ? "A conversation on this account is answering." : "Its conversations are waiting for your next message."))
            }
        }
        .poolAnimation(PoolMotion.quick, value: use)
    }
}

/// A small dot that breathes while work is under way; still with reduced motion.
struct WorkingDot: View {
    let color: Color
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var windowVisible = true
    var body: some View {
        if reduceMotion {
            dot.opacity(1).accessibilityHidden(true)
        } else {
            TimelineView(.animation(minimumInterval: 1 / 8, paused: !windowVisible)) { context in
                // 1.6 s breathing cycle between 0.35 and 1.
                let phase = (sin(context.date.timeIntervalSinceReferenceDate * 2 * .pi / 1.6) + 1) / 2
                dot.opacity(0.35 + 0.65 * phase)
            }
            .poolTrackWindowVisible($windowVisible)
            .accessibilityHidden(true)
        }
    }
    private var dot: some View { Circle().fill(color).frame(width: 5, height: 5) }
}

extension View {
    func poolBadge(color: Color, outlined: Bool = false) -> some View {
        font(.system(size: 9, weight: .semibold)).foregroundStyle(color).lineLimit(1).fixedSize()
            .padding(.horizontal, 5).padding(.vertical, 1)
            .background(outlined ? Color.clear : color.opacity(0.12), in: Capsule())
            .overlay(Capsule().stroke(outlined ? color.opacity(0.45) : .clear, lineWidth: 0.8))
    }
}
