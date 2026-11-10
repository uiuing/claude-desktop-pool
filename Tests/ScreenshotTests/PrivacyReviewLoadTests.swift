import XCTest
import SwiftUI
import PoolPrivacy
@testable import ClaudePool

/// Opening a review that holds a large tool result froze the window: the text was laid out whole.
@MainActor
final class PrivacyReviewLoadTests: XCTestCase {
    /// The open review shows its first page of fields, so one of twenty large fields opens about as
    /// fast as one holding only a page of them. Laid out whole it takes about three times as long.
    /// Measured against itself, not a fixed time, so a slower machine does not fail it.
    func testOpeningALargeReviewLaysOutQuickly() throws {
        let long = String(repeating: "plain tool output line with some words in it\n", count: 5_000) // ~225 KB
        let field = PrivacyReviewField(location: "messages/2/content/1/content/0/text", segments: [
            .text(long), .replaced(original: "lin.mei@studio.example", placeholder: "{{EMAIL_1}}", category: .email), .text(long)])
        func open(_ count: Int) -> TimeInterval {
            let model = PoolAppModel.demoModel(language: "en")
            let review = PrivacyReview(id: UUID(), at: Date(), fields: Array(repeating: field, count: count), categories: [.email: count])
            model.privacyReviews = [review]
            let view = NSHostingView(rootView: ScrollView { PrivacyReviewList(model: model, expanded: review.id).padding(18) }
                .frame(width: 640, height: 620))
            view.frame = NSRect(x: 0, y: 0, width: 640, height: 620)
            let began = Date()
            view.layoutSubtreeIfNeeded()
            view.display()
            return Date().timeIntervalSince(began)
        }
        let page = open(PrivacyReviewList.page), large = open(20)
        XCTAssertLessThan(large, page * 2 + 0.25, "Opening a large review must lay out only its first page")
    }
}
