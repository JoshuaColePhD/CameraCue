import Foundation
import AVFoundation
import Speech
import TeleprompterCore

/// File evaluation uses on-device recognition only. No implicit server fallback.
@MainActor public final class LegacySpeechSession: StreamingSpeechSession {
    public let engineID = SpeechEngineID.legacy
    private var recognizer: SFSpeechRecognizer?
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var active = false
    private var startedAt = 0.0
    private var completed: Result<Void, Error>?
    private var waiters: [CheckedContinuation<Void, Error>] = []
    private let onObservation: @MainActor (SpeechObservation) -> Void
    private let onFailure: @MainActor (String) -> Void
    public var elapsed: Double { max(0, ProcessInfo.processInfo.systemUptime - startedAt) }
    public init(onObservation: @escaping @MainActor (SpeechObservation) -> Void, onFailure: @escaping @MainActor (String) -> Void = { _ in }) {
        self.onObservation = onObservation; self.onFailure = onFailure
    }
    public func prepare(format: AVAudioFormat, allowModelDownload: Bool) async throws {
        guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US")) else { throw SpeechSessionError.unsupported }
        guard SFSpeechRecognizer.authorizationStatus() == .authorized else {
            throw NSError(domain: "CameraCue.Speech", code: 4, userInfo: [NSLocalizedDescriptionKey: "Speech Recognition access is unavailable for this evaluator (status \(SFSpeechRecognizer.authorizationStatus().rawValue)). Enable its grant in System Settings or authorize its current signed build."])
        }
        guard recognizer.isAvailable, recognizer.supportsOnDeviceRecognition else { throw SpeechSessionError.unsupported }
        self.recognizer = recognizer
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true; request.requiresOnDeviceRecognition = true
        self.request = request; active = true; completed = nil
        startedAt = ProcessInfo.processInfo.systemUptime
        task = recognizer.recognitionTask(with: request) { @Sendable [weak self] result, error in
            let text = result?.bestTranscription.formattedString
            let words = result?.bestTranscription.segments.map { segment in
                TimedSpeechWord(text: segment.substring, start: segment.timestamp, end: segment.timestamp + segment.duration,
                                confidence: segment.confidence > 0 ? Double(segment.confidence) : nil)
            } ?? []
            let final = result?.isFinal ?? false
            let failure = error?.localizedDescription
            Task { @MainActor in
                guard let self, self.active else { return }
                if let text, !text.isEmpty {
                    self.onObservation(SpeechObservation(engine: .legacy, text: text, audioStart: 0, audioEnd: words.last?.end ?? 0,
                                                         deliveredAt: self.elapsed, isFinal: final, words: words))
                }
                if final { self.complete(.success(())) }
                else if let failure {
                    self.onFailure(failure)
                    self.complete(.failure(NSError(domain: "CameraCue.Speech", code: 1, userInfo: [NSLocalizedDescriptionKey: failure])))
                }
            }
        }
    }
    public func append(_ buffer: OwnedSpeechBuffer, sourceUptime: Double? = nil) { request?.append(buffer.buffer) }
    public func receiver() -> @Sendable (OwnedSpeechBuffer, Double?) -> Void {
        // Used only by the file feeder on the main actor; live capture has its own
        // synchronous audio-request sink to avoid per-frame actor dispatch.
        return { [weak self] buffer, time in Task { @MainActor in self?.append(buffer, sourceUptime: time) } }
    }
    public func drainInput() async {}
    public func finish() async throws {
        request?.endAudio()
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            if let completed { c.resume(with: completed) } else { waiters.append(c) }
        }
    }
    private func complete(_ result: Result<Void, Error>) {
        guard completed == nil else { return }
        completed = result; active = false
        for waiter in waiters { waiter.resume(with: result) }; waiters = []
    }
    public func stop() { complete(.failure(SpeechSessionError.cancelled)); task?.cancel(); task = nil; request?.endAudio(); request = nil }
    deinit {}
}
