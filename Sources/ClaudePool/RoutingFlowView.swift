import SwiftUI
import PoolCore

/// Desktop on the left, redaction in the middle, and on the right every account Desktop's conversations
/// are on, one line each: there is no single "current" account. Below, each conversation says what it
/// is doing and where it is.
struct RoutingFlowView: View {
    @Bindable var model: PoolAppModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// At most this many account lanes; more accounts in use show as "+N".
    static let laneLimit = 3

    struct Lane: Identifiable, Equatable {
        var id: UUID { accountID }
        var accountID: UUID
        var conversations: Int
        var working: Bool
    }

    var body: some View {
        let conversations = model.conversations
        let use = model.accountUse
        let lanes = Self.lanes(use)
        let hidden = use.count - lanes.filter { $0.conversations > 0 }.count
        let working = conversations.contains { isAnswering($0) }
        PoolCard {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 8) {
                    Text(model.t("Live route")).font(.system(size: 13, weight: .semibold))
                    Spacer()
                    Text(model.useSummaryText).font(.system(size: 10, weight: .medium))
                        .foregroundStyle(working ? PoolPalette.accent : .secondary).monospacedDigit()
                        .accessibilityIdentifier("routing.conversations")
                }
                flow(lanes: lanes, hidden: hidden, working: working)
                conversationList(conversations)
            }
        }
        .animation(reduceMotion ? nil : PoolMotion.list, value: lanes)
        .animation(reduceMotion ? nil : PoolMotion.list, value: conversations)
    }

    /// Accounts with a conversation's run on them (sub-agents on another account included),
    /// answering ones first, then by how many.
    static func lanes(_ use: [UUID: AccountUse]) -> [Lane] {
        let lanes = use.map { id, use in
            Lane(accountID: id, conversations: use.conversations, working: use.working)
        }.sorted { a, b in
            if a.working != b.working { return a.working }
            if a.conversations != b.conversations { return a.conversations > b.conversations }
            return a.accountID.uuidString < b.accountID.uuidString
        }
        return Array(lanes.prefix(laneLimit))
    }

    private func isAnswering(_ conversation: PoolConversation) -> Bool {
        guard model.snapshot.mode == .running || model.snapshot.mode == .stopping else { return false }
        return conversation.isWorking && conversation.state != .waiting
    }

    private static let laneHeight: CGFloat = 40, laneGap: CGFloat = 8
    private func flow(lanes: [Lane], hidden: Int, working: Bool) -> some View {
        let count = CGFloat(max(1, lanes.count))
        let height = max(104, count * Self.laneHeight + (count - 1) * Self.laneGap + (hidden > 0 ? 18 : 0))
        let animate = !model.demo && !reduceMotion && (working || model.privacy.isProcessing)
        return GeometryReader { geometry in
            let laneWidth = min(200, geometry.size.width * 0.42)
            let laneX = geometry.size.width - laneWidth
            let middle = (laneX - 20) * 0.62
            let center = height / 2
            let laneYs = Self.laneCenters(count: lanes.count, height: height - (hidden > 0 ? 18 : 0))
            ZStack(alignment: .topLeading) {
                RouteLines(start: CGPoint(x: 64, y: center - 10), middle: CGPoint(x: middle, y: center - 10),
                           ends: zip(lanes, laneYs).map { lane, y in
                               RouteLines.End(point: CGPoint(x: laneX - 2, y: y), active: lane.working, dashed: lane.conversations == 0)
                           },
                           inspecting: model.privacy.isProcessing, flowing: working, animate: animate, frozen: model.demo)
                    .accessibilityHidden(true)
                node(symbol: "desktopcomputer", title: "Claude Desktop", detail: model.conversationCountText(model.conversations.count),
                     color: .secondary, width: 98)
                    .position(x: 44, y: center + 6)
                node(symbol: !model.preferences.redaction ? "shield.slash" : model.privacy.phase == .ready ? "shield.checkered" : "shield.lefthalf.filled",
                     title: model.t("Sensitive data redaction"), detail: model.privacyStatusTitle,
                     color: !model.preferences.redaction ? .secondary : model.privacy.phase == .ready ? PoolPalette.good : PoolPalette.amber, width: 106)
                    .position(x: middle, y: center + 6)
                ForEach(Array(zip(lanes, laneYs)), id: \.0.id) { lane, y in
                    laneView(lane).frame(width: laneWidth, height: Self.laneHeight)
                        .position(x: laneX + laneWidth / 2, y: y)
                        .transition(.opacity.combined(with: .move(edge: .trailing)))
                }
                if hidden > 0 {
                    Text(model.t("+{0} more accounts", "\(hidden)")).font(.system(size: 9)).foregroundStyle(.secondary)
                        .position(x: laneX + laneWidth / 2, y: height - 8)
                }
                if lanes.isEmpty {
                    laneView(nil).frame(width: laneWidth, height: Self.laneHeight).position(x: laneX + laneWidth / 2, y: center - 10)
                }
            }
        }.frame(height: height)
    }
    private static func laneCenters(count: Int, height: CGFloat) -> [CGFloat] {
        let total = CGFloat(count) * laneHeight + CGFloat(max(0, count - 1)) * laneGap
        let top = (height - total) / 2 - 10
        let half: CGFloat = laneHeight / 2, step: CGFloat = laneHeight + laneGap
        return (0..<count).map { index -> CGFloat in
            let center: CGFloat = top + half + CGFloat(index) * step
            return Swift.max(half, center)
        }
    }

    /// One account on the right: who, and how it is used, with the same badges as everywhere else.
    private func laneView(_ lane: Lane?) -> some View {
        let color: Color = lane?.working == true ? PoolPalette.accent : lane?.conversations ?? 0 > 0 ? .primary : .secondary
        return HStack(spacing: 7) {
            Image(systemName: lane == nil ? "person.crop.circle.dashed" : "person.crop.circle")
                .font(.system(size: 15, weight: .light)).foregroundStyle(lane?.working == true ? PoolPalette.accent : .secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(lane.map { model.accountName($0.accountID) } ?? model.t("No conversations"))
                    .font(.system(size: 10, weight: .medium)).foregroundStyle(color).fixedSize(horizontal: false, vertical: true)
                if let lane {
                    AccountUseBadges(model: model, use: lane.conversations > 0 ? AccountUse(conversations: lane.conversations, working: lane.working) : nil)
                    if let account = model.snapshot.accounts.first(where: { $0.id == lane.accountID }), let brief = model.accountBrief(account) {
                        Text(brief).font(.system(size: 9)).foregroundStyle(.secondary).monospacedDigit().lineLimit(1).minimumScaleFactor(0.8)
                            .help(model.accountQuotaSummary(account))
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8)
        .frame(maxHeight: .infinity)
        .background((lane?.working == true ? PoolPalette.accent : Color.primary).opacity(lane?.working == true ? 0.07 : 0.035),
                    in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10)
            .stroke(lane?.working == true ? PoolPalette.accent.opacity(0.3) : Color.primary.opacity(0.08),
                    style: StrokeStyle(lineWidth: 1, dash: lane?.conversations ?? 0 > 0 ? [] : [3, 3])))
        .accessibilityElement(children: .combine)
    }

    private func node(symbol: String, title: String, detail: String, color: Color, width: CGFloat) -> some View {
        VStack(spacing: 5) {
            Image(systemName: symbol).font(.system(size: 19, weight: .light)).foregroundStyle(color)
                .frame(width: 44, height: 44)
                .background(color.opacity(0.07), in: RoundedRectangle(cornerRadius: 14))
                .overlay(RoundedRectangle(cornerRadius: 14).stroke(color.opacity(0.18), lineWidth: 1))
            Text(title).font(.system(size: 10, weight: .medium)).multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true).help(title)
            Text(detail).font(.system(size: 9)).foregroundStyle(.secondary).multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true).help(detail)
        }.frame(width: width).accessibilityElement(children: .combine)
    }

    /// Each conversation: its number, model and what it is doing, then the account it is on. A move to
    /// another account says why, and the account name slides in when it changes.
    @ViewBuilder private func conversationList(_ conversations: [PoolConversation]) -> some View {
        if conversations.isEmpty {
            HStack(alignment: .top, spacing: 7) {
                Image(systemName: "arrow.triangle.branch").foregroundStyle(.secondary)
                Text(model.t("Each conversation Desktop starts goes to the account with the most left. It stays there; when that account drops below the switch threshold, it moves at your next message."))
                    .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }.font(.system(size: 10))
        } else {
            VStack(spacing: 0) {
                ForEach(conversations.prefix(5)) { conversation in
                    conversationRow(conversation)
                    if conversation.id != conversations.prefix(5).last?.id { Divider().opacity(0.5) }
                }
                if conversations.count > 5 {
                    Text(model.t("+{0} more conversations", "\(conversations.count - 5)")).font(.system(size: 9)).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading).padding(.top, 6)
                }
            }
        }
    }
    private func conversationRow(_ conversation: PoolConversation) -> some View {
        let answering = isAnswering(conversation)
        let decision = model.routeDecisions.last { $0.sessionID.map(conversation.sessionIDs.contains) ?? false }
        let moved = decision.map { [.lowQuota, .quotaExhausted, .failover].contains($0.reason) } ?? false
        return HStack(spacing: 8) {
            Group {
                if answering { WorkingDot(color: PoolPalette.accent) }
                else { Circle().fill(conversation.state == .attention ? PoolPalette.amber : Color.secondary.opacity(0.4)).frame(width: 5, height: 5) }
            }.frame(width: 8)
            Text(model.t("Conversation {0}", "\(conversation.number)")).font(.system(size: 11, weight: .medium))
            Text(conversation.model).font(.system(size: 10)).foregroundStyle(.secondary)
            Text(model.conversationStateText(conversation.state)).font(.system(size: 10))
                .foregroundStyle(answering ? PoolPalette.accent : conversation.state == .attention ? PoolPalette.amber : .secondary)
            Spacer(minLength: 6)
            if moved, let decision {
                Image(systemName: "arrow.triangle.swap").font(.system(size: 9)).foregroundStyle(PoolPalette.amber)
                    .help(model.routeReason(decision.reason))
            }
            Text(model.accountName(conversation.accountID) + (conversation.accountIDs.count > 1 ? " +\(conversation.accountIDs.count - 1)" : ""))
                .font(.system(size: 10)).foregroundStyle(.secondary)
                .help(conversation.accountIDs.map { model.accountName($0) }.joined(separator: ", "))
                .fixedSize(horizontal: false, vertical: true)
                .id(conversation.accountID)
                .transition(.asymmetric(insertion: .move(edge: .trailing).combined(with: .opacity), removal: .opacity))
        }
        .padding(.vertical, 6)
        .help(decision.map { model.routeReason($0.reason) } ?? "")
        .accessibilityElement(children: .combine)
    }
}

/// Lines from Desktop to redaction and from redaction to each account lane. A dot runs along the lines
/// of accounts answering now; the lane of the account new conversations go to is dashed.
private struct RouteLines: View {
    struct End { var point: CGPoint; var active: Bool; var dashed: Bool }
    let start: CGPoint
    let middle: CGPoint
    let ends: [End]
    let inspecting: Bool
    let flowing: Bool
    let animate: Bool
    let frozen: Bool
    @State private var windowVisible = true

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 12, paused: !animate || !windowVisible)) { timeline in
            Canvas { context, _ in
                let phase = frozen ? 0.43 : timeline.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1.8) / 1.8
                let inbound = Path { $0.move(to: CGPoint(x: start.x, y: start.y)); $0.addLine(to: CGPoint(x: middle.x - 26, y: middle.y)) }
                let inColor = inspecting ? PoolPalette.good : PoolPalette.accent
                let inActive = inspecting || flowing
                context.stroke(inbound, with: .color(inActive ? inColor.opacity(0.28) : Color.primary.opacity(0.1)),
                               style: StrokeStyle(lineWidth: 1.5, lineCap: .round))
                if inActive && (animate || frozen) {
                    dot(context, at: point(on: inbound, from: CGPoint(x: start.x, y: start.y), to: CGPoint(x: middle.x - 26, y: middle.y), t: phase), color: inColor)
                }
                let from = CGPoint(x: middle.x + 26, y: middle.y)
                for end in ends {
                    let c1 = CGPoint(x: from.x + (end.point.x - from.x) * 0.5, y: from.y)
                    let c2 = CGPoint(x: from.x + (end.point.x - from.x) * 0.5, y: end.point.y)
                    let path = Path { $0.move(to: from); $0.addCurve(to: end.point, control1: c1, control2: c2) }
                    context.stroke(path, with: .color(end.active ? PoolPalette.accent.opacity(0.32) : Color.primary.opacity(end.dashed ? 0.14 : 0.1)),
                                   style: StrokeStyle(lineWidth: 1.5, lineCap: .round, dash: end.dashed ? [3, 4] : []))
                    if end.active && (animate || frozen) {
                        dot(context, at: bezier(from, c1, c2, end.point, t: phase), color: PoolPalette.accent)
                    }
                }
            }
        }
        .poolTrackWindowVisible($windowVisible)
    }
    private func point(on _: Path, from a: CGPoint, to b: CGPoint, t: Double) -> CGPoint {
        CGPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t)
    }
    private func bezier(_ p0: CGPoint, _ p1: CGPoint, _ p2: CGPoint, _ p3: CGPoint, t: Double) -> CGPoint {
        let u = 1 - t
        return CGPoint(x: u*u*u*p0.x + 3*u*u*t*p1.x + 3*u*t*t*p2.x + t*t*t*p3.x,
                       y: u*u*u*p0.y + 3*u*u*t*p1.y + 3*u*t*t*p2.y + t*t*t*p3.y)
    }
    private func dot(_ context: GraphicsContext, at p: CGPoint, color: Color) {
        context.fill(Path(ellipseIn: CGRect(x: p.x - 5, y: p.y - 5, width: 10, height: 10)), with: .color(color.opacity(0.12)))
        context.fill(Path(ellipseIn: CGRect(x: p.x - 2.5, y: p.y - 2.5, width: 5, height: 5)), with: .color(color))
    }
}
