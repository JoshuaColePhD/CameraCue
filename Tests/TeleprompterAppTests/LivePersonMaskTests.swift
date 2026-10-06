import XCTest
import CoreVideo
@testable import TeleprompterApp

final class LivePersonMaskTests: XCTestCase {
    private func frame() throws -> CVPixelBuffer {
        var buffer: CVPixelBuffer?
        XCTAssertEqual(CVPixelBufferCreate(nil, 16, 16, kCVPixelFormatType_32BGRA, nil, &buffer), kCVReturnSuccess)
        return try XCTUnwrap(buffer)
    }
    func testWorkIsBoundedAndResetRejectsOldMask() async throws {
        let entered = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
        let worker = LivePersonMask { buffer in
            entered.signal(); release.wait(); return buffer
        }
        let source = try frame()
        XCTAssertTrue(worker.submit(source))
        XCTAssertEqual(entered.wait(timeout: .now() + 1), .success)
        XCTAssertTrue(worker.isComputing)
        XCTAssertFalse(worker.submit(source), "A slow mask must not grow a frame backlog")
        worker.reset()
        release.signal()
        for _ in 0..<200 {
            if !worker.isComputing { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertFalse(worker.isComputing)
        XCTAssertNil(worker.latest, "A completed mask from the previous setting must be discarded")
    }
    func testStartupSeedsMaskBeforePreview() throws {
        let source = try frame()
        let worker = LivePersonMask { $0 }
        XCTAssertTrue(try XCTUnwrap(worker.first(source)) === source)
        XCTAssertTrue(try XCTUnwrap(worker.latest) === source)
        worker.reset()
        XCTAssertNil(worker.latest)
    }
}
