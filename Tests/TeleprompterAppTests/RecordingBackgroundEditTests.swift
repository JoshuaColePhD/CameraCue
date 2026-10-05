import XCTest
import AVFoundation
import CoreImage
@testable import TeleprompterApp

final class RecordingBackgroundEditTests: XCTestCase {
    private func directory() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("background-edit-\(UUID())")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }
    private func video(at url: URL, color: CIColor, transform: CGAffineTransform = .identity) async throws {
        let writer = try ProcessedMovieWriter(url: url, width: 128, height: 72, realtime: false, includeAudio: false, transform: transform)
        var buffer: CVPixelBuffer?
        CVPixelBufferCreate(nil, 128, 72, kCVPixelFormatType_32BGRA, [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &buffer)
        let frame = try XCTUnwrap(buffer)
        CIContext().render(CIImage(color: color), to: frame)
        for i in 0..<15 {
            while !writer.isVideoReady { try await Task.sleep(for: .milliseconds(2)) }
            XCTAssertTrue(try writer.appendVideo(frame, time: CMTime(value: Int64(i), timescale: 30)))
        }
        let _: URL = try await withCheckedThrowingContinuation { continuation in writer.finish { continuation.resume(with: $0) } }
    }
    private func pixel(_ url: URL) async throws -> (Int, Int, [UInt8]) {
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url)); generator.appliesPreferredTrackTransform = true
        let (image, _) = try await generator.image(at: .zero)
        var bytes = [UInt8](repeating: 0, count: 4)
        CIContext().render(CIImage(cgImage: image), toBitmap: &bytes, rowBytes: 4, bounds: CGRect(x: image.width / 2, y: image.height / 2, width: 1, height: 1), format: .RGBA8, colorSpace: CGColorSpaceCreateDeviceRGB())
        return (image.width, image.height, bytes)
    }
    func testExportNewBackgroundPreservesSourceAndAllFrames() async throws {
        let folder = try directory(); defer { try? FileManager.default.removeItem(at: folder) }
        let source = folder.appendingPathComponent("source.mov")
        try await video(at: source, color: CIColor(red: 1, green: 0, blue: 0))
        let before = try Data(contentsOf: source)
        var background = CameraBackground(); background.mode = .color; background.color = "mint"
        let output = folder.appendingPathComponent("edited.mp4")
        _ = try await VideoBackgroundExport.export(recording: source, background: background, destination: output)
        XCTAssertEqual(try Data(contentsOf: source), before)
        let decoded = try await pixel(output)
        XCTAssertGreaterThan(decoded.2[1], 210); XCTAssertLessThan(decoded.2[0], 205)
        let asset = AVURLAsset(url: output)
        let duration = try await asset.load(.duration); XCTAssertGreaterThan(duration.seconds, 0.45)
        let tracks = try await asset.loadTracks(withMediaType: .video)
        let reader = try AVAssetReader(asset: asset)
        let trackOutput = AVAssetReaderTrackOutput(track: try XCTUnwrap(tracks.first), outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
        reader.add(trackOutput); XCTAssertTrue(reader.startReading())
        var count = 0; while trackOutput.copyNextSampleBuffer() != nil { count += 1 }
        XCTAssertEqual(count, 15, "Offline exports must not drop frames through encoder backpressure")
        XCTAssertFalse(RecordingBackgroundSource.resolve(output).isCameraOriginal)
    }
    func testOriginalSourceRestorationAndMissingOriginalFallback() async throws {
        let folder = try directory(); defer { try? FileManager.default.removeItem(at: folder) }
        let originals = folder.appendingPathComponent(".Originals"); try FileManager.default.createDirectory(at: originals, withIntermediateDirectories: true)
        let raw = originals.appendingPathComponent("raw.mov"), flattened = folder.appendingPathComponent("flat.mov")
        try await video(at: raw, color: CIColor(red: 1, green: 0, blue: 0))
        try await video(at: flattened, color: CIColor(red: 0, green: 0, blue: 1))
        var bg = CameraBackground(); bg.mode = .image
        try RecordingBackgroundMetadata(background: bg, originalRelativePath: ".Originals/raw.mov", originalIsCameraSource: true).write(for: flattened)
        XCTAssertTrue(RecordingBackgroundSource.resolve(flattened).isCameraOriginal)
        let output = folder.appendingPathComponent("restored.mp4")
        _ = try await VideoBackgroundExport.export(recording: flattened, background: CameraBackground(), destination: output)
        let decoded = try await pixel(output), original = try await pixel(raw); XCTAssertEqual(decoded.2, original.2); XCTAssertGreaterThan(decoded.2[0], 220); XCTAssertLessThan(decoded.2[2], 10)
        XCTAssertTrue(RecordingBackgroundSource.resolve(output).isCameraOriginal)
        try FileManager.default.removeItem(at: raw)
        XCTAssertEqual(RecordingBackgroundSource.resolve(flattened).url, flattened)
        XCTAssertFalse(RecordingBackgroundSource.resolve(flattened).isCameraOriginal)
    }
    func testRotationAndCancellationDoNotDamageSourceOrLeavePartialOutput() async throws {
        let folder = try directory(); defer { try? FileManager.default.removeItem(at: folder) }
        let source = folder.appendingPathComponent("portrait.mov")
        try await video(at: source, color: .black, transform: CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: 72, ty: 0))
        let before = try Data(contentsOf: source)
        var background = CameraBackground(); background.mode = .color
        let output = folder.appendingPathComponent("portrait.mp4")
        _ = try await VideoBackgroundExport.export(recording: source, background: background, destination: output)
        let decoded = try await pixel(output); XCTAssertEqual(decoded.0, 72); XCTAssertEqual(decoded.1, 128)
        let cancelled = folder.appendingPathComponent("cancelled.mp4")
        let task = Task { try await VideoBackgroundExport.export(recording: source, background: background, destination: cancelled) }
        task.cancel()
        do { _ = try await task.value; XCTFail("Cancelled export must stop") } catch is CancellationError {} catch { XCTFail("Unexpected cancellation error: \(error)") }
        XCTAssertFalse(FileManager.default.fileExists(atPath: cancelled.path)); XCTAssertEqual(try Data(contentsOf: source), before)
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: folder.path).contains { $0.hasPrefix(".background-export-") })
        do { _ = try await VideoBackgroundExport.export(recording: source, background: background, destination: output); XCTFail("Existing output must not be replaced") } catch {}
    }
    func testCancellationDuringProcessingRemovesPartialExport() async throws {
        let folder = try directory(); defer { try? FileManager.default.removeItem(at: folder) }
        let source = folder.appendingPathComponent("source.mov")
        try await video(at: source, color: .black)
        var background = CameraBackground(); background.mode = .color
        let output = folder.appendingPathComponent("cancelled.mp4")
        let task = Task {
            try await VideoBackgroundExport.export(recording: source, background: background, destination: output) { progress in
                if progress > 0 { withUnsafeCurrentTask { $0?.cancel() } }
            }
        }
        do { _ = try await task.value; XCTFail("Mid-export cancellation must stop") } catch is CancellationError {} catch { XCTFail("Unexpected error: \(error)") }
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path)); XCTAssertFalse(FileManager.default.fileExists(atPath: output.path))
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: folder.path).contains { $0.hasPrefix(".background-export-") })
    }
    func testSidecarRejectsPathTraversalAndRemainsCompatibleWithOldVideos() throws {
        let folder = try directory(); defer { try? FileManager.default.removeItem(at: folder) }
        let source = folder.appendingPathComponent("take.mp4"); try Data("movie".utf8).write(to: source)
        XCTAssertEqual(RecordingBackgroundSource.resolve(source).url, source)
        let metadata = RecordingBackgroundMetadata(background: CameraBackground(), originalRelativePath: "../other.mp4", originalIsCameraSource: true)
        XCTAssertNil(metadata.originalURL(for: source))
        try Data("corrupt metadata".utf8).write(to: RecordingBackgroundMetadata.sidecar(for: source))
        XCTAssertEqual(RecordingBackgroundSource.resolve(source).url, source)
    }
    func testCapturePairKeepsUnprocessedCameraPixelsSeparately() async throws {
        let folder = try directory(); defer { try? FileManager.default.removeItem(at: folder) }
        let pair = try CaptureMoviePair(url: folder.appendingPathComponent("take.mov"), width: 128, height: 72, keepOriginal: true)
        func make(_ color: CIColor) throws -> CVPixelBuffer {
            var value: CVPixelBuffer?; CVPixelBufferCreate(nil, 128, 72, kCVPixelFormatType_32BGRA, [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &value)
            let frame = try XCTUnwrap(value); CIContext().render(CIImage(color: color), to: frame); return frame
        }
        let raw = try make(CIColor(red: 1, green: 0, blue: 0)), processed = try make(CIColor(red: 0, green: 0, blue: 1))
        for i in 0..<15 { _ = try pair.appendVideo(processed, original: raw, time: CMTime(value: Int64(i), timescale: 30)); try await Task.sleep(for: .milliseconds(10)) }
        let primary: URL = try await withCheckedThrowingContinuation { c in pair.finish { c.resume(with: $0) } }
        let savedRaw = try XCTUnwrap(pair.originalURL)
        let a = try await pixel(primary), b = try await pixel(savedRaw)
        XCTAssertGreaterThan(a.2[2], 220); XCTAssertGreaterThan(b.2[0], 220)
        XCTAssertEqual(savedRaw.deletingLastPathComponent().lastPathComponent, ".Originals")
    }
    func testExistingCameraClipExportPreservesAudioAndAllowsUIFixture() async throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let source = root.appendingPathComponent("ReviewArtifacts/CameraCue QuickTime check.mov")
        guard FileManager.default.fileExists(atPath: source.path) else { throw XCTSkip("Local camera clip missing") }
        let folder = try directory(); defer { try? FileManager.default.removeItem(at: folder) }
        let asset = AVURLAsset(url: source)
        let exporter = try XCTUnwrap(AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetHighestQuality))
        exporter.timeRange = CMTimeRange(start: CMTime(seconds: 2, preferredTimescale: 600), duration: CMTime(seconds: 1, preferredTimescale: 600))
        let clip = folder.appendingPathComponent("camera.mov"); try await exporter.export(to: clip, as: .mov)
        var setting = CameraBackground(); setting.mode = .image; setting.image = "quiet-office"
        let output = folder.appendingPathComponent("edited.mp4")
        _ = try await VideoBackgroundExport.export(recording: clip, background: setting, destination: output)
        let result = AVURLAsset(url: output)
        let audios = try await result.loadTracks(withMediaType: .audio); XCTAssertEqual(audios.count, 1)
        let duration = try await result.load(.duration); XCTAssertGreaterThan(duration.seconds, 0.95)
        let reader = try AVAssetReader(asset: result)
        let audio = AVAssetReaderTrackOutput(track: try XCTUnwrap(audios.first), outputSettings: [AVFormatIDKey: kAudioFormatLinearPCM])
        reader.add(audio); XCTAssertTrue(reader.startReading()); XCTAssertNotNil(audio.copyNextSampleBuffer()); reader.cancelReading()
        let artifact = root.appendingPathComponent("ReviewArtifacts/Background editor fixture.mp4")
        try? FileManager.default.removeItem(at: artifact)
        try FileManager.default.copyItem(at: output, to: artifact)
    }
}
