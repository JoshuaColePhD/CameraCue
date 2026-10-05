import XCTest
import AVFoundation
import CoreImage
import ImageIO
@testable import TeleprompterApp

final class CameraBackgroundTests: XCTestCase {
    private func pixel(_ image: CIImage, x: Int = 0, y: Int = 0) -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: 4)
        CIContext().render(image, toBitmap: &bytes, rowBytes: 4, bounds: CGRect(x: x, y: y, width: 1, height: 1), format: .RGBA8, colorSpace: CGColorSpaceCreateDeviceRGB())
        return bytes
    }
    func testPersonMaskKeepsSubjectAndReplacesRoom() throws {
        let p = CameraBackgroundProcessor()
        var setting = CameraBackground(); setting.mode = .color; setting.color = "sky"
        try p.configure(setting)
        let frame = CIImage(color: CIColor(red: 1, green: 0, blue: 0)).cropped(to: CGRect(x: 0, y: 0, width: 32, height: 32))
        let white = CIImage(color: .white).cropped(to: frame.extent)
        let black = CIImage(color: .black).cropped(to: frame.extent)
        let subject = pixel(p.composite(frame, mask: white), x: 16, y: 16)
        let background = pixel(p.composite(frame, mask: black), x: 16, y: 16)
        XCTAssertGreaterThan(subject[0], 250); XCTAssertLessThan(subject[1], 5)
        XCTAssertGreaterThan(background[2], 235); XCTAssertGreaterThan(background[1], 200)
        XCTAssertEqual(pixel(p.composite(frame, mask: nil), x: 16, y: 16), background, "Missing mask must not reveal the original room")
    }
    func testOriginalPreservesFrameAndBlurChangesBackground() throws {
        let p = CameraBackgroundProcessor()
        let bounds = CGRect(x: 0, y: 0, width: 64, height: 64)
        let frame = CIImage(color: .white).cropped(to: CGRect(x: 0, y: 0, width: 32, height: 64)).composited(over: CIImage(color: .black).cropped(to: bounds))
        XCTAssertEqual(pixel(p.composite(frame, mask: nil), x: 30, y: 30), pixel(frame, x: 30, y: 30))
        var setting = CameraBackground(); setting.mode = .blur; try p.configure(setting)
        let blurred = pixel(p.composite(frame, mask: nil), x: 30, y: 30)
        XCTAssertLessThan(blurred[0], 240); XCTAssertGreaterThan(blurred[0], 100)
    }
    func testPresetsAreBundledHighResolutionAndCustomFailureRetainsSetting() throws {
        let p = CameraBackgroundProcessor()
        for id in CameraBackground.presets {
            var setting = CameraBackground(); setting.mode = .image; setting.image = id
            let cg = try XCTUnwrap(CameraBackground.loadImage(try XCTUnwrap(setting.imageURL)))
            XCTAssertGreaterThanOrEqual(cg.width, 1600); XCTAssertGreaterThanOrEqual(cg.height, 900)
            try p.configure(setting)
        }
        var invalid = CameraBackground(); invalid.mode = .image; invalid.image = "custom"; invalid.customPath = "/missing.png"
        XCTAssertThrowsError(try p.configure(invalid))
    }
    func testAspectFillCoversDestinationWithoutDistortion() {
        let image = CIImage(color: .white).cropped(to: CGRect(x: 0, y: 0, width: 300, height: 100))
        let bounds = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        XCTAssertEqual(CameraBackgroundProcessor.aspectFill(image, into: bounds).extent, bounds)
    }
    func testProcessedWriterProducesPlayableMP4AndPreservesBackground() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("background-export-\(UUID())")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let mov = folder.appendingPathComponent("take.mov"), mp4 = folder.appendingPathComponent("take.mp4")
        let writer = try ProcessedMovieWriter(url: mov, width: 128, height: 72)
        let context = CIContext()
        var buffer: CVPixelBuffer?
        XCTAssertEqual(CVPixelBufferCreate(nil, 128, 72, kCVPixelFormatType_32BGRA, [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &buffer), kCVReturnSuccess)
        let output = try XCTUnwrap(buffer)
        let processor = CameraBackgroundProcessor()
        var setting = CameraBackground(); setting.mode = .color; setting.color = "mint"; try processor.configure(setting)
        let frame = CIImage(color: CIColor(red: 1, green: 0, blue: 0)).cropped(to: CGRect(x: 0, y: 0, width: 128, height: 72))
        let composite = processor.composite(frame, mask: CIImage(color: .black).cropped(to: frame.extent))
        context.render(composite, to: output)
        for i in 0..<30 {
            _ = try writer.appendVideo(output, time: CMTime(value: Int64(i), timescale: 30))
            try await Task.sleep(for: .milliseconds(10))
        }
        let _: URL = try await withCheckedThrowingContinuation { continuation in writer.finish { continuation.resume(with: $0) } }
        try await CameraRecording.exportMP4(mov, mp4)
        let asset = AVURLAsset(url: mp4)
        let playable = try await asset.load(.isPlayable); XCTAssertTrue(playable)
        let tracks = try await asset.loadTracks(withMediaType: .video); XCTAssertEqual(tracks.count, 1)
        let generator = AVAssetImageGenerator(asset: asset)
        let (cg, _) = try await generator.image(at: .zero)
        let recorded = pixel(CIImage(cgImage: cg), x: 60, y: 30)
        XCTAssertGreaterThan(recorded[1], 210); XCTAssertLessThan(recorded[0], 205)
        XCTAssertGreaterThan(writer.writtenFrames, 20)
    }
    @MainActor func testBackgroundPreferenceSurvivesReopening() async throws {
        let name = "background-preferences-\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name)); defer { defaults.removePersistentDomain(forName: name) }
        let video = CameraRecording(defaults: defaults, authorize: { false })
        var setting = CameraBackground(); setting.mode = .color; setting.color = "peach"
        await video.changeBackground(setting)
        XCTAssertEqual(video.background, setting)
        XCTAssertEqual(CameraRecording(defaults: defaults, authorize: { false }).background, setting)
    }
    func testExistingCameraClipSegmentationAndAudioExport() async throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let fixture = root.appendingPathComponent("ReviewArtifacts/CameraCue QuickTime check.mov")
        guard FileManager.default.fileExists(atPath: fixture.path) else { throw XCTSkip("Local camera clip unavailable") }
        let asset = AVURLAsset(url: fixture)
        let tracks = try await asset.loadTracks(withMediaType: .video)
        let track = try XCTUnwrap(tracks.first)
        let audioTracks = try await asset.loadTracks(withMediaType: .audio)
        let reader = try AVAssetReader(asset: asset)
        reader.timeRange = CMTimeRange(start: CMTime(seconds: 2, preferredTimescale: 600), duration: CMTime(seconds: 2, preferredTimescale: 600))
        let video = AVAssetReaderTrackOutput(track: track, outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
        let audio = AVAssetReaderTrackOutput(track: try XCTUnwrap(audioTracks.first), outputSettings: [AVFormatIDKey: kAudioFormatLinearPCM, AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false, AVLinearPCMIsNonInterleaved: false])
        reader.add(video); reader.add(audio); XCTAssertTrue(reader.startReading())
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("segmented-camera-\(UUID())")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let mov = folder.appendingPathComponent("processed.mov"), mp4 = folder.appendingPathComponent("processed.mp4")
        let processor = CameraBackgroundProcessor()
        var setting = CameraBackground(); setting.mode = .image; try processor.configure(setting)
        var writer: ProcessedMovieWriter?
        var costs: [Double] = []
        var first: CVPixelBuffer?
        while let sample = video.copyNextSampleBuffer(), let buffer = CMSampleBufferGetImageBuffer(sample) {
            let time = CMSampleBufferGetPresentationTimeStamp(sample)
            let before = Date()
            let processed = try processor.process(buffer, time: time.seconds)
            costs.append(Date().timeIntervalSince(before) * 1000)
            if writer == nil {
                writer = try ProcessedMovieWriter(url: mov, width: CVPixelBufferGetWidth(processed), height: CVPixelBufferGetHeight(processed))
                first = processed
                let original = pixel(CIImage(cvPixelBuffer: buffer), x: 640, y: 450)
                let subject = pixel(CIImage(cvPixelBuffer: processed), x: 640, y: 450)
                XCTAssertLessThan(abs(Int(original[0]) - Int(subject[0])), 15, "Face must be preserved by the actual Vision mask")
                XCTAssertNotEqual(pixel(CIImage(cvPixelBuffer: buffer), x: 20, y: 360), pixel(CIImage(cvPixelBuffer: processed), x: 20, y: 360), "Room must be replaced")
            }
            _ = try writer?.appendVideo(processed, time: time)
            try await Task.sleep(for: .milliseconds(10))
        }
        while let sample = audio.copyNextSampleBuffer() {
            try writer?.appendAudio(sample)
            try await Task.sleep(for: .milliseconds(2))
        }
        let completed = try XCTUnwrap(writer)
        let _: URL = try await withCheckedThrowingContinuation { c in completed.finish { c.resume(with: $0) } }
        try await CameraRecording.exportMP4(mov, mp4)
        let saved = AVURLAsset(url: mp4)
        let savedAudio = try await saved.loadTracks(withMediaType: .audio)
        XCTAssertEqual(savedAudio.count, 1)
        let duration = try await saved.load(.duration); XCTAssertGreaterThan(duration.seconds, 1.5)
        let generator = AVAssetImageGenerator(asset: saved)
        let (decoded, _) = try await generator.image(at: .zero)
        let reference = pixel(CIImage(cvPixelBuffer: try XCTUnwrap(first)), x: 20, y: 360)
        let actual = pixel(CIImage(cgImage: decoded), x: 20, y: 360)
        XCTAssertLessThan(abs(Int(reference[0]) - Int(actual[0])), 15)
        let ordered = costs.sorted()
        print("BACKGROUND_PROFILE frames=\(costs.count) median_ms=\(ordered[ordered.count/2]) p95_ms=\(ordered[Int(Double(ordered.count-1)*0.95)]) max_ms=\(ordered.last!) dropped=\(completed.droppedFrames)")
        if let cg = processor.context.createCGImage(CIImage(cvPixelBuffer: try XCTUnwrap(first)), from: CGRect(x: 0, y: 0, width: 1280, height: 720)),
           let destination = CGImageDestinationCreateWithURL(root.appendingPathComponent("ReviewArtifacts/background-composited-check.png") as CFURL, "public.png" as CFString, 1, nil) {
            CGImageDestinationAddImage(destination, cg, nil); XCTAssertTrue(CGImageDestinationFinalize(destination))
        }
    }
    @MainActor func testPreviewMailboxCoalescesAndDisconnectsWithoutCaptureQueue() async {
        let hub = CameraPreviewFrames()
        var buffer: CVPixelBuffer?
        CVPixelBufferCreate(nil, 16, 16, kCVPixelFormatType_32BGRA, nil, &buffer)
        let frame = buffer!
        var delivered = 0
        let subscription = hub.attach { _ in delivered += 1 }
        for _ in 0..<100 { hub.push(frame) }
        await Task.yield()
        // Allow the queued main-thread delivery once, not 100 frame updates.
        try? await Task.sleep(for: .milliseconds(30))
        XCTAssertEqual(delivered, 1)
        hub.detach(subscription); hub.push(frame)
        try? await Task.sleep(for: .milliseconds(30))
        XCTAssertEqual(delivered, 1)
        let view = ProcessedCameraPreviewView(frame: .zero)
        view.connect(hub); view.disconnect()
    }

    @MainActor func testPreviewAcceptsProcessedFramesAndMirrorsOnlyPreview() async throws {
        let hub = CameraPreviewFrames()
        let view = ProcessedCameraPreviewView(frame: CGRect(x: 0, y: 0, width: 128, height: 72))
        view.layout()
        view.connect(hub)
        defer { view.disconnect() }
        var buffer: CVPixelBuffer?
        CVPixelBufferCreate(nil, 128, 72, kCVPixelFormatType_32BGRA, [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &buffer)
        let frame = try XCTUnwrap(buffer)
        CIContext().render(CIImage(color: CIColor(red: 0.2, green: 0.7, blue: 0.9)), to: frame)
        hub.push(frame)
        for _ in 0..<100 {
            try await Task.sleep(for: .milliseconds(10))
            if view.display.sampleBufferRenderer.status == .rendering { break }
        }
        XCTAssertNil(view.display.sampleBufferRenderer.error)
        XCTAssertEqual(view.display.sampleBufferRenderer.status, .rendering, "Native renderer must accept processed pixels")
        // A layer without a presented window has no displayed buffer on a locked
        // or headless Mac. Inspect displayed pixels when the render server exposes them.
        if let actual = view.display.sampleBufferRenderer.displayedPixelBuffer() {
            XCTAssertGreaterThan(pixel(CIImage(cvPixelBuffer: actual), x: 60, y: 30)[2], 200)
        }
        XCTAssertEqual(view.display.affineTransform().a, -1, "Only the preview is mirrored")
    }

}
