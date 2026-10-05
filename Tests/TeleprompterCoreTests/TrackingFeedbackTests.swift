import XCTest
@testable import TeleprompterCore

final class TrackingFeedbackTests: XCTestCase {
    let date = Date(timeIntervalSince1970: 100)
    func testDistinctMissesEnterRecoveryAndReliableMatchRestoresFollowing() {
        var feedback = TrackingFeedback()
        feedback.consume("wrong words", confidence: .low, at: date)
        feedback.consume("another miss", confidence: .low, at: date.addingTimeInterval(1.9))
        XCTAssertEqual(feedback.state, .listening)
        feedback.consume("still something different", confidence: .low, at: date.addingTimeInterval(2.1))
        XCTAssertEqual(feedback.state, .recovering)
        feedback.consume("the wooden horse", confidence: .high, at: date.addingTimeInterval(3))
        XCTAssertEqual(feedback.state, .following)
    }
    func testSilenceAndDuplicateCallbacksNeverTriggerRecovery() {
        var feedback = TrackingFeedback()
        feedback.consume("unmatched speech", confidence: .low, at: date)
        feedback.consume("Unmatched speech!", confidence: .low, at: date.addingTimeInterval(20))
        feedback.consume("", confidence: .low, at: date.addingTimeInterval(40))
        XCTAssertEqual(feedback.state, .listening)
        feedback.consume("matched speech", confidence: .medium, at: date.addingTimeInterval(41))
        feedback.consume("", confidence: .low, at: date.addingTimeInterval(60))
        XCTAssertEqual(feedback.state, .following)
        feedback.reset()
        XCTAssertEqual(feedback.state, .listening)
    }
}
