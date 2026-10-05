import AppKit
import AVFoundation
import XCTest
@testable import TeleprompterApp

final class CameraPreviewTests: XCTestCase {
    @MainActor func testTeardownDoesNotWaitForBusyCaptureQueue() async {
        let entered = expectation(description: "Capture queue busy")
        let released = DispatchSemaphore(value: 0)
        CameraSessionWork.queue.async {
            entered.fulfill()
            _ = released.wait(timeout: .now() + 3)
        }
        await fulfillment(of: [entered], timeout: 1)
        let view = CameraPreviewView(frame: NSRect(x: 0, y: 0, width: 320, height: 150))
        let before = Date()
        view.connect(AVCaptureSession())
        view.disconnect()
        XCTAssertLessThan(Date().timeIntervalSince(before), 0.1, "UI must not wait for session work")
        released.signal()
        let detached = expectation(description: "Layer detached")
        let preview = view.preview
        CameraSessionWork.queue.async {
            XCTAssertNil(preview.layer.session)
            detached.fulfill()
        }
        await fulfillment(of: [detached], timeout: 3)
    }

    @MainActor func testRapidPreviewReplacementEndsDetached() async {
        let view = CameraPreviewView(frame: .zero)
        for _ in 0..<10 { view.connect(AVCaptureSession()); view.disconnect() }
        let detached = expectation(description: "Ordered teardown")
        let preview = view.preview
        CameraSessionWork.queue.async {
            XCTAssertNil(preview.layer.session)
            detached.fulfill()
        }
        await fulfillment(of: [detached], timeout: 5)
    }
}
