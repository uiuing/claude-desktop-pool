import XCTest
import SwiftUI
import PoolPrivacy
@testable import ClaudePool

/// Opening a review that holds a large tool result froze the window: the text was laid out whole.
@MainActor
final class PrivacyReviewLoadTests: XCTestCase {
    func testOpeningALargeReviewLaysOutQuickly() throws {
        let model = PoolAppModel.demoModel(language: "en")
        let long = String(repeating: "plain tool output line with some words in it\n", count: 5_000) // ~225 KB
        let field = PrivacyReviewField(location: "messages/2/content/1/content/0/text", segments: [
            .text(long), .replaced(original: "lin.mei@studio.example", placeholder: "{{EMAIL_1}}", category: .email), .text(long)])
        let review = PrivacyReview(id: UUID(), at: Date(), fields: Array(repeating: field, count: 20), categories: [.email: 20])
        model.privacyReviews = [review]
        let view = NSHostingView(rootView: ScrollView { PrivacyReviewList(model: model, expanded: review.id).padding(18) }
            .frame(width: 640, height: 620))
        view.frame = NSRect(x: 0, y: 0, width: 640, height: 620)
        let began = Date()
        view.layoutSubtreeIfNeeded()
        view.display()
        XCTAssertLessThan(Date().timeIntervalSince(began), 2, "Opening a large review must not stall the window")
    }
}
