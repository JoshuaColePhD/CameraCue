import AVFoundation
import CoreImage

/// File-based export only. No camera/microphone sessions or capture settings.
enum VideoBackgroundExport {
    static func destination(for url: URL) -> URL {
        url.deletingLastPathComponent().appendingPathComponent("\(url.deletingPathExtension().lastPathComponent) Background \(UUID().uuidString.prefix(8)).mp4")
    }
    static func export(recording: URL, background: CameraBackground, destination: URL,
                       progress: @escaping @Sendable (Double) -> Void = { _ in }) async throws -> URL {
        try Task.checkCancellation()
        guard !FileManager.default.fileExists(atPath: destination.path), destination.standardizedFileURL != recording.standardizedFileURL else {
            throw RecordingFailure.message("Choose a new output file. Existing recordings are never overwritten.")
        }
        let source = RecordingBackgroundSource.resolve(recording)
        let staging = destination.deletingLastPathComponent().appendingPathComponent(".background-export-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: staging) }
        let final = staging.appendingPathComponent("ready.mp4")
        if background.mode == .original {
            try await copyMP4(source.url, to: final)
        } else {
            let asset = AVURLAsset(url: source.url)
            let duration = try await asset.load(.duration)
            let tracks = try await asset.loadTracks(withMediaType: .video)
            guard let track = tracks.first, duration.seconds.isFinite, duration.seconds > 0 else { throw RecordingFailure.message("This recording has no readable video.") }
            let transform = try await track.load(.preferredTransform)
            let reader = try AVAssetReader(asset: asset)
            let output = AVAssetReaderTrackOutput(track: track, outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
            output.alwaysCopiesSampleData = false
            guard reader.canAdd(output) else { throw RecordingFailure.message("This video format cannot be read.") }
            reader.add(output)
            guard reader.startReading() else { throw reader.error ?? RecordingFailure.message("Could not open the video.") }
            let processor = CameraBackgroundProcessor(offline: true)
            try processor.configure(background)
            let movie = staging.appendingPathComponent("processed.mov")
            var writer: ProcessedMovieWriter?
            var orientedPool: CVPixelBufferPool?
            var firstTime: CMTime?
            var lastTime: CMTime?
            var lastDuration = CMTime(value: 1, timescale: 30)
            var lastProgress = -1.0
            do {
                while let sample = output.copyNextSampleBuffer() {
                    try Task.checkCancellation()
                    guard let input = CMSampleBufferGetImageBuffer(sample) else { continue }
                    let time = CMSampleBufferGetPresentationTimeStamp(sample)
                    let image = CIImage(cvPixelBuffer: input).transformed(by: transform)
                    let bounds = image.extent
                    let width = Int(bounds.width.rounded()), height = Int(bounds.height.rounded())
                    guard width > 0, height > 0 else { throw RecordingFailure.message("Invalid video dimensions.") }
                    if writer == nil {
                        writer = try ProcessedMovieWriter(url: movie, width: width, height: height, realtime: false, includeAudio: false)
                        CVPixelBufferPoolCreate(nil, [kCVPixelBufferPoolMinimumBufferCountKey: 2] as CFDictionary, [kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA, kCVPixelBufferWidthKey: width, kCVPixelBufferHeightKey: height, kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &orientedPool)
                        firstTime = time
                    }
                    var upright: CVPixelBuffer?
                    guard let orientedPool, CVPixelBufferPoolCreatePixelBuffer(nil, orientedPool, &upright) == kCVReturnSuccess, let upright else { throw RecordingFailure.message("Could not allocate export frames.") }
                    processor.context.render(image.transformed(by: CGAffineTransform(translationX: -bounds.minX, y: -bounds.minY)), to: upright)
                    let processed = try processor.process(upright, time: time.seconds)
                    guard let writer else { throw RecordingFailure.message("Could not create a video writer.") }
                    let deadline = Date().addingTimeInterval(30)
                    while !writer.isVideoReady {
                        try Task.checkCancellation()
                        if let error = writer.failure { throw error }
                        guard Date() < deadline else { throw RecordingFailure.message("The video encoder stopped responding.") }
                        try await Task.sleep(for: .milliseconds(3))
                    }
                    guard try writer.appendVideo(processed, time: time) else { throw RecordingFailure.message("A video frame could not be encoded.") }
                    lastTime = time
                    let sampleDuration = CMSampleBufferGetDuration(sample)
                    if sampleDuration.isNumeric && sampleDuration.seconds > 0 { lastDuration = sampleDuration }
                    let fraction = min(0.9, max(0, time.seconds / duration.seconds * 0.9))
                    if fraction - lastProgress >= 0.01 { lastProgress = fraction; progress(fraction) }
                }
                guard reader.status == .completed else { throw reader.error ?? RecordingFailure.message("Reading the video was interrupted.") }
                guard let writer, let firstTime, let lastTime else { throw RecordingFailure.message("This recording has no video frames.") }
                let _: URL = try await withTaskCancellationHandler {
                    try await withCheckedThrowingContinuation { continuation in writer.finish { continuation.resume(with: $0) } }
                } onCancel: { writer.cancel() }
                try Task.checkCancellation()
                // Reattach original audio tracks at their actual offsets. Rotated
                // video has already been rendered upright, with no extra transform.
                let composition = AVMutableComposition()
                let processedAsset = AVURLAsset(url: movie)
                let renderedTrack = try await processedAsset.loadTracks(withMediaType: .video).first
                let rendered = try unwrap(renderedTrack, "Could not read the processed video.")
                let renderedRange = try await rendered.load(.timeRange)
                let videoTrack = try unwrap(composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid), "Could not prepare the video export.")
                try videoTrack.insertTimeRange(renderedRange, of: rendered, at: firstTime)
                let end = CMTimeAdd(lastTime, lastDuration)
                for originalAudio in try await asset.loadTracks(withMediaType: .audio) {
                    let range = try await originalAudio.load(.timeRange)
                    let intersection = CMTimeRangeGetIntersection(range, otherRange: CMTimeRange(start: .zero, end: end))
                    guard intersection.duration.seconds > 0 else { continue }
                    let audio = try unwrap(composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid), "Could not retain the audio.")
                    try audio.insertTimeRange(intersection, of: originalAudio, at: intersection.start)
                }
                progress(0.92)
                try await exportAsset(composition, to: final)
            } catch { reader.cancelReading(); writer?.cancel(); throw error }
        }
        try Task.checkCancellation()
        guard !FileManager.default.fileExists(atPath: destination.path) else { throw RecordingFailure.message("That output file already exists.") }
        // Move only after a complete export; never leave a partial library MP4.
        try FileManager.default.moveItem(at: final, to: destination)
        do { try source.metadata(background: background, destination: destination).write(for: destination) }
        catch { try? FileManager.default.removeItem(at: destination); throw error }
        progress(1)
        return destination
    }
    private static func unwrap<T>(_ value: T?, _ message: String) throws -> T {
        guard let value else { throw RecordingFailure.message(message) }; return value
    }
    private static func copyMP4(_ url: URL, to destination: URL) async throws {
        try await exportAsset(AVURLAsset(url: url), to: destination)
    }
    private static func exportAsset(_ asset: AVAsset, to destination: URL) async throws {
        let compatible = await AVAssetExportSession.compatibility(ofExportPreset: AVAssetExportPresetPassthrough, with: asset, outputFileType: .mp4)
        let exporter = try unwrap(AVAssetExportSession(asset: asset, presetName: compatible ? AVAssetExportPresetPassthrough : AVAssetExportPresetHighestQuality), "Could not prepare an MP4 export.")
        try await withTaskCancellationHandler { try await exporter.export(to: destination, as: .mp4) } onCancel: { exporter.cancelExport() }
    }
}
