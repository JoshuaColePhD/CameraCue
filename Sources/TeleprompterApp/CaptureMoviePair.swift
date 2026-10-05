import AVFoundation

/// Producer-queue owned; encoder cancellation may arrive from another queue.
/// Each writer serializes encoder calls, and cross-queue result state is locked.
final class CaptureMoviePair: @unchecked Sendable {
    let primary: ProcessedMovieWriter
    private let original: ProcessedMovieWriter?
    private let resultLock = NSLock()
    private var savedOriginalURL: URL?
    var originalURL: URL? {
        resultLock.lock(); defer { resultLock.unlock() }; return savedOriginalURL
    }
    init(url: URL, width: Int, height: Int, keepOriginal: Bool) throws {
        primary = try ProcessedMovieWriter(url: url, width: width, height: height)
        do {
            if keepOriginal {
                let folder = url.deletingLastPathComponent().appendingPathComponent(".Originals", isDirectory: true)
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                original = try ProcessedMovieWriter(url: folder.appendingPathComponent(url.lastPathComponent), width: width, height: height)
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
    func finish(_ completion: @escaping @Sendable (Result<URL, Error>) -> Void) {
        let group = DispatchGroup(), results = MoviePairResults()
        group.enter()
        primary.finish { result in results.store(result, original: false); group.leave() }
        if let original {
            group.enter()
            original.finish { result in results.store(result, original: true); group.leave() }
        }
        group.notify(queue: DispatchQueue.global(qos: .utility)) { [self] in
            let (saved, raw) = results.snapshot()
            if case .success(let url) = raw {
                resultLock.lock(); savedOriginalURL = url; resultLock.unlock()
            }
            completion(saved ?? .failure(RecordingFailure.message("Could not save the recording.")))
        }
    }
    func cancel() { primary.cancel(); original?.cancel() }
}

/// AVAssetWriter completions can arrive independently on different queues.
private final class MoviePairResults: @unchecked Sendable {
    private let lock = NSLock()
    private var primary: Result<URL, Error>?
    private var original: Result<URL, Error>?
    func store(_ result: Result<URL, Error>, original isOriginal: Bool) {
        lock.lock(); defer { lock.unlock() }
        if isOriginal { original = result } else { primary = result }
    }
    func snapshot() -> (Result<URL, Error>?, Result<URL, Error>?) {
        lock.lock(); defer { lock.unlock() }; return (primary, original)
    }
}
