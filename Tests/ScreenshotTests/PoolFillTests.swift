import XCTest
import SwiftUI
@testable import ClaudePool

/// The main window took most of the main thread while many runs worked: at every change it tried sizes
/// on its content to find its own smallest and largest, and the scrolling page laid out all it held for each.
@MainActor
final class PoolFillTests: XCTestCase {
    /// What a page was asked, as a layout that stands for it.
    private final class Asked { var proposals: [ProposedViewSize] = [] }
    private struct Page: Layout {
        let asked: Asked
        func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
            asked.proposals.append(proposal)
            return CGSize(width: proposal.width ?? 900, height: proposal.height ?? 1400)
        }
        func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {}
    }
    /// The main window's shape: a side bar, a header and the page under it, with the window's smallest size.
    private func window<Content: View>(@ViewBuilder page: () -> Content) -> some View {
        HStack(spacing: 0) {
            Color.gray.frame(width: 128)
            VStack(spacing: 0) {
                Color.gray.frame(height: 52)
                page()
            }.frame(minWidth: 0, maxWidth: .infinity, maxHeight: .infinity)
        }.frame(minWidth: 640, minHeight: 520)
    }

    func testAWindowSizingItselfDoesNotLayOutAFilledPage() {
        let filled = Asked(), bare = Asked()
        func ask(_ asked: Asked, fill: Bool) -> (placed: Int, sized: Int) {
            let host = NSHostingController(rootView: window {
                if fill { PoolFill { Page(asked: asked) { Color.clear } } } else { Page(asked: asked) { Color.clear } }
            })
            host.view.frame = .init(x: 0, y: 0, width: 700, height: 600)
            host.view.layoutSubtreeIfNeeded()
            let placed = asked.proposals.count
            // what a window asks of its content at every change
            _ = host.view.fittingSize
            _ = host.sizeThatFits(in: .zero)
            _ = host.sizeThatFits(in: .init(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude))
            return (placed, asked.proposals.count - placed)
        }
        let withFill = ask(filled, fill: true), without = ask(bare, fill: false)
        XCTAssertGreaterThan(without.sized, 0, "Without it the window's sizing reaches the page")
        // the window's own ideal size is still the page's: asked once, with no size set
        XCTAssertTrue(filled.proposals.dropFirst(withFill.placed).allSatisfy { $0.width == nil || $0.height == nil },
                      "A window trying a size is answered without the page: \(filled.proposals)")
        XCTAssertLessThan(withFill.sized, without.sized)
        // laid out where it is shown, at the room it has
        XCTAssertTrue(filled.proposals.prefix(withFill.placed).contains { $0.width == 700 - 128 && $0.height == 600 - 52 }, "\(filled.proposals)")
    }

    func testAFilledPageTakesTheRoomItIsGiven() {
        let host = NSHostingController(rootView: window { PoolFill { Color.clear } })
        host.view.frame = .init(x: 0, y: 0, width: 700, height: 600)
        host.view.layoutSubtreeIfNeeded()
        XCTAssertEqual(host.sizeThatFits(in: .zero), .init(width: 640, height: 520), "The window's smallest size is its own")
        XCTAssertEqual(host.sizeThatFits(in: .init(width: 900, height: 800)), .init(width: 900, height: 800))
    }
}
