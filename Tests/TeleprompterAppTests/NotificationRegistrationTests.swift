import XCTest
import Foundation
@testable import TeleprompterApp

@MainActor final class NotificationRegistrationTests: XCTestCase {
    private enum Scope { @TaskLocal static var value = 0 }
    func testTokenRemovalStopsDeliveryWithoutRetainingRegistration() {
        let center = NotificationCenter()
        let counter = NotificationCounter()
        let name = Notification.Name("CameraCue.isolated-test")
        var registration: NotificationRegistration? = NotificationRegistration(center: center, name: name) { _ in counter.increment() }
        center.post(name: name, object: nil)
        XCTAssertEqual(counter.count, 1)
        withExtendedLifetime(registration) {}
        registration = nil
        center.post(name: name, object: nil)
        XCTAssertEqual(counter.count, 1)
    }
    func testSpeechTeardownInsideTaskLocalScopeDoesNotAbort() {
        // Reproduces the runtime context from native hosting-view disposal in CI.
        // Creating the owner registers observers; it never starts audio capture.
        Scope.$value.withValue(1) {
            for _ in 0..<20 {
                weak var released: SpeechFollower?
                autoreleasepool {
                    let speech = SpeechFollower()
                    released = speech
                    withExtendedLifetime(speech) {}
                }
                XCTAssertNil(released)
            }
        }
    }
}
private final class NotificationCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    var count: Int { lock.lock(); defer { lock.unlock() }; return value }
    func increment() { lock.lock(); value += 1; lock.unlock() }
}
