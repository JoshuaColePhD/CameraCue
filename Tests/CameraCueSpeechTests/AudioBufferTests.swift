import XCTest
import AVFoundation
@testable import CameraCueSpeech

final class AudioBufferTests: XCTestCase {
    func testCopyRetainsAudioAfterTapStorageIsReused() throws {
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 16000, channels: 1))
        let original = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4))
        original.frameLength = 4
        original.floatChannelData![0][0] = 0.75
        let owned = try OwnedSpeechBuffer(copying: original)
        original.floatChannelData![0][0] = -0.25
        XCTAssertEqual(owned.buffer.floatChannelData![0][0], 0.75)
    }
}
