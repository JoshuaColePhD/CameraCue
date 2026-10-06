import XCTest
@testable import TeleprompterApp

@MainActor final class PermissionRequestTests: XCTestCase {
    func testDuplicateCallbackCompletesOnlyOnce() async {
        let result = await PermissionRequest.wait(timeout: .milliseconds(100)) { callback in
            callback(true); callback(false)
        }
        XCTAssertEqual(result, true)
    }
    func testMissingCallbackReturnsTimeout() async {
        let result = await PermissionRequest.wait(timeout: .milliseconds(10)) { _ in }
        XCTAssertNil(result)
    }
    func testLateGrantCannotChangeTimedOutResult() async throws {
        let result = await PermissionRequest.wait(timeout: .milliseconds(10)) { callback in
            Task {
                try? await Task.sleep(for: .milliseconds(60))
                callback(true)
            }
        }
        XCTAssertNil(result)
        try await Task.sleep(for: .milliseconds(100))
    }
    func testCancellationReleasesPendingSetup() async {
        let request = Task { await PermissionRequest.wait(timeout: .seconds(60)) { _ in } }
        request.cancel()
        let result = await request.value
        XCTAssertNil(result)
    }
}
