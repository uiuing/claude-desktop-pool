import AppKit
import SwiftUI

enum PoolPalette {
    static let accent = adaptive(light: NSColor(red: 0.72, green: 0.36, blue: 0.24, alpha: 1),
                                 dark: NSColor(red: 0.91, green: 0.57, blue: 0.43, alpha: 1))
    static let good = adaptive(light: NSColor(red: 0.24, green: 0.52, blue: 0.39, alpha: 1),
                               dark: NSColor(red: 0.46, green: 0.76, blue: 0.61, alpha: 1))
    static let amber = adaptive(light: NSColor(red: 0.73, green: 0.49, blue: 0.16, alpha: 1),
                                dark: NSColor(red: 0.92, green: 0.68, blue: 0.36, alpha: 1))
    static let background = Color(nsColor: .windowBackgroundColor)
    static let surface = Color(nsColor: .controlBackgroundColor)
    static let line = Color.primary.opacity(0.075)
    /// A card on the menu panel: a step off the panel in both appearances.
    static let panelCard = Color.primary.opacity(0.05)
    static func quota(_ value: Double?) -> Color {
        guard let value else { return .secondary }
        // Healthy reads as plain text; only a limit running low draws the eye.
        return value <= 10 ? .red : value <= 25 ? amber : .primary
    }
    /// A bar or ring: green while healthy, amber when low, red when nearly out.
    static func level(_ value: Double?) -> Color {
        guard let value else { return .secondary }
        return value > 25 ? good : quota(value)
    }
    private static func adaptive(light: NSColor, dark: NSColor) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
        })
    }
}

struct PoolMark: View {
    var size: CGFloat = 36
    var body: some View {
        Group {
            if let image = Self.art {
                Image(decorative: image, scale: 1).resizable().interpolation(.high)
            } else {
                RoundedRectangle(cornerRadius: size * 0.22, style: .continuous).fill(PoolPalette.accent.gradient)
            }
        }.frame(width: size, height: size).accessibilityHidden(true)
    }
    /// Drawn once at a size that downsamples cleanly to every mark in the app.
    private static let art = PoolIconArt.mark(pixels: 192)
}

struct PoolBadge: View {
    let title: String
    var color: Color = PoolPalette.good
    var dot = true
    var body: some View {
        HStack(spacing: 5) {
            if dot { Circle().fill(color).frame(width: 5, height: 5) }
            Text(title).font(.system(size: 11, weight: .medium))
        }
        .foregroundStyle(color).padding(.horizontal, 9).padding(.vertical, 5)
        .background(color.opacity(0.095), in: Capsule())
        .fixedSize()
    }
}

struct PoolCard<Content: View>: View {
    var padding: CGFloat = 14
    @ViewBuilder var content: Content
    var body: some View {
        content.padding(padding).frame(maxWidth: .infinity, alignment: .leading)
            .background(PoolPalette.surface, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous).stroke(PoolPalette.line, lineWidth: 1))
    }
}

/// Motion is short and follows the data: values glide to their new level, lists reorder in place,
/// and nothing moves when the person asked for less motion.
enum PoolMotion {
    /// A figure or bar reaching its new value.
    static let value = Animation.smooth(duration: 0.55)
    /// Rows changing places or appearing.
    static let list = Animation.spring(response: 0.42, dampingFraction: 0.86)
    /// Small state changes: a chip, a hover, a disclosure.
    static let quick = Animation.snappy(duration: 0.22)
    /// A page or a notice coming in.
    static let page = Animation.easeOut(duration: 0.24)
}

/// Buttons answer a press by settling in slightly.
struct PoolPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.scaleEffect(configuration.isPressed ? 0.92 : 1)
            .poolAnimation(PoolMotion.quick, value: configuration.isPressed)
    }
}

/// Reports whether the window holding the view is visible (not covered, minimized or closed), so
/// continuous animations can pause while nobody can see them. Assumes visible until a window says otherwise.
private struct PoolWindowVisibilityReader: NSViewRepresentable {
    @Binding var visible: Bool

    final class Probe: NSView {
        var onChange: (Bool) -> Void = { _ in }
        private var observer: NSObjectProtocol?
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let observer { NotificationCenter.default.removeObserver(observer) }
            observer = nil
            guard let window else { return }
            observer = NotificationCenter.default.addObserver(forName: NSWindow.didChangeOcclusionStateNotification, object: window, queue: .main) { [weak self] _ in
                self?.report()
            }
            report()
        }
        private func report() {
            let value = window?.occlusionState.contains(.visible) ?? true
            DispatchQueue.main.async { [onChange] in onChange(value) }
        }
        deinit { if let observer { NotificationCenter.default.removeObserver(observer) } }
    }

    func makeNSView(context: Context) -> Probe {
        let probe = Probe()
        probe.onChange = { value in if visible != value { visible = value } }
        return probe
    }
    func updateNSView(_ probe: Probe, context: Context) {
        probe.onChange = { value in if visible != value { visible = value } }
    }
}

extension View {
    /// Keeps `visible` in step with whether this view's window can be seen.
    func poolTrackWindowVisible(_ visible: Binding<Bool>) -> some View {
        background(PoolWindowVisibilityReader(visible: visible).frame(width: 0, height: 0))
    }
}

/// What is being read right now breathes gently; it holds still under Reduce Motion.
private struct PoolReadingPulse: ViewModifier {
    let active: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var windowVisible = true
    @ViewBuilder func body(content: Content) -> some View {
        if active && !reduceMotion {
            TimelineView(.animation(minimumInterval: 1 / 12, paused: !windowVisible)) { context in
                let phase = (sin(context.date.timeIntervalSinceReferenceDate * 2 * .pi / 1.4) + 1) / 2
                content.opacity(0.45 + 0.55 * phase)
            }
            .poolTrackWindowVisible($windowVisible)
        } else {
            content.opacity(active ? 0.6 : 1)
        }
    }
}

extension View {
    /// Digits roll to a new value instead of jumping.
    func poolNumeric(_ value: Double?) -> some View { modifier(PoolNumericTransition(value: value)) }
    /// Animates changes of `value` unless Reduce Motion is on.
    func poolAnimation<V: Equatable>(_ animation: Animation, value: V) -> some View { modifier(PoolAnimation(animation: animation, value: value)) }
    /// Marks a figure that is being read now.
    func poolReading(_ active: Bool) -> some View { modifier(PoolReadingPulse(active: active)) }
}

private struct PoolNumericTransition: ViewModifier {
    let value: Double?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    func body(content: Content) -> some View {
        content.contentTransition(reduceMotion ? .identity : .numericText(value: value ?? -1))
            .animation(reduceMotion ? nil : PoolMotion.value, value: value)
    }
}

private struct PoolAnimation<V: Equatable>: ViewModifier {
    let animation: Animation
    let value: V
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    func body(content: Content) -> some View { content.animation(reduceMotion ? nil : animation, value: value) }
}

struct PoolGauge: View {
    let value: Double?
    var height: CGFloat = 5
    var body: some View {
        GeometryReader { bounds in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.065))
                Capsule().fill(PoolPalette.level(value))
                    .frame(width: bounds.size.width * CGFloat(min(100, max(0, value ?? 0))) / 100)
                    .opacity(value == nil ? 0 : 1)
            }
        }.frame(height: height).poolAnimation(PoolMotion.value, value: value).accessibilityHidden(true)
    }
}

/// Takes the room it is offered without asking what is inside it. A window works out its smallest and
/// largest sizes at every change by trying widths and heights on its content, a width of nothing among
/// them, and a scroll view lays out all it holds for each: with many runs working that was most of the
/// main thread. Only a size nobody set, the page's own, is still asked of the page.
struct PoolFill: Layout {
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        if let width = proposal.width, let height = proposal.height { return CGSize(width: width, height: height) }
        let own = subviews.first?.sizeThatFits(proposal) ?? .zero
        return CGSize(width: proposal.width ?? own.width, height: proposal.height ?? own.height)
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for subview in subviews { subview.place(at: bounds.origin, anchor: .topLeading, proposal: .init(bounds.size)) }
    }
    // It has no guides of its own either: the stack around it asks for them while it sizes itself,
    // and working them out from what is inside would lay the page out at every size the window tries.
    func explicitAlignment(of guide: HorizontalAlignment, in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGFloat? { nil }
    func explicitAlignment(of guide: VerticalAlignment, in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGFloat? { nil }
}

struct PoolSecondaryButton: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(.system(size: 12, weight: .medium))
            .padding(.horizontal, 12).padding(.vertical, 8)
            .background(Color.primary.opacity(configuration.isPressed ? 0.09 : 0.045), in: RoundedRectangle(cornerRadius: 8))
            .contentShape(RoundedRectangle(cornerRadius: 8))
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .opacity(isEnabled ? 1 : 0.45)
            .poolAnimation(PoolMotion.quick, value: configuration.isPressed)
    }
}

struct PoolSectionHeading<Accessory: View>: View {
    let title: String
    @ViewBuilder var accessory: Accessory
    var body: some View {
        HStack {
            Text(title).font(.system(size: 15, weight: .semibold))
            Spacer()
            accessory
        }
    }
}

struct PoolSettingLabel: View {
    let title: String
    let systemImage: String
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: systemImage).frame(width: 16)
            Text(title)
        }
    }
}

struct PoolTextEditor: NSViewRepresentable {
    @Binding var text: String
    let placeholder: String
    let accessibilityLabel: String
    let identifier: String
    var isEditable = true
    @Environment(\.colorScheme) private var colorScheme

    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        let editor = PoolPlaceholderTextView(frame: NSRect(x: 0, y: 0, width: 0, height: 74))
        editor.isRichText = false
        editor.importsGraphics = false
        editor.allowsUndo = true
        editor.drawsBackground = false
        editor.isVerticallyResizable = true
        editor.isHorizontallyResizable = false
        editor.autoresizingMask = [.width]
        editor.textContainer?.widthTracksTextView = true
        editor.textContainer?.containerSize = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
        editor.textContainer?.lineFragmentPadding = 0
        editor.textContainerInset = NSSize(width: 10, height: 8)
        editor.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        editor.textColor = .labelColor
        editor.isAutomaticQuoteSubstitutionEnabled = false
        editor.isAutomaticDashSubstitutionEnabled = false
        editor.isAutomaticTextReplacementEnabled = false
        editor.delegate = context.coordinator
        scroll.documentView = editor
        return scroll
    }
    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let editor = scroll.documentView as? PoolPlaceholderTextView else { return }
        context.coordinator.parent = self
        if editor.string != text { editor.string = text }
        editor.placeholder = placeholder
        editor.isEditable = isEditable
        editor.setAccessibilityLabel(accessibilityLabel)
        editor.setAccessibilityIdentifier(identifier)
        scroll.appearance = NSAppearance(named: colorScheme == .dark ? .darkAqua : .aqua)
        editor.needsDisplay = true
    }
    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: PoolTextEditor
        init(_ parent: PoolTextEditor) { self.parent = parent }
        func textDidChange(_ notification: Notification) {
            guard let editor = notification.object as? NSTextView else { return }
            parent.text = editor.string
            editor.needsDisplay = true
        }
    }
}

final class PoolPlaceholderTextView: NSTextView {
    var placeholder = ""
    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard string.isEmpty, let textContainer, let font else { return }
        let storage = NSTextStorage(string: placeholder, attributes: [.font: font, .foregroundColor: NSColor.placeholderTextColor])
        let layout = NSLayoutManager()
        layout.usesFontLeading = layoutManager?.usesFontLeading ?? true
        let container = NSTextContainer(containerSize: textContainer.containerSize)
        container.lineFragmentPadding = textContainer.lineFragmentPadding
        storage.addLayoutManager(layout)
        layout.addTextContainer(container)
        layout.drawGlyphs(forGlyphRange: layout.glyphRange(for: container), at: textContainerOrigin)
    }
}
