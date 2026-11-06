import AppKit
import SwiftUI

/// What the quit panel shows. Quitting has no window of its own to speak from: the menu has just
/// closed and the main window may not be open.
struct QuitIndicatorView: View {
    let title: String
    let detail: String

    var body: some View {
        HStack(spacing: 12) {
            ProgressView().controlSize(.small)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 13, weight: .semibold))
                Text(detail).font(.system(size: 11)).foregroundStyle(.secondary)
            }.fixedSize()
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .accessibilityElement(children: .combine)
    }
}

/// A small panel at the top of the screen for as long as quitting takes. It never takes focus or
/// clicks, and appears over full-screen apps and on every Space.
@MainActor
final class QuitIndicator {
    private let panel: NSPanel

    init(model: PoolAppModel) {
        let content = QuitIndicatorView(title: model.t("Quitting Claude Pool"),
                                        detail: model.t("Ending Claude sessions. This takes a few seconds."))
            .environment(\.locale, model.locale).preferredColorScheme(model.preferredColorScheme)
        let host = NSHostingView(rootView: content)
        let size = host.fittingSize
        panel = NSPanel(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: false)
        panel.contentView = host
        panel.isOpaque = false; panel.backgroundColor = .clear; panel.hasShadow = true
        panel.isReleasedWhenClosed = false; panel.ignoresMouseEvents = true; panel.hidesOnDeactivate = false
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        if let frame = (NSScreen.main ?? NSScreen.screens.first)?.visibleFrame {
            panel.setFrameOrigin(NSPoint(x: frame.midX - size.width / 2, y: frame.maxY - size.height - 12))
        }
        panel.orderFrontRegardless()
    }

    func close() { panel.close() }
}
