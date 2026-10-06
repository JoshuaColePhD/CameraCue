import XCTest
import AVFoundation
import AppKit
import AVKit
import SwiftUI
@testable import TeleprompterApp

@MainActor final class VideoExportTests: XCTestCase {
    func testRealMP4ExportPreservesGeneratedVideoAndAudio() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("CameraCue-export-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let raw = directory.appendingPathComponent("video.mov")
        let writer = try AVAssetWriter(outputURL: raw, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 64, AVVideoHeightKey: 64])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32ARGB, kCVPixelBufferWidthKey as String: 64, kCVPixelBufferHeightKey as String: 64])
        writer.add(input)
        guard writer.startWriting() else { throw writer.error ?? RecordingFailure.message("Fixture writer could not start") }; writer.startSession(atSourceTime: .zero)
        for frame in 0..<30 {
            var pixel: CVPixelBuffer?
            XCTAssertEqual(CVPixelBufferCreate(kCFAllocatorDefault, 64, 64, kCVPixelFormatType_32ARGB, nil, &pixel), kCVReturnSuccess)
            let buffer = try XCTUnwrap(pixel)
            CVPixelBufferLockBaseAddress(buffer, [])
            memset(CVPixelBufferGetBaseAddress(buffer), 170, CVPixelBufferGetDataSize(buffer))
            CVPixelBufferUnlockBaseAddress(buffer, [])
            let deadline = Date().addingTimeInterval(5)
            while !input.isReadyForMoreMediaData && writer.status == .writing && Date() < deadline { try await Task.sleep(for: .milliseconds(5)) }
            XCTAssertTrue(adaptor.append(buffer, withPresentationTime: CMTime(value: Int64(frame), timescale: 30)))
        }
        input.markAsFinished()
        // Use the callback boundary with a checked continuation. The SDK's
        // imported async bridge aborts in the older Mac CI runtime.
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            writer.finishWriting { @Sendable in continuation.resume() }
        }
        XCTAssertEqual(writer.status, .completed)
        let wav = directory.appendingPathComponent("audio.wav")
        var audio = Data()
        func word<T: FixedWidthInteger>(_ value: T) { var value = value.littleEndian; withUnsafeBytes(of: &value) { audio.append(contentsOf: $0) } }
        audio.append(Data("RIFF".utf8)); word(UInt32(36 + 88200)); audio.append(Data("WAVEfmt ".utf8))
        word(UInt32(16)); word(UInt16(1)); word(UInt16(1)); word(UInt32(44100)); word(UInt32(88200)); word(UInt16(2)); word(UInt16(16))
        audio.append(Data("data".utf8)); word(UInt32(88200)); audio.append(Data(repeating: 0, count: 88200)); try audio.write(to: wav)
        let composition = AVMutableComposition()
        let videoAsset = AVURLAsset(url: raw), audioAsset = AVURLAsset(url: wav)
        let sourceVideo = try await videoAsset.loadTracks(withMediaType: .video)
        let videoTrack = try XCTUnwrap(sourceVideo.first)
        let sourceAudio = try await audioAsset.loadTracks(withMediaType: .audio)
        let audioTrack = try XCTUnwrap(sourceAudio.first)
        let duration = CMTime(value: 29, timescale: 30)
        try composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid)?.insertTimeRange(CMTimeRange(start: .zero, duration: duration), of: videoTrack, at: .zero)
        try composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)?.insertTimeRange(CMTimeRange(start: .zero, duration: duration), of: audioTrack, at: .zero)
        let movie = directory.appendingPathComponent("capture.mov")
        let captureExport = try XCTUnwrap(AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetHighestQuality))
        try await captureExport.export(to: movie, as: .mov)
        let mp4 = directory.appendingPathComponent("take.mp4")
        try await CameraRecording.exportMP4(movie, mp4)
        let extracted = directory.appendingPathComponent("coaching-audio.m4a")
        try await RecordingAudioExtractor.extract(mp4, to: extracted)
        let readable = try AVAudioFile(forReading: extracted)
        XCTAssertGreaterThan(readable.length, 0)
        XCTAssertEqual(readable.processingFormat.channelCount, 1)
        // A finding can be clicked before native player metadata finishes
        // loading. The initial seek must be queued rather than discarded.
        let host = NSHostingView(rootView: SavedTakePlayer(url: mp4, seekRequest: PlaybackSeekRequest(seconds: 0.5)).frame(width: 640, height: 400))
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 640, height: 400), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = host; window.orderFront(nil)
        defer { window.close() }
        func videoView(_ view: NSView) -> AVPlayerView? {
            if let result = view as? AVPlayerView { return result }
            return view.subviews.lazy.compactMap { videoView($0) }.first
        }
        let seekDeadline = Date().addingTimeInterval(3)
        while (videoView(host)?.player?.currentTime().seconds ?? 0) < 0.4, Date() < seekDeadline { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertGreaterThanOrEqual(videoView(host)?.player?.currentTime().seconds ?? 0, 0.4, "Initial finding click must survive player loading")
        let result = AVURLAsset(url: mp4)
        let videoTracks = try await result.loadTracks(withMediaType: .video)
        let audioTracks = try await result.loadTracks(withMediaType: .audio)
        XCTAssertEqual(videoTracks.count, 1); XCTAssertEqual(audioTracks.count, 1)
        let actualDuration = try await result.load(.duration)
        XCTAssertGreaterThan(actualDuration.seconds, 0.8)
        let reader = try AVAssetReader(asset: result)
        let output = AVAssetReaderTrackOutput(track: try XCTUnwrap(videoTracks.first), outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
        reader.add(output); XCTAssertTrue(reader.startReading())
        XCTAssertNotNil(output.copyNextSampleBuffer(), "Saved MP4 must have decodable video")
        reader.cancelReading()
        let bytes = try Data(contentsOf: mp4)
        XCTAssertEqual(String(data: bytes.subdata(in: 4..<8), encoding: .ascii), "ftyp", "Verify an actual MPEG-4 container, not a renamed MOV")
    }
}
