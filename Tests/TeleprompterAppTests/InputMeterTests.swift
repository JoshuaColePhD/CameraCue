import XCTest
import AVFoundation
@testable import TeleprompterApp

final class InputMeterTests: XCTestCase {
    func testSilenceVoiceAndClippingMapToBoundedInputActivity() throws {
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 1))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1024))
        buffer.frameLength = 1024
        let channel = try XCTUnwrap(buffer.floatChannelData?[0])
        let meter = InputLevelMeter()
        for i in 0..<1024 { channel[i] = 0 }
        meter.measure(buffer)
        XCTAssertEqual(meter.value, 0)
        for i in 0..<1024 { channel[i] = 0.1 * sin(Float(i) * 0.15) }
        meter.measure(buffer)
        XCTAssertGreaterThan(meter.value, 0.3)
        XCTAssertLessThan(meter.value, 0.9)
        for i in 0..<1024 { channel[i] = 2 }
        meter.measure(buffer)
        XCTAssertEqual(meter.value, 1)
    }
}
