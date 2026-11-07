import SwiftUI
import PoolPrivacy

struct PrivacyPreparationRow: View {
    @Bindable var model: PoolAppModel
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "shield.lefthalf.filled").foregroundStyle(PoolPalette.accent).frame(width: 16)
            VStack(alignment: .leading, spacing: 4) {
                Text(model.t("Sensitive data redaction")).font(.system(size: 11, weight: .medium))
                Text(model.privacyStatusTitle).font(.system(size: 10)).foregroundStyle(.secondary)
            }
            Spacer(minLength: 3)
            PrivacyInstallButton(model: model)
        }
    }
}

struct PrivacyInstallButton: View {
    @Bindable var model: PoolAppModel
    var body: some View {
        if model.privacy.phase == .installing {
            if let progress = model.privacy.progress { ProgressView(value: progress).frame(width: 90) }
            else { ProgressView().controlSize(.small) }
        } else if model.privacy.phase != .ready {
            Button(model.t(model.privacy.phase == .failed ? "Try again" : "Prepare redaction")) { model.perform(.installPrivacyModel) }
                .controlSize(.small).disabled(!model.snapshot.executableReady || model.isWorking)
                .accessibilityIdentifier("privacy.install")
        }
    }
}

/// Says the developer recording is on, wherever redaction or the log is shown, with its folder and off.
struct DeveloperRecordingBanner: View {
    @Bindable var model: PoolAppModel
    @State private var confirmsDelete = false
    var body: some View {
        if let recording = model.developerRecording {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: "record.circle").foregroundStyle(PoolPalette.amber)
                VStack(alignment: .leading, spacing: 3) {
                    Text(model.t("Developer recording is on")).font(.system(size: 11, weight: .semibold))
                    Text(recording.until.map { model.t("Message text and redaction originals are kept on this Mac until {0}.", $0.formatted(Date.FormatStyle(date: .abbreviated, time: .shortened).locale(model.locale))) }
                         ?? model.t("Message text and redaction originals are kept on this Mac for this launch."))
                        .font(.system(size: 10)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 6)
                Button(model.t("Show in Finder")) { model.perform(.showDeveloperRecording) }.controlSize(.small)
                    .accessibilityIdentifier("devrecord.show")
                Menu(model.t("Turn off")) {
                    Button(model.t("Turn off and keep records")) { model.perform(.stopDeveloperRecording(delete: false)) }
                    Button(model.t("Turn off and delete records"), role: .destructive) { confirmsDelete = true }
                }.controlSize(.small).fixedSize().accessibilityIdentifier("devrecord.off")
            }
            .padding(10)
            .background(PoolPalette.amber.opacity(0.08), in: RoundedRectangle(cornerRadius: 7))
            .overlay(RoundedRectangle(cornerRadius: 7).stroke(PoolPalette.amber.opacity(0.3)))
            .confirmationDialog(model.t("Delete every developer record?"), isPresented: $confirmsDelete) {
                Button(model.t("Delete records"), role: .destructive) { model.perform(.stopDeveloperRecording(delete: true)) }
            }
            .accessibilityIdentifier("devrecord.banner")
        }
    }
}

struct PrivacyDetailsSheet: View {
    @Bindable var model: PoolAppModel
    @Environment(\.dismiss) private var dismiss
    @State private var input = ""
    init(model: PoolAppModel, initialText: String = "") {
        self.model = model; _input = State(initialValue: initialText)
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                PoolSettingLabel(title: model.t("Sensitive data redaction"), systemImage: "shield.lefthalf.filled").font(.system(size: 15, weight: .semibold))
                Spacer()
                Button(model.t("Close")) { dismiss() }.keyboardShortcut(.cancelAction).accessibilityIdentifier("privacy.close")
            }.padding(18)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    DeveloperRecordingBanner(model: model)
                    HStack(spacing: 10) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("AstrLink Guard").font(.system(size: 12, weight: .semibold))
                            Text(model.privacy.modelVersion.map { model.t("Version {0}", $0) } ?? model.privacyStatusTitle)
                                .font(.system(size: 10)).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if model.privacy.phase == .ready { PoolBadge(title: model.privacyStatusTitle) }
                        else { PrivacyInstallButton(model: model) }
                    }
                    Text(model.t("All supported kinds of sensitive data are redacted."))
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                    HStack(alignment: .firstTextBaseline, spacing: 20) {
                        statistic(model.privacy.protectedCount, title: "Redacted items")
                        statistic(model.privacy.requestCount, title: "Inspected requests")
                        Spacer()
                        Text(model.t("This run")).font(.system(size: 10)).foregroundStyle(.secondary)
                    }
                    if let message = model.privacy.message {
                        Text(model.t(message)).font(.system(size: 11)).foregroundStyle(PoolPalette.amber)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Divider()
                    PrivacyReviewList(model: model)
                    Divider()
                    Text(model.t("Try a local preview")).font(.system(size: 12, weight: .semibold))
                    PoolTextEditor(text: $input, placeholder: model.t("Paste sample text to preview locally."),
                                   accessibilityLabel: model.t("Text to inspect"), identifier: "privacy.input", isEditable: model.privacyPreview.phase != .working)
                        .frame(height: 74).accessibilityIdentifier("privacy.input")
                        .background(Color.primary.opacity(0.03), in: RoundedRectangle(cornerRadius: 7))
                        .overlay(RoundedRectangle(cornerRadius: 7).stroke(PoolPalette.line))
                    HStack(alignment: .firstTextBaseline) {
                        Text(model.t("Text in images is not detected.")).font(.system(size: 10)).foregroundStyle(.secondary)
                        Spacer()
                        Button(model.t(model.privacyPreview.phase == .working ? "Inspecting…" : "Preview locally")) { model.perform(.previewPrivacy(input)) }
                            .controlSize(.small).disabled(input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || model.privacy.phase != .ready || model.privacyPreview.phase == .working)
                            .accessibilityIdentifier("privacy.preview")
                    }
                    if model.privacyPreview.phase == .ready {
                        VStack(alignment: .leading, spacing: 8) {
                            Text(model.t("Redacted items: {0}", "\(model.privacyPreview.protectedCount)"))
                                .font(.system(size: 11, weight: .medium))
                            Text(model.privacyPreview.text).font(.system(size: 11, design: .monospaced)).textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading).padding(10)
                                .background(PoolPalette.good.opacity(0.06), in: RoundedRectangle(cornerRadius: 7))
                                .accessibilityIdentifier("privacy.result")
                            ForEach(model.privacyPreview.categories) { category in
                                HStack {
                                    Text(model.t(category.title))
                                    Spacer()
                                    Text("\(category.count)").monospacedDigit()
                                }.font(.system(size: 10)).foregroundStyle(.secondary)
                            }
                        }
                    } else if let message = model.privacyPreview.message {
                        Text(model.t(message)).font(.system(size: 11)).foregroundStyle(PoolPalette.amber)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }.padding(18)
            }
        }.frame(width: 640, height: 620).background(PoolPalette.background)
            .preferredColorScheme(model.preferredColorScheme)
            .onChange(of: input) { _, _ in
                if model.privacyPreview.phase != .idle && model.privacyPreview.phase != .working { model.perform(.clearPrivacyPreview) }
            }
            .onDisappear { input = ""; model.perform(.clearPrivacyPreview) }
    }
    private func statistic(_ value: Int, title: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("\(value)").font(.system(size: 18, weight: .medium, design: .rounded)).monospacedDigit()
            Text(model.t(title)).font(.system(size: 10)).foregroundStyle(.secondary)
        }
    }
}

enum PrivacyReviewMode: String, CaseIterable, Identifiable {
    case sideBySide, received, sent
    var id: String { rawValue }
    var title: String {
        switch self { case .sideBySide: return "Side by side"; case .received: return "Received"; case .sent: return "Sent" }
    }
}

/// Recent protected requests: what came in, what Claude was sent instead, and what was put back
/// into the reply. Held in memory only.
struct PrivacyReviewList: View {
    @Bindable var model: PoolAppModel
    @State private var expanded: UUID?
    @State private var mode: PrivacyReviewMode = .sideBySide
    /// Fields of the open review shown so far.
    @State private var shown = PrivacyReviewList.page
    static let page = 6
    init(model: PoolAppModel, expanded: UUID? = nil) {
        self.model = model; _expanded = State(initialValue: expanded)
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(model.t("Recent requests")).font(.system(size: 12, weight: .semibold))
                Spacer()
                if !model.privacyReviews.isEmpty {
                    Button(model.t("Clear")) { expanded = nil; model.perform(.clearPrivacyReview) }
                        .buttonStyle(.link).font(.system(size: 11)).accessibilityIdentifier("privacy.clearReview")
                }
            }
            Text(model.t(model.developerRecording == nil ? "Kept in memory only, never written to disk, and gone when Claude Pool quits."
                         : "The developer recording also keeps these requests whole on this Mac."))
                .font(.system(size: 10)).foregroundStyle(.secondary)
            if model.privacyReviews.isEmpty {
                Text(model.t("Requests that had something redacted appear here."))
                    .font(.system(size: 11)).foregroundStyle(.tertiary).frame(maxWidth: .infinity, alignment: .leading).padding(10)
                    .background(Color.primary.opacity(0.03), in: RoundedRectangle(cornerRadius: 7))
            } else {
                LazyVStack(spacing: 6) { ForEach(model.privacyReviews) { review in row(review) } }
            }
        }.accessibilityIdentifier("privacy.review")
    }

    private func row(_ review: PrivacyReview) -> some View {
        let open = expanded == review.id
        return VStack(alignment: .leading, spacing: 10) {
            Button {
                expanded = open ? nil : review.id; shown = Self.page
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "chevron.right").font(.system(size: 9, weight: .semibold)).foregroundStyle(.secondary)
                        .rotationEffect(.degrees(open ? 90 : 0)).poolAnimation(PoolMotion.quick, value: open)
                    Text(model.clockTime(review.at)).font(.system(size: 11, weight: .medium)).monospacedDigit()
                    Text(model.t("{0} redacted", "\(review.replacedCount)")).font(.system(size: 11)).foregroundStyle(.secondary)
                    if review.restored > 0 {
                        Text(model.t("{0} put back", "\(review.restored)")).font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 6)
                    ForEach(kinds(review).prefix(3), id: \.self) { kind in
                        Text(model.t(kind.rawValue)).font(.system(size: 9, weight: .semibold)).foregroundStyle(PoolPalette.amber)
                            .padding(.horizontal, 6).padding(.vertical, 2).background(PoolPalette.amber.opacity(0.12), in: Capsule())
                    }
                }.contentShape(Rectangle())
            }.buttonStyle(.plain).accessibilityIdentifier("privacy.reviewRow")
            if open {
                // No transition: laying out long text on every frame of one is what made opening a row slow.
                VStack(alignment: .leading, spacing: 10) {
                    steps(review)
                    Picker(model.t("Show"), selection: $mode) {
                        ForEach(PrivacyReviewMode.allCases) { Text(model.t($0.title)).tag($0) }
                    }.pickerStyle(.segmented).labelsHidden().controlSize(.small).frame(maxWidth: 300)
                    // Not lazy inside this VStack anyway, so the parts shown are few and more come on asking.
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(Array(review.fields.prefix(shown).enumerated()), id: \.offset) { index, field in
                            PrivacyFieldView(reviewID: review.id, index: index, field: field, mode: mode, place: place(field.location),
                                             received: model.t("Received"), sent: model.t("Sent")).equatable()
                        }
                    }
                    if review.fields.count > shown {
                        Button(model.t("Show {0} more", "\(min(Self.page, review.fields.count - shown))")) { shown += Self.page }
                            .buttonStyle(.link).font(.system(size: 11)).accessibilityIdentifier("privacy.reviewMore")
                    }
                    if review.omitted > 0 {
                        Text(model.t("{0} more parts not kept", "\(review.omitted)")).font(.system(size: 10)).foregroundStyle(.tertiary)
                    }
                }
            }
        }.padding(10).background(Color.primary.opacity(0.03), in: RoundedRectangle(cornerRadius: 8))
    }

    /// What happened to the request, in order.
    private func steps(_ review: PrivacyReview) -> some View {
        let parts = [model.t("Received"), model.t("Found {0}", "\(review.replacedCount)"), model.t("Sent with placeholders"),
                     model.t("Put back {0}", "\(review.restored)")]
        return HStack(spacing: 6) {
            ForEach(Array(parts.enumerated()), id: \.offset) { index, part in
                if index > 0 { Image(systemName: "arrow.right").font(.system(size: 8, weight: .semibold)).foregroundStyle(.tertiary) }
                Text(part).font(.system(size: 10, weight: .medium)).foregroundStyle(.secondary)
            }
        }
    }

    private func kinds(_ review: PrivacyReview) -> [PrivacyCategory] {
        review.categories.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key.rawValue < $1.key.rawValue }.map(\.key)
    }
    /// "Instructions", "Message 3", "Message 3 · tool result".
    private func place(_ location: String) -> String {
        let parts = location.split(separator: "/").map(String.init)
        switch parts.first {
        case "system": return model.t("Instructions")
        case "tools": return model.t("Tool {0}", parts.count > 1 ? parts[1].replacingOccurrences(of: "~1", with: "/").replacingOccurrences(of: "~0", with: "~") : "")
        case "messages":
            let number = parts.count > 1 ? Int(parts[1]).map { "\($0 + 1)" } ?? parts[1] : ""
            if parts.count > 4, parts[4] == "input" { return model.t("Message {0} · tool input", number) }
            if parts.count > 4, parts[4] == "content" { return model.t("Message {0} · tool result", number) }
            return model.t("Message {0}", number)
        default: return location
        }
    }
}

/// One field of a review. A review never changes what its fields say, so comparing where it is says
/// everything: the marked-up text is not built again each time the app's model changes.
private struct PrivacyFieldView: View, Equatable {
    let reviewID: UUID
    let index: Int
    let field: PrivacyReviewField
    let mode: PrivacyReviewMode
    let place: String
    let received: String
    let sent: String
    static func == (a: Self, b: Self) -> Bool {
        a.reviewID == b.reviewID && a.index == b.index && a.mode == b.mode && a.place == b.place && a.received == b.received
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(place).font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
            switch mode {
            case .sideBySide:
                HStack(alignment: .top, spacing: 8) {
                    column(received, sent: false)
                    column(sent, sent: true)
                }
            case .received: column(nil, sent: false)
            case .sent: column(nil, sent: true)
            }
        }
    }
    private func column(_ title: String?, sent: Bool) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            if let title { Text(title).font(.system(size: 9, weight: .medium)).foregroundStyle(.tertiary) }
            // AppKit text, not SwiftUI's Text: a tool result of hundreds of KB laid out as one selectable
            // Text froze the window; NSTextView lays out only what is on screen and scrolls within its box.
            PrivacyReviewText(segments: field.segments, sent: sent)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(PoolPalette.surface, in: RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(PoolPalette.line))
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// A review's text, read-only and selectable, each replaced value or placeholder marked. Short text takes
/// its own height; long text stops at `mostHeight` and scrolls inside.
private struct PrivacyReviewText: NSViewRepresentable {
    let segments: [PrivacyReviewSegment]
    let sent: Bool
    static let mostHeight: CGFloat = 240
    /// Longer than this, the height is not measured: measuring means laying all of it out.
    static let measuredLength = 3_000
    private static let inset = NSSize(width: 8, height: 8)

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder
        let view = NSTextView(frame: .zero)
        view.isEditable = false
        view.isSelectable = true
        view.isRichText = true
        view.drawsBackground = false
        view.isVerticallyResizable = true
        view.isHorizontallyResizable = false
        view.autoresizingMask = [.width]
        view.textContainer?.widthTracksTextView = true
        view.textContainer?.containerSize = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
        view.textContainer?.lineFragmentPadding = 0
        view.textContainerInset = Self.inset
        view.layoutManager?.allowsNonContiguousLayout = true
        view.textStorage?.setAttributedString(attributed())
        scroll.documentView = view
        return scroll
    }
    // The text is set once: a review never changes, and the field view above is Equatable.
    func updateNSView(_ scroll: NSScrollView, context: Context) {}

    func sizeThatFits(_ proposal: ProposedViewSize, nsView scroll: NSScrollView, context: Context) -> CGSize? {
        let width = proposal.width ?? 300
        guard let view = scroll.documentView as? NSTextView, let layout = view.layoutManager, let container = view.textContainer,
              (view.textStorage?.length ?? 0) <= Self.measuredLength else { return CGSize(width: width, height: Self.mostHeight) }
        container.containerSize = NSSize(width: max(1, width - 2 * Self.inset.width), height: .greatestFiniteMagnitude)
        layout.ensureLayout(for: container)
        let height = ceil(layout.usedRect(for: container).height) + 2 * Self.inset.height
        return CGSize(width: width, height: min(max(height, 28), Self.mostHeight))
    }

    private func attributed() -> NSAttributedString {
        let plain: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedSystemFont(ofSize: 11, weight: .regular), .foregroundColor: NSColor.labelColor]
        let tint = NSColor(sent ? PoolPalette.good : PoolPalette.amber)
        let marked: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedSystemFont(ofSize: 11, weight: .semibold),
                                                     .foregroundColor: tint, .backgroundColor: tint.withAlphaComponent(0.14)]
        let result = NSMutableAttributedString()
        for segment in segments {
            switch segment {
            case .text(let text): result.append(NSAttributedString(string: text, attributes: plain))
            case .replaced(let original, let placeholder, _):
                result.append(NSAttributedString(string: sent ? placeholder : original, attributes: marked))
            }
        }
        return result
    }
}
