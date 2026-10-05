import AVFoundation

/// Frame-queue owned. Optional raw and processed streams use identical timestamps
/// and microphone samples, with the untouched camera image saved separately.
final class CaptureMoviePair {
    let primary: ProcessedMovieWriter
    private let original: ProcessedMovieWriter?
    private(set) var originalURL: URL?
    init(url: URL, width: Int, height: Int, keepOriginal: Bool) throws {
        primary = try ProcessedMovieWriter(url: url, width: width, height: height)
        do {
            if keepOriginal {
                let folder = url.deletingLastPathComponent().appendingPathComponent(".Originals", isDirectory: true)
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                let raw = folder.appendingPathComponent(url.lastPathComponent)
                original = try ProcessedMovieWriter(url: raw, width: width, height: height)
            } else { original = nil }
        } catch { primary.cancel(); throw error }
    }
    func appendVideo(_ processed: CVPixelBuffer, original buffer: CVPixelBuffer, time: CMTime) throws -> Bool {
        if let original { _ = try original.appendVideo(buffer, time: time) }
        return try primary.appendVideo(processed, time: time)
    }
    func appendAudio(_ sample: CMSampleBuffer) throws {
        try original?.appendAudio(sample); try primary.appendAudio(sample)
    }
    func finish(_ completion: @escaping (Result<URL, Error>) -> Void) {
        let group = DispatchGroup(), lock = NSLock()
        var primaryResult: Result<URL, Error>?
        var originalResult: Result<URL, Error>?
        group.enter()
        primary.finish { result in lock.lock(); primaryResult = result; lock.unlock(); group.leave() }
        if let original {
            group.enter()
            original.finish { result in lock.lock(); originalResult = result; lock.unlock(); group.leave() }
        }
        group.notify(queue: DispatchQueue.global(qos: .utility)) { [self] in
            lock.lock(); let saved = primaryResult; let raw = originalResult; lock.unlock()
            if case .success(let url) = raw { originalURL = url }
            completion(saved ?? .failure(RecordingFailure.message("Could not save the recording.")))
        }
    }
    func cancel() { primary.cancel(); original?.cancel() }
}
