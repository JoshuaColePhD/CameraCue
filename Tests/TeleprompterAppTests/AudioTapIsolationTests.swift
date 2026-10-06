import XCTest
import AVFoundation
import CameraCueSpeech
@testable import TeleprompterApp

@MainActor final class AudioTapIsolationTests: XCTestCase {
    func testProductionModernTapRunsOnBackgroundAudioThread() async throws {
        let probe = TapProbe()
        // Creation on MainActor must not impose MainActor on the audio callback.
        let tap = SpeechFollower.makeModernAudioTap(receiver: { buffer, origin in
            probe.receive(buffer: buffer, origin: origin)
        }, failure: { probe.fail() })
        try await Task.detached {
            let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 16000, channels: 1))
            let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 160))
            buffer.frameLength = 160
            tap(buffer, AVAudioTime(sampleTime: 0, atRate: 16000))
        }.value
        XCTAssertEqual(probe.frames, 1)
        XCTAssertTrue(probe.background)
        XCTAssertFalse(probe.failed)
        XCTAssertNotNil(probe.origin)
    }
}
private final class TapProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: (UInt32, Bool, Bool, Double?) = (0, false, false, nil)
    var frames: UInt32 { lock.lock(); defer { lock.unlock() }; return storage.0 }
    var background: Bool { lock.lock(); defer { lock.unlock() }; return storage.1 }
    var failed: Bool { lock.lock(); defer { lock.unlock() }; return storage.2 }
    var origin: Double? { lock.lock(); defer { lock.unlock() }; return storage.3 }
    func receive(buffer: OwnedSpeechBuffer, origin: Double?) {
        lock.lock(); defer { lock.unlock() }
        storage = (1, !Thread.isMainThread, false, origin)
    }
    func fail() { lock.lock(); storage.2 = true; lock.unlock() }
}
