import AVFoundation
import Speech
import Foundation
import TeleprompterCore

@MainActor public protocol StreamingSpeechSession: AnyObject {
    var engineID: SpeechEngineID { get }
    var elapsed: Double { get }
    func prepare(format: AVAudioFormat, allowModelDownload: Bool) async throws
    func append(_ buffer: OwnedSpeechBuffer, sourceUptime: Double?)
    func receiver() -> @Sendable (OwnedSpeechBuffer, Double?) -> Void
    func drainInput() async
    func finish() async throws
    func stop()
}

@available(macOS 26, *)
@MainActor public final class AnalyzerSpeechSession: StreamingSpeechSession {
    public let engineID = SpeechEngineID.analyzer
    private var analyzer: SpeechAnalyzer?
    private var sink: AnalyzerBufferSink?
    private var resultTask: Task<Void, Error>?
    private var startedAt = 0.0
    private let fastResults: Bool
    private let onObservation: @MainActor (SpeechObservation) -> Void
    private let onFailure: @MainActor (String) -> Void
    public var elapsed: Double { max(0, ProcessInfo.processInfo.systemUptime - startedAt) }
    public init(fastResults: Bool = false, onObservation: @escaping @MainActor (SpeechObservation) -> Void, onFailure: @escaping @MainActor (String) -> Void = { _ in }) {
        self.fastResults = fastResults; self.onObservation = onObservation; self.onFailure = onFailure
    }
    public static func supported(locale: Locale = Locale(identifier: "en-US")) async -> Bool {
        guard SpeechTranscriber.isAvailable else { return false }
        return await SpeechTranscriber.supportedLocale(equivalentTo: locale) != nil
    }
    public func prepare(format: AVAudioFormat, allowModelDownload: Bool) async throws {
        guard await Self.supported(), let locale = await SpeechTranscriber.supportedLocale(equivalentTo: Locale(identifier: "en-US")) else { throw SpeechSessionError.unsupported }
        let transcriber = SpeechTranscriber(locale: locale, transcriptionOptions: [], reportingOptions: fastResults ? [.volatileResults, .fastResults] : [.volatileResults], attributeOptions: [.audioTimeRange, .transcriptionConfidence])
        let status = await AssetInventory.status(forModules: [transcriber])
        if status != .installed {
            guard allowModelDownload else { throw SpeechSessionError.assetsMissing }
            if let installation = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) { try await installation.downloadAndInstall() }
        }
        try Task.checkCancellation()
        guard let target = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber], considering: format) else { throw SpeechSessionError.audioFormat }
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        try await analyzer.prepareToAnalyze(in: target)
        let pair = AsyncStream<AnalyzerInput>.makeStream(bufferingPolicy: .bufferingOldest(32))
        let demand = SpeechInputDemand()
        let sink = AnalyzerBufferSink(target: target, continuation: pair.continuation, demand: demand) { [weak self] reason in
            Task { @MainActor in self?.onFailure(reason) }
        }
        self.analyzer = analyzer; self.sink = sink
        startedAt = ProcessInfo.processInfo.systemUptime
        resultTask = Task { [weak self] in
            do {
                for try await result in transcriber.results {
                    guard !Task.isCancelled, let self else { return }
                    let text = String(result.text.characters)
                    var words: [TimedSpeechWord] = []
                    for run in result.text.runs {
                        let value = String(result.text[run.range].characters)
                        guard let range = run.audioTimeRange else { continue }
                        let tokens = value.split(whereSeparator: \.isWhitespace)
                        let estimated = tokens.count > 1
                        for (index, token) in tokens.enumerated() {
                            let start = range.start.seconds + range.duration.seconds * Double(index) / Double(max(1, tokens.count))
                            let end = range.start.seconds + range.duration.seconds * Double(index + 1) / Double(max(1, tokens.count))
                            words.append(TimedSpeechWord(text: String(token), start: start, end: end, confidence: run.transcriptionConfidence,
                                                       timingSource: estimated ? .estimatedWithinSegment : .recognizer))
                        }
                    }
                    self.onObservation(SpeechObservation(engine: .analyzer, text: text, audioStart: result.range.start.seconds,
                                                         audioEnd: CMTimeRangeGetEnd(result.range).seconds, deliveredAt: self.elapsed,
                                                         isFinal: result.isFinal, words: words, sourceUptimeOrigin: sink.sourceOrigin))
                }
            } catch {
                if !Task.isCancelled { self?.onFailure(error.localizedDescription) }
                throw error
            }
        }
        try await analyzer.start(inputSequence: DemandSpeechSequence(stream: pair.stream, demand: demand))
    }
    public func append(_ buffer: OwnedSpeechBuffer, sourceUptime: Double? = nil) { sink?.append(buffer, sourceUptime: sourceUptime) }
    public func receiver() -> @Sendable (OwnedSpeechBuffer, Double?) -> Void {
        let sink = sink
        return { buffer, time in sink?.append(buffer, sourceUptime: time) }
    }
    public func drainInput() async { await sink?.drain() }
    public func finish() async throws {
        await sink?.endInput()
        if let reason = sink?.lastFailure { throw NSError(domain: "CameraCue.Speech", code: 3, userInfo: [NSLocalizedDescriptionKey: reason]) }
        guard let analyzer else { throw SpeechSessionError.cancelled }
        try await analyzer.finalizeAndFinishThroughEndOfInput()
        try await resultTask?.value
    }
    public func stop() {
        sink?.cancel(); sink = nil
        resultTask?.cancel(); resultTask = nil
        if let analyzer { Task { await analyzer.cancelAndFinishNow() } }
        analyzer = nil
    }
    deinit {}
}

/// Conversion occurs on one serial worker. Captured bytes are owned, queued work
/// is bounded, and dropped input fails explicitly instead of silently losing time.
@available(macOS 26, *)
private final class AnalyzerBufferSink: @unchecked Sendable {
    private let queue = DispatchQueue(label: "CameraCue.speech-conversion", qos: .userInitiated)
    private let lock = NSLock()
    private var accepting = true
    private var recordedFailure: String?
    private let demand: SpeechInputDemand
    private var pending = 0
    private var origin: Double?
    private let target: AVAudioFormat
    private let continuation: AsyncStream<AnalyzerInput>.Continuation
    private let failure: @Sendable (String) -> Void
    private var outputFrames: Int64 = 0
    private var converter: AVAudioConverter?
    init(target: AVAudioFormat, continuation: AsyncStream<AnalyzerInput>.Continuation, demand: SpeechInputDemand, failure: @escaping @Sendable (String) -> Void) {
        self.target = target; self.continuation = continuation; self.demand = demand; self.failure = failure
    }
    var lastFailure: String? { lock.lock(); defer { lock.unlock() }; return recordedFailure }
    var sourceOrigin: Double? { lock.lock(); defer { lock.unlock() }; return origin }
    func append(_ copy: OwnedSpeechBuffer, sourceUptime: Double?) {
        lock.lock()
        guard accepting else { lock.unlock(); return }
        if origin == nil { origin = sourceUptime }
        guard pending < 16 else { accepting = false; recordedFailure = SpeechSessionError.backlog.localizedDescription; lock.unlock(); continuation.finish(); failure(SpeechSessionError.backlog.localizedDescription); return }
        pending += 1; lock.unlock()
        queue.async { [self] in
            defer { lock.lock(); pending -= 1; lock.unlock() }
            lock.lock(); let active = accepting; lock.unlock()
            guard active else { return }
            do {
                let input = copy.buffer
                let output: AVAudioPCMBuffer
                if input.format == target { output = input }
                else {
                    if converter?.inputFormat != input.format { converter = AVAudioConverter(from: input.format, to: target) }
                    guard let converter, let converted = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: AVAudioFrameCount(ceil(Double(input.frameLength) * target.sampleRate / input.format.sampleRate)) + 64) else { throw SpeechSessionError.audioFormat }
                    var error: NSError?, supplied = false
                    let status = converter.convert(to: converted, error: &error) { _, flag in
                        if supplied { flag.pointee = .noDataNow; return nil }
                        supplied = true; flag.pointee = .haveData; return input
                    }
                    guard status != .error, error == nil else { throw error ?? SpeechSessionError.audioFormat }
                    output = converted
                }
                guard output.frameLength > 0 else { return }
                let event = AnalyzerInput(buffer: output, bufferStartTime: CMTime(value: outputFrames, timescale: Int32(target.sampleRate)))
                outputFrames += Int64(output.frameLength)
                demand.enqueued()
                if case .dropped = continuation.yield(event) { demand.consumed(); throw SpeechSessionError.backlog }
            } catch { lock.lock(); recordedFailure = error.localizedDescription; lock.unlock(); cancel(); failure(error.localizedDescription) }
        }
    }
    private var isAccepting: Bool { lock.lock(); defer { lock.unlock() }; return accepting }
    func drain() async {
        await withCheckedContinuation { c in queue.async { c.resume() } }
        while demand.count >= 16 {
            if !isAccepting || Task.isCancelled { return }
            try? await Task.sleep(for: .milliseconds(2))
        }
    }
    func endInput() async { await drain(); continuation.finish() }
    func cancel() { lock.lock(); accepting = false; lock.unlock(); continuation.finish() }
}

@available(macOS 26, *)
private final class SpeechInputDemand: @unchecked Sendable {
    private let lock = NSLock()
    private var queued = 0
    var count: Int { lock.lock(); defer { lock.unlock() }; return queued }
    func enqueued() { lock.lock(); queued += 1; lock.unlock() }
    func consumed() { lock.lock(); queued = max(0, queued - 1); lock.unlock() }
}
@available(macOS 26, *)
private struct DemandSpeechSequence: AsyncSequence, Sendable {
    typealias Element = AnalyzerInput
    let stream: AsyncStream<AnalyzerInput>
    let demand: SpeechInputDemand
    struct AsyncIterator: AsyncIteratorProtocol {
        var base: AsyncStream<AnalyzerInput>.Iterator
        let demand: SpeechInputDemand
        mutating func next() async -> AnalyzerInput? {
            let element = await base.next()
            if element != nil { demand.consumed() }
            return element
        }
    }
    func makeAsyncIterator() -> AsyncIterator { AsyncIterator(base: stream.makeAsyncIterator(), demand: demand) }
}
